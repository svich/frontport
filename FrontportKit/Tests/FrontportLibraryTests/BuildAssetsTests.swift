import Foundation
import FrontportCore
import FrontportPackager
import Testing
@testable import FrontportLibrary
import FrontportROMs

/// A Port's Build Assets on their own, over a temporary folder: the real ROMStore and Packager, which signs nothing, and
/// a Release installed as the Library leaves it, with Build Assets made from `bbb` beside its app.
@Suite struct BuildAssetsTests {
    // MARK: Changing Releases

    /// Carrying them forward needs no ROM. Only the app's own count: beside it through the Packager's link, or inside
    /// it in the old layout, never through a link of another's.
    @Test func onlyTheAppsOwnAreCarriedForward() async throws {
        let f = try Setup()
        let current = try await f.installed()
        let record = BuildAssetsRecord(roms: ["bbb"], format: "1")

        let plan = try await f.assets().plan(from: current)
        #expect(plan.roms.isEmpty)
        #expect(plan.ready(f.product()) == .init(url: f.paths.assets(for: port), record: record))

        let inside = try f.moveInside(current)
        #expect(try await f.assets().plan(from: current).ready(f.product()) == .init(url: inside, record: record))

        let outside = f.tmp.url.appending(path: "outside.o2r")
        try FileManager.default.moveItem(at: inside, to: outside)
        try FileManager.default.createSymbolicLink(at: inside, withDestinationURL: outside)
        await #expect(throws: FrontportError.romMissing(port, requirement: "Star Fox 64")) {
            try await f.assets().plan(from: current)
        }
    }

    @Test func missingOnesAreMadeAgainFromTheirROMs() async throws {
        let f = try Setup()
        let current = try await f.installed()
        try FileManager.default.removeItem(at: f.paths.assets(for: port))
        await #expect(throws: FrontportError.romMissing(port, requirement: "Star Fox 64")) {
            try await f.assets().plan(from: current)
        }
        try await f.roms.add("bbb")

        let plan = try await f.assets().plan(from: current)

        let made = try f.made("assets from bbb")
        #expect(plan.roms.sha1s == ["bbb"])
        #expect(plan.ready(f.product(made)) == .init(url: made, record: BuildAssetsRecord(roms: ["bbb"], format: "1")))
        #expect(plan.ready(f.product()) == nil, "the Recipe made none")
    }

    @Test func anotherFormatIsMadeFromEveryROM() async throws {
        let f = try Setup()
        let current = try await f.installed()
        try await f.roms.add("bbb")
        try await f.roms.add("ccc")

        let plan = try await f.assets(entry(format: "2")).plan(from: current)

        let made = try f.made("assets from bbb,ccc")
        #expect(plan.ready(f.product(made)) == .init(url: made, record: BuildAssetsRecord(roms: ["bbb", "ccc"], format: "2")))
    }

    @Test func aPortWithoutThemGetsNone() async throws {
        let f = try Setup()
        var without = entry
        without.buildAssets = nil
        try await f.roms.add("bbb")

        let plan = try await f.assets(without).plan(from: nil)

        #expect(plan.ready(f.product(try f.made("assets"))) == nil)
    }

    // MARK: Adding ROMs

    @Test func madeAgainOnlyForAROMTheyWereNotMadeFrom() async throws {
        let f = try Setup()
        let current = try await f.installed()
        try await f.roms.add("bbb")
        #expect(await f.assets().regeneration(of: current) == nil)

        try await f.roms.add("ccc")
        let plan = try #require(await f.assets().regeneration(of: current))

        let made = try f.made("assets from bbb,ccc")
        #expect(plan.roms.sha1s == ["bbb", "ccc"])
        #expect(plan.ready(f.product(made)) == .init(url: made, record: BuildAssetsRecord(roms: ["bbb", "ccc"], format: "1")))
    }

    /// The Recipe would now make them in a format the installed app wasn't built for: they wait for the update. A stop
    /// Block's app aside, and a Build Requirement without a Match, wait too.
    @Test func notWhileAnotherFormatWaitsTheAppIsAsideOrAROMIsMissing() async throws {
        let f = try Setup()
        let current = try await f.installed()
        try await f.roms.add("ccc")
        #expect(await f.assets().regeneration(of: current) == nil, "no Match for bbb")
        try await f.roms.add("bbb")

        #expect(await f.assets(entry(format: "2")).regeneration(of: current) == nil)
        #expect(await f.assets().regeneration(of: try f.folder.disable(current)) == nil)
    }

    // MARK: Installing

    /// Beside the app, they change without it: neither packaged again nor re-signed.
    @Test func besideTheAppTheyChangeWithoutIt() async throws {
        let f = try Setup()
        let current = try await f.installed()
        let ready = try f.ready("assets from bbb,ccc")

        let installed = try await f.assets().install(ready, in: current, progress: { _ in })

        #expect(installed.buildAssets == ready.record && installed.release == current.release)
        #expect(f.folder.record == installed)
        #expect(try f.read(f.paths.assets(for: port)) == "assets from bbb,ccc")
        #expect(try f.read(f.paths.app(for: installed).appending(path: sf64)) == "assets from bbb,ccc")
        #expect(f.packager.packaged.get.count == 1 && f.packager.resigned.get.isEmpty)
        #expect(!f.exists(f.paths.staging(for: port)))
    }

    /// The app's exception names a file or a folder, so it's re-signed when they turn into the other, or were missing.
    @Test(arguments: [false, true])
    func aFolderOrMissingOnesResign(missing: Bool) async throws {
        let f = try Setup()
        let current = try await f.installed()
        if missing { try FileManager.default.removeItem(at: f.paths.assets(for: port)) }
        let ready = try f.ready("assets from bbb,ccc", folder: !missing)

        let installed = try await f.assets().install(ready, in: current, progress: { _ in })

        let app = f.paths.app(for: installed)
        #expect(f.packager.resigned.get.map(\.app) == [app])
        #expect(f.packager.resigned.get.map(\.installedAssets) == [f.paths.assets(for: port)])
        #expect(try f.read(app.appending(path: missing ? sf64 : "\(sf64)/data")) == "assets from bbb,ccc")
        #expect(f.folder.record == installed)
    }

    @Test func aFailedResignPutsTheInstalledOnesBack() async throws {
        let f = try Setup()
        let current = try await f.installed()
        let ready = try f.ready("assets from bbb,ccc", folder: true)

        await #expect(throws: FrontportError.signingFailed("refused")) {
            try await f.assets(packager: Refusing(packager: f.packager, refusing: [1])).install(ready, in: current, progress: { _ in })
        }

        #expect(f.folder.record == current)
        #expect(try f.read(f.paths.assets(for: port)) == "assets from bbb")
        #expect(!f.exists(f.paths.staging(for: port)))
    }

    /// Once re-signed for them, the app is signed again for the ones put back. Should that fail, it keeps the new
    /// ones, which it's signed for.
    @Test(arguments: [false, true])
    func aRecordThatCannotBeWrittenPutsThemBack(undoRefused: Bool) async throws {
        let f = try Setup()
        let current = try await f.installed()
        let record = f.paths.installRecord(for: port)
        try FileManager.default.removeItem(at: record)
        try FileManager.default.createDirectory(at: record.appending(path: "blocked"), withIntermediateDirectories: true)
        let ready = try f.ready("assets from bbb,ccc", folder: true)

        await #expect(throws: (any Error).self) {
            try await f.assets(packager: Refusing(packager: f.packager, refusing: undoRefused ? [2] : []))
                .install(ready, in: current, progress: { _ in })
        }

        let assets = f.paths.assets(for: port)
        if undoRefused {
            #expect(try f.read(assets.appending(path: "data")) == "assets from bbb,ccc")
        } else {
            #expect(try f.read(assets) == "assets from bbb")
        }
        #expect(f.exceptions().last?.hasSuffix("/") == FileOperations.isDirectory(assets), "signed for what's there")
        #expect(!f.exists(f.paths.staging(for: port)))
    }

    /// An app from before Frontport kept them beside it is packaged again, which moves them out.
    @Test func anAppThatKeepsThemInsideIsPackagedAgain() async throws {
        let f = try Setup()
        let current = try await f.installed()
        _ = try f.moveInside(current)
        let ready = try f.ready("assets from bbb,ccc")

        let installed = try await f.assets().install(ready, in: current, progress: { _ in })

        let app = f.paths.app(for: installed)
        #expect(f.packager.packaged.get.count == 2)
        #expect(f.packager.packaged.get.last?.installedAssets == f.paths.assets(for: port))
        #expect(try f.read(f.paths.assets(for: port)) == "assets from bbb,ccc")
        #expect(f.destination(app.appending(path: sf64)) == "../../../assets")
        #expect(f.folder.record == installed && installed.buildAssets == ready.record)
        #expect(!f.exists(f.paths.staging(for: port)))
    }
}

