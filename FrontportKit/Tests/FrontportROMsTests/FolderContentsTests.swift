import Foundation
import FrontportCore
import Testing
@testable import FrontportROMs

@Suite struct FolderContentsTests {
    /// A PC game's files, as its zip holds them under `INTRPLAY/CARMDEMO/`.
    static let game: [String: Data] = [
        "CARMA.EXE": Synthetic.noise(4 << 10, seed: 1),
        "DATA/GENERAL.TXT": Data("general\n".utf8),
        "DATA/OPTIONS.TXT": Data("options\n".utf8),
        "DATA/ACTORS/EAGLE.ACT": Synthetic.noise(8 << 10, seed: 2),
        "DATA/A.TXT": Data("sorted before DATA/ACTORS by its dot\n".utf8),
    ]

    /// Writes `files` under `folder` in the scratch folder, with a hidden file and a `__MACOSX` beside them.
    func folder(_ name: String, _ files: [String: Data] = game, in tmp: TemporaryDirectory) throws -> URL {
        for (path, data) in files { try tmp.file("\(name)/\(path)", data) }
        try tmp.file("\(name)/.DS_Store", Data("finder".utf8))
        try tmp.file("\(name)/DATA/__MACOSX/._GENERAL.TXT", Data("fork".utf8))
        return tmp.url.appending(path: name, directoryHint: .isDirectory)
    }

