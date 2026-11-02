import Foundation
import FrontportCore
import FrontportPackager
import FrontportROMs
import Testing
@testable import FrontportLibrary

private let noProgress: ProgressHandler = { _ in }

/// An iOS version built from its iOS Recipe: prepared from what the Builder leaves in `Builds/<port>.ios/out`, then
/// installed like a prebuilt one.
@Suite struct DeviceBuildTests {
    @Test func preparesTheIOSVersionFromItsRecipeAndInstallsIt() async throws {
        let f = try BuildFixture()
        let phases = Box<[ProgressUpdate.Phase]>([])

        let prepared = try await f.library.prepare(
            IOSVersion(of: built), channel: .stable, progress: { update in phases.update { $0.append(update.phase) } })

        // The pinned ref's Release, built for iOS by the Recipe the iOS version names, from the Catalog that lists it.
        #expect(prepared.release == f.release("1.0") && prepared.release.asset == nil)
        #expect(prepared.appName == "Tiny.app" && prepared.minimumOS == "15.0" && prepared.families == [1, 2])
        let build = try #require(f.builder.builds.get.only)
        #expect(build.sdk == .iphoneos && build.ref == "v1.0" && build.roms.isEmpty)
        #expect(build.entry == IOSVersion(built)?.view, "the iOS view, keeping the id and the Catalog")
        #expect(build.log == f.paths.buildLog(for: "tiny.ios"))
        #expect(build.recipe == f.catalog.recipe)
        let asked = try #require(f.catalog.asked.get.only)
        #expect(asked.catalog == built.catalog && asked.releases == built.ios?.releases)
        #expect(f.fetcher.fetched.get.isEmpty)
        #expect(phases.get == [.resolving, .fetching, .building])

        // Kept in `prepared/` as a prebuilt app is; the Recipe's output and `preparing/` go.
        let app = f.paths.devicePreparedApp(prepared)
        #expect(try DeviceFixtures.version(of: app) == "v1.0")
        #expect(try JSON.read(PreparedDeviceApp.self, from: f.paths.devicePreparedRecord(for: built.id)) == prepared)
        #expect(!f.exists(f.paths.buildOutput(for: "tiny.ios")) && !f.exists(f.paths.devicePreparing(for: built.id)))
        #expect(!f.exists(f.paths.downloads(for: "tiny.ios")) && !f.exists(f.paths.builds(for: built.id)))
        #expect(prepared.isCurrent(for: try IOSVersion(of: built), latest: f.release("1.0")))
        #expect(try await f.library.prepare(IOSVersion(of: built), channel: .stable, progress: noProgress) == prepared)
        #expect(f.builder.builds.get.count == 1, "prepared for that ref already")

        let installation = try await f.library.installPrepared(IOSVersion(of: built), on: ready(iPhone), team: testTeam, progress: noProgress)
        #expect(installation.release == f.release("1.0") && installation.bundleId == "dev.frontport.port.tiny.a1b2c3d4e5")
        #expect(f.control.installs.get.map(\.signed) == [true])
        #expect(f.control.apps.get[iPhone.id] == ["dev.frontport.port.tiny.a1b2c3d4e5": "v1.0"])
        #expect(f.isUnsigned(f.paths.devicePreparedApp(prepared)), "the prepared app stays unsigned for the next Device")
    }

    /// The build runs beside `prepared/`, which stays until a build of another ref succeeds.
    @Test func thePreparedAppSurvivesARebuild() async throws {
        let f = try BuildFixture()
        _ = try await f.library.prepare(IOSVersion(of: built), channel: .stable, progress: noProgress)
        f.releases.set([.stable: f.release("1.1")])
        f.builder.failure.set(.buildFailed("tiny", status: 1, log: f.paths.buildLog(for: "tiny.ios")))

        await #expect(throws: FrontportError.buildFailed("tiny", status: 1, log: f.paths.buildLog(for: "tiny.ios"))) {
            try await f.library.prepare(IOSVersion(of: built), channel: .stable, progress: noProgress)
        }
        #expect(f.builder.seen.get == ["v1.0"], "the build saw the app prepared before it")
        let kept = try #require(await f.library.prepared(built.id))
        #expect(kept.release == f.release("1.0"))
        #expect(try DeviceFixtures.version(of: f.paths.devicePreparedApp(kept)) == "v1.0")

