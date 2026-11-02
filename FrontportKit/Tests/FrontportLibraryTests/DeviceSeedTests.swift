import Foundation
import FrontportCore
import FrontportPackager
import Testing
@testable import FrontportLibrary
@testable import FrontportROMs

private let noProgress: ProgressHandler = { _ in }

/// The folder ROM Seedy takes, and a demo of it, which another release of Seedy filled a folder from.
private let gameSHA1 = String(repeating: "f", count: 40)
private let demoSHA1 = String(repeating: "d", count: 40)
private let game = ["A.TXT": "first file\n", "DATA/B.TXT": "second file\n", "DATA/SUB/C.DAT": "third file\n"]

/// A Port whose iOS version takes a file ROM at `Documents/seedy.z64` and a folder ROM filling `Documents/Game`.
private let seedy = CatalogEntry(
    id: "seedy", name: "Seedy", kind: .decomp, game: "seedy-game", developer: "Tests", summary: "", description: "",
    source: URL(string: "https://github.com/tests/seedy")!, bundleId: "dev.frontport.port.seedy",
    releases: .githubRelease(GitHubReleaseSource(repo: "tests/seedy", asset: "Seedy-*-mac.zip")),
    requirements: [
        Requirement(label: "Seedy ROM", stage: .runtime, oneOf: ["aaa"], seedPath: "roms/seedy.z64"),
        Requirement(label: "Seedy Game", stage: .runtime, oneOf: [gameSHA1, demoSHA1], seedPath: "game"),
        Requirement(label: "Mac only", stage: .runtime, oneOf: ["ccc"], seedPath: "roms/"),
    ],
    ios: IOSSpec(
        releases: .githubRelease(GitHubReleaseSource(repo: "tests/seedy", asset: "Seedy-*.ipa")),
        seedPaths: ["Documents/seedy.z64", "Documents/Game", nil]))

private let bundleId = "dev.frontport.port.seedy.a1b2c3d4e5"
private let marker = "Documents/Game/.frontport-rom"

/// Seeding Seedy's ROMs on an iPhone it's installed on, through `devicectl`'s stand-in and the real ROMs: what the
/// Device Library checks and stages around `DeviceSeeder`, whose own tests cover what's put and recorded.
@Suite struct DeviceSeedTests {
    @Test func seedsFilesThenMarkersAndRecordsWhatsThere() async throws {
        let f = try await SeedFixture()
        let phases = Box<[ProgressUpdate.Phase]>([])

        let plan = try #require(try await f.library.seed(IOSVersion(of: seedy), on: ready(iPhone), progress: { update in phases.update { $0.append(update.phase) } }))

        #expect(f.control.text(at: "Documents/seedy.z64", of: bundleId, on: iPhone.id) == "rom aaa")
        for (path, text) in game { #expect(f.control.text(at: "Documents/Game/\(path)", of: bundleId, on: iPhone.id) == text) }
        #expect(f.control.text(at: marker, of: bundleId, on: iPhone.id) == "\(gameSHA1)\n")
        // One put, the files first and the marker last.
        #expect(f.control.puts.get == [game.keys.sorted().map { "Documents/Game/\($0)" } + ["Documents/seedy.z64", marker]])

        #expect(plan.items.map(\.step) == [.seeded, .seeded], "the plan as the Device stands afterwards")
        let record = try #require(await f.library.installation(for: seedy.id, on: iPhone.id))
        #expect(record.seeded == ["Seedy ROM": ["aaa"], "Seedy Game": [gameSHA1]])
        #expect(phases.get == [.seeding, .transferring])
        #expect(!f.exists(f.paths.deviceSeeds(for: seedy.id, on: iPhone.id)), "the staging goes")
        #expect(!f.exists(f.paths.containers), "nothing in a Port's Data on this Mac")
        #expect(!f.exists(f.paths.library))
    }

    /// The Device says what runs there; refused while the Port does.
    @Test func refusedWhileThePortRunsOnTheDevice() async throws {
        let f = try await SeedFixture()
        let record = await f.library.installation(for: seedy.id, on: iPhone.id)
        f.control.processes.set([iPhone.id: [
            1: URL(string: "file:///sbin/launchd")!,
            30785: URL(string: "file:///private/var/containers/Bundle/Application/4EDD/Tiny.app/Tiny")!,
        ]])

        #expect(try await f.library.isRunning(seedy.id, on: iPhone.id))
        #expect(try await !f.library.isRunning(seedy.id, on: iPad.id), "without its Installation there")
        await #expect(throws: FrontportError.running(seedy.id)) {
            try await f.library.seed(IOSVersion(of: seedy), on: ready(iPhone), progress: noProgress)
        }
        #expect(f.control.puts.get.isEmpty)
        #expect(await f.library.installation(for: seedy.id, on: iPhone.id) == record)

        // Another app with an executable of that name doesn't count.
        f.control.processes.set([iPhone.id: [30785: URL(string: "file:///private/var/containers/Bundle/Application/5EDD/Other.app/Tiny")!]])
        #expect(try await !f.library.isRunning(seedy.id, on: iPhone.id))
        _ = try await f.library.seed(IOSVersion(of: seedy), on: ready(iPhone), progress: noProgress)
        #expect(!f.control.puts.get.isEmpty)
    }

