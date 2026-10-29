import Foundation
import FrontportCore

/// One prebuilt tool in the pinned prefix, verified against a SHA-256 pinned in code.
public struct ToolchainPackage: Hashable, Sendable {
    public enum Archive: String, Hashable, Sendable {
        case tarGz
        case zip
    }

    /// Folder name under `Toolchain/<version>/`, such as "cmake".
    public var name: String
    public var version: String
    public var url: URL
    /// Lowercase hex SHA-256 of the archive.
    public var sha256: String
    public var archive: Archive
    /// Folder inside the archive that becomes `Toolchain/<version>/<name>`; empty for the archive's top level.
    public var root: String
    /// Commands linked into `Toolchain/<version>/bin`: name to path relative to the package folder.
    public var commands: [String: String]

    public init(
        name: String, version: String, url: URL, sha256: String, archive: Archive, root: String = "",
        commands: [String: String]
    ) {
        self.name = name
        self.version = version
        self.url = url
        self.sha256 = sha256
        self.archive = archive
        self.root = root
        self.commands = commands
    }
}

/// The pinned prefix Frontport manages in `Toolchain/<version>/`, next to the Command Line Tools.
///
/// It holds build tools only. Libraries a Port needs are pinned and built by its Recipe, so a Catalog
/// update can change them without a Frontport release.
public struct ToolchainManifest: Hashable, Sendable {
    public var packages: [ToolchainPackage]

    public init(packages: [ToolchainPackage]) { self.packages = packages }

    /// Names the folder, so changing a pin installs a new prefix beside the old one.
    public var version: String { packages.map { "\($0.name)-\($0.version)" }.joined(separator: "+") }

    /// Official universal macOS builds, digests from GitHub's release asset API.
    public static let pinned = ToolchainManifest(packages: [
        ToolchainPackage(
            name: "cmake", version: "4.4.4",
            url: URL(string: "https://github.com/Kitware/CMake/releases/download/v4.4.4/cmake-4.4.4-macos-universal.tar.gz")!,
            sha256: "4b7b73704b1db9b374e5c9ab8e17ac6148b817b6396ee75cd94a852cbac9d305",
            archive: .tarGz, root: "cmake-4.4.4-macos-universal",
            commands: [
                "cmake": "CMake.app/Contents/bin/cmake",
                "ctest": "CMake.app/Contents/bin/ctest",
                "cpack": "CMake.app/Contents/bin/cpack",
            ]),
        ToolchainPackage(
            name: "ninja", version: "1.13.2",
            url: URL(string: "https://github.com/ninja-build/ninja/releases/download/v1.13.2/ninja-mac.zip")!,
            sha256: "c99048673aa765960a99cf10c6ddb9f1fad506099ff0a0e137ad8960a88f321b",
            archive: .zip, commands: ["ninja": "ninja"]),
    ])
}

/// Downloads `url` to `destination` (which must not exist), reporting the fraction received.
public typealias ToolchainDownload = @Sendable (
    _ url: URL, _ destination: URL, _ progress: @escaping @Sendable (Double) -> Void
) async throws -> Void

/// Installs and checks a `ToolchainManifest` under `Toolchain/`.
struct ToolchainInstaller: Sendable {
    let paths: AppPaths
    let manifest: ToolchainManifest
    let download: ToolchainDownload

    var root: URL { paths.toolchain(version: manifest.version) }
    var bin: URL { root.appending(path: "bin", directoryHint: .isDirectory) }
    private var record: URL { root.appending(path: "toolchain.json") }

    private struct Record: Codable {
        var version: String
        var packages: [String: String]
    }

    /// True when the prefix is complete: written last by `install`, and every command still resolves.
    var isInstalled: Bool {
        guard let record = try? JSON.read(Record.self, from: record), record.version == manifest.version else { return false }
        return manifest.packages.allSatisfy { package in
            package.commands.keys.allSatisfy {
                FileManager.default.isExecutableFile(atPath: bin.appending(path: $0).path(percentEncoded: false))
            }
        }
    }