        f.builder.failure.set(nil)
        let rebuilt = try await f.library.prepare(IOSVersion(of: built), channel: .stable, progress: noProgress)
        #expect(rebuilt.release == f.release("1.1"))
        #expect(try DeviceFixtures.version(of: f.paths.devicePreparedApp(rebuilt)) == "v1.1")
        #expect(f.builder.builds.get.map(\.ref) == ["v1.0", "v1.1", "v1.1"])
        #expect(f.builder.seen.get == ["v1.0", "v1.0"], "and again on the next try")
    }

    /// Only exactly one iOS app, a folder of its own, is taken from the output; nothing of it is kept otherwise.
    @Test(arguments: [
        (BuiltOutput.twoApps, FrontportError.appNotFound("The iOS Recipe must leave exactly one app in its output folder; found Other.app, Tiny.app.")),
        (.none, .appNotFound("The iOS Recipe must leave exactly one app in its output folder; found none.")),
        (.link, .appNotFound("The iOS Recipe left Tiny.app, which isn’t an app folder.")),
        (.macApp, .notForDevice("Tiny.app is laid out as a Mac app.")),
        (.simulator, .notForDevice("Tiny.app is built for the iOS Simulator.")),
    ])
    func refusesAnOutputThatIsntOneIOSApp(_ output: BuiltOutput, _ error: FrontportError) async throws {
        let f = try BuildFixture()
        f.builder.output.set(output)

        await #expect(throws: error) {
            try await f.library.prepareAndInstall(IOSVersion(of: built), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress)
        }

        #expect(await f.library.prepared(built.id) == nil)
        #expect(!f.exists(f.paths.buildOutput(for: "tiny.ios")) && !f.exists(f.paths.devicePreparing(for: built.id)))
        #expect(f.control.installs.get.isEmpty && f.provisioning.requests.get.isEmpty)
        #expect(!f.exists(f.paths.deviceInstallation(for: built.id, on: iPhone.id)))
    }

    @Test func installsTheToolchainBeforeTheFirstBuild() async throws {
        let f = try BuildFixture()
        f.builder.status.set(.needsPrefix)

        _ = try await f.library.prepare(IOSVersion(of: built), channel: .stable, progress: noProgress)

        #expect(f.builder.toolchainInstalls.get == 1)
        #expect(f.builder.toolchainSDKs.get == [.iphoneos, .iphoneos], "Xcode's, which needs no Command Line Tools")
        #expect(f.builder.builds.get.count == 1)
    }

    /// The Catalog changing the iOS Recipe at the same ref makes the prepared app stale and is an Update, which builds
    /// with the new Recipe; installed with it, it's no Update any more.
    @Test func aNewRecipeAtTheSameRefIsBuiltAgainAsAnUpdate() async throws {
        let f = try BuildFixture()
        let installed = try await f.library.prepareAndInstall(IOSVersion(of: built), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress)
        #expect(installed.recipeSHA256 == String(repeating: "0", count: 64))
        #expect(IOSVersion(built)?.update(for: installed, newest: f.release("1.0")) == nil)

        let changed = pinned("v1.0", recipe: String(repeating: "1", count: 64))
        let prepared = try #require(await f.library.prepared(built.id))
        #expect(!prepared.isCurrent(for: try IOSVersion(of: changed), latest: f.release("1.0")), "so Install builds again")
        #expect(IOSVersion(changed)?.update(for: installed, newest: f.release("1.0")) == f.release("1.0"))

        let updated = try await f.library.update(IOSVersion(of: changed), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress)
        #expect(updated.recipeSHA256 == String(repeating: "1", count: 64) && updated.release == f.release("1.0"))
        #expect(f.builder.builds.get.map(\.ref) == ["v1.0", "v1.0"] && f.control.installs.get.count == 2)
        #expect(IOSVersion(changed)?.update(for: updated, newest: f.release("1.0")) == nil)
        #expect(try await f.library.update(IOSVersion(of: changed), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress)
            == updated)
        #expect(f.builder.builds.get.count == 2, "nothing built for what's installed")
    }

    /// Offline, the pinned commits have no dates and their hashes don't compare as versions: the Catalog's newly
    /// pinned commit is installed over the one there, and so is the one it goes back to.
    @Test func updatesToWhicheverCommitTheCatalogPinsOffline() async throws {
        let f = try BuildFixture()
        let (first, second) = ("f" + String(repeating: "1", count: 39), "0" + String(repeating: "a", count: 39))
        let commit = { (ref: String) in Release(port: built.id, version: String(ref.prefix(7)), tag: ref, channel: .stable) }
        f.releases.set([.stable: commit(first)])
        _ = try await f.library.prepareAndInstall(IOSVersion(of: pinned(first)), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress)

        f.releases.set([.stable: commit(second)])
        let updated = try await f.library.update(IOSVersion(of: pinned(second)), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress)
        #expect(updated.release.tag == second)

        f.releases.set([.stable: commit(first)])
        let back = try await f.library.update(IOSVersion(of: pinned(first)), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress)
        #expect(back.release.tag == first)
        #expect(f.builder.builds.get.map(\.ref) == [first, second, first])
    }

    /// A Builder that builds only for the Mac, such as the Library's own fake, refuses an iOS build.
    @Test func aMacOnlyBuilderRefusesTheIOSVersion() async throws {
        let f = try BuildFixture()
        let library = DeviceLibrary(
            paths: f.paths, catalog: f.catalog, releases: FakeReleases(latest: f.releases), fetcher: f.fetcher,
            builder: FakeBuilder(paths: f.paths, appName: "Tiny"), packager: DevicePackager(signer: f.signer),
            control: f.control, provisioning: f.provisioning, roms: ROMStore(paths: f.paths))

        await #expect(throws: FrontportError.cantInstallOnDevice("This Builder can’t build Tiny’s iOS version.")) {
            try await library.prepare(IOSVersion(of: built), channel: .stable, progress: noProgress)
        }
        #expect(!f.exists(f.paths.buildOutput(for: built.id)), "nothing is built for the Mac instead")
    }

    /// The build folder and its log go with the Port's last Installation on a Device.
    @Test func theBuildFolderGoesWithTheLastInstallation() async throws {
        let f = try BuildFixture()
        _ = try await f.library.prepareAndInstall(IOSVersion(of: built), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress)
        try DeviceFixtures.write(Data("log".utf8), to: f.paths.buildLog(for: "tiny.ios"))
        try DeviceFixtures.write(Data("source".utf8), to: f.paths.buildSource(for: "tiny.ios").appending(path: "kept"))

        try await f.library.uninstall(built.id, from: iPhone.id)

        #expect(!f.exists(f.paths.builds(for: "tiny.ios")) && !f.exists(f.paths.logs(for: "tiny.ios")))
    }
}

