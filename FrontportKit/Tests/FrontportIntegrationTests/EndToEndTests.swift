import Darwin
import Foundation
import FrontportArtwork
import FrontportBuilder
import FrontportCatalog
import FrontportCore
import FrontportLauncher
import FrontportLibrary
import FrontportPackager
import FrontportReleases
import FrontportROMs
import Testing

/// Every real module composed as the app composes them, over the signed Catalog the app bundles and a temporary
/// Frontport folder. Downloads real Releases from GitHub, signs them, and launches Ports for a few seconds in their
/// real containers (`~/Library/Containers/dev.frontport.port.<id>`), whose Data it deletes again.
///
///     FRONTPORT_NETWORK_TESTS=1 [FRONTPORT_GITHUB_TOKEN=…] [FRONTPORT_INTEGRATION_ROOT=/kept/folder] \
///     swift test --filter FrontportIntegrationTests
///
/// A Port whose container already holds Data is refused rather than overwritten.
@Suite(
    .enabled(if: Integration.requested, "Set FRONTPORT_NETWORK_TESTS=1 to install real Ports"),
    .serialized, .timeLimit(.minutes(30)))
struct EndToEndTests {
    @Test func bundledCatalogVerifies() async throws {
        let world = try await World()
        #expect(world.catalog.ports.count == 22)
        #expect(world.catalog.ports.filter(\.isInstallable).count == 22)
    }

    /// Zelda 64: Recompiled ships a zip inside a zip; 2 Ship 2 Harkinian a zip holding a DMG.
    @Test(arguments: ["zelda64recomp", "2ship"] as [PortID])
    func installsLaunchesUpdatesAndRemoves(_ port: PortID) async throws {
        let world = try await World()
        let entry = try #require(world.catalog.entry(port))
        let data = world.paths.data(for: entry.bundleId)
        try #require(!FileManager.default.fileExists(atPath: data.path(percentEncoded: false)),
            "\(data.path(percentEncoded: false)) holds Data this test would delete")
        defer { try? FileOperations.removeUntrusted(data) }

        // Two Releases with digests: install the older, so there's an update to take and roll back.
        let verifiable = try await world.github.releases(for: entry, channel: .stable).filter { $0.asset?.sha256 != nil }
        try #require(verifiable.count >= 2, "\(port) needs two Releases with digests")
        let (newest, older) = (verifiable[0], verifiable[1])
        world.releases.pin(older)
        let installed = try await world.library.install(entry, channel: .stable, progress: world.progress)
        world.releases.pin(nil)
        #expect(installed.release.tag == older.tag)
        try await expectSignedPort(world.paths.app(for: installed), entry: entry, permissions: installed.permissions)

