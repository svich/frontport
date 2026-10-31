import Foundation
import FrontportCore
import Testing
@testable import FrontportROMs

@Suite struct SteamTests {
    /// Half-Life's `valve` folder as Steam installs it, with the `config.cfg` the game rewrites.
    static let valve: [String: Data] = [
        "valve/liblist.gam": Data("game \"Half-Life\"\n".utf8),
        "valve/config.cfg": Data("bind w +forward\n".utf8),
        "valve/halflife.wad": Synthetic.noise(8 << 10, seed: 1),
        "valve/maps/c0a0.bsp": Synthetic.noise(16 << 10, seed: 2),
        "valve/empty.txt": Data(),
    ]
    /// Beside it in the same install folder, and in the same depot: another app's.
    static let gearbox: [String: Data] = ["gearbox/liblist.gam": Data("game \"Opposing Force\"\n".utf8)]

    /// A Steam folder holding Half-Life, app 70, as depot 1, with its app manifest and depot manifest.
    func steam(in tmp: TemporaryDirectory, state: String = "4") throws -> SteamLibrary {
        let root = tmp.url.appending(path: "Steam", directoryHint: .isDirectory)
        try tmp.file("Steam/steamapps/libraryfolders.vdf", Data("""
            "libraryfolders"
            {
            \t"0"
            \t{
            \t\t"path"\t\t"\(root.path(percentEncoded: false))"
            \t}
            }
            """.utf8))
        try tmp.file("Steam/steamapps/appmanifest_70.acf", Data("""
            "AppState"
            {
            \t"appid"\t\t"70"
            \t"name"\t\t"Half-Life"
            \t"StateFlags"\t\t"\(state)"
            \t"installdir"\t\t"Half-Life"
            \t"buildid"\t\t"15961492"
            \t"InstalledDepots"
            \t{
            \t\t"1"
            \t\t{
            \t\t\t"manifest"\t\t"2667117727132184734"
            \t\t\t"size"\t\t"0"
            \t\t}
            \t}
            }
            """.utf8))
        let files = Self.valve.merging(Self.gearbox) { $1 }
        for (path, data) in files { try tmp.file("Steam/steamapps/common/Half-Life/\(path)", data) }
        try tmp.file("Steam/depotcache/1_2667117727132184734.manifest", Self.manifest(files, configs: ["valve/config.cfg"]))
        return SteamLibrary(root: root)
    }

    /// A depot manifest of `files`, as Steam writes one: Windows separators, a folder's own mapping, all zeros as an
    /// empty file's SHA-1, and Steam's user-config flag on `configs`.
    static func manifest(_ files: [String: Data], configs: Set<String> = []) -> Data {
        var payload = Data()
        var folders: Set<String> = []
        for (path, data) in files.sorted(by: { $0.key < $1.key }) {
            let parent = (path as NSString).deletingLastPathComponent
            if !parent.isEmpty, folders.insert(parent).inserted {
                payload += field(1, mapping(parent, size: 0, flags: 64, sha1: Data(count: 20)))
            }
            let sha1 = data.isEmpty ? Data(count: 20) : Data(hex: Hashing.sha1(data))
            payload += field(1, mapping(path, size: data.count, flags: configs.contains(path) ? 1 : 0, sha1: sha1))
        }
        let metadata = varintField(1, 1) + varintField(2, 2_667_117_727_132_184_734)
        return section(0x71F6_17D0, payload) + section(0x1F48_12BE, metadata) + section(0x1B81_B817, Data())
            + littleEndian(0x32C4_15AB)
    }

    static func mapping(_ path: String, size: Int, flags: UInt64, sha1: Data) -> Data {
        field(1, Data(path.replacingOccurrences(of: "/", with: "\\").utf8)) + varintField(2, UInt64(size))
            + varintField(3, flags) + field(4, Data(count: 20)) + field(5, sha1)
    }

    static func varint(_ value: UInt64) -> Data {
        var value = value
        var bytes = Data()
        repeat {
            bytes.append(UInt8(value & 0x7F) | (value > 0x7F ? 0x80 : 0))
            value >>= 7
        } while value > 0
        return bytes
    }