    @Test func needsTheInstallationAndADeviceItCanReach() async throws {
        let f = try await SeedFixture()
        await #expect(throws: FrontportError.notInstalled(seedy.id)) {
            try await f.library.seed(IOSVersion(of: seedy), on: ready(iPad), progress: noProgress)
        }
        await #expect(throws: FrontportError.self) {
            try await f.library.seed(IOSVersion(of: seedy), on: DeviceReading(device: iPhone, connection: .away), progress: noProgress)
        }
        await #expect(throws: FrontportError.self) {
            try await f.library.seed(
                IOSVersion(of: seedy), on: DeviceReading(device: iPhone, connection: .wired, isLocked: true, developerMode: true), progress: noProgress)
        }
        await #expect(throws: FrontportError.self) {
            try await f.library.seed(
                IOSVersion(of: seedy), on: DeviceReading(device: iPhone, connection: .wired, isLocked: false, developerMode: false), progress: noProgress)
        }
        do {
            _ = try await f.library.seed(
                IOSVersion(of: seedy), on: DeviceReading(device: iPhone, connection: .wired, isLocked: true, developerMode: true), progress: noProgress)
        } catch FrontportError.deviceUnavailable(let problem, _) {
            #expect(problem == .locked)
        }
        #expect(f.control.puts.get.isEmpty)
    }

    /// Each refusal for the Device is one Seeding waits for, so it's tried again once a reading finds the Device ready:
    /// Developer Mode off as much as away or locked.
    @Test func aSeedRefusedForTheDeviceWaitsForIt() async throws {
        let f = try await SeedFixture()
        for reading in [
            DeviceReading(device: iPhone, connection: .away),
            DeviceReading(device: iPhone, connection: .wired, isLocked: true, developerMode: true),
            DeviceReading(device: iPhone, connection: .wired, isLocked: false, developerMode: false),
        ] {
            do {
                _ = try await f.library.seed(IOSVersion(of: seedy), on: reading, progress: noProgress)
                Issue.record("Seeded on \(reading)")
            } catch {
                #expect(DeviceUpkeepState.Wait(refusal: error) == .unready, "\(error)")
                #expect(!DeviceUpkeepState.isReady(reading))
            }
        }
        #expect(f.control.puts.get.isEmpty)
    }

    @Test func aPortWhoseIOSVersionSeedsNothingIsLeftAlone() async throws {
        let f = try await SeedFixture()
        var plain = seedy
        plain.ios?.seedPaths = [nil, nil, nil]

        #expect(try await f.library.seed(IOSVersion(of: plain), on: ready(iPhone), progress: noProgress) == nil)
        #expect(try await f.library.seedingPlan(for: IOSVersion(of: plain), on: ready(iPhone)) == nil)
        #expect(f.control.puts.get.isEmpty)
    }

    @Test func withoutAROMInROMsNothingIsCopied() async throws {
        let f = try await SeedFixture(roms: false)

        let plan = try #require(try await f.library.seed(IOSVersion(of: seedy), on: ready(iPhone), progress: noProgress))

        #expect(plan.items.isEmpty && f.control.puts.get.isEmpty)
        #expect(await f.library.installation(for: seedy.id, on: iPhone.id)?.seeded == [:])
    }

    @Test func thePlanIsReadWithoutCopyingAnything() async throws {
        let f = try await SeedFixture()
        let record = await f.library.installation(for: seedy.id, on: iPhone.id)

        let plan = try #require(try await f.library.seedingPlan(for: IOSVersion(of: seedy), on: ready(iPhone)))

        #expect(plan.items.map(\.step) == [
            .copy(files: ["Documents/seedy.z64"], marker: nil),
            .copy(files: game.keys.sorted().map { "Documents/Game/\($0)" }, marker: marker),
        ])
        #expect(f.control.puts.get.isEmpty)
        #expect(await f.library.installation(for: seedy.id, on: iPhone.id) == record)
        #expect(!f.exists(f.paths.deviceSeeds(for: seedy.id, on: iPhone.id)))
    }

    @Test func leftoverSeedsGoAtLaunch() async throws {
        let f = try await SeedFixture()
        let seeds = f.paths.deviceSeeds(for: seedy.id, on: iPhone.id)
        try DeviceFixtures.write(Data("x".utf8), to: seeds.appending(path: "files/Documents/x"))

        await f.library.removeLeftovers()

        #expect(!f.exists(seeds))
        #expect(await f.library.installation(for: seedy.id, on: iPhone.id) != nil)
    }
}

