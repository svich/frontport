import Foundation
import FrontportCore
import Testing
@testable import FrontportLibrary

/// The Installation's folder on its own, over a temporary folder: no fakes, just apps made in `staging/` as the
/// Packager leaves them.
@Suite struct InstallationFolderTests {
    @Test func theReplacedReleaseIsKeptAsPreviousAndComesBack() throws {
        let f = try Folder()
        let first = try f.replace(nil, with: "1.0", assets: "assets 1.0")
        #expect(first.previous == nil && first.appName == "Starship.app" && f.folder.record == first)

        let second = try f.replace(first, with: "1.1", assets: "assets 1.1")

        #expect(second.previous == first.release && f.folder.record == second)
        #expect(try version(of: f.paths.app(for: second)) == "1.1")
        #expect(try f.read(f.paths.assets(for: port)) == "assets 1.1")
        let kept = try #require(f.folder.kept(entry, expecting: first.release))
        #expect(kept.record == first)
        #expect(try version(of: kept.app) == "1.0")
        #expect(try f.read(f.paths.previousAssets(for: port)) == "assets 1.0")

        // A Rollback swaps it back in, its Build Assets with it, and keeps nothing.
        let back = try f.folder.replace(second, with: kept.app, recording: kept.record, previous: .nothing)

        #expect(back.release == first.release && back.previous == nil && f.folder.record == back)
        #expect(try version(of: f.paths.app(for: back)) == "1.0")
        #expect(try f.read(f.paths.assets(for: port)) == "assets 1.0")
        #expect(!f.exists(f.paths.previous(for: port)))
    }

    /// The same Release packaged again, as when an extra remakes Build Assets inside an app of the old layout, keeps
    /// `previous/` and the record's previous Release.
    @Test func packagingTheSameReleaseAgainKeepsPrevious() throws {
        let f = try Folder()
        let first = try f.replace(nil, with: "1.0", assets: "assets 1.0")
        let second = try f.replace(first, with: "1.1", assets: "assets 1.1")
        var repackaged = second
        repackaged.buildAssets = BuildAssetsRecord(roms: ["bbb", "ccc"], format: "1")

        let app = try f.staged("1.1", assets: "assets 1.1 from bbb,ccc")
        #expect(try f.folder.replace(second, with: app, recording: repackaged, previous: .same) == repackaged)

        #expect(f.folder.record == repackaged)
        #expect(try f.read(f.paths.assets(for: port)) == "assets 1.1 from bbb,ccc")
        #expect(f.folder.kept(entry, expecting: first.release) != nil)
    }

    /// Whatever stops the swap, the current Release and its Build Assets stay in place under its record: also when the
    /// new app has another name, which moves the current one aside first, or comes without Build Assets.
    @Test(arguments: [("Starship", "assets 1.1"), ("Renamed", "assets 1.1"), ("Starship", nil)] as [(String, String?)])
    func aFailedSwapLeavesTheCurrentRelease(name: String, assets: String?) throws {
        let f = try Folder()
        let current = try f.replace(nil, with: "1.0", assets: "assets 1.0")
        let app = try f.staged("1.1", named: name, assets: assets)
        // A folder without write permission can't move to another folder.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: app.path(percentEncoded: false))

        #expect(throws: FrontportError.self) {
            try f.folder.replace(current, with: app, recording: f.record("1.1", assets: assets != nil), previous: .replaced)
        }

