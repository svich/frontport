import Foundation
import FrontportCore
import Testing
@testable import FrontportLibrary

/// Seeding carried out against a plain in-memory container: a file ROM at `Documents/seedy.z64` and a folder ROM filling
/// `Documents/Game`, staged by hand, with nothing fetched, signed or installed.
@Suite struct DeviceSeederTests {
    @Test func putsFilesThenMarkersAndRecordsWhatsThere() async throws {
        let f = try SeederFixture()

        let plan = try await f.seed()

        #expect(f.control.puts.get == [gameFiles + ["Documents/seedy.z64", marker]], "one put, the marker last")
        #expect(f.text(marker) == "\(gameSHA1)\n")
        #expect(plan.items.map(\.step) == [.seeded, .seeded], "the plan as the Device stands afterwards")
        #expect(f.record.seeded == ["Seedy ROM": ["aaa"], "Seedy Game": [gameSHA1]])
        #expect(f.record.filling == nil)
    }

    @Test func seedingAgainPutsNothing() async throws {
        let f = try SeederFixture()
        _ = try await f.seed()
        let record = f.record
        let reads = f.control.reads.get

        let plan = try await f.seed()

        #expect(f.control.puts.get.count == 1)
        #expect(plan.copiesNothing && plan.items.map(\.step) == [.seeded, .seeded])
        #expect(f.record == record)
        #expect(f.control.reads.get == reads + [marker], "the marker is read once per listing, not after its own put")
    }

    @Test func aStoppedPutNotesFillingAndTheNextSeedPutsOnlyTheRest() async throws {
        let f = try SeederFixture()
        f.control.putFailure.set(.deviceUnavailable(.away, detail: "devicectl gave up waiting for the Device."))
        f.control.writesBeforeFailure.set(2)

        await #expect(throws: FrontportError.deviceUnavailable(.away, detail: "devicectl gave up waiting for the Device.")) {
            try await f.seed()
        }

        // Nothing was Seeded before, so nothing is now; the folder's files being put are noted.
        #expect(f.record.seeded == [:])
        #expect(f.record.filling == gameFiles)
        #expect(f.text(gameFiles[0]) != nil && f.text(gameFiles[2]) == nil && f.text(marker) == nil)

        f.control.putFailure.set(nil)
        let before = f.control.written.count
        _ = try await f.seed()