    /// Downloads, verifies and unpacks every package into a staging folder, then moves it into place and
    /// removes prefixes of other versions.
    func install(progress: @escaping ProgressHandler) async throws {
        let fm = FileManager.default
        try FileOperations.createDirectory(paths.toolchain)
        let staging = paths.toolchain.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileOperations.createDirectory(staging)
        defer { try? fm.removeItem(at: staging) }
        let downloads = staging.appending(path: ".downloads", directoryHint: .isDirectory)
        let stagedBin = staging.appending(path: "bin", directoryHint: .isDirectory)
        try FileOperations.createDirectory(downloads)
        try FileOperations.createDirectory(stagedBin)

        let count = Double(manifest.packages.count)
        for (index, package) in manifest.packages.enumerated() {
            try Task.checkCancellation()
            let label = "\(package.name) \(package.version)"
            let base = Double(index) / count
            let archive = downloads.appending(path: "\(package.name).\(package.archive == .zip ? "zip" : "tar.gz")")
            progress(ProgressUpdate(.downloading, fraction: base, message: "Downloading \(label)"))
            try await download(package.url, archive) { fraction in
                progress(ProgressUpdate(.downloading, fraction: base + fraction / count, message: "Downloading \(label)"))
            }

            progress(ProgressUpdate(.verifying, message: "Verifying \(label)"))
            let actual = try Hashing.sha256(file: archive)
            guard actual == package.sha256.lowercased() else {
                throw FrontportError.digestMismatch(asset: package.url.lastPathComponent, expected: package.sha256, actual: actual)
            }

            progress(ProgressUpdate(.extracting, message: "Unpacking \(label)"))
            let unpacked = downloads.appending(path: "\(package.name)-unpacked", directoryHint: .isDirectory)
            try FileOperations.createDirectory(unpacked)
            try await extract(archive, kind: package.archive, into: unpacked)
            let source = package.root.isEmpty ? unpacked : unpacked.appending(path: package.root, directoryHint: .isDirectory)
            let folder = staging.appending(path: package.name, directoryHint: .isDirectory)
            do {
                try fm.moveItem(at: source, to: folder)
            } catch {
                throw FrontportError.extractionFailed("\(package.url.lastPathComponent) has no \(package.root): \(error.localizedDescription)")
            }
            try FileOperations.removeQuarantine(folder)
            for (command, relative) in package.commands {
                let target = folder.appending(path: relative)
                guard fm.isExecutableFile(atPath: target.path(percentEncoded: false)) else {
                    throw FrontportError.extractionFailed("\(package.url.lastPathComponent) has no \(relative)")
                }
                try fm.createSymbolicLink(
                    atPath: stagedBin.appending(path: command).path(percentEncoded: false),
                    withDestinationPath: "../\(package.name)/\(relative)")
            }
        }

        try fm.removeItem(at: downloads)
        let record = Record(
            version: manifest.version,
            packages: Dictionary(uniqueKeysWithValues: manifest.packages.map { ($0.name, $0.sha256) }))
        try JSON.write(record, to: staging.appending(path: "toolchain.json"))
        if fm.fileExists(atPath: root.path(percentEncoded: false)) {
            try fm.removeItem(at: root)
        }
        try fm.moveItem(at: staging, to: root)

        for other in (try? fm.contentsOfDirectory(at: paths.toolchain, includingPropertiesForKeys: nil)) ?? []
        where other.lastPathComponent != manifest.version && !other.lastPathComponent.hasPrefix(".staging-") {
            try? fm.removeItem(at: other)
        }
        progress(ProgressUpdate(.extracting, fraction: 1, message: "Toolchain ready"))
    }

    private func extract(_ archive: URL, kind: ToolchainPackage.Archive, into directory: URL) async throws {
        let result: ProcessResult
        switch kind {
        case .tarGz:
            result = try await ProcessRunner().run(
                URL(fileURLWithPath: "/usr/bin/tar"),
                arguments: ["-xzf", archive.path(percentEncoded: false), "-C", directory.path(percentEncoded: false)])
        case .zip:
            result = try await ProcessRunner().run(
                URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: ["-x", "-k", archive.path(percentEncoded: false), directory.path(percentEncoded: false)])
        }
        guard result.succeeded else {
            throw FrontportError.extractionFailed("\(archive.lastPathComponent): \(result.errorOutput)")
        }
    }

    /// Downloads with URLSession, reporting progress from the task.
    static let urlSession: ToolchainDownload = { url, destination, progress in
        let observer = DownloadObserver(progress)
        let temporary: URL
        let response: URLResponse
        do {
            (temporary, response) = try await URLSession.shared.download(from: url, delegate: observer)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw FrontportError.network("\(url.lastPathComponent): \(error.localizedDescription)")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temporary)
            throw FrontportError.network("\(url.lastPathComponent): HTTP \(http.statusCode)")
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}

/// Forwards a download task's fraction completed.
private final class DownloadObserver: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var observation: NSKeyValueObservation?

    init(_ progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let progress = self.progress
        let observation = task.progress.observe(\.fractionCompleted) { value, _ in
            progress(value.fractionCompleted)
        }
        lock.withLock { self.observation = observation }
    }
}
