import Foundation
import FrontportCore

/// The slow part of adding a ROM: unzipping, standardizing, hashing and staging. Runs off the store's
/// actor, in a work folder the caller owns and removes.
enum Intake {
    /// A file's standard form, hashed but not yet in ROMs.
    struct Candidate: Hashable, Sendable {
        /// The standard form: the user's own file, or a copy in the work folder.
        var file: URL
        /// True when `file` is in the work folder, so it can be moved into ROMs as is.
        var owned: Bool
        var sha1: String
        var format: String
        var size: Int64
        var originalFilename: String
        /// For a folder ROM: the files its identity covers, which are all ROMs keeps.
        var files: [FolderContents.File]? = nil
        /// Why no ROM in the Catalog can have this hash, when Frontport can tell, such as for an NSZ.
        var note: String? = nil
    }

    /// A link (an alias the user picked, say) is followed once, here: everything after reads the file or folder it
    /// leads to, which must be a regular file or a folder. `accepts` says whether the Catalog accepts a hash, which
    /// decides between the standard forms console keys can take.
    @concurrent
    static func prepare(
        _ file: URL, in work: URL, accepts: @Sendable (String) -> Bool = { _ in false }, configs: [Set<String>] = []
    ) async throws -> Candidate {
        let resolved = file.resolvingSymlinksInPath()
        if FileOperations.isDirectory(resolved) { return try folder(resolved, owned: false, accepts: accepts, configs: configs) }
        var rom = try regularFile(file)
        var owned = false
        if rom.pathExtension.lowercased() == "zip" {
            switch try await unzip(rom, into: work) {
            case .file(let unzipped): rom = unzipped
            case .folder(let unzipped):
                return try folder(unzipped, owned: true, named: rom.lastPathComponent, accepts: accepts, configs: configs)
            }
            owned = true
        }
        let format = try ROMFormat.detect(rom)
        switch format.standardization {
        case .none:
            return Candidate(
                file: rom, owned: owned, sha1: try Hashing.sha1(file: rom), format: format.format,
                size: try FileOperations.size(of: rom), originalFilename: rom.lastPathComponent)
        case .contents:
            let identified = try SwitchContents.identify(rom)
            return Candidate(
                file: rom, owned: owned, sha1: identified.sha1, format: identified.format,
                size: try FileOperations.size(of: rom), originalFilename: rom.lastPathComponent, note: identified.note)
        case .keys:
            // The longest form the Catalog accepts, else the whole file's, whose hash a rejection shows.
            let forms = try ConsoleKeys.forms(of: rom)
            let form = forms.first { accepts($0.sha1) } ?? forms[0]
            let standard = work.appending(path: "standard.keys")
            try Data(form.text.utf8).write(to: standard)
            return Candidate(
                file: standard, owned: true, sha1: form.sha1, format: format.format, size: Int64(form.text.utf8.count),
                originalFilename: rom.lastPathComponent)
        case .dropHeader, .swap16, .swap32: break
        }
        let standard = work.appending(path: "standard.\(format.format)")
        let (sha1, size) = try ROMFormat.standardize(rom, format.standardization, into: standard)
        return Candidate(
            file: standard, owned: true, sha1: sha1, format: format.format, size: size,
            originalFilename: rom.lastPathComponent)
    }

    /// A folder an installer held, as a folder ROM, hashed off the caller's actor.
    @concurrent
    static func prepareFolder(
        _ folder: URL, accepts: @Sendable (String) -> Bool = { _ in false }, configs: [Set<String>] = []
    ) async throws -> Candidate {
        try Intake.folder(folder, owned: false, accepts: accepts, configs: configs)
    }

    /// A folder ROM: the game's files under `folder`, without the folders wrapping them. `name` is the zip's it came in.
    /// When the Catalog doesn't accept all of them, it may accept them without the files a Game rewrites (`configs`,
    /// one set per folder ROM that has them), which ROMs then leaves out.
    static func folder(
        _ folder: URL, owned: Bool, named name: String? = nil, accepts: (String) -> Bool = { _ in false },
        configs: [Set<String>] = []
    ) throws -> Candidate {
        let root = try FolderContents.root(of: folder)
        var files = try FolderContents.files(in: root)
        let hashes = try FolderContents.hashes(of: root, files: files)
        var sha1 = FolderContents.identity(of: Array(zip(files.map(\.path), hashes)))
        if !accepts(sha1) {
            for left in configs {
                let kept = zip(files, hashes).filter { !left.contains($0.0.path) }
                guard kept.count < files.count, !kept.isEmpty else { continue }
                let identity = FolderContents.identity(of: kept.map { ($0.0.path, $0.1) })
                guard accepts(identity) else { continue }
                files = kept.map(\.0)
                sha1 = identity
                break
            }
        }
        return Candidate(
            file: root, owned: owned, sha1: sha1, format: ROMRecord.folderFormat, size: files.reduce(0) { $0 + $1.size },
            originalFilename: name ?? root.lastPathComponent, files: files)
    }

