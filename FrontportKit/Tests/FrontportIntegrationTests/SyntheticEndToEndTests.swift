import CryptoKit
import Foundation
import FrontportBuilder
import FrontportCatalog
import FrontportCore
import FrontportLauncher
import FrontportLibrary
import FrontportPackager
import FrontportReleases
import FrontportROMs
import Testing

/// The whole pipeline with synthetic ROMs and stand-in Ports, never real games: every real module composed over a
/// test Catalog signed with a key made here, fake GitHub releases, a Recipe and a toolchain package, all served over
/// real HTTP from the loopback interface. The Ports run sandboxed in their real containers
/// (`~/Library/Containers/dev.frontport.port.synthetic-*`), whose Data the tests delete again.
///
///     FRONTPORT_SYNTHETIC_TESTS=1 [FRONTPORT_INTEGRATION_ROOT=/kept/folder] \
///     swift test --filter SyntheticEndToEndTests
///
/// They need the Command Line Tools (swiftc and clang) but no network. A synthetic Port whose container already holds
/// Data is refused rather than overwritten.
@Suite(
    .enabled(if: Integration.syntheticRequested, "Set FRONTPORT_SYNTHETIC_TESTS=1 to install synthetic Ports"),
    .serialized, .timeLimit(.minutes(10)))
struct SyntheticEndToEndTests {
    /// The Catalog arrives only through `refresh()`. A bad signature, an older `issued` and a 404 leave the cached
    /// Catalog as it was; the Recipe it pins is fetched on demand and checked against its sha256.
    @Test func refreshesTheSignedCatalogOverHTTP() async throws {
        let world = try await SyntheticWorld()
        let store = world.catalogStore
        let epoch = SyntheticWorld.epoch

        // Nothing published, as with the default URL until `main` is pushed: no Catalog at all.
        let unpublished = await #expect(throws: FrontportError.self) { try await store.refresh() }
        #expect(unpublished?.kind == "network")
        let missing = await #expect(throws: FrontportError.self) { try await store.current() }
        #expect(missing?.kind == "catalogUnavailable")

        let first = try world.publish(world.document(issued: epoch))
        let fetched = try await store.refresh()
        #expect(fetched.issued == epoch)
        #expect(fetched.problems() == [])
        #expect(try Data(contentsOf: world.paths.catalogDocument) == first)

        // A newer document that doesn't match its signature: signed by another key, or changed after signing.
        let newer = world.document(issued: epoch + 3600)
        try world.publish(newer, signedBy: Curve25519.Signing.PrivateKey())
        let otherKey = await #expect(throws: FrontportError.self) { try await store.refresh() }
        #expect(otherKey?.kind == "catalogInvalid")
        let signed = try JSON.encode(newer)
        world.server.serve("catalog/catalog.json", .json(signed + Data("\n".utf8)))
        world.server.serve("catalog/catalog.json.sig", .ok(try CatalogSignature.sign(signed, with: world.key)))
        let changed = await #expect(throws: FrontportError.self) { try await store.refresh() }
        #expect(changed?.kind == "catalogInvalid")
        #expect(try await store.current().issued == epoch)
        #expect(try Data(contentsOf: world.paths.catalogDocument) == first)

        // An older one, correctly signed, as a CDN might briefly serve: ignored.
        try world.publish(world.document(issued: epoch - 3600))
        #expect(try await store.refresh().issued == epoch)
        #expect(try Data(contentsOf: world.paths.catalogDocument) == first)

        // Gone (HTTP 404): the cached Catalog stays.
        world.server.serve("catalog/catalog.json", nil)
        let gone = await #expect(throws: FrontportError.self) { try await store.refresh() }
        #expect(gone?.kind == "network")
        #expect(try await store.current().issued == epoch)

        // A newer, valid one replaces it.
        let second = try world.publish(world.document(issued: epoch + 7200, ref: "v1.1"))
        let replaced = try await store.refresh()
        #expect(replaced.issued == epoch + 7200)
        #expect(try Data(contentsOf: world.paths.catalogDocument) == second)

        // Its Recipe is fetched over HTTP when first needed, and only the one the signed Catalog pins is kept.
        let entry = try #require(replaced.entry(SyntheticWorld.source))
        world.publishRecipe(SyntheticRecipe.script(layout: 9))
        let tampered = await #expect(throws: FrontportError.self) { try await store.recipe(for: entry) }
        #expect(tampered?.kind == "catalogInvalid")
        world.publishRecipe(SyntheticRecipe.script(layout: 1))
        let recipe = try await store.recipe(for: entry)
        #expect(path(recipe) == path(world.paths.recipe(SyntheticWorld.recipePath)))
        #expect(try Data(contentsOf: recipe) == SyntheticRecipe.script(layout: 1))

        // At the next launch the cache is verified again: accepted with the key Frontport trusts, refused with another.
        let relaunched = CatalogStore(paths: world.paths, bundled: nil, publicKey: world.key.publicKey)
        #expect(try await relaunched.current().issued == epoch + 7200)
        let untrusted = CatalogStore(paths: world.paths, bundled: nil, publicKey: Curve25519.Signing.PrivateKey().publicKey)
        let refused = await #expect(throws: FrontportError.self) { try await untrusted.current() }
        #expect(refused?.kind == "catalogUnavailable")
        print("[catalog] requests: \(world.server.hits)")
    }