// MARK: Fixture

/// Tiny, whose iOS version a Recipe in another Catalog builds from a pinned ref.
private let built: CatalogEntry = {
    var entry = CatalogEntry(
        id: "tiny", name: "Tiny", kind: .decomp, game: "tiny-game", developer: "Tests", summary: "", description: "",
        source: URL(string: "https://github.com/tests/tiny")!, bundleId: "dev.frontport.port.tiny",
        releases: .githubRelease(GitHubReleaseSource(repo: "tests/tiny", asset: "Tiny-*-mac.zip")),
        requirements: [Requirement(label: "Tiny ROM", stage: .runtime, oneOf: ["aaa"], seedPath: "roms/")],
        ios: IOSSpec(
            releases: .git(GitSource(
                repo: "tests/tiny", refs: [.stable: "v1.0"], recipe: "recipes/tiny-ios.sh",
                recipeSHA256: String(repeating: "0", count: 64))),
            seedPaths: ["Documents"]))
    entry.catalog = URL(string: "https://example.com/catalog/")
    return entry
}()

/// Tiny with its iOS version pinned to `ref`, built by the Recipe with `recipe`.
private func pinned(_ ref: String, recipe: String = String(repeating: "0", count: 64)) -> CatalogEntry {
    var entry = built
    entry.ios?.releases = .git(GitSource(repo: "tests/tiny", refs: [.stable: ref], recipe: "recipes/tiny-ios.sh", recipeSHA256: recipe))
    return entry
}

/// What the fake Recipe leaves in its output folder.
enum BuiltOutput: Sendable, CustomTestStringConvertible {
    case app, twoApps, none, link, macApp, simulator

    var testDescription: String { "\(self)" }
}

/// Builds Tiny's iOS app for the ref into the workspace `sdk` names, as the real Builder's output folder holds it,
/// and records each build. Only an iOS build is expected; a Mac one leaves nothing.
struct FakeDeviceBuilder: RecipeBuilding {
    struct Build: Sendable {
        var entry: CatalogEntry
        var ref: String
        var recipe: URL
        var roms: [String]
        var sdk: BuildSDK
        var log: URL
    }

    let paths: AppPaths
    let builds = Box<[Build]>([])
    let output = Box(BuiltOutput.app)
    let failure = Box<FrontportError?>(nil)
    let status = Box(ToolchainStatus.ready)
    let toolchainInstalls = Box(0)
    /// The SDK each readiness check and toolchain install was for.
    let toolchainSDKs = Box<[BuildSDK]>([])
    /// The version of the app in `prepared/` while each build ran, if there was one.
    let seen = Box<[String]>([])

    func toolchainStatus() async -> ToolchainStatus { status.get }

    func prepareToolchain(progress: @escaping ProgressHandler) async throws {
        toolchainInstalls.update { $0 += 1 }
        status.set(.ready)
    }

    func toolchainStatus(for sdk: BuildSDK) async -> ToolchainStatus {
        toolchainSDKs.update { $0.append(sdk) }
        return await toolchainStatus()
    }

    func prepareToolchain(for sdk: BuildSDK, progress: @escaping ProgressHandler) async throws {
        toolchainSDKs.update { $0.append(sdk) }
        try await prepareToolchain(progress: progress)
    }

