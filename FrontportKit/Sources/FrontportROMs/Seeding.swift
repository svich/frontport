import Darwin
import Foundation
import FrontportCore

/// The ROMs in ROMs that meet a Requirement: the accepted ROM it prefers among those there, plus the extras there.
struct Match: Hashable, Sendable {
    var requirement: Requirement
    var rom: ROMFile
    var extras: [ROMFile]
}

/// Places Runtime ROMs into a Port's Data, and says which are there. Blocking: call it off the main actor.
///
/// Frontport runs unsandboxed and the Port can put links anywhere in its Data (macOS itself links the user's
/// home folders there), so Seeding never follows one: it walks to the target folder one opened folder at a time,
/// refusing links, and then works only relative to that open folder. A folder swapped for a link after it was
/// opened can't redirect the write.
///
/// A file ROM is Seeded when the file in its place is tagged with its SHA-1 (ADR 0010), an Unverified ROM's own. One without the tag, such as
/// one Seeded before Frontport tagged them, is compared with the copy in ROMs and tagged when it's the same; anything
/// else in its place, another accepted ROM included, is replaced.
///
/// A folder ROM is Seeded by filling in: its files missing from the target folder are cloned in, and every file or
/// folder already there is left as it is, since the Port may have rewritten it (a PC game keeps its options and saves
/// among its files). Nothing is removed. A marker in the target names the ROM it was filled from, so another release
/// of the game (the full game after its demo, say) gets a folder of its own, and the old one is moved aside whole.
enum Seeding {
    /// The extended attribute naming the ROM a Seeded file holds, by SHA-1.
    static let tag = "dev.frontport.rom"

    /// Where the Match's ROMs go: the folders to them from Data, and each ROM's name there. At a file `seedPath` that's
    /// the accepted ROM alone; in a folder, it and the extras, each as `<sha1>.<format>`.
    static func targets(_ match: Match) throws -> (folder: [String], names: [(rom: ROMFile, name: String)]) {
        let requirement = match.requirement
        let target: SeedTarget?
        do {
            target = try requirement.seedTarget()
        } catch {
            switch error {
            case .outsideData:
                throw FrontportError.fileOperation("The seed path “\(requirement.seedPath ?? "")” isn’t inside the Port’s Data.")
            case .extrasNeedAFolder:
                throw FrontportError.fileOperation("\(requirement.label) has extras, so its seed path must be a folder.")
            }
        }
        switch target {
        case nil:
            throw FrontportError.fileOperation("\(requirement.label) has no seed path.")
        case .file(let folder, let name):
            return (folder, [(match.rom, name)])
        case .folder(let folder):
            return (folder, ([match.rom] + match.extras).map { ($0, "\($0.record.sha1).\($0.record.format)") })
        }
    }

    /// Seeds each of the Match's ROMs that isn't there yet, creating Data and the folders to its place.
    static func seed(_ match: Match, into data: URL) throws {
        let (components, names) = try targets(match)
        try FileOperations.createDirectory(data)
        let folder = try FileOperations.openFolder(components, in: data)
        defer { close(folder) }
        let url = components.reduce(data) { $0.appending(path: $1, directoryHint: .isDirectory) }
        for (rom, name) in names {
            try Task.checkCancellation()
            if holds(name, in: folder, at: url, rom) { continue }
            if rom.record.isFolder {
                try fill(rom, named: name, in: folder)
            } else {
                try place(rom, named: name, in: folder)
            }
        }
    }

    /// The SHA-1s of the Match's ROMs that are Seeded. Creates nothing and follows no link: a place it can't reach
    /// that way holds nothing Seeded.
    static func seeded(_ match: Match, in data: URL) -> Set<String> {
        guard let (components, names) = try? targets(match), let folder = openExisting(components, in: data) else { return [] }
        defer { close(folder) }
        let url = components.reduce(data) { $0.appending(path: $1, directoryHint: .isDirectory) }
        return Set(names.filter { holds($0.name, in: folder, at: url, $0.rom) }.map(\.rom.record.sha1))
    }