    static func field(_ number: UInt64, _ bytes: Data) -> Data { varint(number << 3 | 2) + varint(UInt64(bytes.count)) + bytes }
    static func varintField(_ number: UInt64, _ value: UInt64) -> Data { varint(number << 3) + varint(value) }
    static func littleEndian(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    static func section(_ magic: UInt32, _ body: Data) -> Data { littleEndian(magic) + littleEndian(UInt32(body.count)) + body }

    /// The identity of `files` under `valve/`, less `config.cfg`.
    static var valveIdentity: String {
        let files = valve.filter { $0.key != "valve/config.cfg" }
            .map { (path: String($0.key.dropFirst("valve/".count)), sha1: Hashing.sha1($0.value)) }
            .sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        return FolderContents.identity(of: files)
    }

    func catalog(_ sha1: String = valveIdentity) -> CatalogDocument {
        CatalogDocument(
            issued: Date(timeIntervalSince1970: 0),
            platforms: [Platform(id: "windows", name: "Windows", shortName: "Windows", medium: .file)],
            games: [Game(id: "half-life", name: "Half-Life", platform: "windows")],
            roms: [
                KnownROM(
                    sha1: sha1, game: "half-life", name: "Steam: the valve folder", format: ROMRecord.folderFormat,
                    configs: ["config.cfg"], steam: KnownROM.Steam(app: 70, folder: "valve"))
            ],
            ports: [Catalogs.entry("xash3d-half-life", game: "half-life", requirements: [
                Requirement(label: "Half-Life", stage: .runtime, oneOf: [sha1], seedPath: "Library/Application Support/Xash3D FWGS/valve"),
            ])])
    }

    @Test func manifestsListFilesWithTheirHashesAndLeaveOutConfigs() throws {
        let tmp = try TemporaryDirectory()
        let steam = try steam(in: tmp)
        let app = try #require(steam.apps().first)
        #expect(app.id == 70)
        #expect(app.name == "Half-Life")
        #expect(app.depots == [SteamLibrary.Depot(id: 1, manifest: "2667117727132184734")])

        let contents = try steam.contents(of: app, folder: "valve", leaving: ["config.cfg"])
        #expect(contents.files.map(\.file.path) == ["empty.txt", "halflife.wad", "liblist.gam", "maps/c0a0.bsp"])
        #expect(contents.files.first?.sha1 == Hashing.sha1(Data()))
        #expect(contents.sha1 == Self.valveIdentity)
    }

    @Test func anAppStillUpdatingIsNotInstalled() throws {
        let tmp = try TemporaryDirectory()
        #expect(try steam(in: tmp, state: "6").apps().isEmpty)
    }

    @Test func anInstalledROMIsOfferedUntilItIsAdded() async throws {
        let tmp = try TemporaryDirectory()
        let store = ROMStore(paths: tmp.paths, steam: try steam(in: tmp))

        let offers = await store.steamOffers(catalog: catalog())
        #expect(offers.map(\.sha1) == [Self.valveIdentity])
        #expect(offers.first?.matches == true)
        #expect(offers.first?.appName == "Half-Life")

        _ = await store.addFromSteam(Self.valveIdentity, catalog: catalog())
        #expect(await store.steamOffers(catalog: catalog()).isEmpty)
    }

    @Test func anotherBuildIsOfferedAsNotMatching() async throws {
        let tmp = try TemporaryDirectory()
        let store = ROMStore(paths: tmp.paths, steam: try steam(in: tmp))
        let other = String(repeating: "b", count: 40)
        #expect(await store.steamOffers(catalog: catalog(other)).map(\.matches) == [false])
    }

    @Test func addingFromSteamKeepsJustItsFilesLessConfigs() async throws {
        let tmp = try TemporaryDirectory()
        let store = ROMStore(paths: tmp.paths, steam: try steam(in: tmp))
        // What playing wrote: a changed config and a save, neither of which Steam lists or the ROM keeps.
        let valve = tmp.url.appending(path: "Steam/steamapps/common/Half-Life/valve", directoryHint: .isDirectory)
        try Data("bind w +jump\n".utf8).write(to: valve.appending(path: "config.cfg"))
        try tmp.file("Steam/steamapps/common/Half-Life/valve/SAVE/quick.sav", Synthetic.noise(1 << 10, seed: 3))

        let results = await store.addFromSteam(Self.valveIdentity, catalog: catalog())

        let record = try #require(results.first?.addedRecord)
        #expect(record.sha1 == Self.valveIdentity)
        #expect(record.originalFilename == "valve")
        let stored = tmp.paths.rom(Self.valveIdentity, format: ROMRecord.folderFormat)
        #expect(try FolderContents.files(in: stored).map(\.path) == ["empty.txt", "halflife.wad", "liblist.gam", "maps/c0a0.bsp"])
        #expect(try FolderContents.identity(of: stored, files: FolderContents.files(in: stored)) == Self.valveIdentity)
    }

    @Test func aChangedFileIsNamed() async throws {
        let tmp = try TemporaryDirectory()
        let store = ROMStore(paths: tmp.paths, steam: try steam(in: tmp))
        try tmp.file("Steam/steamapps/common/Half-Life/valve/liblist.gam", Data("game \"Mod\"\n".utf8))

        let rejection = try #require(await store.addFromSteam(Self.valveIdentity, catalog: catalog()).first?.rejection)
        #expect(rejection.reason.contains("liblist.gam"))
        #expect(rejection.reason.contains("Verify"))
    }

    @Test func aMissingFileIsNamed() async throws {
        let tmp = try TemporaryDirectory()
        let store = ROMStore(paths: tmp.paths, steam: try steam(in: tmp))
        try FileManager.default.removeItem(at: tmp.url.appending(path: "Steam/steamapps/common/Half-Life/valve/maps/c0a0.bsp"))

        let rejection = try #require(await store.addFromSteam(Self.valveIdentity, catalog: catalog()).first?.rejection)
        #expect(rejection.reason.contains("maps/c0a0.bsp is missing"))
    }

    @Test func addingTheInstallFolderTakesItFromSteam() async throws {
        let tmp = try TemporaryDirectory()
        let store = ROMStore(paths: tmp.paths, steam: try steam(in: tmp))
        try tmp.file("Steam/steamapps/common/Half-Life/valve/SAVE/quick.sav", Synthetic.noise(1 << 10, seed: 3))

        for folder in ["Half-Life", "Half-Life/valve"] {
            let url = tmp.url.appending(path: "Steam/steamapps/common/\(folder)", directoryHint: .isDirectory)
            let results = await store.add([url], catalog: catalog())
            #expect(results.count == 1)
            #expect((results.first?.addedRecord ?? results.first?.duplicateRecord)?.sha1 == Self.valveIdentity)
        }
    }

    @Test func aFolderFromElsewhereMatchesWithoutItsConfigs() async throws {
        let tmp = try TemporaryDirectory()
        let store = ROMStore(paths: tmp.paths, steam: SteamLibrary(root: tmp.url.appending(path: "NoSteam")))
        for (path, data) in Self.valve { try tmp.file("copy/\(path)", data) }
        try Data("bind w +jump\n".utf8).write(to: tmp.url.appending(path: "copy/valve/config.cfg"))

        let results = await store.add([tmp.url.appending(path: "copy/valve", directoryHint: .isDirectory)], catalog: catalog())

        #expect(results.first?.addedRecord?.sha1 == Self.valveIdentity)
        let stored = tmp.paths.rom(Self.valveIdentity, format: ROMRecord.folderFormat)
        #expect(try !FolderContents.files(in: stored).map(\.path).contains("config.cfg"))
    }

    @Test func keyValuesReadsNestedBlocksCommentsAndEscapes() throws {
        let parsed = try KeyValues.parse("""
            // a comment
            "Root" { "Key" "a \\"quoted\\" value" "Child" { "inner" "1" } [$WIN32] }
            """)
        #expect(parsed["root"]?["key"]?.string == "a \"quoted\" value")
        #expect(parsed["Root"]?["Child"]?["Inner"]?.string == "1")
    }
}

extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