    /// A prebuilt Port with a Runtime Requirement, installed before its ROM is added. The ROM, fed in `.v64` byte order,
    /// is standardized, kept read-only in ROMs, and Seeded into the Port's real container as a clone. The sandboxed Port
    /// reads it from there. After an update, a Rollback and Delete Data, applying ROMs primes the container and Seeds again.
    @Test func seedsARuntimeROMIntoTheContainerThroughThePipeline() async throws {
        let world = try await SyntheticWorld()
        let port = SyntheticWorld.prebuilt
        let data = world.paths.data(for: port.conventionalBundleID)
        try #require(!exists(data), "\(path(data)) holds Data this test would delete")
        defer { try? FileOperations.removeUntrusted(data) }

        let executable = try await SyntheticPrebuiltPort.compile(in: world.folder.url)
        let v10 = try await SyntheticPrebuiltPort.zip("1.0", executable: executable, in: world.folder.url)
        let v11 = try await SyntheticPrebuiltPort.zip("1.1", executable: executable, in: world.folder.url)
        try world.publishReleases([.init(tag: "v1.0", day: 1, zip: v10)])
        try world.publish(world.document(issued: SyntheticWorld.epoch))
        let catalog = try await world.catalogStore.refresh()
        let entry = try #require(catalog.entry(port))

        // Installed without its ROM: the Requirement is missing, and there's nothing to Seed yet.
        let installed = try await world.library.install(entry, channel: .stable, progress: world.progress)
        #expect(installed.release.tag == "v1.0" && installed.release.version == "1.0")
        try await expectSignedPort(world.paths.app(for: installed), entry: entry, permissions: installed.permissions)
        #expect(!exists(world.paths.downloads(for: port)), "the download goes once its Release is installed")
        let reading = await world.matching(entry)
        #expect(reading.missing().map(\.label) == ["Synthetic 64"])
        #expect(reading.unseeded == [])

        // The ROM in `.v64` byte order is stored in standard `.z64` form, read-only, named by that form's SHA-1.
        let v64 = world.folder.url.appending(path: "Synthetic (Test).v64")
        try SyntheticROM.v64(world.n64).write(to: v64)
        let added = await world.roms.add([v64], catalog: catalog)
        guard case .added(let record) = try #require(added.first) else {
            Issue.record("The .v64 ROM wasn't added: \(added)")
            return
        }
        #expect(record.sha1 == world.n64SHA1 && record.format == "z64" && record.size == 8 << 20)
        let kept = world.paths.rom(for: record)
        #expect(try Hashing.sha1(file: kept) == world.n64SHA1)
        #expect(mode(of: kept) == 0o444)
        // The same dump in `.z64` order is the same ROM; a different one is kept only if the user chooses, with its hash.
        let z64 = world.folder.url.appending(path: "Synthetic (Test).z64")
        try world.n64.write(to: z64)
        var other = world.n64
        other[4] ^= 0xFF
        let otherFile = world.folder.url.appending(path: "Other.z64")
        try other.write(to: otherFile)
        let again = await world.roms.add([z64, otherFile], catalog: catalog)
        #expect(again.first == .duplicate(record))
        guard case .unknown(_, let unknownSHA1, _, _)? = again.last else {
            Issue.record("An unlisted ROM was accepted: \(again)")
            return
        }
        #expect(unknownSHA1 == Hashing.sha1(other))

