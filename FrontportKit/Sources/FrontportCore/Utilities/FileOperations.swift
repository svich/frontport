import Darwin
import Foundation

/// File system primitives the Library, ROMs and Packager share. Blocking: call them off the main actor.
/// Failures throw `FrontportError.fileOperation`.
public enum FileOperations {
    public static let quarantineAttribute = "com.apple.quarantine"

    public enum CloneResult: Hashable, Sendable {
        /// An APFS clone: no extra space until either side changes.
        case cloned
        /// A full copy, because the destination is on another volume or the file system can't clone.
        case copied
    }

    /// Clones a file or directory tree with `clonefile(2)`, falling back to a copy when cloning isn't
    /// possible. Symlinks are cloned as links. `destination` must not exist; its parent must.
    @discardableResult
    public static func clone(_ source: URL, to destination: URL) throws -> CloneResult {
        if clonefile(path(source), path(destination), UInt32(CLONE_NOFOLLOW)) == 0 {
            return .cloned
        }
        let code = errno
        guard code == EXDEV || code == ENOTSUP || code == EOPNOTSUPP else {
            throw failure("Couldn’t clone \(source.lastPathComponent)", code)
        }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw FrontportError.fileOperation("Couldn’t copy \(source.lastPathComponent): \(error.localizedDescription)")
        }
        return .copied
    }

    /// Atomically exchanges two existing paths (files or directories) on the same volume, using
    /// `renamex_np(RENAME_SWAP)`. Afterwards each path holds what the other held.
    public static func swap(_ a: URL, _ b: URL) throws {
        if renamex_np(path(a), path(b), UInt32(RENAME_SWAP)) != 0 {
            throw failure("Couldn’t swap \(a.lastPathComponent) and \(b.lastPathComponent)", errno)
        }
    }

    /// Creates a directory and any missing parents, each with `mode` (0700 by default; macOS doesn't set
    /// it by itself inside containers). Existing directories are left as they are.
    public static func createDirectory(_ url: URL, mode: mode_t = 0o700) throws {
        var missing: [URL] = []
        var current = url.standardizedFileURL
        while !exists(current) {
            missing.append(current)
            let parent = current.deletingLastPathComponent()
            if parent.path(percentEncoded: false) == current.path(percentEncoded: false) { break }
            current = parent
        }
        for directory in missing.reversed() {
            let p = path(directory)
            if mkdir(p, mode) != 0, errno != EEXIST {
                throw failure("Couldn’t create \(directory.lastPathComponent)", errno)
            }
            // mkdir applies the umask.
            if chmod(p, mode) != 0 {
                throw failure("Couldn’t set permissions on \(directory.lastPathComponent)", errno)
            }
        }
    }

    /// Removes `com.apple.quarantine` from the item and, for a directory, everything inside it.
    /// Symlinks are not followed. Only items that carry it are changed, so a read-only folder a build left, which never
    /// had it, passes; removing the attribute from one, even when it's absent, is refused.
    public static func removeQuarantine(_ url: URL) throws {
        try removeQuarantineAttribute(at: url)
        guard isDirectory(url) else { return }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return }
        for case let item as URL in enumerator {
            try removeQuarantineAttribute(at: item)
        }
    }

    private static func removeQuarantineAttribute(at url: URL) throws {
        guard extendedAttribute(quarantineAttribute, at: url) != nil else { return }
        try removeExtendedAttribute(quarantineAttribute, at: url)
    }

    /// Total logical size in bytes of a file, or of every regular file under a directory. Symlinks count as
    /// nothing and aren't followed. Clones count in full.
    public static func size(of url: URL) throws -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        func fileSize(_ item: URL) throws -> Int64 {
            let values = try item.resourceValues(forKeys: keys)
            return values.isRegularFile == true ? Int64(values.fileSize ?? 0) : 0
        }
        guard isDirectory(url) else { return try fileSize(url) }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else {
            return 0
        }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            total += try fileSize(item)
        }
        return total
    }

    /// What a file or folder takes on disk.
    public struct DiskUsage: Hashable, Sendable {
        /// The blocks its regular files have allocated. Clones count in full.
        public var allocated: Int64
        /// The part of `allocated` no other file shares, so removing it frees at least this much: APFS clones share
        /// their blocks until either side changes them.
        public var unshared: Int64
    }

    /// What a file, or every regular file under a folder, takes on disk. Symlinks count as nothing and aren't
    /// followed, and an item that goes away while it's measured counts as nothing.
    public static func usage(of url: URL) throws -> DiskUsage {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        var usage = DiskUsage(allocated: 0, unshared: 0)
        func add(_ item: URL) throws {
            let values = try item.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { return }
            let allocated = Int64(values.totalFileAllocatedSize ?? 0)
            usage.allocated += allocated
            usage.unshared += min(unsharedSize(item) ?? allocated, allocated)
        }
        guard isDirectory(url) else {
            try add(url)
            return usage
        }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else {
            return usage
        }
        for case let item as URL in enumerator {
            try? add(item)
        }
        return usage
    }

    /// The bytes of a file's data no other file shares, or nil where the volume can't tell, as one that can't clone.
    private static func unsharedSize(_ url: URL) -> Int64? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        // The length, the attributes that came back, then the size, packed without padding.
        let returnedSize = MemoryLayout<attribute_set_t>.size
        var buffer = [UInt8](repeating: 0, count: 4 + returnedSize + MemoryLayout<off_t>.size)
        let options = UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW)
        guard getattrlist(path(url), &request, &buffer, buffer.count, options) == 0 else { return nil }
        return buffer.withUnsafeBytes { bytes in
            let returned = bytes.loadUnaligned(fromByteOffset: 4, as: attribute_set_t.self)
            guard returned.forkattr & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0 else { return nil }
            return Int64(bytes.loadUnaligned(fromByteOffset: 4 + returnedSize, as: off_t.self))
        }
    }

    // MARK: Untrusted files

    // Frontport runs unsandboxed, so a link someone else planted (a download, a Recipe, a Port) must never
    // redirect what it reads or writes.

    /// True when `url` is a folder itself, not a link to one.
    public static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(path(url), &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// True when anything is at `url`, a link included, which isn't followed.
    public static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(path(url), &info) == 0
    }

    /// Removes a file or folder someone else wrote, such as a Recipe's build folder, never following a link in it.
    /// Every folder in it is made writable first, so one left read-only doesn't stop the removal. Absent is fine.
    public static func removeUntrusted(_ url: URL) throws {
        guard exists(url) else { return }
        if isDirectory(url) {
            try ownFolder(path(url))
            let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, errorHandler: { _, _ in true })
            // The enumerator reads a folder only when it moves into it, after the loop has made it writable.
            while let item = enumerator?.nextObject() as? URL {
                try ownFolder(path(item))
            }
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw FrontportError.fileOperation("Couldn’t remove \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Gives the owner write access to the item and, for a folder, everything inside it, so a downloaded app can be
    /// changed and signed in place even where upstream shipped read-only files. Links are left alone.
    public static func makeWritable(_ url: URL) throws {
        try ownWrite(path(url))
        guard isDirectory(url) else { return }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return }
        for case let item as URL in enumerator {
            try ownWrite(path(item))
        }
    }

    /// Adds owner write to a file or folder that lacks it; a link is left alone.
    private static func ownWrite(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) != S_IFLNK, info.st_mode & S_IWUSR == 0 else { return }
        if fchmodat(AT_FDCWD, path, (info.st_mode & 0o7777) | S_IWUSR, AT_SYMLINK_NOFOLLOW) != 0 {
            throw failure("Couldn’t make \((path as NSString).lastPathComponent) writable", errno)
        }
    }

    /// Gives the owner full access to a folder itself; a link or anything else is left alone.
    private static func ownFolder(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_mode & S_IRWXU != S_IRWXU else { return }
        if fchmodat(AT_FDCWD, path, (info.st_mode & 0o7777) | S_IRWXU, AT_SYMLINK_NOFOLLOW) != 0 {
            throw failure("Couldn’t make \((path as NSString).lastPathComponent) writable", errno)
        }
    }

    /// True when every file in the folder `source` is at the same path under `target`, in any form, as after a folder
    /// ROM was Seeded there. Only reads: a link in `target` may decide the answer, never what's written.
    public static func holdsEveryFile(of source: URL, in target: URL) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path(source)) else { return false }
        return names.allSatisfy { name in
            let item = source.appending(path: name)
            let counterpart = target.appending(path: name)
            return isDirectory(item) ? holdsEveryFile(of: item, in: counterpart) : exists(counterpart)
        }
    }

    /// True when `url` is a regular file or a folder itself, not a link or anything else.
    public static func isFileOrFolder(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(path(url), &info) == 0 else { return false }
        return [S_IFREG, S_IFDIR].contains(info.st_mode & S_IFMT)
    }

    /// Refuses an untrusted file or folder that could lead Frontport outside it: `url` must be a regular file or
    /// a folder, not a link, and inside a folder nothing may be a special file (a FIFO, socket or device), and every
    /// link must lead somewhere inside it twice over: followed beneath `url` one link at a time (`resolvesBeneath`),
    /// and by where it finally resolves. So a link that leads out and back, through a link someone else controls, is
    /// refused too.
    ///
    /// `allowing` names the links that may lead out, by their paths inside the folder and their exact destinations.
    /// Only the Packager passes any, for the links it has just made itself (`PortLinks`), and no other link may lead
    /// through one.
    public static func refuseEscapingLinks(in url: URL, allowing allowed: [String: String] = [:]) throws {
        let name = url.lastPathComponent
        var info = stat()
        guard lstat(path(url), &info) == 0 else { throw failure("Couldn’t read \(name)", errno) }
        switch info.st_mode & S_IFMT {
        case S_IFREG: return
        case S_IFDIR: break
        case S_IFLNK: throw FrontportError.fileOperation("\(name) is a symbolic link.")
        default: throw FrontportError.fileOperation("\(name) isn’t a file or folder.")
        }
        guard let root = realPath(path(url)),
            let enumerator = FileManager.default.enumerator(atPath: path(url))
        else { throw FrontportError.fileOperation("Couldn’t read \(name).") }
        // The enumerator lists links without descending into them.
        for case let relative as String in enumerator {
            let item = path(url) + "/" + relative
            guard lstat(item, &info) == 0 else { throw failure("Couldn’t read \(relative) in \(name)", errno) }
            switch info.st_mode & S_IFMT {
            case S_IFREG:
                continue
            case S_IFDIR:
                // The enumerator skips a folder it can't read, and the links in it with it.
                guard access(item, R_OK | X_OK) == 0 else { throw failure("Couldn’t read \(relative) in \(name)", errno) }
            case S_IFLNK:
                let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: item)
                if let destination, allowed[relative] == destination { continue }
                guard resolvesBeneath(relative, in: path(url), avoiding: Set(allowed.keys)),
                    let target = linkTarget(item), target == root || target.hasPrefix(root + "/")
                else {
                    throw FrontportError.fileOperation("\(name) holds a symbolic link that leads outside it: \(relative).")
                }
            default:
                throw FrontportError.fileOperation("\(name) holds a special file: \(relative).")
            }
        }
    }

    /// The most links `resolvesBeneath` follows for one path before it gives up, as on a loop.
    private static let maxLinks = 40

    /// True when `relative` inside the folder at `root` resolves without ever leaving it, followed one component at a
    /// time as `openat2` does with `RESOLVE_BENEATH`: every link on the way is read and expanded from its own folder.
    /// False when a link's text on the way is absolute, when ".." would climb above `root`, when the way is or passes
    /// through a link `avoiding` names, or after `maxLinks` links. Past a component that doesn't exist, the rest is
    /// read without the file system; one that can't be read refuses.
    private static func resolvesBeneath(_ relative: String, in root: String, avoiding avoided: Set<String>) -> Bool {
        let avoided = Set(avoided.map { $0.lowercased() })
        var position: [Substring] = []
        var pending = Array(relative.split(separator: "/").reversed())
        var links = 0
        var info = stat()
        while let component = pending.popLast() {
            if component == "." { continue }
            if component == ".." {
                guard !position.isEmpty else { return false }
                position.removeLast()
                continue
            }
            position.append(component)
            let path = position.joined(separator: "/")
            // Compared without case, as the volume may.
            guard !avoided.contains(path.lowercased()) else { return false }
            guard lstat(root + "/" + path, &info) == 0 else {
                guard errno == ENOENT || errno == ENOTDIR else { return false }
                continue
            }
            guard (info.st_mode & S_IFMT) == S_IFLNK else { continue }
            links += 1
            guard links <= maxLinks, let text = try? FileManager.default.destinationOfSymbolicLink(atPath: root + "/" + path),
                !text.hasPrefix("/")
            else { return false }
            position.removeLast()
            pending.append(contentsOf: text.split(separator: "/").reversed())
        }
        return true
    }

    /// Every symbolic link inside a folder, by its path relative to the folder, with its destination. None is
    /// followed, so a link inside a linked folder isn't listed.
    public static func links(in folder: URL) throws -> [String: String] {
        guard let enumerator = FileManager.default.enumerator(atPath: path(folder)) else {
            throw FrontportError.fileOperation("Couldn’t read \(folder.lastPathComponent).")
        }
        var result: [String: String] = [:]
        var info = stat()
        for case let relative as String in enumerator {
            let item = path(folder) + "/" + relative
            guard lstat(item, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK else { continue }
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: item) else {
                throw FrontportError.fileOperation("Couldn’t read \(relative) in \(folder.lastPathComponent).")
            }
            result[relative] = destination
        }
        return result
    }

    /// Opens the folder `components` lead to inside `root`, a Port's Data, creating missing folders with mode 0700,
    /// and refusing any that is a link or not a folder: each is opened from the one before, so a folder swapped for a
    /// link meanwhile can't lead outside `root`. The caller closes the descriptor.
    public static func openFolder(_ components: [String], in root: URL) throws -> Int32 {
        var folder = open(path(root), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw refusal(root.lastPathComponent, errno) }
        for (index, component) in components.enumerated() {
            let created = mkdirat(folder, component, 0o700) == 0
            if !created, errno != EEXIST {
                let code = errno
                close(folder)
                throw failure("Couldn’t create \(component)", code)
            }
            let next = openat(folder, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let code = errno
            close(folder)
            guard next >= 0 else {
                throw refusal(components[...index].joined(separator: "/") + " in \(root.lastPathComponent)", code)
            }
            // mkdirat applies the umask.
            if created, fchmod(next, 0o700) != 0 {
                let code = errno
                close(next)
                throw failure("Couldn’t set permissions on \(component)", code)
            }
            folder = next
        }
        return folder
    }

    /// Creates the folders `components` lead to inside `root` as `openFolder` does, never following a link.
    public static func createFolders(_ components: [String], in root: URL) throws {
        close(try openFolder(components, in: root))
    }

    /// Opening a folder failed: a link gets its own message, since that's the case `openFolder` guards against, with
    /// the way out of it: Delete Data clears whatever the Port left.
    private static func refusal(_ name: String, _ code: Int32) -> FrontportError {
        if code == ELOOP || code == ENOTDIR {
            return .fileOperation("Couldn’t use \(name): it’s a symbolic link or not a folder. Delete Data to start over.")
        }
        return failure("Couldn’t open \(name)", code)
    }

    /// Opens a file for appending, creating it with mode 0644 if needed. Refuses a link or anything but a regular
    /// file.
    public static func openForAppending(_ url: URL) throws -> FileHandle {
        try openRegularFile(url, flags: O_WRONLY | O_APPEND | O_CREAT)
    }

    /// The contents of a regular file. Refuses a link or anything else.
    public static func readRegularFile(_ url: URL) throws -> Data {
        let handle = try openRegularFile(url, flags: O_RDONLY)
        defer { try? handle.close() }
        do {
            return try handle.readToEnd() ?? Data()
        } catch {
            throw FrontportError.fileOperation("Couldn’t read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private static func openRegularFile(_ url: URL, flags: Int32) throws -> FileHandle {
        let name = url.lastPathComponent
        // O_NONBLOCK: opening a FIFO mustn't wait for a writer.
        let fd = open(path(url), flags | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            if errno == ELOOP { throw FrontportError.fileOperation("\(name) is a symbolic link.") }
            throw failure("Couldn’t open \(name)", errno)
        }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw FrontportError.fileOperation("\(name) isn’t a regular file.")
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Where a link leads, with every link on the way resolved. A dangling link's target is worked out from its
    /// text.
    private static func linkTarget(_ link: String) -> String? {
        if let resolved = realPath(link) { return resolved }
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link),
            let parent = realPath((link as NSString).deletingLastPathComponent)
        else { return nil }
        let joined = destination.hasPrefix("/") ? destination : parent + "/" + destination
        return URL(filePath: joined).standardized.path(percentEncoded: false)
    }

    /// The canonical path of the deepest part of `url` that exists, with the rest appended as it is.
    public static func canonicalPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while true {
            if let resolved = realPath(path(existing)) {
                return rest.reversed().reduce(resolved) { ($0 == "/" ? "" : $0) + "/" + $1 }
            }
            guard existing.pathComponents.count > 1 else { return path(url) }
            rest.append(existing.lastPathComponent)
            existing = existing.deletingLastPathComponent()
        }
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: Extended attributes

    /// The attribute's value, or nil when absent. Doesn't follow symlinks.
    public static func extendedAttribute(_ name: String, at url: URL) -> Data? {
        let p = path(url)
        let length = getxattr(p, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard length >= 0 else { return nil }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { getxattr(p, name, $0.baseAddress, length, 0, XATTR_NOFOLLOW) }
        return read >= 0 ? data.prefix(read) : nil
    }

    public static func setExtendedAttribute(_ name: String, _ value: Data, at url: URL) throws {
        let result = value.withUnsafeBytes { setxattr(path(url), name, $0.baseAddress, value.count, 0, XATTR_NOFOLLOW) }
        if result != 0 { throw failure("Couldn’t set \(name) on \(url.lastPathComponent)", errno) }
    }

    /// Removes an attribute; absent is fine.
    public static func removeExtendedAttribute(_ name: String, at url: URL) throws {
        if removexattr(path(url), name, XATTR_NOFOLLOW) != 0, errno != ENOATTR {
            throw failure("Couldn’t remove \(name) from \(url.lastPathComponent)", errno)
        }
    }

    // MARK: Helpers

    /// File system path without a trailing slash, which some syscalls reject for new paths.
    private static func path(_ url: URL) -> String {
        var p = url.path(percentEncoded: false)
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    private static func failure(_ message: String, _ code: Int32) -> FrontportError {
        .fileOperation("\(message): \(String(cString: strerror(code)))")
    }
}
