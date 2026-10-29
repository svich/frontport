import Foundation
import FrontportCore
import Testing
@testable import FrontportROMs

/// Leaves the given folders in its own output folder, as an unpack Recipe would.
struct FakeUnpacker: ROMUnpacking {
    let output: URL
    let folders: [String: [String: Data]]

    func unpack(_ installer: URL, as rom: KnownROM, progress: @escaping ProgressHandler) async throws -> [URL] {
        for (folder, files) in folders {
            for (path, data) in files {
                let file = output.appending(path: "\(folder)/\(path)")
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file)
            }
        }
        return folders.keys.sorted().map { output.appending(path: $0, directoryHint: .isDirectory) }
    }

    func discard(_ rom: KnownROM) {
        try? FileManager.default.removeItem(at: output)
    }
}

@Suite struct InstallerTests {
    static let game = FolderContentsTests.game
    static let support: [String: Data] = ["app/DOSBOX/dosbox.exe": Synthetic.noise(2 << 10, seed: 9)]

    /// A Catalog listing an installer that yields one folder ROM, which a Port's Requirement accepts.
    func catalog(installer: String, yields game: String) -> CatalogDocument {
        let unpack = Unpack(recipe: "recipes/innoextract.sh", recipeSHA256: String(repeating: "a", count: 64), yields: [game])
        return CatalogDocument(
            issued: Date(timeIntervalSince1970: 0),
            platforms: [Platform(id: "dos", name: "MS-DOS", shortName: "DOS", medium: .file)],
            games: [Game(id: "carmageddon", name: "Carmageddon", platform: "dos")],
            roms: [
                KnownROM(sha1: installer, game: nil, platform: "dos", name: "Max Pack installer (GOG)", format: "exe", unpack: unpack),
                KnownROM(sha1: game, game: "carmageddon", name: "Max Pack (GOG)", format: ROMRecord.folderFormat),
            ],
            ports: [Catalogs.entry("dethrace", game: "carmageddon", requirements: [
                Requirement(label: "Carmageddon", stage: .runtime, oneOf: [game], seedPath: "Library/Application Support/dethrace"),
            ])])
    }

    func gameIdentity(in tmp: TemporaryDirectory) throws -> String {
        for (path, data) in Self.game { try tmp.file("expected/CARMA/\(path)", data) }
        let folder = tmp.url.appending(path: "expected/CARMA", directoryHint: .isDirectory)
        return try FolderContents.identity(of: folder, files: FolderContents.files(in: folder))
    }

    @Test func anInstallerAddsTheFolderROMsItYieldsAndIsNotKept() async throws {
        let tmp = try TemporaryDirectory()
        let installer = try tmp.file("setup_carmageddon.exe", Synthetic.noise(64 << 10, seed: 4))
        let sha1 = try Hashing.sha1(file: installer)
        let game = try gameIdentity(in: tmp)
        let unpacker = FakeUnpacker(
            output: tmp.url.appending(path: "out", directoryHint: .isDirectory),
            folders: ["CARMA": Self.game, "__support": Self.support])
        let store = ROMStore(paths: tmp.paths, unpacker: unpacker)

        let results = await store.add([installer], catalog: catalog(installer: sha1, yields: game))

        let record = try #require(results.first?.addedRecord)
        #expect(results.count == 1)
        #expect(record.sha1 == game)
        #expect(record.isFolder)
        #expect(record.name == "Max Pack (GOG)")
        #expect(record.game == "carmageddon")
        #expect(await store.records().map(\.sha1) == [game])
        #expect(!FileManager.default.fileExists(atPath: tmp.paths.rom(sha1, format: "exe").path(percentEncoded: false)))
        // Nothing the installer held is kept outside ROMs, which still holds every file of the game.
        #expect(!FileManager.default.fileExists(atPath: unpacker.output.path(percentEncoded: false)))
        let stored = tmp.paths.rom(game, format: ROMRecord.folderFormat)
        #expect(try FolderContents.identity(of: stored, files: FolderContents.files(in: stored)) == game)

        let again = await store.add([installer], catalog: catalog(installer: sha1, yields: game))
        #expect(again.map(\.duplicateRecord) == [record])
    }

    @Test func anInstallerIsRefusedWithoutAnUnpackerOrTheROMsItShouldHold() async throws {
        let tmp = try TemporaryDirectory()
        let installer = try tmp.file("setup_carmageddon.exe", Synthetic.noise(64 << 10, seed: 4))
        let sha1 = try Hashing.sha1(file: installer)
        let game = try gameIdentity(in: tmp)
        let document = catalog(installer: sha1, yields: game)

        let unable = await ROMStore(paths: tmp.paths).add([installer], catalog: document)
        #expect(unable.count == 1)
        #expect(unable.first?.rejection?.sha1 == sha1)
        #expect(unable.first?.rejection?.reason.contains("can’t unpack") == true)

        var altered = Self.game
        altered["DATA/GENERAL.TXT"] = Data("patched\n".utf8)
        let unpacker = FakeUnpacker(output: tmp.url.appending(path: "out", directoryHint: .isDirectory), folders: ["CARMA": altered])
        let store = ROMStore(paths: tmp.paths, unpacker: unpacker)
        let empty = await store.add([installer], catalog: document)
        #expect(empty.count == 1)
        #expect(empty.first?.rejection?.reason.contains("held none of the ROMs") == true)
        #expect(await store.records().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: unpacker.output.path(percentEncoded: false)))
    }
}