// MARK: Fixture

/// Seedy installed on the iPhone, with its file ROM and folder ROM in ROMs unless `roms` is false.
private struct SeedFixture {
    let tmp: TemporaryDirectory
    let paths: AppPaths
    let control = FakeDeviceControl()
    let roms: StoredROMs
    let library: DeviceLibrary

    init(roms withROMs: Bool = true) async throws {
        tmp = try TemporaryDirectory()
        paths = AppPaths(root: tmp.url.appending(path: "root"), containers: tmp.url.appending(path: "Containers"))
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        roms = StoredROMs(store: ROMStore(paths: paths))
        let release = Release(
            port: seedy.id, version: "1.0", tag: "v1.0", published: Date(timeIntervalSince1970: 1_800_000_000),
            asset: ReleaseAsset(name: "Seedy-1.0.ipa", url: URL(string: "https://example.com/Seedy-1.0.ipa")!, size: 3, sha256: "00"))
        library = DeviceLibrary(
            paths: paths, catalog: FakeCatalog(recipe: tmp.url), releases: FakeReleases(latest: Box([.stable: release])),
            fetcher: FakeDeviceFetcher(paths: paths), builder: FakeBuilder(paths: paths, appName: "Seedy"),
            packager: DevicePackager(signer: RecordingDeviceSigner()), control: control,
            provisioning: try FakeProvisioning(profile: tmp.url.appending(path: "Profiles/wildcard.mobileprovision")),
            roms: roms.store)
        _ = try await library.prepareAndInstall(IOSVersion(of: seedy), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress)
        if withROMs {
            try await roms.add("aaa")
            try await addFolder(gameSHA1, game)
        }
    }

    /// Stores a folder ROM as intake leaves it, read-only in `ROMs/<sha1>.folder/`, and lists it in the index.
    func addFolder(_ sha1: String, _ files: [String: String]) async throws {
        let folder = paths.rom(sha1, format: ROMRecord.folderFormat)
        for (path, text) in files { try DeviceFixtures.write(Data(text.utf8), to: folder.appending(path: path)) }
        var index = (try? JSON.read([ROMRecord].self, from: paths.romIndex)) ?? []
        index.append(
            ROMRecord(
                sha1: sha1, game: "seedy-game", name: "Seedy", format: ROMRecord.folderFormat,
                size: Int64(files.values.reduce(0) { $0 + $1.utf8.count }), added: Date(), originalFilename: "SEEDY"))
        try JSON.write(index, to: paths.romIndex)
        await roms.store.reloadIndex()
    }

    func exists(_ url: URL) -> Bool { FileOperations.exists(url) }
}