        // Launch: the Port runs in its sandbox, with its container as home.
        let events = await world.launcher.events()
        let run = try await world.launcher.launch(entry, installation: installed)
        try await Task.sleep(for: .seconds(6))
        let pid = processID(running: world.paths.app(for: installed))
        #expect(pid != nil, "\(port) quit by itself; see \(run.log.path(percentEncoded: false))")
        #expect(pid.map(isSandboxed) == true)
        #expect(await world.launcher.isRunning(entry))
        #expect(FileManager.default.fileExists(atPath: data.appending(path: "Library").path(percentEncoded: false)))
        await #expect(throws: FrontportError.running(port)) {
            try await world.library.update(entry, to: nil, progress: world.progress)
        }
        await world.launcher.stop(entry)
        guard let ended = try await endOf(run, in: events, timeout: .seconds(20)) else {
            if let pid { kill(pid, SIGKILL) }
            Issue.record("\(port) didn't quit when asked")
            return
        }
        print("[\(port)] ran \(older.version) for \(ended.duration ?? 0) s, status \(ended.exitStatus ?? -1)\(ended.signaled ? " (signal)" : ""); Data: \(listing(data.appending(path: "Library/Application Support")))")

        // Update to the newest Release, then roll back.
        let updated = try await world.library.update(entry, to: nil, progress: world.progress)
        #expect(updated.release.tag == newest.tag && updated.previous?.tag == older.tag)
        try await expectSignedPort(world.paths.app(for: updated), entry: entry, permissions: updated.permissions)
        let beforeUpdate = try #require(await world.library.snapshots(for: port).first)
        #expect(beforeUpdate.reason == .update && beforeUpdate.release == older.version && beforeUpdate.target == newest.version)

        let rolledBack = try await world.library.rollback(entry, progress: world.progress)
        #expect(rolledBack.release.tag == older.tag && rolledBack.previous == nil)
        try await expectSignedPort(world.paths.app(for: rolledBack), entry: entry, permissions: rolledBack.permissions)
        #expect(await world.library.snapshots(for: port).first?.reason == .rollback)

        // Uninstall keeps Data and Snapshots; Delete Data removes both, leaving the container to macOS.
        try await world.library.uninstall(entry)
        #expect(await world.library.installation(for: port) == nil)
        #expect(!FileManager.default.fileExists(atPath: world.paths.library(for: port).path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: data.path(percentEncoded: false)))
        #expect(await !world.library.snapshots(for: port).isEmpty)

        try await world.library.deleteData(entry)
        #expect(!FileManager.default.fileExists(atPath: data.path(percentEncoded: false)))
        #expect(await world.library.snapshots(for: port).isEmpty)
        let metadata = world.paths.container(for: entry.bundleId).appending(path: ".com.apple.containermanagerd.metadata.plist")
        #expect(FileManager.default.fileExists(atPath: metadata.path(percentEncoded: false)))

        // The primer has macOS lay Data out again without running the Port.
        try await world.primer.prime(entry)
        #expect(FileManager.default.fileExists(atPath: data.appending(path: "Library/Application Support").path(percentEncoded: false)))
    }

    /// Ghostship's DMG carries a license agreement; it's converted before attaching. Not launched.
    @Test func packagesGhostshipFromItsLicensedDiskImage() async throws {
        let world = try await World()
        let (entry, app) = try await world.fetch("ghostship")
        try await world.packager.package(app, entry: entry, permissions: entry.permissions, assets: nil, installedAssets: nil)
        try await expectSignedPort(app, entry: entry, permissions: entry.permissions)
    }

    /// sm64coopdx's self-updater is stripped before signing. Not launched.
    @Test func packagesSm64coopdxWithoutItsUpdater() async throws {
        let world = try await World()
        let (entry, app) = try await world.fetch("sm64coopdx")
        let updater = app.appending(path: "Contents/MacOS/coopdx_updater")
        try #require(FileManager.default.fileExists(atPath: updater.path(percentEncoded: false)), "upstream ships it")
        #expect(entry.strip == ["Contents/MacOS/coopdx_updater"])

        try await world.packager.package(app, entry: entry, permissions: entry.permissions, assets: nil, installedAssets: nil)

        #expect(!FileManager.default.fileExists(atPath: updater.path(percentEncoded: false)))
        try await expectSignedPort(app, entry: entry, permissions: entry.permissions)
    }

    /// Starship is built from source with a Build-Stage ROM, so without one the Library stops before building.
    @Test func sourceBuiltPortNeedsItsROMFirst() async throws {
        let world = try await World()
        let entry = try #require(world.catalog.entry("starship"))
        #expect(entry.isSourceBuilt)
        #expect(try await world.github.latest(for: entry, channel: .stable)?.tag == "v2.0.0")
        let recipe = try await world.catalogStore.recipe(for: entry)
        #expect(recipe.path(percentEncoded: false).hasPrefix(world.paths.catalog.path(percentEncoded: false)))
        print("[starship] toolchain: \(await world.builder.toolchainStatus())")

        await #expect(throws: FrontportError.romMissing("starship", requirement: "Star Fox 64")) {
            try await world.library.install(entry, channel: .stable, progress: world.progress)
        }
        #expect(await world.library.installation(for: "starship") == nil)
    }
}