        // In ROMs but not in the Port's Data: not Seeded until ROMs are applied.
        #expect(await world.matching(entry).unseeded.map(\.label) == ["Synthetic 64"])
        try await world.library.applyROMs(to: entry, progress: world.progress)
        #expect(await world.matching(entry).unseeded == [])
        let seeded = data.appending(path: SyntheticWorld.seedPath)
        #expect(try Hashing.sha1(file: seeded) == world.n64SHA1)
        #expect(sharesAllBlocks(seeded), "the Seeded ROM is an APFS clone of the one in ROMs")
        #expect(mode(of: seeded) == 0o644)
        #expect(mode(of: seeded.deletingLastPathComponent()) == 0o700)

        // The sandboxed Port reads the Seeded ROM from its container and rewrites its own copy; the one in ROMs stays.
        let first = try await world.run(entry, installed)
        #expect(first.run.exitStatus == 0 && !first.run.signaled)
        #expect(first.log.contains("version=1.0\n"))
        #expect(first.log.contains("home=\(path(data).trimmingSuffix("/"))\n"))
        #expect(first.log.contains("container=\(port.conventionalBundleID)\n"))
        #expect(first.log.contains("sha1=\(world.n64SHA1)\n"))
        #expect(first.log.contains("rewrote=yes\n"))
        #expect(first.log.contains("outside=denied\n"), "the sandbox keeps the Port out of ROMs")
        #expect(try Hashing.sha1(file: seeded) == world.n64RewrittenSHA1)
        #expect(try Hashing.sha1(file: kept) == world.n64SHA1)
        #expect(mode(of: kept) == 0o444)

        // Upstream publishes 1.1, and then 1.2 without a digest, which is listed but never offered.
        try world.publishReleases([
            .init(tag: "v1.0", day: 1, zip: v10), .init(tag: "v1.1", day: 2, zip: v11),
            .init(tag: "v1.2", day: 3, zip: v11, digest: false),
        ])
        #expect(try await world.github.releases(for: entry, channel: .stable).map(\.tag) == ["v1.2", "v1.1", "v1.0"])
        let updated = try await world.library.update(entry, to: nil, progress: world.progress)
        #expect(updated.release.tag == "v1.1" && updated.previous?.tag == "v1.0")
        try await expectSignedPort(world.paths.app(for: updated), entry: entry, permissions: updated.permissions)
        let beforeUpdate = try #require(await world.library.snapshots(for: port).first)
        #expect(beforeUpdate.reason == .update && beforeUpdate.release == "1.0" && beforeUpdate.target == "1.1")
        #expect(world.server.hits.contains { $0.path == "/" + SyntheticWorld.releasesPath && $0.status == 304 })

        // 1.1 finds the Data 1.0 left, its rewritten copy included.
        let second = try await world.run(entry, updated)
        #expect(second.run.exitStatus == 0)
        #expect(second.log.contains("version=1.1\n") && second.log.contains("sha1=\(world.n64RewrittenSHA1)\n"))

        let rolledBack = try await world.library.rollback(entry, progress: world.progress)
        #expect(rolledBack.release.tag == "v1.0" && rolledBack.previous == nil)
        #expect(await world.library.snapshots(for: port).first?.reason == .rollback)

        // Delete Data leaves the container to macOS; the ROM is in ROMs but no longer Seeded.
        try await world.library.deleteData(entry)
        #expect(!exists(data))
        #expect(await world.library.snapshots(for: port) == [])
        let metadata = world.paths.container(for: port.conventionalBundleID)
            .appending(path: ".com.apple.containermanagerd.metadata.plist")
        #expect(exists(metadata))
        #expect(await world.matching(entry).unseeded.map(\.label) == ["Synthetic 64"])

        // Applying ROMs primes the container, so macOS lays Data out again, then Seeds a fresh clone.
        try await world.library.applyROMs(to: entry, progress: world.progress)
        #expect(exists(data.appending(path: "SystemData")) && exists(data.appending(path: "tmp")), "\(listing(data))")
        #expect(await world.matching(entry).unseeded == [])
        #expect(try Hashing.sha1(file: seeded) == world.n64SHA1)
        #expect(sharesAllBlocks(seeded))

        let third = try await world.run(entry, rolledBack)
        #expect(third.run.exitStatus == 0)
        #expect(third.log.contains("version=1.0\n") && third.log.contains("sha1=\(world.n64SHA1)\n"))

