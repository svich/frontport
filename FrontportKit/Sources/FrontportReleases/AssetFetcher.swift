import Foundation
import FrontportCore
import Synchronization

/// The Fetcher: downloads a Release's asset into `Downloads/`, verifies it against GitHub's SHA-256 digest,
/// unpacks it and hands back the .app inside. Nothing unverified is ever unpacked.
public actor AssetFetcher: AssetFetching {
    private let paths: AppPaths
    private let session: URLSession
    private let runner: ProcessRunner

    public init(paths: AppPaths, session: URLSession = AssetFetcher.defaultSession, runner: ProcessRunner = ProcessRunner()) {
        self.paths = paths
        self.session = session
        self.runner = runner
    }

    public static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        return URLSession(configuration: configuration)
    }()

    /// Downloads (or reuses a cached copy whose digest matches), verifies, unpacks into a fresh temporary
    /// folder, moves the single top-level .app into `directory` (replacing an app of the same name) and
    /// strips quarantine from it. Returns the app's new location. An app holding a link that leads out of it is
    /// refused, since everything after runs unsandboxed and would follow it.
    public func fetch(_ release: Release, into directory: URL, progress: @escaping ProgressHandler) async throws -> URL {
        guard let asset = release.asset else {
            throw FrontportError.assetNotFound(release.port, pattern: release.tag)
        }
        guard let expected = asset.sha256?.lowercased() else {
            throw FrontportError.digestMissing(asset: asset.name)
        }
        guard !asset.name.isEmpty, !asset.name.contains("/"), !asset.name.hasPrefix(".") else {
            throw FrontportError.extractionFailed("“\(asset.name)” isn’t a usable file name.")
        }

        let archive = try await download(asset, for: release.port, expected: expected, progress: progress)

        try FileOperations.createDirectory(directory)
        // On the destination's volume, so the final move is a rename.
        let work = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: directory, create: true)
        // A disk image's apps can hold read-only folders, which would stop a plain removal part way.
        defer { try? FileOperations.removeUntrusted(work) }

        let app = try await Unpacker(runner: runner, progress: progress).app(in: archive, work: work)
        try Task.checkCancellation()

        let destination = directory.appending(path: app.lastPathComponent, directoryHint: .isDirectory)
        do {
            if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: app, to: destination)
        } catch {
            throw FrontportError.fileOperation("Couldn’t move \(app.lastPathComponent) into place: \(error.localizedDescription)")
        }
        do {
            guard FileOperations.isDirectory(destination) else {
                throw FrontportError.appNotFound("\(app.lastPathComponent) isn’t an app folder.")
            }
            try FileOperations.refuseEscapingLinks(in: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        // A read-only file, such as UZDoom's libraries, keeps its quarantine flag otherwise.
        try FileOperations.makeWritable(destination)
        try FileOperations.removeQuarantine(destination)
        return destination
    }

    /// The verified archive in `Downloads/<port>/`.
    private func download(
        _ asset: ReleaseAsset, for port: PortID, expected: String, progress: @escaping ProgressHandler
    ) async throws -> URL {
        let file = paths.download(asset, for: port)
        let folder = file.deletingLastPathComponent()
        try FileOperations.createDirectory(folder)

        if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
            progress(ProgressUpdate(.verifying, message: asset.name))
            if (try? Hashing.sha256(file: file)) == expected { return file }
            try? FileManager.default.removeItem(at: file)
        }

        let partial = folder.appending(path: ".\(asset.name).\(UUID().uuidString).part")
        defer { try? FileManager.default.removeItem(at: partial) }

        progress(ProgressUpdate(.downloading, fraction: 0, message: asset.name))
        let reporter = ByteProgress(name: asset.name, progress: progress)
        try await Download.run(
            asset.url, to: partial, name: asset.name, session: session, expectedSize: asset.size,
            onBytes: { reporter.report(received: $0, total: $1) })

        progress(ProgressUpdate(.verifying, message: asset.name))
        let actual = try Hashing.sha256(file: partial)
        guard actual == expected else {
            throw FrontportError.digestMismatch(asset: asset.name, expected: expected, actual: actual)
        }
        try? FileManager.default.removeItem(at: file)
        do {
            try FileManager.default.moveItem(at: partial, to: file)
        } catch {
            throw FrontportError.fileOperation("Couldn’t save \(asset.name): \(error.localizedDescription)")
        }
        return file
    }
}

/// Turns byte counts into `.downloading` updates, at most one per percent.
private final class ByteProgress: Sendable {
    private let name: String
    private let progress: ProgressHandler
    private let lastPercent = Mutex(-1)

    init(name: String, progress: @escaping ProgressHandler) {
        self.name = name
        self.progress = progress
    }

    func report(received: Int64, total: Int64) {
        guard total > 0 else {
            progress(ProgressUpdate(.downloading, message: "\(name): \(received.formatted(.byteCount(style: .file)))"))
            return
        }
        let fraction = min(Double(received) / Double(total), 1)
        let percent = Int(fraction * 100)
        let changed = lastPercent.withLock { last in
            guard percent > last else { return false }
            last = percent
            return true
        }
        guard changed else { return }
        let message = "\(received.formatted(.byteCount(style: .file))) of \(total.formatted(.byteCount(style: .file)))"
        progress(ProgressUpdate(.downloading, fraction: fraction, message: message))
    }
}