/// Installs a Port into the Frontport folder `FRONTPORT_APP_ROOT` names and leaves it there, so a Debug build of the
/// app can be tried against it with `FRONTPORT_ROOT`. `FRONTPORT_APP_ROMS` adds files to its ROMs first, as the ROMs
/// screen would, `FRONTPORT_APP_ASSIGN` keeps files Unverified as the ROMs it names, and `FRONTPORT_APP_LAUNCH`
/// launches the Port for that many seconds, then stops it, with `FRONTPORT_APP_ENV` added to its environment:
///
///     FRONTPORT_NETWORK_TESTS=1 FRONTPORT_APP_ROOT=/tmp/fp [FRONTPORT_APP_PORT=zelda64recomp] \
///     [FRONTPORT_APP_ROMS=/path/a.nsp,/path/prod.keys] [FRONTPORT_APP_ASSIGN=/path/folder=<sha1>,…] \
///     [FRONTPORT_APP_LAUNCH=60] [FRONTPORT_APP_ENV=DM_AUDIO=0,…] \
///     swift test --filter installsForTheApp
@Suite(.enabled(if: Integration.requested && Integration.environment["FRONTPORT_APP_ROOT"] != nil), .timeLimit(.minutes(600)))
struct AppRootTests {
    @Test func installsForTheApp() async throws {
        let root = try #require(Integration.environment["FRONTPORT_APP_ROOT"])
        let world = try await World(root: URL(filePath: root, directoryHint: .isDirectory))
        let entry = try #require(world.catalog.entry(PortID(Integration.environment["FRONTPORT_APP_PORT"] ?? "zelda64recomp")))
        let files = (Integration.environment["FRONTPORT_APP_ROMS"] ?? "").split(separator: ",").map { URL(filePath: String($0)) }
        var intakes = await world.roms.add(files, catalog: world.catalog)
        for pair in (Integration.environment["FRONTPORT_APP_ASSIGN"] ?? "").split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { intakes += await world.roms.assign(URL(filePath: parts[0]), as: parts[1], catalog: world.catalog) }
        }
        for intake in intakes {
            switch intake {
            case .added(let record), .duplicate(let record): print("[roms] \(record.originalFilename): \(record.sha1) \(record.name)")
            case .rejected(let file, let sha1, let reason): Issue.record("\(file.lastPathComponent) (\(sha1 ?? "-")): \(reason)")
            case .unknown(let file, let sha1, _, let reason): Issue.record("\(file.lastPathComponent) (\(sha1)): \(reason)")
            }
        }
        var installation = await world.library.installation(for: entry.id)
        if installation == nil {
            installation = try await world.library.install(entry, channel: entry.defaultChannel, progress: world.progress)
        }
        let installed = try #require(installation)
        try await expectSignedPort(world.paths.app(for: installed), entry: entry, permissions: installed.permissions)
        print("[\(entry.id)] \(installed.release.version) in \(world.paths.root.path(percentEncoded: false))")

        guard let seconds = Integration.environment["FRONTPORT_APP_LAUNCH"].flatMap(Double.init) else { return }
        var launched = entry
        for pair in (Integration.environment["FRONTPORT_APP_ENV"] ?? "").split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { launched.launch.environment[parts[0]] = parts[1] }
        }
        let events = await world.launcher.events()
        let run = try await world.launcher.launch(launched, installation: installed)
        try await Task.sleep(for: .seconds(seconds))
        let pid = processID(running: world.paths.app(for: installed))
        #expect(pid != nil, "\(entry.id) quit by itself; see \(run.log.path(percentEncoded: false))")
        #expect(pid.map(isSandboxed) == true)
        await world.launcher.stop(entry)
        let ended = try await endOf(run, in: events, timeout: .seconds(30))
        if ended == nil, let pid { kill(pid, SIGKILL) }
        print("[\(entry.id)] ran for \(ended?.duration ?? seconds) s, status \(ended?.exitStatus ?? -1); log: \(run.log.path(percentEncoded: false))")
    }
}

// MARK: Composition

enum Integration {
    static let environment = ProcessInfo.processInfo.environment
    static var requested: Bool { environment["FRONTPORT_NETWORK_TESTS"] == "1" }
    /// The synthetic tests need no network beyond the loopback, so they have a switch of their own.
    static var syntheticRequested: Bool { requested || environment["FRONTPORT_SYNTHETIC_TESTS"] == "1" }

    static let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    /// The signed Catalog the app bundles.
    static let bundledCatalog = repository.appending(path: "App/Resources/catalog", directoryHint: .isDirectory)

    /// `App/Primer/main.c`, compiled as Xcode builds `frontport-primer`.
    static func primerExecutable(in folder: URL) async throws -> URL {
        let output = folder.appending(path: "frontport-primer")
        let result = try await ProcessRunner().run(
            URL(filePath: "/usr/bin/xcrun"),
            arguments: ["clang", "-o", output.path(percentEncoded: false),
                repository.appending(path: "App/Primer/main.c").path(percentEncoded: false)])
        try result.check("clang")
        return output
    }
}