    /// Zips `folder` with `ditto`, keeping the folder itself, as Finder's Compress does.
    func zip(_ folder: URL, as name: String, in tmp: TemporaryDirectory) throws -> URL {
        let archive = tmp.url.appending(path: name)
        let ditto = Process()
        ditto.executableURL = URL(filePath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", folder.path(percentEncoded: false), archive.path(percentEncoded: false)]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        return archive
    }

    /// The identity as the shell computes it, per `FolderContents`' documentation.
    func shellIdentity(of folder: URL) throws -> String {
        let shell = Process()
        let output = Pipe()
        shell.executableURL = URL(filePath: "/bin/sh")
        shell.currentDirectoryURL = folder
        shell.arguments = [
            "-c",
            "find . -type f ! -path '*/.*' ! -path '*/__MACOSX/*' | cut -c3- | LC_ALL=C sort | tr '\\n' '\\0' | xargs -0 shasum | shasum",
        ]
        shell.standardOutput = output
        try shell.run()
        shell.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return String(text.prefix(40))
    }

    func identity(of folder: URL) throws -> String {
        try FolderContents.identity(of: folder, files: FolderContents.files(in: folder))
    }

    @Test func identityIsWhatTheShellPrintsAndLeavesOutHiddenFiles() throws {
        let tmp = try TemporaryDirectory()
        let game = try folder("CARMDEMO", in: tmp)

        let files = try FolderContents.files(in: game)

        #expect(files.map(\.path) == ["CARMA.EXE", "DATA/A.TXT", "DATA/ACTORS/EAGLE.ACT", "DATA/GENERAL.TXT", "DATA/OPTIONS.TXT"])
        #expect(try identity(of: game) == shellIdentity(of: game))
    }

    @Test func wrappingFoldersAreLeftOut() throws {
        let tmp = try TemporaryDirectory()
        let game = try folder("INTRPLAY/CARMDEMO", in: tmp)
        try tmp.file("INTRPLAY/.hidden", Data())

        let root = try FolderContents.root(of: tmp.url.appending(path: "INTRPLAY"))

        #expect(root.lastPathComponent == "CARMDEMO")
        #expect(try identity(of: root) == identity(of: game))
    }

    @Test func anyChangedFileChangesTheIdentity() throws {
        let tmp = try TemporaryDirectory()
        let original = try identity(of: folder("a", in: tmp))
        var saved = Self.game
        saved["DATA/SAVEGAME/SAVE0"] = Data("save".utf8)
        var renamed = Self.game
        renamed["DATA/general.txt"] = renamed.removeValue(forKey: "DATA/GENERAL.TXT")

        #expect(try identity(of: folder("b", saved, in: tmp)) != original)
        #expect(try identity(of: folder("c", renamed, in: tmp)) != original)
    }

    @Test func linksAndEmptyFoldersAreRefused() throws {
        let tmp = try TemporaryDirectory()
        let linked = try folder("linked", in: tmp)
        try FileManager.default.createSymbolicLink(at: linked.appending(path: "DATA/OUT"), withDestinationURL: tmp.url)
        let empty = tmp.url.appending(path: "empty/DATA", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        #expect(throws: FrontportError.self) { try FolderContents.files(in: linked) }
        #expect(throws: FrontportError.self) { try FolderContents.files(in: tmp.url.appending(path: "empty")) }
    }

    @Test func aFolderAndItsZipAreTheSameROMKeptReadOnly() async throws {
        let tmp = try TemporaryDirectory()
        let game = try folder("INTRPLAY/CARMDEMO", in: tmp)
        let sha1 = try identity(of: game)
        let archive = try zip(tmp.url.appending(path: "INTRPLAY"), as: "CARMDEMO.ZIP", in: tmp)
        let store = ROMStore(paths: tmp.paths)
        let catalog = Catalogs.accepting([sha1], game: "carmageddon", format: ROMRecord.folderFormat)

        let zipped = await store.add([archive], catalog: catalog)
        let dropped = await store.add([tmp.url.appending(path: "INTRPLAY")], catalog: catalog)

        let record = try #require(zipped.first?.addedRecord)
        #expect(dropped.first?.duplicateRecord == record)
        #expect(record.sha1 == sha1)
        #expect(record.format == "folder")
        #expect(record.isFolder)
        #expect(record.originalFilename == "CARMDEMO.ZIP")
        #expect(record.size == Int64(Self.game.values.reduce(0) { $0 + $1.count }))

        let stored = tmp.paths.rom(sha1, format: "folder")
        #expect(try FolderContents.files(in: stored) == FolderContents.files(in: game))
        #expect(try FileManager.default.contentsOfDirectory(atPath: stored.path(percentEncoded: false)).sorted() == ["CARMA.EXE", "DATA"])
        #expect(try mode(of: stored) == 0o555)
        #expect(try mode(of: stored.appending(path: "DATA/ACTORS")) == 0o555)
        #expect(try mode(of: stored.appending(path: "DATA/GENERAL.TXT")) == 0o444)

        try await store.remove(sha1)
        #expect(!FileManager.default.fileExists(atPath: stored.path(percentEncoded: false)))
        #expect(await store.records().isEmpty)
    }

    /// bsdtar leaves a CD's files as the disc has them, readable by their owner alone.
    @Test func aCDsReadOnlyFilesAreAddedAndLeftAsTheyAre() async throws {
        let tmp = try TemporaryDirectory()
        let game = try folder("FALLOUT", in: tmp)
        let file = game.appending(path: "DATA/GENERAL.TXT")
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path(percentEncoded: false))
        let sha1 = try identity(of: game)
        let store = ROMStore(paths: tmp.paths)

        let results = await store.add([game], catalog: Catalogs.accepting([sha1], game: "fallout", format: ROMRecord.folderFormat))

        #expect(results.first?.addedRecord?.sha1 == sha1)
        #expect(try mode(of: tmp.paths.rom(sha1, format: "folder").appending(path: "DATA/GENERAL.TXT")) == 0o444)
        #expect(try mode(of: file) == 0o400)
    }

    @Test func aFolderNoPortAcceptsIsRejectedWithItsHash() async throws {
        let tmp = try TemporaryDirectory()
        let game = try folder("CARMDEMO", in: tmp)
        let store = ROMStore(paths: tmp.paths)

        let results = await store.add([game], catalog: Catalogs.accepting([]))

        let rejection = try #require(results.first?.rejection)
        #expect(rejection.sha1 == (try identity(of: game)))
        #expect(rejection.reason == ROMStore.notInCatalog)
        #expect(await store.records().isEmpty)
    }

    // MARK: Seeding

    /// A store holding the demo, dethrace accepting it at `seedPath`, its Data, and the demo in ROMs.
    func seeded(seedPath: String, in tmp: TemporaryDirectory) async throws -> (ROMStore, CatalogEntry, URL, URL) {
        let game = try folder("CARMDEMO", in: tmp)
        let sha1 = try identity(of: game)
        let store = ROMStore(paths: tmp.paths)
        _ = await store.add([game], catalog: Catalogs.accepting([sha1], game: "carmageddon", format: ROMRecord.folderFormat))
        let requirement = Requirement(label: "Carmageddon", stage: .runtime, oneOf: [sha1], seedPath: seedPath)
        let data = tmp.paths.data(for: "dev.frontport.port.dethrace")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let entry = Catalogs.entry("dethrace", game: "carmageddon", requirements: [requirement])
        return (store, entry, data, tmp.paths.rom(sha1, format: ROMRecord.folderFormat))
    }

    func isSeeded(_ store: ROMStore, _ entry: CatalogEntry) async -> Bool {
        let installed = [entry.id: Catalogs.installation(entry)]
        return await store.matching([entry], installations: installed)[entry.id]?.unseeded.isEmpty == true
    }

    @Test func seedingFillsInMissingFilesAndKeepsThePortsOwn() async throws {
        let tmp = try TemporaryDirectory()
        let (store, entry, data, stored) = try await seeded(seedPath: "Library/Application Support/dethrace", in: tmp)
        let folder = data.appending(path: "Library/Application Support/dethrace", directoryHint: .isDirectory)

        try await store.seed(entry)
        #expect(FileOperations.holdsEveryFile(of: stored, in: folder))
        #expect(await isSeeded(store, entry))
        for (path, contents) in Self.game {
            #expect(try Data(contentsOf: folder.appending(path: path)) == contents)
        }
        #expect(try mode(of: folder.appending(path: "DATA/OPTIONS.TXT")) == 0o644)
        #expect(try mode(of: folder.appending(path: "DATA/ACTORS")) == 0o700)

        // The Port rewrites its options, saves a game and deletes a file; another Seeding restores only the file.
        try Data("mine\n".utf8).write(to: folder.appending(path: "DATA/OPTIONS.TXT"))
        try tmp.file("Containers/dev.frontport.port.dethrace/Data/Library/Application Support/dethrace/DATA/SAVEGAME/SAVE0", Data("save".utf8))
        try FileManager.default.removeItem(at: folder.appending(path: "DATA/ACTORS/EAGLE.ACT"))
        #expect(!FileOperations.holdsEveryFile(of: stored, in: folder))
        #expect(await !isSeeded(store, entry))

        try await store.seed(entry)

        #expect(try Data(contentsOf: folder.appending(path: "DATA/OPTIONS.TXT")) == Data("mine\n".utf8))
        #expect(try Data(contentsOf: folder.appending(path: "DATA/SAVEGAME/SAVE0")) == Data("save".utf8))
        #expect(try Data(contentsOf: folder.appending(path: "DATA/ACTORS/EAGLE.ACT")) == Self.game["DATA/ACTORS/EAGLE.ACT"])
        #expect(try Data(contentsOf: stored.appending(path: "DATA/OPTIONS.TXT")) == Self.game["DATA/OPTIONS.TXT"])
    }

    @Test func seedingNeverWritesThroughALinkThePortLeft() async throws {
        let tmp = try TemporaryDirectory()
        let (store, entry, data, _) = try await seeded(seedPath: "game", in: tmp)
        let outside = tmp.url.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: data.appending(path: "game"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: data.appending(path: "game/CARMA.EXE"), withDestinationURL: outside.appending(path: "x"))
        try FileManager.default.createSymbolicLink(at: data.appending(path: "game/DATA"), withDestinationURL: outside)

        await #expect(throws: FrontportError.self) { try await store.seed(entry) }

        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path(percentEncoded: false)).isEmpty)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: data.appending(path: "game/CARMA.EXE").path(percentEncoded: false)).hasSuffix("outside/x"))
    }

    @Test func anotherReleaseGetsAFolderOfItsOwnAndTheFirstIsMovedAside() async throws {
        let tmp = try TemporaryDirectory()
        var full = Self.game
        full["DATA/GENERAL.TXT"] = Data("the full game\n".utf8)
        full["DATA/RACES/CITYA1.TXT"] = Data("a race the demo lacks\n".utf8)
        let demoFolder = try folder("demo", in: tmp)
        let fullFolder = try folder("full", full, in: tmp)
        let (demo, game) = (try identity(of: demoFolder), try identity(of: fullFolder))
        let store = ROMStore(paths: tmp.paths)
        let catalog = Catalogs.accepting([game, demo], game: "carmageddon", format: ROMRecord.folderFormat)
        let requirement = Requirement(label: "Carmageddon", stage: .runtime, oneOf: [game, demo], seedPath: "dethrace")
        let entry = Catalogs.entry("dethrace", game: "carmageddon", requirements: [requirement])
        let data = tmp.paths.data(for: "dev.frontport.port.dethrace")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let target = data.appending(path: "dethrace", directoryHint: .isDirectory)
        func marker(_ folder: URL) throws -> String {
            try String(contentsOf: folder.appending(path: ROMRecord.folderMarker), encoding: .utf8)
        }

        // The demo first, played once.
        _ = await store.add([demoFolder], catalog: catalog)
        try await store.seed(entry)
        try Data("demo options\n".utf8).write(to: target.appending(path: "DATA/OPTIONS.TXT"))
        #expect(try marker(target) == "\(demo)\n")

        // Then the full game: the Requirement prefers it, so it gets the folder, and the demo's moves aside whole.
        _ = await store.add([fullFolder], catalog: catalog)
        #expect(await !isSeeded(store, entry))
        try await store.seed(entry)

        let aside = data.appending(path: "dethrace (\(demo.prefix(8)))", directoryHint: .isDirectory)
        #expect(try marker(target) == "\(game)\n")
        #expect(try Data(contentsOf: target.appending(path: "DATA/GENERAL.TXT")) == full["DATA/GENERAL.TXT"])
        #expect(try Data(contentsOf: target.appending(path: "DATA/OPTIONS.TXT")) == full["DATA/OPTIONS.TXT"])
        #expect(try marker(aside) == "\(demo)\n")
        #expect(try Data(contentsOf: aside.appending(path: "DATA/OPTIONS.TXT")) == Data("demo options\n".utf8))
        #expect(!FileManager.default.fileExists(atPath: aside.appending(path: "DATA/RACES").path(percentEncoded: false)))

        // Seeding the same release again only fills in.
        #expect(await isSeeded(store, entry))
        try await store.seed(entry)
        #expect(try FileManager.default.contentsOfDirectory(atPath: data.path(percentEncoded: false)).sorted() == ["dethrace", "dethrace (\(demo.prefix(8)))"])
    }

    @Test func aFolderSeedPathTakesEachFolderROMByItsHash() async throws {
        let tmp = try TemporaryDirectory()
        let (store, entry, data, stored) = try await seeded(seedPath: "games/", in: tmp)

        try await store.seed(entry)

        let folder = data.appending(path: "games/\(stored.lastPathComponent)", directoryHint: .isDirectory)
        #expect(try Data(contentsOf: folder.appending(path: "DATA/GENERAL.TXT")) == Self.game["DATA/GENERAL.TXT"])
        #expect(await isSeeded(store, entry))
    }
}
