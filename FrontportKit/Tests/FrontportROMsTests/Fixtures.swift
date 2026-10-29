import Foundation
import FrontportCore

/// A unique scratch folder, removed when the test drops it.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "FrontportROMsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    // Folder ROMs and some tests leave read-only folders, which a plain removal stops at.
    deinit { try? FileOperations.removeUntrusted(url) }

    var paths: AppPaths {
        AppPaths(
            root: url.appending(path: "Frontport", directoryHint: .isDirectory),
            containers: url.appending(path: "Containers", directoryHint: .isDirectory))
    }

    @discardableResult
    func file(_ name: String, _ data: Data) throws -> URL {
        let file = url.appending(path: name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        return file
    }

    /// Zips files into `name` with `ditto`, as Finder's Compress does.
    func zip(_ name: String, _ files: [String: Data]) throws -> URL {
        let folder = url.appending(path: "zip-\(UUID().uuidString)", directoryHint: .isDirectory)
        for (fileName, data) in files {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appending(path: fileName))
        }
        let archive = url.appending(path: name)
        let ditto = Process()
        ditto.executableURL = URL(filePath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", folder.path(percentEncoded: false), archive.path(percentEncoded: false)]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        return archive
    }
}

func mode(of url: URL) throws -> Int {
    try (FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.posixPermissions] as? Int) ?? -1
}

/// Synthetic ROMs: the right magic and headers, deterministic noise for the rest.
enum Synthetic {
    static let n64Magic: [UInt8] = [0x80, 0x37, 0x12, 0x40]

    static func noise(_ count: Int, seed: UInt64) -> Data {
        var data = Data(count: count)
        var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        data.withUnsafeMutableBytes { bytes in
            for offset in stride(from: 0, to: count - count % 8, by: 8) {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                bytes.storeBytes(of: state, toByteOffset: offset, as: UInt64.self)
            }
        }
        return data
    }

    /// A big-endian (`.z64`) N64 image, 8 MiB by default.
    static func z64(size: Int = 8 << 20, seed: UInt64 = 1) -> Data {
        var data = noise(size, seed: seed)
        data.replaceSubrange(0..<4, with: n64Magic)
        return data
    }

    /// `.v64`: 16-bit byte-swapped.
    static func v64(_ z64: Data) -> Data { swapped(z64, unit: 2) }

    /// `.n64`: 32-bit little-endian words.
    static func n64(_ z64: Data) -> Data { swapped(z64, unit: 4) }

    static func swapped(_ data: Data, unit: Int) -> Data {
        var bytes = [UInt8](data)
        bytes.withUnsafeMutableBufferPointer { b in
            var offset = 0
            while offset + unit <= b.count {
                b.swapAt(offset, offset + unit - 1)
                if unit == 4 { b.swapAt(offset + 1, offset + 2) }
                offset += unit
            }
        }
        return Data(bytes)
    }

    /// A headerless SNES image, 1 MiB by default.
    static func sfc(size: Int = 1 << 20, seed: UInt64 = 2) -> Data { noise(size, seed: seed) }

    /// The 512-byte header SNES copiers prepend.
    static func copierHeadered(_ sfc: Data) -> Data { Data(repeating: 0xAA, count: 512) + sfc }

    /// A headerless NES image: 32 KiB PRG plus 8 KiB CHR.
    static func nes(seed: UInt64 = 3) -> Data { noise(40 << 10, seed: seed) }

    /// The 16-byte iNES header ("NES\x1A", 2 PRG banks, 1 CHR bank).
    static func iNES(_ nes: Data) -> Data {
        Data([0x4E, 0x45, 0x53, 0x1A, 0x02, 0x01, 0x01, 0x00] + [UInt8](repeating: 0, count: 8)) + nes
    }

    static func sha1(_ data: Data) -> String { Hashing.sha1(data) }
}

/// Catalogs for intake tests.
enum Catalogs {
    static func entry(_ id: PortID, game: GameID, requirements: [Requirement]) -> CatalogEntry {
        CatalogEntry(
            id: id, name: id.rawValue, kind: .decomp, game: game, developer: "Test", summary: "", description: "",
            source: URL(string: "https://example.org/\(id)")!, bundleId: id.conventionalBundleID,
            releases: .githubRelease(GitHubReleaseSource(repo: "example/\(id)", asset: "*.zip")),
            requirements: requirements)
    }

    /// A source-built entry whose Build Assets are made in `format`.
    static func sourceBuilt(_ id: PortID, game: GameID, requirements: [Requirement], format: String = "1") -> CatalogEntry {
        var entry = entry(id, game: game, requirements: requirements)
        entry.releases = .git(GitSource(repo: "example/\(id)", refs: [.stable: "v1"], recipe: "recipes/\(id).sh", recipeSHA256: ""))
        entry.buildAssets = BuildAssetsSpec(path: "Contents/Resources/assets", format: format)
        return entry
    }

    /// The entry installed, with Build Assets made from `builtFrom` in `format` when given.
    static func installation(_ entry: CatalogEntry, builtFrom: [String]? = nil, format: String = "1") -> Installation {
        Installation(
            port: entry.id, release: Release(port: entry.id, version: "1.0"), channel: .stable, installedAt: Date(),
            appName: "\(entry.id).app", buildAssets: builtFrom.map { BuildAssetsRecord(roms: $0, format: format) },
            entry: entry)
    }

    /// A Catalog that knows `roms` (all for one N64 Game) and has one Port accepting them plus `requirementOnly`.
    static func accepting(
        _ roms: [String], requirementOnly: [String] = [], game: GameID = "ocarina-of-time", format: String = "z64"
    ) -> CatalogDocument {
        let known = roms.enumerated().map { KnownROM(sha1: $1, game: game, name: "Dump \($0)", format: format) }
        let requirement = Requirement(label: "Ocarina of Time", stage: .runtime, oneOf: roms + requirementOnly, seedPath: "roms/")
        return CatalogDocument(
            issued: Date(timeIntervalSince1970: 0),
            platforms: [Platform(id: "n64", name: "Nintendo 64", shortName: "N64", medium: .cartridge)],
            games: [Game(id: game, name: "The Legend of Zelda: Ocarina of Time", platform: "n64")],
            roms: known,
            ports: [entry("shipwright", game: game, requirements: [requirement])])
    }
}

extension ROMIntake {
    var addedRecord: ROMRecord? {
        if case .added(let record) = self { return record }
        return nil
    }

    var duplicateRecord: ROMRecord? {
        if case .duplicate(let record) = self { return record }
        return nil
    }

    var rejection: (sha1: String?, reason: String)? {
        if case .rejected(_, let sha1, let reason) = self { return (sha1, reason) }
        return nil
    }

    var unknown: (sha1: String, format: String, reason: String)? {
        if case .unknown(_, let sha1, let format, let reason) = self { return (sha1, format, reason) }
        return nil
    }
}