    func build(
        _ entry: CatalogEntry, ref: String, recipe: URL, roms: BuildROMs, sdk: BuildSDK, log: URL,
        progress: @escaping ProgressHandler
    ) async throws -> BuildProduct {
        builds.update { $0.append(Build(entry: entry, ref: ref, recipe: recipe, roms: roms.sha1s, sdk: sdk, log: log)) }
        let prepared = paths.devicePrepared(for: entry.id).appending(path: "Tiny.app")
        if let version = try? DeviceFixtures.version(of: prepared) { seen.update { $0.append(version) } }
        progress(ProgressUpdate(.fetching))
        progress(ProgressUpdate(.building))
        let out = paths.buildOutput(for: sdk.workspace(for: entry.id))
        try? FileOperations.removeUntrusted(out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        if let failure = failure.get {
            try? FileOperations.removeUntrusted(out)
            throw failure
        }
        let app = out.appending(path: "Tiny.app", directoryHint: .isDirectory)
        switch output.get {
        case .app:
            _ = try DeviceFixtures.app(named: "Tiny", version: ref, in: out)
        case .twoApps:
            _ = try DeviceFixtures.app(named: "Tiny", version: ref, in: out)
            _ = try DeviceFixtures.app(named: "Other", version: ref, in: out)
        case .none:
            break
        case .link:
            let elsewhere = try DeviceFixtures.app(named: "Tiny", version: ref, in: paths.root.appending(path: "elsewhere"))
            try FileManager.default.createSymbolicLink(at: app, withDestinationURL: elsewhere)
        case .macApp:
            _ = try makeApp(named: "Tiny", version: ref, in: out)
        case .simulator:
            _ = try DeviceFixtures.app(named: "Tiny", version: ref, in: out, platform: 7)
        }
        return BuildProduct(app: app)
    }

    func unpack(
        _ installer: URL, named name: String, workspace: PortID, recipe: URL, log: URL, progress: @escaping ProgressHandler
    ) async throws -> [URL] { [] }
}

/// Hands out one Recipe, recording the entry each request was for, so a test sees how it was routed.
struct RecordingCatalog: CatalogProviding {
    let recipe: URL
    let asked = Box<[CatalogEntry]>([])

    func current() async throws -> CatalogDocument { throw FrontportError.catalogUnavailable("fake") }
    func refresh() async throws -> CatalogDocument { throw FrontportError.catalogUnavailable("fake") }
    func recipe(for entry: CatalogEntry) async throws -> URL {
        asked.update { $0.append(entry) }
        return recipe
    }
    func recipe(at path: String, sha256: String, in catalog: URL?) async throws -> URL { recipe }
}

private struct BuildFixture {
    let tmp: TemporaryDirectory
    let paths: AppPaths
    let releases = Box<[Channel: Release]>([:])
    let catalog: RecordingCatalog
    let fetcher: FakeDeviceFetcher
    let builder: FakeDeviceBuilder
    let signer = RecordingDeviceSigner()
    let control = FakeDeviceControl()
    let provisioning: FakeProvisioning
    let library: DeviceLibrary

    init() throws {
        tmp = try TemporaryDirectory()
        paths = AppPaths(root: tmp.url.appending(path: "root"), containers: tmp.url.appending(path: "Containers"))
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        catalog = RecordingCatalog(recipe: tmp.url.appending(path: "recipes/tiny-ios.sh"))
        fetcher = FakeDeviceFetcher(paths: paths)
        builder = FakeDeviceBuilder(paths: paths)
        provisioning = try FakeProvisioning(profile: tmp.url.appending(path: "Profiles/wildcard.mobileprovision"))
        releases.set([.stable: Self.release("1.0")])
        library = DeviceLibrary(
            paths: paths, catalog: catalog, releases: FakeReleases(latest: releases), fetcher: fetcher, builder: builder,
            packager: DevicePackager(signer: signer), control: control, provisioning: provisioning, roms: ROMStore(paths: paths))
    }

    func release(_ version: String) -> Release { Self.release(version) }

    /// The pinned ref's Release, as Releases makes it for a source-built entry: no asset.
    static func release(_ version: String) -> Release {
        Release(port: built.id, version: version, tag: "v\(version)", channel: .stable)
    }

    func exists(_ url: URL) -> Bool { FileOperations.exists(url) }

    /// True when the app holds no Provisioning Profile and isn't signed for a Device, as the Recipe left it.
    func isUnsigned(_ app: URL) -> Bool {
        !exists(app.appending(path: "embedded.mobileprovision"))
            && (try? Data(contentsOf: app.appending(path: "_CodeSignature/CodeResources"))) == Data("upstream".utf8)
    }
}

extension Array {
    /// The one element, or nil when there isn't exactly one.
    fileprivate var only: Element? { count == 1 ? first : nil }
}
