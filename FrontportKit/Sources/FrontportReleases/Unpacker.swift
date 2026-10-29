import Darwin
import Foundation
import FrontportCore

/// Archive formats the Fetcher unpacks, recognized by file name.
enum ArchiveFormat: Hashable, Sendable {
    case zip, tar, dmg

    init?(name: String) {
        let name = name.lowercased()
        if name.hasSuffix(".zip") {
            self = .zip
        } else if name.hasSuffix(".dmg") {
            self = .dmg
        } else if [".tar", ".tar.gz", ".tgz", ".tar.xz", ".txz", ".tar.bz2", ".tbz", ".tbz2"].contains(where: name.hasSuffix) {
            self = .tar
        } else {
            return nil
        }
    }
}

/// Unpacks a downloaded archive, recursing into archives inside it, and finds the one top-level .app.
struct Unpacker: Sendable {
    /// How many archives deep to look, such as a dmg inside a zip.
    static let maxDepth = 3

    private static let ditto = URL(filePath: "/usr/bin/ditto")
    private static let tar = URL(filePath: "/usr/bin/tar")
    private static let hdiutil = URL(filePath: "/usr/bin/hdiutil")

    let runner: ProcessRunner
    let progress: ProgressHandler

    /// Unpacks `archive` into folders under `work`, an empty folder, and returns the .app inside.
    func app(in archive: URL, work: URL) async throws -> URL {
        let apps = try await unpack(archive, work: work, depth: 0)
        guard let app = apps.first else { throw FrontportError.appNotFound(archive.lastPathComponent) }
        guard apps.count == 1 else {
            let names = apps.map(\.lastPathComponent).joined(separator: ", ")
            throw FrontportError.extractionFailed("\(archive.lastPathComponent) holds more than one app: \(names).")
        }
        return app
    }

    private func unpack(_ archive: URL, work: URL, depth: Int) async throws -> [URL] {
        guard let format = ArchiveFormat(name: archive.lastPathComponent) else {
            throw FrontportError.extractionFailed("\(archive.lastPathComponent) isn’t a zip, tar or dmg archive.")
        }
        try Task.checkCancellation()
        let destination = work.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileOperations.createDirectory(destination)
        progress(ProgressUpdate(.extracting, message: archive.lastPathComponent))

        switch format {
        case .zip:
            try await run(Self.ditto, ["-x", "-k", path(archive), path(destination)])
        case .tar:
            try await run(Self.tar, ["-x", "-f", path(archive), "-C", path(destination)])
        case .dmg:
            try await copyOut(of: archive, into: destination, work: work)
        }

        let found = Self.contents(of: destination)
        if !found.apps.isEmpty || depth >= Self.maxDepth { return found.apps }
        var apps: [URL] = []
        for nested in found.archives {
            apps += try await unpack(nested, work: work, depth: depth + 1)
        }
        return apps
    }

    // MARK: Disk images

    /// Attaches the image read-only, copies its apps (or, failing that, its archives) into `destination`,
    /// and always detaches it, cancelled or not.
    ///
    /// An image with a license agreement can't be attached without someone accepting it (hdiutil prompts, and
    /// cancels on end of input), so it is first converted to a plain image, which carries no agreement.
    private func copyOut(of original: URL, into destination: URL, work: URL) async throws {
        var image = original
        if try await hasLicenseAgreement(original) {
            progress(ProgressUpdate(.extracting, message: "Converting \(original.lastPathComponent)"))
            image = work.appending(path: "\(UUID().uuidString).cdr")
            try await run(Self.hdiutil, ["convert", path(original), "-quiet", "-format", "UDTO", "-o", path(image)])
        }
        defer { if image != original { try? FileManager.default.removeItem(at: image) } }
        do {
            // Under /private/tmp, hdiutil makes a fresh folder per mount and removes it on detach. Volumes
            // mounted inside the TemporaryItems folder the work folder lives in can't be read (EPERM).
            let result = try await run(Self.hdiutil, [
                "attach", "-nobrowse", "-readonly", "-noautoopen", "-mountrandom", "/private/tmp", "-plist", path(image),
            ])
            let mountPoints = Self.mountPoints(fromAttachOutput: result.stdout)
            guard !mountPoints.isEmpty else {
                throw FrontportError.extractionFailed("\(image.lastPathComponent) has no volume to open.")
            }
            progress(ProgressUpdate(.extracting, message: "Copying from \(image.lastPathComponent)"))
            for mountPoint in mountPoints {
                let found = Self.contents(of: mountPoint)
                for item in found.apps.isEmpty ? found.archives : found.apps {
                    let target = destination.appending(path: item.lastPathComponent)
                    if FileManager.default.fileExists(atPath: path(target)) { continue }
                    try await run(Self.ditto, [path(item), path(target)])
                }
            }
        } catch {
            await Self.detach(image, runner: runner)
            throw error
        }
        await Self.detach(image, runner: runner)
    }