        #expect(try version(of: f.paths.app(for: current)) == "1.0")
        #expect(try f.read(f.paths.assets(for: port)) == "assets 1.0")
        #expect(f.folder.record == current)
        #expect(!f.exists(f.paths.previous(for: port)))
    }

    /// The record follows the app: when it can't be written, the app goes back, and `previous/` still holds the Release
    /// the record says it does.
    @Test func aFailedRecordLeavesTheCurrentRelease() throws {
        let f = try Folder()
        let first = try f.replace(nil, with: "1.0", assets: "assets 1.0")
        let current = try f.replace(first, with: "1.1", assets: "assets 1.1")
        // install.json can't be written: a folder stands in its way.
        let record = f.paths.installRecord(for: port)
        try FileManager.default.removeItem(at: record)
        try FileManager.default.createDirectory(at: record, withIntermediateDirectories: false)

        #expect(throws: (any Error).self) { try f.replace(current, with: "1.2", assets: "assets 1.2") }

        #expect(try version(of: f.paths.app(for: current)) == "1.1")
        #expect(try f.read(f.paths.assets(for: port)) == "assets 1.1")
        #expect(f.folder.kept(entry, expecting: current.previous) != nil)
    }

    /// On a case-insensitive volume `starship.app` and `Starship.app` are one name: replacing one with the other
    /// mustn't remove both. The test folder is on the startup volume, case-insensitive by default.
    @Test func renamingTheAppOnlyByCaseKeepsIt() throws {
        let f = try Folder()
        let first = try f.replace(nil, with: "1.0", named: "starship")
        let second = try f.replace(first, with: "1.1", named: "Starship")

        #expect(second.appName == "Starship.app")
        #expect(try version(of: f.paths.app(for: second)) == "1.1")
        #expect(try f.listing(f.paths.library(for: port)).contains("Starship.app"))

        let kept = try #require(f.folder.kept(entry, expecting: first.release))
        let back = try f.folder.replace(second, with: kept.app, recording: kept.record, previous: .nothing)

        #expect(back.appName == "starship.app")
        #expect(try version(of: f.paths.app(for: back)) == "1.0")
        #expect(try f.listing(f.paths.library(for: port)).contains("starship.app"))
    }

    /// A Release without Build Assets leaves none beside its app; the previous Release keeps its own.
    @Test func aReleaseWithoutBuildAssetsLeavesNoneBehind() throws {
        let f = try Folder()
        let first = try f.replace(nil, with: "1.0", assets: "assets 1.0")

        _ = try f.replace(first, with: "1.1")

        #expect(f.folder.assets == nil && !f.exists(f.paths.assets(for: port)))
        #expect(try f.read(f.paths.previousAssets(for: port)) == "assets 1.0")
        #expect(f.folder.kept(entry, expecting: first.release) != nil)
    }

    /// `previous/` counts only as the Release the record expects, with its app and the Build Assets it links to.
    @Test func keptIsOnlyTheExpectedReleaseWhole() throws {
        let f = try Folder()
        let first = try f.replace(nil, with: "1.0", assets: "assets 1.0")
        _ = try f.replace(first, with: "1.1", assets: "assets 1.1")

        #expect(f.folder.kept(entry, expecting: first.release) != nil)
        #expect(f.folder.kept(entry, expecting: nil) == nil)
        #expect(f.folder.kept(entry, expecting: Folder.release("0.9")) == nil)
        #expect(f.folder.kept(entry, expecting: Release(port: port, version: "1.0", tag: "v1.0-rebuilt")) == nil)

        try FileManager.default.removeItem(at: f.paths.previousAssets(for: port))
        #expect(f.folder.kept(entry, expecting: first.release) == nil, "its app links to Build Assets that are gone")
    }

    /// From before Frontport kept Build Assets beside the app, they're inside it, and must be there to be kept.
    @Test func anOldLayoutReleaseIsKeptWithTheBuildAssetsInsideIt() throws {
        let f = try Folder()
        let first = try f.replace(nil, with: "1.0", assets: "assets 1.0")
        _ = try f.moveInside(first)
        _ = try f.replace(first, with: "1.1", assets: "assets 1.1")

        let kept = try #require(f.folder.kept(entry, expecting: first.release))
        #expect(try f.read(kept.app.appending(path: spec.path)) == "assets 1.0")
        #expect(f.destination(kept.app.appending(path: spec.path)) == nil && !f.exists(f.paths.previousAssets(for: port)))

        try FileManager.default.removeItem(at: kept.app.appending(path: spec.path))
        #expect(f.folder.kept(entry, expecting: first.release) == nil)
    }

    /// A stop Block moves only the app aside: its link to the Build Assets leads nowhere until it's back.
    @Test func aStopBlockMovesOnlyTheAppAside() throws {
        let f = try Folder()
        let installed = try f.replace(nil, with: "1.0", assets: "assets 1.0")

        let disabled = try f.folder.disable(installed)

        let aside = f.folder.app(disabled)
        #expect(disabled.disabled && f.folder.record == disabled)
        #expect(aside == f.paths.blocked(for: port).appending(path: "Starship.app", directoryHint: .isDirectory))
        #expect(try version(of: aside) == "1.0")
        #expect(!f.exists(f.paths.app(for: installed)))
        #expect(try f.read(f.paths.assets(for: port)) == "assets 1.0")
        #expect(f.destination(aside.appending(path: spec.path)) == "../../../assets")
        #expect(!f.exists(aside.appending(path: spec.path)))
        #expect(try f.folder.disable(disabled) == disabled, "already aside")

        let enabled = try f.folder.enable(disabled)

        #expect(enabled == installed && f.folder.record == installed)
        #expect(try f.read(f.paths.app(for: enabled).appending(path: spec.path)) == "assets 1.0")
        #expect(!f.exists(f.paths.blocked(for: port)))
    }

    /// A change of Release lifts a stop Block, whether the app it moved aside is kept as the previous Release or
    /// replaced by it.
    @Test func replacingADisabledReleaseLiftsTheBlock() throws {
        let f = try Folder()
        let first = try f.replace(nil, with: "1.0", assets: "assets 1.0")

        let updated = try f.replace(f.folder.disable(first), with: "1.1", assets: "assets 1.1")

        #expect(!updated.disabled && updated.previous == first.release)
        #expect(try version(of: f.paths.app(for: updated)) == "1.1")
        #expect(!f.exists(f.paths.blocked(for: port)))
        let kept = try #require(f.folder.kept(entry, expecting: first.release))
        #expect(try version(of: kept.app) == "1.0")

        let back = try f.folder.replace(f.folder.disable(updated), with: kept.app, recording: kept.record, previous: .nothing)

        #expect(!back.disabled && back.release == first.release)
        #expect(try version(of: f.paths.app(for: back)) == "1.0")
        #expect(try f.read(f.paths.app(for: back).appending(path: spec.path)) == "assets 1.0")
        #expect(!f.exists(f.paths.blocked(for: port)) && !f.exists(f.paths.previous(for: port)))
    }

    /// With no change under way, `staging/` is left over, and so is a whole folder without a record, as a first install
    /// that failed leaves it; one that can't be read still marks an Installation.
    @Test func leftoversAreStagingOrAFolderWithoutARecord() throws {
        let f = try Folder()
        #expect(f.folder.leftovers == f.paths.library(for: port))

        _ = try f.replace(nil, with: "1.0")
        #expect(f.folder.leftovers == f.paths.staging(for: port))

        try Data("{".utf8).write(to: f.paths.installRecord(for: port))
        #expect(f.folder.record == nil && f.folder.isRecorded)
        #expect(f.folder.leftovers == f.paths.staging(for: port))
    }
}