// MARK: Setup

private let port: PortID = "starship"
private let sf64 = "Contents/Resources/sf64.o2r"
private let entry = CatalogEntry(
    id: port, name: "Starship", kind: .decomp, game: "star-fox-64", developer: "HarbourMasters", summary: "",
    description: "", source: URL(string: "https://github.com/HarbourMasters/Starship")!,
    bundleId: "dev.frontport.port.starship",
    releases: .git(GitSource(repo: "HarbourMasters/Starship", refs: [.stable: "v2.0.0"], recipe: "recipes/starship.sh", recipeSHA256: "0")),
    requirements: [Requirement(label: "Star Fox 64", stage: .build, oneOf: ["bbb"], extras: ["ccc"])],
    buildAssets: BuildAssetsSpec(path: sf64, format: "1"))

private func entry(format: String) -> CatalogEntry {
    var entry = entry
    entry.buildAssets?.format = format
    return entry
}

/// Refuses the re-signs it's told to, counting from 1, as codesign would an app it can't verify, and passes the rest on.
private struct Refusing: PortPackaging {
    let packager: RecordingPackager
    let refusing: Set<Int>
    private let count = Box(0)

    init(packager: RecordingPackager, refusing: Set<Int>) {
        self.packager = packager
        self.refusing = refusing
    }

