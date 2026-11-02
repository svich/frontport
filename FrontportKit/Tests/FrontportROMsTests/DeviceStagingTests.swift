import Foundation
import FrontportCore
import Testing
@testable import FrontportROMs

/// ROMs laid out for a Device: as Seeding lays them out in Data, by their iOS seedPaths, in a folder under `Devices/`.
@Suite struct DeviceStagingTests {
    /// A folder ROM: a PC Game's files.
    static let game: [String: Data] = [
        "MASTER.DAT": Synthetic.noise(4 << 10, seed: 1),
        "DATA/SOUND/MUSIC.ACM": Synthetic.noise(2 << 10, seed: 2),
        "DATA/TEXT.TXT": Data("text\n".utf8),
    ]

    /// A Port with an iOS version whose Requirements take `ios` seedPaths, and a store holding `roms`.
    func port(
        _ requirements: [Requirement], ios seedPaths: [String?], roms: [Data], format: String = "z64",
        in tmp: TemporaryDirectory
    ) async throws -> (store: ROMStore, entry: CatalogEntry) {
        let store = ROMStore(paths: tmp.paths)
        let files = try roms.enumerated().map { try tmp.file("in/\($0).\(format)", $1) }
        _ = await store.add(files, catalog: Catalogs.accepting(roms.map(Synthetic.sha1)))
        var entry = Catalogs.entry("ghostship", game: "ocarina-of-time", requirements: requirements)
        entry.ios = IOSSpec(
            releases: .githubRelease(GitHubReleaseSource(repo: "example/ghostship", asset: "*-iOS.zip")), seedPaths: seedPaths)
        return (store, entry)
    }

    /// `Devices/<udid>/ghostship/seeds/files/`, not there yet.
    func root(_ tmp: TemporaryDirectory) -> URL {
        tmp.paths.deviceSeeds(for: "ghostship", on: "00008110-0000000000000000")
            .appending(path: "files", directoryHint: .isDirectory)
    }

