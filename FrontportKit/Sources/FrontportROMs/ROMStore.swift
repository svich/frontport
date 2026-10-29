import Darwin
import Foundation
import FrontportCore

/// The user's ROMs: read-only files in standard form at `ROMs/<sha1>.<format>`, listed in `ROMs/index.json`.
///
/// Unzipping, hashing, converting and Seeding run off the actor. Index changes run on it without
/// suspending, so concurrent calls always see, and write, a consistent index.
public actor ROMStore: ROMStoring {
    public nonisolated let paths: AppPaths
    /// Unpacks installers the Catalog lists; without one, they're refused.
    private let unpacker: (any ROMUnpacking)?
    /// Oldest first. Nil until first read from disk.
    private var index: [ROMRecord]?

    public init(paths: AppPaths = .default, unpacker: (any ROMUnpacking)? = nil) {
        self.paths = paths
        self.unpacker = unpacker
    }

    // MARK: Lookup

    /// Every ROM added, newest first.
    func records() -> [ROMRecord] {
        loadedIndex().reversed()
    }

    func record(for sha1: String) -> ROMRecord? {
        loadedIndex().first { $0.sha1 == sha1 }
    }

    func file(for sha1: String) -> ROMFile? {
        guard let record = record(for: sha1) else { return nil }
        let url = paths.rom(for: record)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? ROMFile(record: record, url: url) : nil
    }

    /// The files in ROMs, by SHA-1, as the index lists them.
    private func files() -> [String: ROMFile] {
        Dictionary(loadedIndex().map { ($0.sha1, ROMFile(record: $0, url: paths.rom(for: $0))) }, uniquingKeysWith: { $1 })
    }

    // MARK: Intake

    /// The extensions of the files `add` takes as a ROM of this standard format, such as "z64", "v64" and "n64".
    public nonisolated static func extensions(of format: String) -> [String] { ROMFormat.extensions(of: format) }

    public func add(_ files: [URL], catalog: CatalogDocument) async -> [ROMIntake] {
        var results: [ROMIntake] = []
        for file in files {
            results += await add(file, catalog: catalog)
        }
        return results
    }

    public func assign(_ file: URL, as sha1: String, catalog: CatalogDocument) async -> [ROMIntake] {
        await add(file, catalog: catalog, as: sha1)
    }

    /// One result, or for an installer one per ROM it holds. With `target`, a file the Catalog doesn't list is kept
    /// Unverified as the ROM it names.
    private func add(_ file: URL, catalog: CatalogDocument, as target: String? = nil) async -> [ROMIntake] {
        var sha1: String?
        do {
            try Task.checkCancellation()
            let work = try workFolder()
            // A folder ROM's staged copy is read-only until it's in ROMs.
            defer { try? FileOperations.removeUntrusted(work) }

            let candidate = try await Intake.prepare(file, in: work, accepts: { catalog.listing($0).rom != nil })
            sha1 = candidate.sha1
            let known: KnownROM
            var ownSHA1: String?
            switch catalog.listing(candidate.sha1) {
            case .installer(let installer): return try await unpack(file, candidate, installer, catalog: catalog, in: work)
            case .rom(let rom, _): known = rom
            case .unknown:
                let choices = catalog.assignable(format: candidate.format)
                func reason(_ base: String) -> String { [base, candidate.note].compactMap(\.self).joined(separator: " ") }
                guard let target else {
                    if let existing = unverifiedRecord(candidate.sha1) { return [.duplicate(existing)] }
                    guard !choices.isEmpty else {
                        return [.rejected(file: file, sha1: candidate.sha1, reason: reason(Self.notInCatalog))]
                    }
                    return [.unknown(file: file, sha1: candidate.sha1, format: candidate.format, reason: reason(Self.unlisted))]
                }
                guard let chosen = choices.first(where: { $0.sha1 == target }) else {
                    return [.rejected(file: file, sha1: candidate.sha1, reason: "The Catalog doesn’t take this file as that ROM.")]
                }
                known = chosen
                ownSHA1 = candidate.sha1
            }
            if let existing = presentRecord(known.sha1), !Self.givesWay(existing, to: ownSHA1) { return [.duplicate(existing)] }
            let staged = try await Intake.stage(candidate, in: work)
            return [try commit(staged, candidate, known, ownSHA1: ownSHA1)]
        } catch is CancellationError {
            return [.rejected(file: file, sha1: sha1, reason: "Adding was cancelled.")]
        } catch FrontportError.romRejected(let hash, let reason) {
            return [.rejected(file: file, sha1: hash ?? sha1, reason: reason)]
        } catch {
            return [.rejected(file: file, sha1: sha1, reason: Self.describe(error))]
        }
    }

    /// True when a ROM in ROMs makes way for one being added as the same ROM: an Unverified one, for one the Catalog
    /// lists. Nothing makes way for an Unverified one.
    private static func givesWay(_ existing: ROMRecord, to ownSHA1: String?) -> Bool {
        existing.isUnverified && ownSHA1 == nil
    }

    /// The Unverified ROM whose own standard form has this hash, if its file is still in ROMs.
    private func unverifiedRecord(_ ownSHA1: String) -> ROMRecord? {
        loadedIndex().first { $0.ownSHA1 == ownSHA1 && FileOperations.exists(paths.rom(for: $0)) }
    }

    /// Unpacks an installer and adds the folder ROMs the Catalog says it yields, leaving out everything else it holds.
    /// The installer itself isn't kept.
    private func unpack(
        _ file: URL, _ candidate: Intake.Candidate, _ installer: KnownROM, catalog: CatalogDocument, in work: URL
    ) async throws -> [ROMIntake] {
        guard let unpacker else {
            throw FrontportError.romRejected(sha1: candidate.sha1, reason: "This copy of Frontport can’t unpack installers.")
        }
        let yields = Set(installer.unpack?.yields ?? [])
        var results: [ROMIntake] = []
        let folders = try await unpacker.unpack(candidate.file, as: installer, progress: { _ in })
        // What the installer held, kept ROMs or not, is no use once they're staged or committed here.
        defer { unpacker.discard(installer) }
        for folder in folders {
            try Task.checkCancellation()
            // What else the installer holds, such as an emulator, may well not be a folder ROM at all.
            guard let yielded = try? await Intake.prepareFolder(folder), yields.contains(yielded.sha1),
                let known = catalog.listing(yielded.sha1).rom
            else { continue }
            if let existing = presentRecord(yielded.sha1), !Self.givesWay(existing, to: nil) {
                results.append(.duplicate(existing))
                continue
            }
            let staging = work.appending(path: yielded.sha1, directoryHint: .isDirectory)
            try FileOperations.createDirectory(staging)
            results.append(try commit(try await Intake.stage(yielded, in: staging), yielded, known))
        }
        guard !results.isEmpty else {
            throw FrontportError.romRejected(
                sha1: candidate.sha1, reason: "\(installer.name) held none of the ROMs the Catalog expects from it.")
        }
        return results
    }

    static let unlisted = "No ROM in the Catalog has this hash."

    static let notInCatalog =
        "No Port in the Catalog accepts this ROM. Only the ROMs its Requirements list are accepted, so ROM hacks, other revisions and damaged ROMs aren’t."

    /// Moves a staged file into ROMs and records it, with the Game (or Platform) and name the Catalog gives it, and for
    /// an Unverified ROM its own hash. It takes the place of an Unverified ROM kept as the same ROM. Doesn't suspend, so
    /// it's atomic on the actor.
    private func commit(_ staged: URL, _ candidate: Intake.Candidate, _ known: KnownROM, ownSHA1: String? = nil) throws -> ROMIntake {
        // Another add of the same ROM may have finished while this one was hashing.
        let replaced = presentRecord(known.sha1)
        if let replaced, !Self.givesWay(replaced, to: ownSHA1) { return .duplicate(replaced) }

        let destination = paths.rom(known.sha1, format: candidate.format)
        if candidate.files != nil {
            try FolderContents.protectContents(of: staged)
            // A folder left without a record, or the Unverified one this replaces, can only be this same ROM, but
            // rename won't replace one.
            try FileOperations.removeUntrusted(destination)
            try Self.check(rename(Self.path(staged), Self.path(destination)), "Couldn’t store \(candidate.originalFilename)")
            try Self.check(chmod(Self.path(destination), 0o555), "Couldn’t protect \(candidate.originalFilename)")
        } else {
            // Never follows a link, so only the staged copy can become read-only.
            try Self.check(
                fchmodat(AT_FDCWD, Self.path(staged), 0o444, AT_SYMLINK_NOFOLLOW), "Couldn’t protect \(candidate.originalFilename)")
            // Replaces a file left without a record, or the Unverified one this replaces, which can only be this same ROM.
            try Self.check(rename(Self.path(staged), Self.path(destination)), "Couldn’t store \(candidate.originalFilename)")
        }

        let record = ROMRecord(
            sha1: known.sha1, game: known.game, platform: known.platform, name: known.name,
            format: candidate.format, size: candidate.size,
            added: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)),
            originalFilename: candidate.originalFilename, ownSHA1: ownSHA1)
        var updated = loadedIndex().filter { $0.sha1 != record.sha1 }
        updated.append(record)
        do {
            try save(updated)
        } catch {
            try? Self.removeStored(destination)
            throw error
        }
        // The Unverified ROM this replaced, kept in another format, such as an NSZ an NSP replaces.
        if let replaced, paths.rom(for: replaced) != destination { try? Self.removeStored(paths.rom(for: replaced)) }
        return .added(record)
    }

    // MARK: Removal

    public func remove(_ sha1: String) throws {
        guard let record = record(for: sha1) else { return }
        try save(loadedIndex().filter { $0.sha1 != sha1 })
        try Self.removeStored(paths.rom(for: record))
    }

    /// Removes a file or a folder ROM from ROMs; absent is fine.
    private static func removeStored(_ file: URL) throws {
        if FileOperations.isDirectory(file) {
            try FileOperations.removeUntrusted(file)
        } else if unlink(path(file)) != 0, errno != ENOENT {
            try check(-1, "Couldn’t remove \(file.lastPathComponent)")
        }
    }

    // MARK: Matching

    public func matching(_ entries: [CatalogEntry], installations: [PortID: Installation]) async -> Matching {
        await Self.read(records(), files(), entries: entries, installations: installations, paths: paths)
    }

    public func seed(_ entry: CatalogEntry) async throws {
        try entry.checkIdentity()
        let files = files()
        let matches = entry.requirements(for: .runtime).filter { $0.seedPath != nil }.compactMap { Self.match($0, in: files) }
        try await Self.seed(matches, into: paths.data(for: entry.bundleId))
    }

    @concurrent
    private static func seed(_ matches: [Match], into data: URL) async throws {
        for match in matches {
            try Seeding.seed(match, into: data)
        }
    }

    /// The Requirement's Match among `files`, or nil when it's missing.
    static func match(_ requirement: Requirement, in files: [String: ROMFile]) -> Match? {
        guard let rom = requirement.oneOf.lazy.compactMap({ files[$0] }).first else { return nil }
        return Match(requirement: requirement, rom: rom, extras: requirement.extras.compactMap { files[$0] })
    }

    // MARK: Index

    /// The index, without records whose file is no longer in ROMs.
    private func loadedIndex() -> [ROMRecord] {
        if let index { return index }
        var loaded: [ROMRecord] = []
        if FileManager.default.fileExists(atPath: paths.romIndex.path(percentEncoded: false)) {
            do {
                loaded = try JSON.read([ROMRecord].self, from: paths.romIndex)
            } catch {
                // Keep the unreadable index for inspection; the files themselves are still in ROMs and can be added again.
                let aside = paths.roms.appending(path: "index-unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: paths.romIndex, to: aside)
            }
        }
        loaded = loaded.filter { FileOperations.exists(paths.rom(for: $0)) }
        index = loaded
        return loaded
    }

    /// Reads the index again at the next lookup, for tests that write it themselves.
    func reloadIndex() {
        index = nil
    }

    private func save(_ records: [ROMRecord]) throws {
        do {
            try FileOperations.createDirectory(paths.roms)
            try JSON.write(records, to: paths.romIndex)
        } catch let error as FrontportError {
            throw error
        } catch {
            throw FrontportError.fileOperation("Couldn’t save the ROMs index: \(error.localizedDescription)")
        }
        index = records
    }

    /// The record for a hash whose file is still in ROMs.
    private func presentRecord(_ sha1: String) -> ROMRecord? {
        file(for: sha1)?.record
    }

    /// A private folder on the ROMs volume, so staged files can be renamed into ROMs.
    private func workFolder() throws -> URL {
        try FileOperations.createDirectory(paths.roms)
        return try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: paths.roms, create: true)
    }

    private static func describe(_ error: any Error) -> String {
        (error as? FrontportError)?.errorDescription ?? "The file couldn’t be read. \(error.localizedDescription)"
    }

    private static func path(_ url: URL) -> String { url.path(percentEncoded: false) }

    /// Throws with `errno` when a system call failed.
    static func check(_ result: Int32, _ message: @autoclosure () -> String) throws {
        guard result != 0 else { return }
        let code = errno
        throw FrontportError.fileOperation("\(message()): \(String(cString: strerror(code)))")
    }
}