        #expect(Array(f.control.written.dropFirst(before)) == [gameFiles[2], "Documents/seedy.z64", marker])
        #expect(f.record.seeded == ["Seedy ROM": ["aaa"], "Seedy Game": [gameSHA1]])
        #expect(f.record.filling == nil)
    }

    @Test func aFolderFileCutShortIsPutAgainButNotOneThePortWrote() async throws {
        let f = try SeederFixture()
        f.control.putFailure.set(.deviceUnavailable(.away, detail: "devicectl gave up waiting for the Device."))
        f.control.truncatesOnFailure.set(true)
        await #expect(throws: FrontportError.self) { try await f.seed() }
        #expect(f.text(gameFiles[0]) == "first", "cut off part way")
        // The Port meanwhile saves a game beside it, and writes a longer file of its own where a ROM's file isn't yet.
        f.write("save", at: "Documents/Game/SAVE.SAV")
        f.write("written by the Port\n", at: gameFiles[1])

        f.control.putFailure.set(nil)
        let before = f.control.written.count
        _ = try await f.seed()

        #expect(Array(f.control.written.dropFirst(before)) == [gameFiles[0], gameFiles[2], "Documents/seedy.z64", marker])
        #expect(f.text(gameFiles[0]) == "first file\n")
        #expect(f.text(gameFiles[1]) == "written by the Port\n")
        #expect(f.text("Documents/Game/SAVE.SAV") == "save")
        #expect(f.record.seeded == ["Seedy ROM": ["aaa"], "Seedy Game": [gameSHA1]])
    }

    @Test func aFolderGetsOnlyItsMissingFilesAndKeepsThePorts() async throws {
        let f = try SeederFixture()
        _ = try await f.seed()
        // The Port rewrites a file of the Game's, saves a game, and the user deletes a file in Files.
        f.write("rewritten by the Port", at: gameFiles[0])
        f.write("save", at: "Documents/Game/SAVE.SAV")
        f.control.containers.update { $0[iPhone.id]?[bundleId]?[gameFiles[1]] = nil }
        let before = f.control.written.count

        _ = try await f.seed()

        #expect(Array(f.control.written.dropFirst(before)) == [gameFiles[1]])
        #expect(f.text(gameFiles[0]) == "rewritten by the Port")
        #expect(f.text("Documents/Game/SAVE.SAV") == "save")
        #expect(f.text(gameFiles[1]) == "second file\n")
    }

    @Test func aFileROMChangedOnTheDeviceIsPutOverIt() async throws {
        let f = try SeederFixture()
        _ = try await f.seed()
        f.write("something else entirely", at: "Documents/seedy.z64")

        _ = try await f.seed()

        #expect(f.text("Documents/seedy.z64") == "rom aaa")
    }

    @Test func leavesAFolderMarkedAsAnotherROMAlone() async throws {
        let f = try SeederFixture()
        f.write("\(demoSHA1)\n", at: marker)
        f.write("demo", at: "Documents/Game/DEMO.DAT")

        let plan = try await f.seed()

        #expect(plan.items.map(\.step) == [.seeded, .heldBy(demoSHA1)])
        #expect(f.control.written == ["Documents/seedy.z64"], "nothing mixed in")
        #expect(f.text(marker) == "\(demoSHA1)\n")
        #expect(f.control.reads.get == [marker], "read once, not again after the put")
        #expect(f.record.seeded == ["Seedy ROM": ["aaa"]])
    }

    @Test func aFileROMAPutOverwritesIsntRecordedShouldThePutStop() async throws {
        let f = try SeederFixture()
        _ = try await f.seed()
        // bbb, the size of aaa, is staged in its place, and with the folder's marker gone a marker follows the file.
        f.control.containers.update { $0[iPhone.id]?[bundleId]?[marker] = nil }
        f.control.putFailure.set(.deviceUnavailable(.away, detail: "devicectl gave up waiting for the Device."))
        f.control.writesBeforeFailure.set(1)
        await #expect(throws: FrontportError.self) { try await f.seed(rom: "bbb") }
        #expect(f.text("Documents/seedy.z64") == "rom bbb")
        #expect(f.record.seeded["Seedy ROM"] == nil, "aaa is gone")

        f.control.putFailure.set(nil)
        _ = try await f.seed()
        #expect(f.text("Documents/seedy.z64") == "rom aaa")
        #expect(f.record.seeded == ["Seedy ROM": ["aaa"], "Seedy Game": [gameSHA1]])
    }

    @Test func thePlanPutsAndRecordsNothing() async throws {
        let f = try SeederFixture()
        let record = f.record

        let plan = try await f.seeder.plan(try f.stage(), for: record)

        #expect(plan.items.map(\.step) == [
            .copy(files: ["Documents/seedy.z64"], marker: nil), .copy(files: gameFiles, marker: marker),
        ])
        #expect(f.control.puts.get.isEmpty && f.record == record)
    }

    @Test func pruneKeepsOnlyWhatsListedAndNoEmptyFolders() throws {
        let tmp = try TemporaryDirectory()
        for path in ["a/keep.txt", "a/b/drop.txt", "c/drop.txt"] {
            try DeviceFixtures.write(Data("x".utf8), to: tmp.url.appending(path: path))
        }

        try DeviceSeeder.prune(tmp.url, keeping: ["a/keep.txt"])

        let left = FileManager.default.enumerator(atPath: tmp.url.path(percentEncoded: false))?.allObjects as? [String]
        #expect(left?.sorted() == ["a", "a/keep.txt"])
    }
}

// MARK: Fixture