        // Installed again with the ROM already in ROMs, after Delete Data: Seeded by the install itself.
        try await world.library.uninstall(entry)
        try await world.library.deleteData(entry)
        let reinstalled = try await world.library.install(entry, channel: .stable, progress: world.progress)
        #expect(reinstalled.release.tag == "v1.1")
        #expect(await world.matching(entry).unseeded == [])
        #expect(try Hashing.sha1(file: seeded) == world.n64SHA1)
        let fourth = try await world.run(entry, reinstalled)
        #expect(fourth.log.contains("version=1.1\n") && fourth.log.contains("sha1=\(world.n64SHA1)\n"))

        try await world.library.uninstall(entry)
        try await world.library.deleteData(entry)
        #expect(!exists(data))
        #expect(try Hashing.sha1(file: kept) == world.n64SHA1)
    }

    /// A source-built Port with a Build-Stage Requirement: its Recipe, served and pinned by the signed Catalog, compiles
    /// the app in the build sandbox and makes Build Assets from the ROM. An extra added later makes them again. An update
    /// to another pinned ref with the same `format` carries them forward without giving the Recipe a ROM; a `format`
    /// bump regenerates them.
    @Test func makesBuildAssetsFromTheROMAndCarriesThemForward() async throws {
        let world = try await SyntheticWorld()
        let port = SyntheticWorld.source
        let data = world.paths.data(for: port.conventionalBundleID)
        try #require(!exists(data), "\(path(data)) holds Data this test would delete")
        defer { try? FileOperations.removeUntrusted(data) }

        world.publishRecipe(SyntheticRecipe.script(layout: 1))
        try world.publish(world.document(issued: SyntheticWorld.epoch, ref: "v1.0"))
        let catalog = try await world.catalogStore.refresh()
        let entry = try #require(catalog.entry(port))
        #expect(entry.isSourceBuilt)

        // Without its Build-Stage ROM the install stops before building.
        await #expect(throws: FrontportError.romMissing(port, requirement: "Synthetic SNES")) {
            try await world.library.install(entry, channel: .stable, progress: world.progress)
        }
        #expect(await world.library.installation(for: port) == nil)

        // The ROM with a copier header is stored without it, named by the headerless form's SHA-1.
        let rom = try await world.add(SyntheticROM.copierHeadered(world.snes), named: "Synthetic (Test).smc", catalog: catalog)
        #expect(rom.sha1 == world.snesSHA1 && rom.format == "sfc" && rom.size == 1 << 20)

        // Install: the Recipe compiles the app in the build sandbox and makes Build Assets from the ROM.
        let installed = try await world.library.install(entry, channel: .stable, progress: world.progress)
        #expect(installed.release.tag == "v1.0")
        #expect(installed.buildAssets == BuildAssetsRecord(roms: [world.snesSHA1], format: "1"))
        try await expectSignedPort(world.paths.app(for: installed), entry: entry, permissions: installed.permissions)
        let made = world.assets(layout: 1, madeAt: "v1.0", from: [world.snes])
        #expect(try world.assets(in: installed) == made)
        var log = try world.buildLog()
        #expect(log.contains("synthtool: building v1.0"), "the pinned toolchain is on the Recipe's PATH")
        #expect(log.contains(world.romsLine([world.snes])) && log.contains("==> Build Assets from 1 ROMs"))
        #expect(!exists(world.paths.builds(for: port).appending(path: "roms")), "the ROMs are removed after the build")
        for folder in ["out", "tmp"] {
            #expect(!exists(world.paths.builds(for: port).appending(path: folder)), "\(folder) is removed once the app is installed")
        }
        #expect(try await world.run(entry, installed).log == "ref=v1.0\n" + world.printed(made))
        // What it writes beside its executable lands in its Data, through the Redirect, in its real sandbox.
        let ran = data.appending(path: "\(SyntheticWorld.logFolder)/ran")
        #expect(try text(ran) == "ref=v1.0\n")

        // An extra added later is applied right away: the Build Assets are made again for the same Release.
        _ = try await world.add(world.extraA, named: "Synthetic (Extra A).sfc", catalog: catalog)
        try await world.library.applyROMs(to: entry, progress: world.progress)
        let extended = try #require(await world.library.installation(for: port))
        #expect(extended.release == installed.release && extended.previous == nil)
        // The log holds only the latest build.
        log = try world.buildLog()
        #expect(log.contains("build \(port) at v1.0") && !log.contains("fetch \(port)"), "same ref and Recipe: no new fetch")
        #expect(extended.buildAssets == BuildAssetsRecord(roms: [world.snesSHA1, world.extraASHA1].sorted(), format: "1"))
        try await expectSignedPort(world.paths.app(for: extended), entry: entry, permissions: extended.permissions)
        let madeWithExtra = world.assets(layout: 1, madeAt: "v1.0", from: [world.snes, world.extraA])
        #expect(try world.assets(in: extended) == madeWithExtra)
        #expect(try await world.run(entry, extended).log == "ref=v1.0\n" + world.printed(madeWithExtra))

        // Another pinned ref with the same format: the Build Assets are cloned forward. That needs no ROM, so the Recipe
        // gets none, and it works with the ROMs removed.
        try await world.roms.remove(world.snesSHA1)
        try await world.roms.remove(world.extraASHA1)
        try world.publish(world.document(issued: SyntheticWorld.epoch + 86_400, ref: "v1.1"))
        let carriedEntry = try #require(try await world.catalogStore.refresh().entry(port))
        let carried = try await world.library.update(carriedEntry, to: nil, progress: world.progress)
        #expect(carried.release.tag == "v1.1" && carried.previous?.tag == "v1.0")
        #expect(carried.buildAssets == extended.buildAssets)
        log = try world.buildLog()
        #expect(log.contains("fetch \(port) at v1.1") && log.contains("build \(port) at v1.1") && !log.contains("v1.0"))
        #expect(log.contains("==> ROMs: none, so no Build Assets\n") && !log.contains("==> Build Assets from"))
        #expect(try world.assets(in: carried) == madeWithExtra)
        #expect(try await world.run(carriedEntry, carried).log == "ref=v1.1\n" + world.printed(madeWithExtra))

        // A Recipe change that alters the Build Assets comes with a format bump, so the update must regenerate them,
        // which needs the ROM again.
        world.publishRecipe(SyntheticRecipe.script(layout: 2))
        try world.publish(world.document(
            issued: SyntheticWorld.epoch + 2 * 86_400, ref: "v1.2", recipe: SyntheticRecipe.script(layout: 2), format: "2"))
        let bumpedEntry = try #require(try await world.catalogStore.refresh().entry(port))
        await #expect(throws: FrontportError.romMissing(port, requirement: "Synthetic SNES")) {
            try await world.library.update(bumpedEntry, to: nil, progress: world.progress)
        }
        #expect(await world.library.installation(for: port) == carried)

        // ROMs added while that update waits leave the installed app with the Build Assets made for it: the Recipe now
        // makes them in a format that app wasn't built for.
        _ = try await world.add(SyntheticROM.copierHeadered(world.snes), named: "Synthetic (Test).smc", catalog: catalog)
        _ = try await world.add(world.extraB, named: "Synthetic (Extra B).sfc", catalog: catalog)
        let before = try world.buildLog()
        try await world.library.applyROMs(to: bumpedEntry, progress: world.progress)
        #expect(await world.library.installation(for: port) == carried)
        #expect(try world.assets(in: carried) == madeWithExtra)
        #expect(try world.buildLog() == before, "nothing was built")

        // The update regenerates them from the ROMs now present.
        let regenerated = try await world.library.update(bumpedEntry, to: nil, progress: world.progress)
        #expect(regenerated.release.tag == "v1.2" && regenerated.previous?.tag == "v1.1")
        #expect(regenerated.buildAssets == BuildAssetsRecord(roms: [world.snesSHA1, world.extraBSHA1].sorted(), format: "2"))
        log = try world.buildLog()
        #expect(log.contains(world.romsLine([world.snes, world.extraB])) && log.contains("==> Build Assets from 2 ROMs"))
        let remade = world.assets(layout: 2, madeAt: "v1.2", from: [world.snes, world.extraB])
        #expect(try world.assets(in: regenerated) == remade)
        #expect(try await world.run(bumpedEntry, regenerated).log == "ref=v1.2\n" + world.printed(remade))

        // Rollback brings back the previous Release with the Build Assets made for it.
        let rolledBack = try await world.library.rollback(bumpedEntry, progress: world.progress)
        #expect(rolledBack.release.tag == "v1.1" && rolledBack.buildAssets == extended.buildAssets)
        #expect(try await world.run(bumpedEntry, rolledBack).log == "ref=v1.1\n" + world.printed(madeWithExtra))
        #expect(try text(ran) == "ref=v1.1\n")

        // Delete Data leaves the Build Assets alone. The Redirect's folder comes back at once, after the primer has
        // macOS lay Data out again, so a launch from the Dock finds it.
        try await world.library.deleteData(bumpedEntry)
        #expect(!exists(ran) && exists(data.appending(path: SyntheticWorld.logFolder)) && exists(data.appending(path: "tmp")))
        #expect(try world.assets(in: rolledBack) == madeWithExtra)
        try await world.library.uninstall(bumpedEntry)
        #expect(!exists(world.paths.builds(for: port)) && !exists(world.paths.logs(for: port)))
    }
}