    @Test func aFileSeedPathGetsTheMatchAsThatFile() async throws {
        let tmp = try TemporaryDirectory()
        let rom = Synthetic.z64(size: 1 << 20)
        let requirement = Requirement(label: "Super Mario 64", stage: .runtime, oneOf: [Synthetic.sha1(rom)], seedPath: "roms/sm64.z64")
        let (store, entry) = try await port([requirement], ios: ["Documents/sm64.z64"], roms: [rom], in: tmp)
        let root = root(tmp)

        let staged = try await store.stage(IOSVersion(of: entry), into: root)

        #expect(staged == [
            StagedSeed(
                label: "Super Mario 64", sha1: Synthetic.sha1(rom), fileSHA1: Synthetic.sha1(rom), path: "Documents/sm64.z64",
                files: [DeviceFile(path: "Documents/sm64.z64", isDirectory: false, size: Int64(rom.count))])
        ])
        let file = root.appending(path: "Documents/sm64.z64")
        #expect(try Data(contentsOf: file) == rom)
        #expect(try mode(of: file) == 0o644, "a clone the Port may rewrite, as in Data")
        #expect(!FileManager.default.fileExists(atPath: tmp.paths.containers.path(percentEncoded: false)), "nothing in Data")
        #expect(staged.first?.markerPath == nil && staged.first?.isFolder == false)
    }

    @Test func aFolderSeedPathGetsEachROMByItsHash() async throws {
        let tmp = try TemporaryDirectory()
        let roms = [Synthetic.z64(size: 1 << 20, seed: 1), Synthetic.z64(size: 1 << 20, seed: 2)]
        let requirement = Requirement(
            label: "Ocarina of Time", stage: .runtime, oneOf: [Synthetic.sha1(roms[0])], extras: [Synthetic.sha1(roms[1])],
            seedPath: "roms/")
        let (store, entry) = try await port([requirement], ios: ["Documents/roms/"], roms: roms, in: tmp)
        let root = root(tmp)

        let staged = try await store.stage(IOSVersion(of: entry), into: root)

        #expect(staged.map(\.path) == roms.map { "Documents/roms/\(Synthetic.sha1($0)).z64" })
        #expect(staged.map(\.label) == ["Ocarina of Time", "Ocarina of Time"])
        for (seed, rom) in zip(staged, roms) {
            #expect(try Data(contentsOf: root.appending(path: seed.path)) == rom)
            #expect(seed.files == [DeviceFile(path: seed.path, isDirectory: false, size: Int64(rom.count))])
        }
    }

    @Test func aFolderROMIsFilledInWithItsMarker() async throws {
        let tmp = try TemporaryDirectory()
        for (path, data) in Self.game { try tmp.file("FALLOUT/\(path)", data) }
        let folder = tmp.url.appending(path: "FALLOUT", directoryHint: .isDirectory)
        let sha1 = try FolderContents.identity(of: folder, files: FolderContents.files(in: folder))
        let store = ROMStore(paths: tmp.paths)
        _ = await store.add([folder], catalog: Catalogs.accepting([sha1], game: "fallout", format: ROMRecord.folderFormat))
        var entry = Catalogs.entry(
            "fallout-ce", game: "fallout",
            requirements: [Requirement(label: "Fallout", stage: .runtime, oneOf: [sha1], seedPath: "Library/Application Support/Fallout")])
        entry.ios = IOSSpec(
            releases: .githubRelease(GitHubReleaseSource(repo: "example/fallout-ce", asset: "*.ipa")), seedPaths: ["Documents"])
        let root = root(tmp)

        let staged = try #require(try await store.stage(IOSVersion(of: entry), into: root).first)

        #expect(staged.path == "Documents" && staged.isFolder)
        #expect(staged.marker == "\(sha1)\n")
        #expect(staged.markerPath == "Documents/.frontport-rom")
        #expect(try String(decoding: Data(contentsOf: root.appending(path: "Documents/.frontport-rom")), as: UTF8.self) == "\(sha1)\n")
        let expected = Self.game.map { DeviceFile(path: "Documents/\($0.key)", isDirectory: false, size: Int64($0.value.count)) }
        #expect(staged.files == expected.sorted { $0.path < $1.path }, "every file, the marker left out")
        for (path, data) in Self.game { #expect(try Data(contentsOf: root.appending(path: "Documents/\(path)")) == data) }
    }

    @Test func requirementsWithoutAnIOSSeedPathOrAMatchGetNothing() async throws {
        let tmp = try TemporaryDirectory()
        let roms = [Synthetic.z64(size: 1 << 20, seed: 1), Synthetic.z64(size: 1 << 20, seed: 2)]
        let requirements = [
            Requirement(label: "Build", stage: .build, oneOf: [Synthetic.sha1(roms[0])]),
            Requirement(label: "Mac only", stage: .runtime, oneOf: [Synthetic.sha1(roms[1])], seedPath: "roms/"),
            Requirement(label: "Missing", stage: .runtime, oneOf: ["0000000000000000000000000000000000000000"], seedPath: "roms/"),
            Requirement(label: "Both", stage: .runtime, oneOf: [Synthetic.sha1(roms[1])], seedPath: "roms/b.z64"),
        ]
        let (store, entry) = try await port(requirements, ios: [nil, nil, "Documents/", "Documents/b.z64"], roms: roms, in: tmp)

        let staged = try await store.stage(IOSVersion(of: entry), into: root(tmp))

        #expect(staged.map(\.label) == ["Both"])
    }

    @Test func refusesARootOutsideTheDevicesFolder() async throws {
        let tmp = try TemporaryDirectory()
        let rom = Synthetic.z64(size: 1 << 20)
        let requirement = Requirement(label: "Super Mario 64", stage: .runtime, oneOf: [Synthetic.sha1(rom)], seedPath: "sm64.z64")
        let (store, entry) = try await port([requirement], ios: ["Documents/sm64.z64"], roms: [rom], in: tmp)
        let data = tmp.paths.data(for: entry.bundleId)
        // A link inside Devices that leads into a Port's Data.
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmp.paths.devices, withIntermediateDirectories: true)
        let link = tmp.paths.devices.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: data)

        for root in [
            data, tmp.paths.root.appending(path: "Builds/seeds"), tmp.paths.devices, link,
            link.appending(path: "files"), tmp.paths.devices.appending(path: "../ROMs/x"),
        ] {
            await #expect(throws: FrontportError.self, "\(root.path(percentEncoded: false))") {
                try await store.stage(IOSVersion(of: entry), into: root)
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: data.path(percentEncoded: false)).isEmpty, "Data untouched")
        #expect(!FileManager.default.fileExists(atPath: tmp.paths.root.appending(path: "Builds").path(percentEncoded: false)))
    }

    @Test func refusesAFolderThatIsntFresh() async throws {
        let tmp = try TemporaryDirectory()
        let rom = Synthetic.z64(size: 1 << 20)
        let requirement = Requirement(label: "Super Mario 64", stage: .runtime, oneOf: [Synthetic.sha1(rom)], seedPath: "sm64.z64")
        let (store, entry) = try await port([requirement], ios: ["Documents/sm64.z64"], roms: [rom], in: tmp)
        let root = root(tmp)
        try tmp.file("Frontport/Devices/00008110-0000000000000000/ghostship/seeds/files/left.txt", Data("x".utf8))

        await #expect(throws: FrontportError.self) { try await store.stage(IOSVersion(of: entry), into: root) }
    }

    @Test func theMacsSeedingNeverTakesTheIOSView() async throws {
        let tmp = try TemporaryDirectory()
        let rom = Synthetic.z64(size: 1 << 20)
        let requirement = Requirement(label: "Super Mario 64", stage: .runtime, oneOf: [Synthetic.sha1(rom)], seedPath: "sm64.z64")
        let (store, entry) = try await port([requirement], ios: ["Documents/sm64.z64"], roms: [rom], in: tmp)

        await #expect(throws: FrontportError.self) { try await store.seed(IOSVersion(of: entry).view) }
        #expect(!FileManager.default.fileExists(atPath: tmp.paths.containers.path(percentEncoded: false)))
    }
}
