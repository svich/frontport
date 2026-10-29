import Darwin
import Foundation
import FrontportCore

/// A game that comes as a folder of files rather than one ROM file, such as a PC game's install folder or a demo's
/// zip. It's identified by every file it holds: the SHA-1 of what `shasum` prints for them, one `<sha1>  <path>` line
/// each, sorted by path. So anyone can check it inside the folder:
///
///     find . -type f ! -path '*/.*' ! -path '*/__MACOSX/*' | cut -c3- | LC_ALL=C sort | tr '\n' '\0' | xargs -0 shasum | shasum
///
/// Hidden files and a zip's `__MACOSX` are left out, and so are the folders that only wrap the game, such as the
/// `INTRPLAY/CARMDEMO/` in a zip of an early Carmageddon demo. ROMs keeps exactly the files the identity covers.
enum FolderContents {
    struct File: Hashable, Sendable {
        /// Relative to the folder, `/` between components.
        var path: String
        var size: Int64
    }

    /// The folder the game's files are in: `folder`, or the one folder it holds and nothing else, however deep.
    static func root(of folder: URL) throws -> URL {
        var current = folder
        while true {
            let names = try visibleNames(in: current)
            guard names.count == 1 else { return current }
            let only = current.appending(path: names[0], directoryHint: .isDirectory)
            guard FileOperations.isDirectory(only) else { return current }
            current = only
        }
    }

    /// Every file under `folder`, sorted by path as `LC_ALL=C sort` would. Refuses a link, anything but files and
    /// folders, and a folder with no files, so ROMs never holds anything that could lead outside it.
    static func files(in folder: URL) throws -> [File] {
        var files: [File] = []
        func walk(_ url: URL, _ prefix: String) throws {
            for name in try visibleNames(in: url) {
                let item = url.appending(path: name)
                let path = prefix + name
                guard !name.contains("\n") else { throw rejected("\(path) has a line break in its name.") }
                var info = stat()
                guard lstat(item.path(percentEncoded: false), &info) == 0 else { throw rejected("\(path) couldn’t be read.") }
                switch info.st_mode & S_IFMT {
                case S_IFDIR: try walk(item, path + "/")
                case S_IFREG: files.append(File(path: path, size: Int64(info.st_size)))
                case S_IFLNK: throw rejected("\(path) is a symbolic link. Add the folder the link leads to instead.")
                default: throw rejected("\(path) isn’t a file or a folder.")
                }
            }
        }
        try walk(folder, "")
        guard !files.isEmpty else { throw rejected("\(folder.lastPathComponent) holds no files.") }
        return files.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    }

    /// SHA-1 of `shasum`'s lines for the files, in order.
    static func identity(of folder: URL, files: [File]) throws -> String {
        var lines = ""
        for file in files {
            try Task.checkCancellation()
            lines += "\(try Hashing.sha1(file: folder.appending(path: file.path)))  \(file.path)\n"
        }
        return Hashing.sha1(Data(lines.utf8))
    }

    /// Clones `files` from `folder` into a new folder at `destination`, then refuses the copy unless it holds exactly
    /// them, so a file swapped for a link meanwhile can't reach ROMs.
    static func copy(_ files: [File], from folder: URL, to destination: URL) throws {
        try FileOperations.createDirectory(destination)
        for file in files {
            try Task.checkCancellation()
            let target = destination.appending(path: file.path)
            try FileOperations.createDirectory(target.deletingLastPathComponent())
            try FileOperations.clone(folder.appending(path: file.path), to: target)
        }
        guard try self.files(in: destination) == files else {
            throw rejected("\(folder.lastPathComponent) changed while it was being added.")
        }
    }

    /// Makes every file and folder inside `folder` read-only, never following a link; `folder` itself stays as it is,
    /// so it can still be renamed into ROMs.
    static func protectContents(of folder: URL) throws {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return }
        var folders: [URL] = []
        for case let item as URL in enumerator {
            if FileOperations.isDirectory(item) {
                folders.append(item)
            } else {
                try ROMStore.check(fchmodat(AT_FDCWD, item.path(percentEncoded: false), 0o444, AT_SYMLINK_NOFOLLOW), "Couldn’t protect \(item.lastPathComponent)")
            }
        }
        // Deepest first, so each is still writable while what's inside it changes.
        for item in folders.reversed() {
            try ROMStore.check(fchmodat(AT_FDCWD, item.path(percentEncoded: false), 0o555, AT_SYMLINK_NOFOLLOW), "Couldn’t protect \(item.lastPathComponent)")
        }
    }

    /// Names in the folder, leaving out hidden ones and a zip's `__MACOSX`.
    private static func visibleNames(in folder: URL) throws -> [String] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
                .filter { !$0.hasPrefix(".") && $0 != "__MACOSX" }
                .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        } catch {
            throw rejected("\(folder.lastPathComponent) couldn’t be read.")
        }
    }

    private static func rejected(_ reason: String) -> FrontportError {
        .romRejected(sha1: nil, reason: reason)
    }
}
