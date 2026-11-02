import Darwin
import Foundation
import FrontportCore

/// Seeding on a Device starts here: the Matches laid out by their iOS seedPaths as Seeding lays them out in Data, but in
/// a folder of Frontport's own under `Devices/`, for `devicectl` to copy. Never a Port's Data on this Mac.
extension ROMStore {
    public func stage(_ version: IOSVersion, into root: URL) async throws -> [StagedSeed] {
        try Self.checkStaging(root, paths: paths)
        let files = files()
        let matches = version.requirements.compactMap { Self.match($0, in: files) }
        return try await Self.stage(matches, into: root)
    }

    /// Refuses a root that isn't a fresh folder inside `Devices/`, by where it resolves: one that exists must be an
    /// empty folder itself, not a link.
    static func checkStaging(_ root: URL, paths: AppPaths) throws {
        let canonical = FileOperations.canonicalPath(root)
        let inside = { (folder: URL) in canonical.hasPrefix(FileOperations.canonicalPath(folder) + "/") }
        guard inside(paths.devices), !inside(paths.containers) else {
            throw FrontportError.fileOperation("ROMs are laid out for iPhone and iPad only inside Frontport’s Devices folder.")
        }
        if FileOperations.exists(root) {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))) ?? []
            guard FileOperations.isDirectory(root), contents.isEmpty else {
                throw FrontportError.fileOperation("\(root.lastPathComponent) isn’t an empty folder to lay ROMs out in.")
            }
        }
    }

    /// Seeds each Match into `root` as into Data, then reads back what it laid out.
    @concurrent
    private static func stage(_ matches: [Match], into root: URL) async throws -> [StagedSeed] {
        var staged: [StagedSeed] = []
        for match in matches {
            try Seeding.seed(match, into: root)
            let (folder, names) = try Seeding.targets(match)
            for (rom, name) in names {
                let path = (folder + [name]).joined(separator: "/")
                let url = root.appending(path: path)
                guard rom.record.isFolder else {
                    let file = DeviceFile(path: path, isDirectory: false, size: try size(of: url))
                    staged.append(
                        StagedSeed(
                            label: match.requirement.label, sha1: rom.record.sha1, fileSHA1: rom.record.fileSHA1, path: path,
                            files: [file]))
                    continue
                }
                let marker = try FileOperations.readRegularFile(url.appending(path: ROMRecord.folderMarker))
                staged.append(
                    StagedSeed(
                        label: match.requirement.label, sha1: rom.record.sha1, fileSHA1: rom.record.fileSHA1, path: path,
                        files: try files(in: url, at: path), marker: String(decoding: marker, as: UTF8.self)))
            }
        }
        return staged
    }

    /// The regular files in the laid-out folder at every depth, its marker left out, with paths below `path`.
    private static func files(in folder: URL, at path: String) throws -> [DeviceFile] {
        let names = FileManager.default.enumerator(atPath: folder.path(percentEncoded: false))?.allObjects as? [String] ?? []
        return try names.sorted().compactMap { name in
            let url = folder.appending(path: name)
            guard name != ROMRecord.folderMarker, FileOperations.isFileOrFolder(url), !FileOperations.isDirectory(url) else {
                return nil
            }
            return DeviceFile(path: "\(path)/\(name)", isDirectory: false, size: try size(of: url))
        }
    }

    private static func size(of url: URL) throws -> Int64 {
        var info = stat()
        guard lstat(url.path(percentEncoded: false), &info) == 0 else {
            throw FrontportError.fileOperation("Couldn’t read \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        return Int64(info.st_size)
    }
}