    func package(_ app: URL, entry: CatalogEntry, permissions: Permissions, assets: URL?, installedAssets: URL?) async throws {
        try await packager.package(app, entry: entry, permissions: permissions, assets: assets, installedAssets: installedAssets)
    }

    func resign(_ app: URL, entry: CatalogEntry, permissions: Permissions, installedAssets: URL?) async throws {
        if refusing.contains(count.update({ $0 += 1; return $0 })) { throw FrontportError.signingFailed("refused") }
        try await packager.resign(app, entry: entry, permissions: permissions, installedAssets: installedAssets)
    }
}

private struct Setup {
    let tmp: TemporaryDirectory
    let paths: AppPaths
    let roms: StoredROMs
    let packager: RecordingPackager
    let folder: InstallationFolder

    init() throws {
        tmp = try TemporaryDirectory()
        paths = AppPaths(root: tmp.url.appending(path: "root"), containers: tmp.url.appending(path: "Containers"))
        roms = StoredROMs(store: ROMStore(paths: paths))
        packager = RecordingPackager(paths: paths, primer: nil)
        folder = InstallationFolder(paths: paths, port: port)
    }

    func assets(_ entry: CatalogEntry = entry, packager: (any PortPackaging)? = nil) -> BuildAssets {
        BuildAssets(entry: entry, folder: folder, roms: roms.store, packager: packager ?? self.packager)
    }

    /// Starship 2.0.0, packaged and swapped in as the Library installs it, with Build Assets made from `bbb`.
    func installed() async throws -> Installation {
        let staging = try folder.freshStaging()
        defer { try? FileOperations.removeUntrusted(staging) }
        let app = try makeApp(named: "Starship", version: "v2.0.0", in: staging)
        try await packager.package(
            app, entry: entry, permissions: entry.permissions, assets: try made("assets from bbb"),
            installedAssets: paths.assets(for: port))
        let installation = Installation(
            port: port, release: Release(port: port, version: "2.0.0", tag: "v2.0.0"), channel: .stable,
            installedAt: Date(timeIntervalSince1970: 0), appName: "", permissions: entry.permissions,
            buildAssets: BuildAssetsRecord(roms: ["bbb"], format: "1"), entry: entry)
        return try folder.replace(nil, with: app, recording: installation, previous: .nothing)
    }

    /// Build Assets as the Recipe leaves them in its output: a file holding `text`, or a folder holding it as `data`.
    func made(_ text: String, folder: Bool = false) throws -> URL {
        let out = tmp.url.appending(path: "out", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let assets = out.appending(path: "assets")
        if folder {
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: assets.appending(path: "data"))
        } else {
            try Data(text.utf8).write(to: assets)
        }
        return assets
    }

    /// Build Assets the Recipe made again from `bbb` and `ccc`, ready to install.
    func ready(_ text: String, folder: Bool = false) throws -> BuildAssets.Ready {
        BuildAssets.Ready(url: try made(text, folder: folder), record: BuildAssetsRecord(roms: ["bbb", "ccc"], format: "1"))
    }

    /// What the Recipe left: an app, and Build Assets when it made them.
    func product(_ assets: URL? = nil) -> BuildProduct {
        BuildProduct(app: tmp.url.appending(path: "out/Starship.app"), assets: assets)
    }

    /// Puts the Build Assets back inside the app, where Frontport kept them before it kept them beside it.
    func moveInside(_ installation: Installation) throws -> URL {
        let inside = paths.app(for: installation).appending(path: sf64)
        try FileManager.default.removeItem(at: inside)
        try FileManager.default.moveItem(at: paths.assets(for: port), to: inside)
        return inside
    }

    /// What each signing of the app let it read beside it, in order: a folder's path ends in `/`.
    func exceptions() -> [String] {
        packager.signer.signed.get.compactMap {
            guard case .paths(let paths)? = $0.entitlements?[PortEntitlements.absoluteReadOnly] else { return nil }
            return paths.first
        }
    }

    func read(_ url: URL) throws -> String { try String(decoding: Data(contentsOf: url), as: UTF8.self) }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    /// Where the link at `url` leads, or nil when it's no link.
    func destination(_ url: URL) -> String? { try? FileManager.default.destinationOfSymbolicLink(atPath: url.path(percentEncoded: false)) }
}