/// The services as `AppServices.live` builds them, over a fresh Frontport folder.
struct World {
    let folder: Scratch
    let paths: AppPaths
    let catalogStore: CatalogStore
    let catalog: CatalogDocument
    let github: GitHubReleases
    let releases: PinnedReleases
    let fetcher: AssetFetcher
    let builder: RecipeBuilder
    let roms: ROMStore
    let packager: PortPackager
    let launcher: PortLauncher
    let primer: ContainerPrimer
    let library: Library
    let progress: ProgressHandler = { update in
        if update.fraction == nil || update.fraction == 1, let message = update.message {
            print("  [\(update.phase.rawValue)] \(message)")
        }
    }

    /// - Parameter root: a Frontport folder to use as it is, instead of a fresh one.
    init(root: URL? = nil) async throws {
        folder = try Scratch()
        paths = AppPaths(
            root: root ?? folder.url.appending(path: "Frontport", directoryHint: .isDirectory),
            containers: AppPaths.default.containers)
        try FileOperations.createDirectory(paths.root)
        catalogStore = CatalogStore(paths: paths, bundled: Integration.bundledCatalog)
        catalog = try await catalogStore.current()
        github = GitHubReleases(
            cache: paths.catalog.appending(path: "releases", directoryHint: .isDirectory),
            token: Integration.environment["FRONTPORT_GITHUB_TOKEN"])
        releases = PinnedReleases(github)
        fetcher = AssetFetcher(paths: paths)
        builder = RecipeBuilder(paths: paths)
        roms = ROMStore(paths: paths, unpacker: ROMUnpacker(catalog: catalogStore, builder: builder, paths: paths))
        primer = ContainerPrimer(executable: try await Integration.primerExecutable(in: folder.url), paths: paths)
        packager = PortPackager(paths: paths, primer: primer)
        launcher = PortLauncher(paths: paths, primer: primer)
        library = Library(
            paths: paths, catalog: catalogStore, releases: releases, fetcher: fetcher, builder: builder, roms: roms,
            packager: packager, launcher: launcher, primer: primer)
    }

    /// The newest verifiable Release of a Catalog entry, unpacked into a fresh folder.
    func fetch(_ port: PortID) async throws -> (CatalogEntry, URL) {
        let entry = try #require(catalog.entry(port))
        let release = try #require(try await github.latest(for: entry, channel: entry.defaultChannel))
        print("[\(port)] \(release.tag): \(release.asset?.name ?? "-")")
        let app = try await fetcher.fetch(release, into: paths.staging(for: port), progress: progress)
        return (entry, app)
    }

}

/// GitHub's Releases, except that `latest` can be pinned to an older one, to install it and then update.
final class PinnedReleases: ReleaseDiscovering, @unchecked Sendable {
    private let base: GitHubReleases
    private let lock = NSLock()
    private var pinned: Release?

    init(_ base: GitHubReleases) { self.base = base }

    func pin(_ release: Release?) { lock.withLock { pinned = release } }

    func releases(for entry: CatalogEntry, channel: Channel) async throws -> [Release] {
        try await base.releases(for: entry, channel: channel)
    }

    func latest(for entry: CatalogEntry, channel: Channel) async throws -> Release? {
        if let pinned = lock.withLock({ pinned }), pinned.port == entry.id { return pinned }
        return try await base.latest(for: entry, channel: channel)
    }
}

/// A folder kept under `FRONTPORT_INTEGRATION_ROOT`, or a temporary one removed afterwards.
final class Scratch: Sendable {
    let url: URL
    private let keep: Bool