    /// True when `name` in the open folder, at `url`, holds the ROM: for a folder ROM, a folder marked as filled from it
    /// with none of its files missing; otherwise a file tagged with it, or one with its exact bytes, which gets the tag.
    private static func holds(_ name: String, in folder: Int32, at url: URL, _ rom: ROMFile) -> Bool {
        if rom.record.isFolder {
            return filledFrom(name, in: folder) == rom.record.fileSHA1
                && FileOperations.holdsEveryFile(of: rom.url, in: url.appending(path: name, directoryHint: .isDirectory))
        }
        // Non-blocking, so a FIFO the Port left there can't hang the open.
        let file = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { return false }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }
        if tagged(file) == rom.record.fileSHA1 { return true }
        guard sameBytes(file, size: info.st_size, as: rom.url) else { return false }
        // Only a later check misses the tag if it can't be set.
        _ = setTag(rom.record.fileSHA1, on: file)
        return true
    }

    /// The SHA-1 a file's tag names, if it has one.
    private static func tagged(_ file: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = fgetxattr(file, tag, &buffer, buffer.count, 0, 0)
        guard count > 0 else { return nil }
        return String(decoding: buffer[..<count], as: UTF8.self)
    }

    private static func setTag(_ sha1: String, on file: Int32) -> Int32 {
        let bytes = Array(sha1.utf8)
        return fsetxattr(file, tag, bytes, bytes.count, 0, 0)
    }

    /// True when the open file, of `size` bytes, holds exactly what the file at `source` does.
    private static func sameBytes(_ file: Int32, size: off_t, as source: URL) -> Bool {
        let original = open(path(source), O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard original >= 0 else { return false }
        defer { close(original) }
        var info = stat()
        guard fstat(original, &info) == 0, info.st_size == size, lseek(file, 0, SEEK_SET) == 0 else { return false }
        let chunk = 1 << 20
        var a = [UInt8](repeating: 0, count: chunk)
        var b = [UInt8](repeating: 0, count: chunk)
        while true {
            let count = read(file, &a, chunk)
            guard count >= 0, readFully(original, &b, count) else { return false }
            if count == 0 { return true }
            guard a.withUnsafeBytes({ x in b.withUnsafeBytes { y in memcmp(x.baseAddress, y.baseAddress, count) == 0 } })
            else { return false }
        }
    }

    /// Reads exactly `count` bytes into the buffer, or for 0, checks the file has nothing more.
    private static func readFully(_ file: Int32, _ buffer: inout [UInt8], _ count: Int) -> Bool {
        if count == 0 { return read(file, &buffer, 1) == 0 }
        var done = 0
        while done < count {
            let got = buffer.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress! + done, count - done) }
            guard got > 0 else { return false }
            done += got
        }
        return true
    }

    /// Opens the folder `components` lead to inside `root`, one component at a time, never creating one or following
    /// a link; nil when that fails.
    private static func openExisting(_ components: [String], in root: URL) -> Int32? {
        var folder = open(path(root), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { return nil }
        for component in components {
            let next = openat(folder, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(folder)
            guard next >= 0 else { return nil }
            folder = next
        }
        return folder
    }

    /// Clones the ROM beside `name` in the open folder, tags it, and renames it over `name`, so the Port never sees a
    /// partial file; a link at `name` is replaced, never followed.
    static func place(_ rom: ROMFile, named name: String, in folder: Int32) throws {
        let temporary = ".\(name).\(UUID().uuidString).seeding"
        try copy(rom.url, to: temporary, in: folder)
        do {
            // The clone inherits the read-only mode of the copy in ROMs; the Port may rewrite its own.
            let file = openat(folder, temporary, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard file >= 0 else { throw failure("Couldn’t open \(name)", errno) }
            let changed = fchmod(file, 0o644)
            var code = errno
            let tagged = changed == 0 ? setTag(rom.record.fileSHA1, on: file) : 0
            if tagged != 0 { code = errno }
            close(file)
            if changed != 0 { throw failure("Couldn’t make \(name) writable", code) }
            if tagged != 0 { throw failure("Couldn’t tag \(name)", code) }
            if renameat(folder, temporary, folder, name) != 0 { throw failure("Couldn’t Seed \(name)", errno) }
        } catch {
            unlinkat(folder, temporary, 0)
            throw error
        }
    }

    /// Fills the folder ROM into the folder `name` in the open folder, then marks it as filled from that ROM. A folder
    /// marked as filled from another ROM is first renamed to `<name> (<its sha1's first 8>)`, with what the Port wrote
    /// there, so two releases' files never mix.
    static func fill(_ rom: ROMFile, named name: String, in parent: Int32) throws {
        if let previous = filledFrom(name, in: parent), previous != rom.record.fileSHA1 {
            var aside = "\(name) (\(previous.prefix(8)))"
            var attempt = 1
            while renameatx_np(parent, name, parent, aside, UInt32(RENAME_EXCL)) != 0 {
                guard errno == EEXIST, attempt < 100 else { throw failure("Couldn’t move \(name) aside", errno) }
                attempt += 1
                aside = "\(name) (\(previous.prefix(8)) \(attempt))"
            }
        }
        try fillContents(rom.url, named: name, in: parent)

        let folder = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw failure("Couldn’t open \(name)", errno) }
        defer { close(folder) }
        let temporary = ".\(ROMRecord.folderMarker).\(UUID().uuidString).seeding"
        let file = openat(folder, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard file >= 0 else { throw failure("Couldn’t mark \(name)", errno) }
        let bytes = Array("\(rom.record.fileSHA1)\n".utf8)
        let written = write(file, bytes, bytes.count)
        close(file)
        // Replaces a marker, or a link the Port left in its place, never following it.
        if written != bytes.count || renameat(folder, temporary, folder, ROMRecord.folderMarker) != 0 {
            let code = errno
            unlinkat(folder, temporary, 0)
            throw failure("Couldn’t mark \(name)", code)
        }
    }

    /// The SHA-1 the marker in the folder `name` names, or nil when there's no folder or no marker there.
    static func filledFrom(_ name: String, in parent: Int32) -> String? {
        let folder = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { return nil }
        defer { close(folder) }
        let file = openat(folder, ROMRecord.folderMarker, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { return nil }
        defer { close(file) }
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = read(file, &buffer, buffer.count)
        guard count > 0 else { return nil }
        return String(decoding: buffer[..<count], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Opens (creating it when missing) the folder `name` in the open folder and clones into it each file of the folder
    /// ROM at `source` that isn't there yet, in any form. A link or a file where a folder should be is refused, as on the
    /// way to the target.
    private static func fillContents(_ source: URL, named name: String, in parent: Int32) throws {
        let created = mkdirat(parent, name, 0o700) == 0
        if !created, errno != EEXIST { throw failure("Couldn’t create \(name)", errno) }
        let folder = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else {
            if errno == ELOOP || errno == ENOTDIR {
                throw FrontportError.fileOperation("Couldn’t use \(name): it’s a symbolic link or not a folder. Delete Data to start over.")
            }
            throw failure("Couldn’t open \(name)", errno)
        }
        defer { close(folder) }
        // mkdirat applies the umask.
        if created, fchmod(folder, 0o700) != 0 { throw failure("Couldn’t set permissions on \(name)", errno) }

        // The folder in ROMs is Frontport's own, read-only, and holds only folders and regular files.
        let names = try FileManager.default.contentsOfDirectory(atPath: path(source))
        for item in names.sorted() {
            try Task.checkCancellation()
            let url = source.appending(path: item)
            if FileOperations.isDirectory(url) {
                try fillContents(url, named: item, in: folder)
                continue
            }
            var info = stat()
            if fstatat(folder, item, &info, AT_SYMLINK_NOFOLLOW) == 0 { continue }
            let temporary = ".\(item).\(UUID().uuidString).seeding"
            try copy(url, to: temporary, in: folder)
            let file = openat(folder, temporary, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            let changed = file >= 0 ? fchmod(file, 0o644) : -1
            let code = errno
            if file >= 0 { close(file) }
            // Never replaces what appeared at the name meanwhile.
            if changed != 0 || renameatx_np(folder, temporary, folder, item, UInt32(RENAME_EXCL)) != 0 {
                let renameCode = errno
                unlinkat(folder, temporary, 0)
                if changed != 0 { throw failure("Couldn’t make \(item) writable", code) }
                if renameCode != EEXIST { throw failure("Couldn’t Seed \(item)", renameCode) }
            }
        }
    }

    /// An APFS clone of `source` at `name` in the folder, or a copy on another volume.
    private static func copy(_ source: URL, to name: String, in folder: Int32) throws {
        if clonefileat(AT_FDCWD, path(source), folder, name, UInt32(CLONE_NOFOLLOW)) == 0 { return }
        guard errno == EXDEV || errno == ENOTSUP || errno == EOPNOTSUPP else {
            throw failure("Couldn’t clone \(source.lastPathComponent)", errno)
        }
        let input = open(path(source), O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw failure("Couldn’t read \(source.lastPathComponent)", errno) }
        defer { close(input) }
        let output = openat(folder, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard output >= 0 else { throw failure("Couldn’t create \(name)", errno) }
        defer { close(output) }
        if fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_DATA)) != 0 {
            let code = errno
            unlinkat(folder, name, 0)
            throw failure("Couldn’t copy \(source.lastPathComponent)", code)
        }
    }

    private static func failure(_ message: String, _ code: Int32) -> FrontportError {
        .fileOperation("\(message): \(String(cString: strerror(code)))")
    }

    private static func path(_ url: URL) -> String {
        var p = url.path(percentEncoded: false)
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