private let gameSHA1 = String(repeating: "f", count: 40)
private let demoSHA1 = String(repeating: "d", count: 40)
private let game = ["A.TXT": "first file\n", "DATA/B.TXT": "second file\n", "DATA/SUB/C.DAT": "third file\n"]
private let gameFiles = game.keys.sorted().map { "Documents/Game/\($0)" }
private let port: PortID = "seedy"
private let bundleId = port.deviceBundleID(team: testTeam)
private let marker = "Documents/Game/.frontport-rom"
private let entry = CatalogEntry(
    id: port, name: "Seedy", kind: .decomp, game: "seedy-game", developer: "Tests", summary: "", description: "",
    source: URL(string: "https://github.com/tests/seedy")!, bundleId: "dev.frontport.port.seedy",
    releases: .githubRelease(GitHubReleaseSource(repo: "tests/seedy", asset: "Seedy-*-mac.zip")),
    ios: IOSSpec(releases: .githubRelease(GitHubReleaseSource(repo: "tests/seedy", asset: "Seedy-*.ipa"))))

/// Seedy recorded as installed on the iPhone, whose container starts empty.
private struct SeederFixture {
    let tmp: TemporaryDirectory
    let paths: AppPaths
    let folder: DeviceFolder
    let control = FakeDeviceControl()
    var seeder: DeviceSeeder { DeviceSeeder(folder: folder, control: control) }

    init() throws {
        tmp = try TemporaryDirectory()
        paths = AppPaths(root: tmp.url.appending(path: "root"), containers: tmp.url.appending(path: "Containers"))
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        folder = DeviceFolder(paths: paths, port: port, device: iPhone.id)
        try folder.write(
            DeviceInstallation(
                port: port, device: iPhone.id, release: Release(port: port, version: "1.0"), channel: .stable,
                installedAt: Date(timeIntervalSince1970: 1_800_000_000), appName: "Seedy.app", bundleId: bundleId,
                team: testTeam, certificate: testCertificate.sha1, certificateExpires: testCertificate.expires,
                profile: DeviceInstallation.Profile(uuid: "uuid", name: "profile", expires: FakeProvisioning.expires),
                entry: entry))
        control.apps.set([iPhone.id: [bundleId: "1.0"]])
    }

    var record: DeviceInstallation { folder.record! }

    /// Stages the file ROM `rom`, then the Game, in a fresh folder, as ROMs lays them out for the container.
    func stage(rom: String = "aaa") throws -> [StagedSeed] {
        let root = paths.deviceSeeds(for: port, on: iPhone.id)
        try? FileManager.default.removeItem(at: root)
        try DeviceFixtures.write(Data("rom \(rom)".utf8), to: root.appending(path: "Documents/seedy.z64"))
        for (path, text) in game { try DeviceFixtures.write(Data(text.utf8), to: root.appending(path: "Documents/Game/\(path)")) }
        try DeviceFixtures.write(Data("\(gameSHA1)\n".utf8), to: root.appending(path: marker))
        return [
            StagedSeed(
                label: "Seedy ROM", sha1: rom, fileSHA1: rom, path: "Documents/seedy.z64",
                files: [DeviceFile(path: "Documents/seedy.z64", isDirectory: false, size: Int64("rom \(rom)".utf8.count))]),
            StagedSeed(
                label: "Seedy Game", sha1: gameSHA1, fileSHA1: gameSHA1, path: "Documents/Game",
                files: game.keys.sorted().map {
                    DeviceFile(path: "Documents/Game/\($0)", isDirectory: false, size: Int64(game[$0]!.utf8.count))
                },
                marker: "\(gameSHA1)\n"),
        ]
    }

    /// Stages afresh, then Seeds over the record as it stands.
    @discardableResult
    func seed(rom: String = "aaa") async throws -> DeviceSeedingPlan {
        let staged = try stage(rom: rom)
        return try await seeder.seed(staged, from: paths.deviceSeeds(for: port, on: iPhone.id), over: record, progress: { _ in })
    }

    func write(_ text: String, at path: String) { control.write(text, at: path, of: bundleId, on: iPhone.id) }

    func text(_ path: String) -> String? { control.text(at: path, of: bundleId, on: iPhone.id) }
}