// MARK: Composition

/// The services as `AppServices.live` builds them, over a fresh Frontport folder, with the Catalog, GitHub's API, the
/// Releases' downloads, the Recipe and the toolchain all served by a `LocalServer`.
extension SyntheticWorld {
    /// Where the entry's Requirements stand in ROMs and, once it's installed, its Data.
    func matching(_ entry: CatalogEntry) async -> PortMatching {
        let installations = await library.installations().filter { $0.port == entry.id }
        let reading = await roms.matching([entry], installations: Dictionary(uniqueKeysWithValues: installations.map { ($0.port, $0) }))
        return reading[entry.id]!
    }
}

struct SyntheticWorld {
    static let prebuilt: PortID = "synthetic-prebuilt"
    static let source: PortID = "synthetic-source"
    static let prebuiltRepo = "frontport-test/synthetic-prebuilt"
    static let sourceRepo = "frontport-test/synthetic-source"
    static let releasesPath = "api/repos/\(prebuiltRepo)/releases"
    static let recipePath = "recipes/synthetic-source.sh"
    static let seedPath = "Library/Application Support/Synthetic/baserom.z64"
    /// Where the source-built Port's Redirect leads its log, in its Data.
    static let logFolder = "Library/Application Support/Synthetic/log"
    /// When the first test Catalog is issued.
    static let epoch = Date(timeIntervalSince1970: 1_790_000_000)