    init() throws {
        if let root = Integration.environment["FRONTPORT_INTEGRATION_ROOT"] {
            url = URL(filePath: root, directoryHint: .isDirectory).appending(path: "run-\(UUID().uuidString.prefix(8))")
            keep = true
        } else {
            url = FileManager.default.temporaryDirectory.appending(path: "FrontportIntegration-\(UUID().uuidString)")
            keep = false
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { if !keep { try? FileOperations.removeUntrusted(url) } }
}

// MARK: Checks

/// Signed inside-out under the hardened runtime with the Port's entitlements, its bundle ID, no quarantine. An app linking
/// to its Build Assets beside it passes every strict check but the one that rejects that link, and may read them.
func expectSignedPort(
    _ app: URL, entry: CatalogEntry, permissions: Permissions, sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let link = entry.buildAssets.flatMap {
        try? FileManager.default.destinationOfSymbolicLink(atPath: app.appending(path: $0.path).path(percentEncoded: false))
    }
    let verify = try await ProcessRunner().run(
        URL(filePath: "/usr/bin/codesign"),
        arguments: ["--verify", link == nil ? "--strict" : "--strict=sideband", "--deep", app.path(percentEncoded: false)])
    #expect(verify.succeeded, "\(verify.errorOutput)", sourceLocation: sourceLocation)

    let info = try #require(NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")), sourceLocation: sourceLocation)
    #expect(info["CFBundleIdentifier"] as? String == entry.bundleId, sourceLocation: sourceLocation)
    #expect(FileOperations.extendedAttribute(FileOperations.quarantineAttribute, at: app) == nil, sourceLocation: sourceLocation)

    let entitlements = try await entitlements(of: app)
    let expected = permissions.entitlements.merging(entry.codeSigning.entitlements) { a, _ in a }
    for (key, value) in expected {
        #expect(entitlements[key] as? Bool == value, "\(key)", sourceLocation: sourceLocation)
    }
    for permission in Permission.allCases where !permissions[permission] {
        #expect(entitlements[permission.entitlement] == nil, "\(permission.entitlement)", sourceLocation: sourceLocation)
    }
    let readable = [PortEntitlements.homeRelativeReadOnly, PortEntitlements.absoluteReadOnly]
        .compactMap { entitlements[$0] as? [String] }.joined()
    if link != nil {
        #expect(readable.count == 1, "\(readable)", sourceLocation: sourceLocation)
        #expect(readable.allSatisfy { $0.contains("/Library/\(entry.id)/assets") }, "\(readable)", sourceLocation: sourceLocation)
    } else {
        #expect(readable.isEmpty, "\(readable)", sourceLocation: sourceLocation)
    }
    let details = try await ProcessRunner().run(
        URL(filePath: "/usr/bin/codesign"), arguments: ["-dv", app.path(percentEncoded: false)])
    #expect(details.errorOutput.contains("flags=0x10002(adhoc,runtime)"), "\(details.errorOutput)", sourceLocation: sourceLocation)
}

func entitlements(of app: URL) async throws -> [String: Any] {
    let result = try await ProcessRunner().run(
        URL(filePath: "/usr/bin/codesign"),
        arguments: ["-d", "--entitlements", "-", "--xml", app.path(percentEncoded: false)], stderr: .discard)
    guard !result.stdout.isEmpty else { return [:] }
    return try PropertyListSerialization.propertyList(from: result.stdout, format: nil) as? [String: Any] ?? [:]
}

/// The process whose executable lies inside `app`.
func processID(running app: URL) -> pid_t? {
    func canonical(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(decoding: UnsafeRawBufferPointer(start: resolved, count: strlen(resolved)), as: UTF8.self)
    }
    guard let root = canonical(app.path(percentEncoded: false)) else { return nil }
    var pids = [pid_t](repeating: 0, count: 8192)
    let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard count > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    for pid in pids.prefix(Int(count)) where pid > 0 {
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
            let path = buffer.withUnsafeBufferPointer({ canonical(String(decoding: $0.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)) })
        else { continue }
        if path.hasPrefix(root + "/") { return pid }
    }
    return nil
}

/// libsystem_sandbox's `sandbox_check(pid, NULL, SANDBOX_FILTER_NONE)`: 1 when the process is sandboxed.
func isSandboxed(_ pid: pid_t) -> Bool {
    typealias SandboxCheck = @convention(c) (pid_t, UnsafePointer<CChar>?, Int32) -> Int32
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_check") else { return false }
    return unsafeBitCast(symbol, to: SandboxCheck.self)(pid, nil, 0) == 1
}

/// The run once it has ended, or nil when it's still going after `timeout`.
func endOf(_ run: Run, in events: AsyncStream<LaunchEvent>, timeout: Duration) async throws -> Run? {
    try await withThrowingTaskGroup(of: Run?.self) { group in
        group.addTask {
            for await event in events {
                if case .ended(let ended) = event, ended.id == run.id { return ended }
            }
            return nil
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            return nil
        }
        let first = try await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

func listing(_ folder: URL) -> String {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []).sorted()
        .joined(separator: ", ")
}