    /// Detaches every attachment of `image`, found through `hdiutil info` so an attach interrupted by
    /// cancellation is cleaned up too. Runs detached from the caller, whose cancellation would stop it.
    private static func detach(_ image: URL, runner: ProcessRunner) async {
        await Task.detached {
            guard let info = try? await runner.run(hdiutil, arguments: ["info", "-plist"], stderr: .discard),
                info.succeeded
            else { return }
            for device in devices(attachedFrom: image, infoOutput: info.stdout) {
                // A volume just mounted can be busy for a moment (indexing, scanning), so try a few times first.
                for attempt in 0..<3 {
                    let detached = try? await runner.run(hdiutil, arguments: ["detach", device], stdout: .discard, stderr: .discard)
                    if detached?.succeeded == true { break }
                    if attempt == 2 {
                        _ = try? await runner.run(
                            hdiutil, arguments: ["detach", "-force", device], stdout: .discard, stderr: .discard)
                    } else {
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                }
            }
        }.value
    }

    private func hasLicenseAgreement(_ image: URL) async throws -> Bool {
        let result = try await run(Self.hdiutil, ["imageinfo", "-plist", path(image)])
        return Self.hasLicenseAgreement(imageInfoOutput: result.stdout)
    }

    static func hasLicenseAgreement(imageInfoOutput output: Data) -> Bool {
        let properties = propertyList(output)?["Properties"] as? [String: Any]
        return properties?["Software License Agreement"] as? Bool == true
    }

    static func mountPoints(fromAttachOutput output: Data) -> [URL] {
        guard let plist = propertyList(output), let entities = plist["system-entities"] as? [[String: Any]] else {
            return []
        }
        return entities.compactMap { $0["mount-point"] as? String }.map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    /// Whole-disk devices (`/dev/diskN`) of the images attached from `image`, matched by file identity since
    /// hdiutil reports resolved paths.
    static func devices(attachedFrom image: URL, infoOutput output: Data) -> [String] {
        guard let target = fileIdentity(image), let plist = propertyList(output),
            let images = plist["images"] as? [[String: Any]]
        else { return [] }
        return images.flatMap { attached -> [String] in
            guard let imagePath = attached["image-path"] as? String,
                fileIdentity(URL(filePath: imagePath)) == target,
                let entities = attached["system-entities"] as? [[String: Any]]
            else { return [] }
            return entities.compactMap { $0["dev-entry"] as? String }
                .filter { $0.wholeMatch(of: /\/dev\/disk\d+/) != nil }
        }
    }

    private static func propertyList(_ data: Data) -> [String: Any]? {
        // hdiutil can print notices before the plist.
        guard let start = data.firstRange(of: Data("<?xml".utf8)) else { return nil }
        let xml = data[start.lowerBound...]
        return (try? PropertyListSerialization.propertyList(from: xml, format: nil)) as? [String: Any]
    }

    private struct FileIdentity: Equatable {
        var device: dev_t
        var inode: ino_t
    }

    private static func fileIdentity(_ url: URL) -> FileIdentity? {
        var info = stat()
        guard stat(url.path(percentEncoded: false), &info) == 0 else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }

    // MARK: Contents

    struct Contents {
        /// .app bundles not inside another bundle.
        var apps: [URL] = []
        /// Archives outside any .app.
        var archives: [URL] = []
    }

    /// Apps and archives under `root`. Symlinks are never followed, so a disk image's `Applications` link
    /// isn't searched, and hidden files and `__MACOSX` are skipped.
    static func contents(of root: URL) -> Contents {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
        var result = Contents()
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return result }
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else {
                continue
            }
            if values.isDirectory == true {
                if item.lastPathComponent == "__MACOSX" {
                    enumerator.skipDescendants()
                } else if item.pathExtension.lowercased() == "app" {
                    result.apps.append(item)
                    enumerator.skipDescendants()
                }
            } else if values.isRegularFile == true, ArchiveFormat(name: item.lastPathComponent) != nil {
                result.archives.append(item)
            }
        }
        result.apps.sort { $0.path < $1.path }
        result.archives.sort { $0.path < $1.path }
        return result
    }

    // MARK: Helpers

    @discardableResult
    private func run(_ tool: URL, _ arguments: [String]) async throws -> ProcessResult {
        let result = try await runner.run(tool, arguments: arguments)
        guard result.succeeded else {
            let output = (result.errorOutput.isEmpty ? result.output : result.errorOutput)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw FrontportError.extractionFailed(
                "\(tool.lastPathComponent) \(arguments.first ?? "") failed (exit status \(result.status)). \(output)")
        }
        return result
    }

    private func path(_ url: URL) -> String { url.path(percentEncoded: false) }
}