    let folder: Scratch
    let server: LocalServer
    /// The key the test Catalog is signed with, standing in for the one built into Frontport.
    let key = Curve25519.Signing.PrivateKey()
    let paths: AppPaths
    let catalogStore: CatalogStore
    let github: GitHubReleases
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

    /// The synthetic ROMs in standard form: an N64 one for the prebuilt Port, and a SNES one with two optional extras
    /// for the source-built Port.
    let n64 = SyntheticROM.z64()
    let snes = SyntheticROM.sfc()
    let extraA = SyntheticROM.extra(seed: 17)
    let extraB = SyntheticROM.extra(seed: 18)
    let n64SHA1: String
    /// The N64 ROM once the Port has written 0 to its last byte.
    let n64RewrittenSHA1: String
    let snesSHA1: String
    let extraASHA1: String
    let extraBSHA1: String

    init() async throws {
        n64SHA1 = Hashing.sha1(n64)
        var rewritten = n64
        rewritten[rewritten.count - 1] = 0
        n64RewrittenSHA1 = Hashing.sha1(rewritten)
        snesSHA1 = Hashing.sha1(snes)
        extraASHA1 = Hashing.sha1(extraA)
        extraBSHA1 = Hashing.sha1(extraB)

        folder = try Scratch()
        server = try await LocalServer()
        paths = AppPaths(
            root: folder.url.appending(path: "Frontport", directoryHint: .isDirectory),
            containers: AppPaths.default.containers)
        try FileOperations.createDirectory(paths.root)
        // Nothing bundled: the Catalog arrives only through refresh().
        catalogStore = CatalogStore(
            paths: paths, bundled: nil, baseURL: server.url("catalog/"), publicKey: key.publicKey,
            session: GitHubReleases.defaultSession)
        github = GitHubReleases(
            cache: paths.catalog.appending(path: "releases", directoryHint: .isDirectory), api: server.url("api/"))
        fetcher = AssetFetcher(paths: paths)
        let toolchain = try await SyntheticToolchain.zip(in: folder.url)
        server.serve("toolchain/synthtool.zip", .ok(toolchain))
        builder = RecipeBuilder(
            paths: paths,
            manifest: SyntheticToolchain.manifest(url: server.url("toolchain/synthtool.zip"), sha256: Hashing.sha256(toolchain)))
        roms = ROMStore(paths: paths)
        primer = ContainerPrimer(executable: try await Integration.primerExecutable(in: folder.url), paths: paths)
        packager = PortPackager(paths: paths, primer: primer)
        launcher = PortLauncher(paths: paths, primer: primer)
        library = Library(
            paths: paths, catalog: catalogStore, releases: github, fetcher: fetcher, builder: builder, roms: roms,
            packager: packager, launcher: launcher, primer: primer)
    }