    /// A folder ROM Steam installed: just the files its manifests list, whatever else the Game has written beside them,
    /// hashed. When they don't make the ROM `sha1` names, says which files differ from what Steam installed, or that
    /// Steam installed another build.
    @concurrent
    static func steamFolder(_ contents: SteamContents, as sha1: String, appName: String) async throws -> Candidate {
        let folder = contents.folder
        for entry in contents.files {
            var info = stat()
            let path = folder.appending(path: entry.file.path).path(percentEncoded: false)
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                throw FrontportError.romRejected(
                    sha1: nil, reason: "\(entry.file.path) is missing from \(appName). Verify its files in Steam, then add it again.")
            }
        }
        let files = contents.files.map(\.file)
        let hashes = try FolderContents.hashes(of: folder, files: files)
        let identity = FolderContents.identity(of: Array(zip(files.map(\.path), hashes)))
        guard identity == sha1 else {
            let changed = zip(contents.files, hashes).filter { $0.0.sha1 != $0.1 }.map(\.0.file.path)
            guard let first = changed.first else {
                throw FrontportError.romRejected(
                    sha1: identity, reason: "Steam installed another build of \(appName) than the one the Catalog lists.")
            }
            let which = changed.count == 1 ? first : "\(changed.count) files, such as \(first),"
            throw FrontportError.romRejected(
                sha1: identity,
                reason: "\(which) in \(appName) changed since Steam installed it. Verify its files in Steam, then add it again.")
        }
        return Candidate(
            file: folder, owned: false, sha1: identity, format: ROMRecord.folderFormat, size: files.reduce(0) { $0 + $1.size },
            originalFilename: folder.lastPathComponent, files: files)
    }

    /// A file in the work folder holding the candidate, ready to be renamed into ROMs. Clones the user's
    /// file rather than reading it, so even a disc image costs nothing on the same volume. A folder ROM gets
    /// clones of just the files its identity covers. Clones keep their source's permissions, and a CD's files
    /// can be read-only, so they're made writable first: an attribute can't be removed from a read-only file.
    @concurrent
    static func stage(_ candidate: Candidate, in work: URL) async throws -> URL {
        if let files = candidate.files {
            let staged = work.appending(path: "staged.\(candidate.format)", directoryHint: .isDirectory)
            try FolderContents.copy(files, from: candidate.file, to: staged)
            try FileOperations.makeWritable(staged)
            try FileOperations.removeQuarantine(staged)
            return staged
        }
        var staged = candidate.file
        if !candidate.owned {
            staged = work.appending(path: "staged.\(candidate.format)")
            try FileOperations.clone(candidate.file, to: staged)
        }
        _ = try regularFile(staged, following: false)
        try FileOperations.makeWritable(staged)
        try FileOperations.removeQuarantine(staged)
        return staged
    }

    /// The regular file at `url`, with links resolved unless `following` is false; anything else is rejected.
    static func regularFile(_ url: URL, following: Bool = true) throws -> URL {
        let resolved = following ? url.resolvingSymlinksInPath() : url
        var info = stat()
        guard lstat(resolved.path(percentEncoded: false), &info) == 0 else {
            throw FrontportError.romRejected(sha1: nil, reason: "The file couldn’t be read.")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw FrontportError.romRejected(sha1: nil, reason: "\(url.lastPathComponent) isn’t a file.")
        }
        return resolved
    }

    /// What a zip holds: one ROM, or a game's folder of files.
    enum Unzipped {
        case file(URL)
        case folder(URL)
    }

    /// Extracts a zip with `ditto` and returns the one ROM inside, or, when it holds several files and none of them
    /// is a ROM, the folder they're in, as a PC game's zip.
    static func unzip(_ archive: URL, into work: URL) async throws -> Unzipped {
        let folder = work.appending(path: "unzipped", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let result = try await ProcessRunner().run(
            URL(filePath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", archive.path(percentEncoded: false), folder.path(percentEncoded: false)])
        guard result.succeeded else {
            throw FrontportError.romRejected(sha1: nil, reason: "The zip couldn’t be unpacked.")
        }

        let files = regularFiles(in: folder)
        let roms = try files.filter { try ROMFormat.recognize($0) != nil }
        if roms.isEmpty, files.count > 1 { return .folder(folder) }
        // A lone file with an unfamiliar extension may still be a ROM the Catalog lists.
        let chosen = roms.isEmpty && files.count == 1 ? files : roms
        guard chosen.count == 1, let rom = chosen.first else {
            let found = chosen.isEmpty ? "none" : "\(chosen.count)"
            throw FrontportError.romRejected(sha1: nil, reason: "A zip must hold exactly one ROM; this one holds \(found).")
        }
        return .file(rom)
    }

    /// Regular files under `folder`, leaving out symlinks, hidden files and macOS resource forks.
    private static func regularFiles(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent == "__MACOSX" {
                enumerator.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true, values?.isSymbolicLink != true { files.append(url) }
        }
        return files
    }
}
