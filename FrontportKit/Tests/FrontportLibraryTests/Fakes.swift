import Foundation
import FrontportCore
import FrontportPackager
@testable import FrontportROMs

final class TemporaryDirectory: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "FrontportLibraryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    // Folder ROMs and some tests leave read-only folders, which a plain removal stops at.
    deinit { try? FileOperations.removeUntrusted(url) }
}

/// Thread-safe mutable state shared between a test and its fakes.
final class Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    var get: Value { lock.withLock { value } }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
    func update<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
}

struct FakeCatalog: CatalogProviding {
    let recipe: URL

    func current() async throws -> CatalogDocument { throw FrontportError.catalogUnavailable("fake") }
    func refresh() async throws -> CatalogDocument { throw FrontportError.catalogUnavailable("fake") }
    func recipe(for entry: CatalogEntry) async throws -> URL { recipe }
    func recipe(at path: String, sha256: String, in catalog: URL?) async throws -> URL { recipe }
}

/// Serves `latest[channel]`.
struct FakeReleases: ReleaseDiscovering {
    let latest: Box<[Channel: Release]>

    func releases(for entry: CatalogEntry, channel: Channel) async throws -> [Release] {
        latest.get[channel].map { [$0] } ?? []
    }

    func latest(for entry: CatalogEntry, channel: Channel) async throws -> Release? {
        latest.get[channel]
    }
}

/// Makes a minimal app named after the Port whose `Contents/Resources/version` is the Release's version. Its
/// executable is a copy of `true`, so the real Packager can sign it.
func makeApp(named name: String, version: String, in directory: URL) throws -> URL {
    let app = directory.appending(path: "\(name).app", directoryHint: .isDirectory)
    let fm = FileManager.default
    try fm.createDirectory(at: app.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
    try fm.createDirectory(at: app.appending(path: "Contents/Resources"), withIntermediateDirectories: true)
    try fm.copyItem(at: URL(filePath: "/usr/bin/true"), to: app.appending(path: "Contents/MacOS/\(name)"))
    let info = ["CFBundleIdentifier": "org.example.\(name.lowercased())", "CFBundleExecutable": name, "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: app.appending(path: "Contents/Info.plist"))
    try Data(version.utf8).write(to: app.appending(path: "Contents/Resources/version"))
    return app
}

func version(of app: URL) throws -> String {
    try String(decoding: Data(contentsOf: app.appending(path: "Contents/Resources/version")), as: UTF8.self)
}

struct FakeFetcher: AssetFetching {
    /// The app's name, which upstream may change between Releases.
    let appName: Box<String>
    /// Releases fetched, and the most fetches seen in flight at once.
    let fetched = Box<[String]>([])
    let inFlight = Box((now: 0, most: 0))

    init(appName: String) { self.appName = Box(appName) }

    func fetch(_ release: Release, into directory: URL, progress: @escaping ProgressHandler) async throws -> URL {
        inFlight.update { $0.now += 1; $0.most = max($0.most, $0.now) }
        defer { inFlight.update { $0.now -= 1 } }
        try await Task.sleep(for: .milliseconds(30))
        fetched.update { $0.append(release.version) }
        return try makeApp(named: appName.get, version: release.version, in: directory)
    }
}

/// Builds into `Builds/<port>/out`; makes Build Assets ("assets from <sha1s>") only when given ROMs.
struct FakeBuilder: RecipeBuilding {
    let paths: AppPaths
    let appName: String
    /// The SHA-1s fed to each build.
    let builds = Box<[[String]]>([])
    /// When set, the Recipe leaves a link to this app instead of an app of its own.
    let linkedApp = Box<URL?>(nil)
    /// When true, the Build Assets are a folder holding the text as `data`, as OpenGOAL's are.
    let assetsFolder = Box(false)
    /// What each unpack leaves, folder name to files; and each unpack's installer name, workspace and log.
    let unpacked = Box<[String: [String: Data]]>([:])
    let unpacks = Box<[(name: String, workspace: PortID, log: URL)]>([])

    func toolchainStatus() async -> ToolchainStatus { .ready }
    func prepareToolchain(progress: @escaping ProgressHandler) async throws {}

    func build(
        _ entry: CatalogEntry, ref: String, recipe: URL, roms: BuildROMs, log: URL,
        progress: @escaping ProgressHandler
    ) async throws -> BuildProduct {
        let sha1s = roms.sha1s
        builds.update { $0.append(sha1s) }
        let out = paths.buildOutput(for: entry.id)
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        if let linked = linkedApp.get {
            let link = out.appending(path: "\(appName).app")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: linked)
            return BuildProduct(app: link)
        }
        let app = try makeApp(named: appName, version: ref, in: out)
        guard !roms.isEmpty else { return BuildProduct(app: app) }
        let assets = out.appending(path: "assets")
        let text = Data("assets from \(sha1s.joined(separator: ","))".utf8)
        if assetsFolder.get {
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            try text.write(to: assets.appending(path: "data"))
        } else {
            try text.write(to: assets)
        }
        return BuildProduct(app: app, assets: assets)
    }

    func unpack(
        _ installer: URL, named name: String, workspace: PortID, recipe: URL, log: URL, progress: @escaping ProgressHandler
    ) async throws -> [URL] {
        unpacks.update { $0.append((name, workspace, log)) }
        let out = paths.buildOutput(for: workspace)
        try? FileManager.default.removeItem(at: out)
        var folders: [URL] = []
        for (folder, files) in unpacked.get.sorted(by: { $0.key < $1.key }) {
            for (path, data) in files {
                let file = out.appending(path: "\(folder)/\(path)")
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file)
            }
            folders.append(out.appending(path: folder, directoryHint: .isDirectory))
        }
        return folders
    }
}