private let port: PortID = "starship"
private let spec = BuildAssetsSpec(path: "Contents/Resources/sf64.o2r", format: "1")
private let entry = CatalogEntry(
    id: port, name: "Starship", kind: .decomp, game: "star-fox-64", developer: "HarbourMasters", summary: "",
    description: "", source: URL(string: "https://github.com/HarbourMasters/Starship")!,
    bundleId: "dev.frontport.port.starship",
    releases: .git(GitSource(repo: "HarbourMasters/Starship", refs: [.stable: "v2.0.0"], recipe: "recipes/starship.sh", recipeSHA256: "0")),
    buildAssets: spec)

private struct Folder {
    let tmp: TemporaryDirectory
    let paths: AppPaths
    let folder: InstallationFolder

    init() throws {
        tmp = try TemporaryDirectory()
        paths = AppPaths(root: tmp.url.appending(path: "root"), containers: tmp.url.appending(path: "Containers"))
        folder = InstallationFolder(paths: paths, port: port)
    }

    static func release(_ version: String) -> Release { Release(port: port, version: version, tag: "v\(version)") }

    /// The record a change to `version` would make; `replace` fills in the app's name and the previous Release.
    func record(_ version: String, assets: Bool) -> Installation {
        Installation(
            port: port, release: Self.release(version), channel: .stable, installedAt: Date(timeIntervalSince1970: 0),
            appName: "", buildAssets: assets ? BuildAssetsRecord(roms: ["bbb"], format: "1") : nil, entry: entry)
    }

    /// An app at `version` in a fresh `staging/`, as the Packager leaves it: with Build Assets holding `assets` beside
    /// it, which it links to, or without either.
    func staged(_ version: String, named name: String = "Starship", assets: String? = nil) throws -> URL {
        let app = try makeApp(named: name, version: version, in: folder.freshStaging())
        if let assets {
            try Data(assets.utf8).write(to: app.deletingLastPathComponent().appending(path: AppPaths.assetsName))
            let link = app.appending(path: spec.path)
            try FileManager.default.createSymbolicLink(
                atPath: link.path(percentEncoded: false), withDestinationPath: PortLinks.assetsDestination(for: spec.path))
        }
        return app
    }

    /// Replaces the current Release with `version`, kept as the previous one, as an update does.
    @discardableResult
    func replace(
        _ current: Installation?, with version: String, named name: String = "Starship", assets: String? = nil
    ) throws -> Installation {
        let app = try staged(version, named: name, assets: assets)
        defer { try? FileOperations.removeUntrusted(paths.staging(for: port)) }
        return try folder.replace(current, with: app, recording: record(version, assets: assets != nil), previous: .replaced)
    }

    /// Puts the Build Assets back inside the app, where Frontport kept them before it kept them beside it.
    func moveInside(_ installation: Installation) throws -> URL {
        let inside = paths.app(for: installation).appending(path: spec.path)
        try FileManager.default.removeItem(at: inside)
        try FileManager.default.moveItem(at: paths.assets(for: port), to: inside)
        return inside
    }

    func read(_ url: URL) throws -> String { try String(decoding: Data(contentsOf: url), as: UTF8.self) }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    func listing(_ folder: URL) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)) }

    /// Where the link at `url` leads, or nil when it's no link.
    func destination(_ url: URL) -> String? { try? FileManager.default.destinationOfSymbolicLink(atPath: url.path(percentEncoded: false)) }
}