    // MARK: Catalog

    /// The test Catalog: both synthetic Ports, the source-built one pinned to `ref`, with `recipe` and Build Assets in
    /// `format`.
    func document(
        issued: Date, ref: String = "v1.0", recipe: Data = SyntheticRecipe.script(layout: 1), format: String = "1"
    ) -> CatalogDocument {
        let prebuilt = CatalogEntry(
            id: Self.prebuilt, name: "Synthetic Prebuilt", kind: .recomp, game: "synthetic-64",
            developer: "Frontport tests", summary: "A stand-in for a prebuilt Port.", description: "",
            source: URL(string: "https://github.com/\(Self.prebuiltRepo)")!, bundleId: Self.prebuilt.conventionalBundleID,
            releases: .githubRelease(GitHubReleaseSource(repo: Self.prebuiltRepo, asset: "Synthetic-*-mac.zip")),
            requirements: [Requirement(label: "Synthetic 64", stage: .runtime, oneOf: [n64SHA1], seedPath: Self.seedPath)],
            launch: LaunchSpec(
                arguments: [Self.seedPath],
                environment: ["SYNTHETIC_OUTSIDE": path(paths.rom(n64SHA1, format: "z64"))]))
        let source = CatalogEntry(
            id: Self.source, name: "Synthetic Source", kind: .decomp, game: "synthetic-snes",
            developer: "Frontport tests", summary: "A stand-in for a source-built Port.", description: "",
            source: URL(string: "https://github.com/\(Self.sourceRepo)")!, bundleId: Self.source.conventionalBundleID,
            releases: .git(GitSource(
                repo: Self.sourceRepo, refs: [.stable: ref], recipe: Self.recipePath, recipeSHA256: Hashing.sha256(recipe))),
            requirements: [
                Requirement(label: "Synthetic SNES", stage: .build, oneOf: [snesSHA1], extras: [extraASHA1, extraBSHA1])
            ],
            buildAssets: BuildAssetsSpec(path: SyntheticRecipe.assetsPath, format: format),
            redirects: [Redirect(path: SyntheticRecipe.logPath, to: Self.logFolder)])
        return CatalogDocument(
            issued: issued,
            platforms: [
                Platform(id: "n64", name: "Nintendo 64", shortName: "N64", medium: .cartridge),
                Platform(id: "snes", name: "Super Nintendo", shortName: "SNES", medium: .cartridge),
            ],
            games: [
                Game(id: "synthetic-64", name: "Synthetic 64", platform: "n64"),
                Game(id: "synthetic-snes", name: "Synthetic SNES", platform: "snes"),
            ],
            roms: [
                KnownROM(sha1: n64SHA1, game: "synthetic-64", name: "Synthetic (Test)", format: "z64"),
                KnownROM(sha1: snesSHA1, game: "synthetic-snes", name: "Synthetic (Test)", format: "sfc"),
                KnownROM(sha1: extraASHA1, game: "synthetic-snes", name: "Synthetic (Extra A)", format: "sfc"),
                KnownROM(sha1: extraBSHA1, game: "synthetic-snes", name: "Synthetic (Extra B)", format: "sfc"),
            ],
            ports: [prebuilt, source])
    }

    /// Serves the document and its signature, made with the test's key unless `signer` says otherwise. Returns the
    /// document's bytes.
    @discardableResult
    func publish(_ document: CatalogDocument, signedBy signer: Curve25519.Signing.PrivateKey? = nil) throws -> Data {
        let data = try JSON.encode(document)
        server.serve("catalog/catalog.json", .json(data))
        server.serve("catalog/catalog.json.sig", .ok(try CatalogSignature.sign(data, with: signer ?? key)))
        return data
    }