/// The real ROMStore over the test's paths, with made-up ROMs put in as intake would have left them, so tests can name
/// them by short made-up hashes.
struct StoredROMs {
    let store: ROMStore

    var paths: AppPaths { store.paths }

    /// Stores `rom <sha1>` as a read-only `<sha1>.z64` and lists it in the index.
    func add(_ sha1: String, game: GameID = "game") async throws {
        let contents = Data("rom \(sha1)".utf8)
        let url = paths.rom(sha1, format: "z64")
        try FileManager.default.createDirectory(at: paths.roms, withIntermediateDirectories: true)
        try contents.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path(percentEncoded: false))
        var index = (try? JSON.read([ROMRecord].self, from: paths.romIndex)) ?? []
        index.append(
            ROMRecord(
                sha1: sha1, game: game, name: sha1, format: "z64", size: Int64(contents.count), added: Date(),
                originalFilename: "\(sha1).n64"))
        try JSON.write(index, to: paths.romIndex)
        await store.reloadIndex()
    }

    func remove(_ sha1: String) async throws {
        try await store.remove(sha1)
    }
}

/// Signs nothing, so the real Packager's checks and links run without codesign: records each item it was asked to sign,
/// with its entitlements.
struct RecordingSigner: Signer {
    let signed = Box<[(item: URL, entitlements: [String: PortEntitlements.Value]?)]>([])

    func sign(_ item: URL, entitlements: [String: PortEntitlements.Value]?) async throws {
        signed.update { $0.append((item, entitlements)) }
    }

    func verify(_ app: URL, strictness: Strictness) async throws {}
}

/// The real Packager over a `RecordingSigner`, recording what the Library asked of it.
struct RecordingPackager: PortPackaging {
    let signer = RecordingSigner()
    let packager: PortPackager
    let packaged = Box<[(app: String, permissions: Permissions, installedAssets: URL?)]>([])
    let resigned = Box<[(app: URL, permissions: Permissions, installedAssets: URL?)]>([])
    /// Runs after each package, so a test can change the world between packaging and the swap.
    let afterPackaging = Box<(@Sendable () throws -> Void)?>(nil)

    init(paths: AppPaths, primer: (any ContainerPriming)?) {
        packager = PortPackager(paths: paths, primer: primer, signer: signer)
    }

    func package(
        _ app: URL, entry: CatalogEntry, permissions: Permissions, assets: URL?, installedAssets: URL?
    ) async throws {
        defer { try? afterPackaging.get?() }
        packaged.update { $0.append((try! version(of: app), permissions, assets == nil ? nil : installedAssets)) }
        try await packager.package(app, entry: entry, permissions: permissions, assets: assets, installedAssets: installedAssets)
    }

    func resign(_ app: URL, entry: CatalogEntry, permissions: Permissions, installedAssets: URL?) async throws {
        resigned.update { $0.append((app, permissions, installedAssets)) }
        try await packager.resign(app, entry: entry, permissions: permissions, installedAssets: installedAssets)
    }

    /// Whether the app at `app` was last signed with these Permissions' entitlements, and no other Permission's.
    func signed(_ app: URL, with permissions: Permissions) -> Bool {
        let path = { (url: URL) in url.standardizedFileURL.path(percentEncoded: false).trimmingCharacters(in: ["/"]) }
        guard let entitlements = signer.signed.get.last(where: { path($0.item) == path(app) })?.entitlements else {
            return false
        }
        return Permission.allCases.allSatisfy { (entitlements[$0.entitlement] == .flag(true)) == permissions[$0] }
    }
}

struct FakeLauncher: PortLaunching {
    let runningPorts = Box<Set<PortID>>([])

    func launch(_ entry: CatalogEntry, installation: Installation) async throws -> Run {
        throw FrontportError.notInstalled(entry.id)
    }
    func isRunning(_ entry: CatalogEntry) async -> Bool { runningPorts.get.contains(entry.id) }
    func running() async -> Set<PortID> { runningPorts.get }
    func stop(_ entry: CatalogEntry) async {}
    func runs(for port: PortID) async -> [Run] { [] }
    func events() async -> AsyncStream<LaunchEvent> { AsyncStream { $0.finish() } }
}

/// Creates `Data/` as macOS does when a sandboxed process with the bundle ID starts, and counts the runs.
struct FakePrimer: ContainerPriming {
    let paths: AppPaths
    let runs = Box(0)

    func prime(_ entry: CatalogEntry) async throws {
        runs.update { $0 += 1 }
        try FileManager.default.createDirectory(
            at: paths.data(for: entry.bundleId).appending(path: "Library/Application Support"),
            withIntermediateDirectories: true)
    }
}