    func publishRecipe(_ recipe: Data) {
        server.serve("catalog/\(Self.recipePath)", .ok(recipe))
    }

    // MARK: Releases

    struct UpstreamRelease {
        var tag: String
        /// Days after `epoch` it was created.
        var day: Int
        var zip: Data
        var digest = true
    }

    /// Serves GitHub's release list for the prebuilt Port, newest first, and each Release's zip.
    func publishReleases(_ releases: [UpstreamRelease]) throws {
        var list: [[String: Any]] = []
        for release in releases.sorted(by: { $0.day > $1.day }) {
            let name = "Synthetic-\(release.tag.dropFirst())-mac.zip"
            let download = "download/\(release.tag)/\(name)"
            server.serve(download, .ok(release.zip))
            var asset: [String: Any] = [
                "name": name, "size": release.zip.count, "browser_download_url": server.url(download).absoluteString,
            ]
            if release.digest { asset["digest"] = "sha256:\(Hashing.sha256(release.zip))" }
            let date = (Self.epoch + Double(release.day) * 86_400).formatted(.iso8601)
            list.append([
                "tag_name": release.tag, "name": "Synthetic \(release.tag)", "body": "Synthetic release \(release.tag).",
                "draft": false, "prerelease": false, "created_at": date, "published_at": date,
                "html_url": server.url("releases/\(release.tag)").absoluteString, "assets": [asset],
            ])
        }
        server.serve(Self.releasesPath, .json(try JSONSerialization.data(withJSONObject: list)))
    }

    // MARK: Running and reading

    /// Launches the Installation, waits for the Port to exit, and returns the ended run and its log.
    func run(_ entry: CatalogEntry, _ installation: Installation) async throws -> (run: Run, log: String) {
        let events = await launcher.events()
        let started = try await launcher.launch(entry, installation: installation)
        let ended = try #require(try await endOf(started, in: events, timeout: .seconds(30)), "\(entry.id) didn't exit")
        let log = try text(ended.log)
        print("[\(entry.id)] \(installation.release.version) exited with \(ended.exitStatus ?? -1):\n\(log)")
        return (ended, log)
    }

    /// The source-built Port's build log, which holds only its latest build.
    func buildLog() throws -> String {
        String(decoding: try Data(contentsOf: paths.buildLog(for: Self.source)), as: UTF8.self)
    }

    /// Writes `contents` to a file of that name and adds it to ROMs, which must accept it.
    func add(_ contents: Data, named name: String, catalog: CatalogDocument) async throws -> ROMRecord {
        let file = folder.url.appending(path: name)
        try contents.write(to: file)
        let result = await roms.add([file], catalog: catalog)
        guard case .added(let record)? = result.first else {
            throw FrontportError.romRejected(sha1: nil, reason: "\(name) wasn't added: \(result)")
        }
        return record
    }

    /// The Build Assets the Recipe makes from these ROMs, which it lists in the order of their file names.
    func assets(layout: Int, madeAt ref: String, from roms: [Data]) -> String {
        let lines = roms.map { (Hashing.sha1($0), $0.count) }.sorted { $0.0 < $1.0 }.map { "rom=\($0.0) \($0.1)\n" }
        return "layout=\(layout)\nmade-at=\(ref)\n" + lines.joined()
    }

    /// An Installation's Build Assets, beside its app, which links to them from inside.
    func assets(in installation: Installation) throws -> String {
        let link = paths.app(for: installation).appending(path: SyntheticRecipe.assetsPath)
        try #require(
            try FileManager.default.destinationOfSymbolicLink(atPath: path(link)) == "../../../assets",
            "\(path(link)) isn't the Packager's link")
        return try text(paths.assets(for: installation.port))
    }

    /// The line the Recipe logs for the ROMs it was given.
    func romsLine(_ roms: [Data]) -> String {
        "==> ROMs: " + roms.map { "\(Hashing.sha1($0)).sfc" }.sorted().joined(separator: " ") + "\n"
    }

    /// What the source-built Port prints for its Build Assets.
    func printed(_ assets: String) -> String {
        assets.split(separator: "\n").map { "assets: \($0)\n" }.joined()
    }
}

extension FrontportError {
    /// The case's name, such as "catalogInvalid".
    fileprivate var kind: String { String(String(describing: self).prefix { $0 != "(" }) }
}

extension String {
    fileprivate func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
