import Foundation
import Testing
@testable import FrontportCore

@MainActor @Suite struct SurveyTests {
    let catalog = FakeCatalog(LineupTests.catalog)
    let library = FakeLibrary()
    let roms = FakeROMs()
    let releases = FakeReleases()
    let activities = Activities()
    let folder: TemporaryDirectory
    let paths: AppPaths
    let survey: Survey

    init() throws {
        folder = try TemporaryDirectory()
        paths = AppPaths(root: folder.url.appending(path: "Frontport"), containers: folder.url.appending(path: "Containers"))
        survey = Survey(
            .init(catalog: catalog, library: library, roms: roms, releases: releases), activities: activities, paths: paths)
    }

    static func installation(_ port: PortID, _ version: String = "9.3.0", entry: CatalogEntry? = nil) -> Installation {
        Installation(
            port: port, release: Release(port: port, version: version), channel: .stable, installedAt: .now,
            appName: "\(port).app", entry: entry)
    }

    static let catalogWithout2Ship = {
        var catalog = LineupTests.catalog
        catalog.ports.removeAll { $0.id == "2ship" }
        return catalog
    }()

    // MARK: Catalog and checking

    /// Offline, the cached Catalog stays in use, and a Release lookup that succeeds still counts as checked.
    @Test func offlineKeepsTheCachedCatalog() async {
        await catalog.set(cached: Self.catalogWithout2Ship, published: nil)
        await survey.load()
        #expect(await survey.refresh())
        #expect(survey.catalog?.entry("2ship") == nil)
        #expect(survey.catalog?.entry("soh") != nil)
        #expect(survey.lastChecked != nil)
    }

    /// Checked once the Catalog or any Release lookup was reached; not when neither was.
    @Test func checkedOnceTheCatalogOrALookupWasReached() async {
        await catalog.set(cached: LineupTests.catalog, published: nil)
        await releases.goOffline()
        await survey.load()
        await survey.refresh()
        #expect(survey.lastChecked == nil)

        await catalog.set(cached: LineupTests.catalog, published: LineupTests.catalog)
        await survey.refresh()
        #expect(survey.lastChecked != nil)
    }

    /// A refresh asked for while one is under way doesn't run.
    @Test func refreshDuringAnotherReturnsAtOnce() async throws {
        let gate = Gate()
        await catalog.hold(gate)
        let survey = survey
        let first = Task { await survey.refresh() }
        let held = await eventually { await gate.isWaiting }
        try #require(held)
        #expect(await survey.refresh() == false)
        await gate.open()
        #expect(await first.value)
    }

    // MARK: Library

    /// The Catalog's Blocks are enforced before the Library is read, so an Installation they disable shows so at once.
    @Test func blocksAreEnforcedBeforeTheLibraryIsRead() async {
        await library.set([Self.installation("soh")])
        await library.block("soh")
        await survey.refresh()
        #expect(survey.installation("soh")?.disabled == true)
    }

    /// A failure to enforce Blocks is presented, and the rest of the refresh goes on.
    @Test func failureToEnforceBlocksIsPresented() async {
        var failures: [any Error] = []
        survey.onFailure = { failures.append($0) }
        await library.set([Self.installation("soh")])
        await library.failBlocks()
        await survey.refresh()
        #expect(failures.count == 1)
        #expect(survey.installation("soh") != nil)
        #expect(survey.lastChecked != nil)
    }

    /// An Installation the Catalog doesn't list keeps the entry its record kept; an older record without one gets a
    /// stand-in named from its app, which isn't enough to re-sign it.
    @Test func unlistedInstallationsGetStandIns() async throws {
        let kept = LineupTests.entry("gone", "Gone Port", game: "oot", repo: "someone/gone")
        let older = Self.installation("older")
        let plist = paths.app(for: older).appending(path: "Contents/Info.plist")
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleDisplayName": "Older Port", "CFBundleIdentifier": "dev.frontport.port.older"],
            format: .xml, options: 0
        ).write(to: plist)
        await library.set([Self.installation("gone", entry: kept), older])

        await survey.load()
        #expect(survey.entry("gone")?.name == "Gone Port")
        #expect(survey.entry("older")?.name == "Older Port")
        #expect(!survey.isListed("gone") && !survey.isListed("older"))
        #expect(survey.knowsEntry("gone"))
        #expect(!survey.knowsEntry("older"))
        #expect(survey.libraryPorts.map(\.id) == ["gone", "older"])
    }

    /// A first install counts as in the Library from when it starts until it ends.
    @Test func firstInstallsUnderWayAreInTheLibrary() async {
        await survey.load()
        activities.run(.install, on: "2ship") { _ in try await Task.sleep(for: .seconds(60)) } end: { _ in }
        #expect(survey.lineup.library.contains("2ship"))
        #expect(!survey.lineup.toInstall.contains { $0.id == "2ship" })

        activities.cancel("2ship")
        let ended = await eventually { !survey.lineup.library.contains("2ship") }
        #expect(ended)
    }

    /// A Port the refreshed Catalog drops stays in the Library, unlisted, with the entry its record kept and no offer.
    @Test func droppedPortsBecomeUnlisted() async {
        await library.set([Self.installation("2ship", "2.0.0", entry: LineupTests.catalog.entry("2ship"))])
        await releases.set(LineupTests.release("2ship", "2.1.0", published: nil))
        await survey.refresh()
        #expect(survey.updates["2ship"]?.version == "2.1.0")

        await catalog.set(cached: Self.catalogWithout2Ship, published: Self.catalogWithout2Ship)
        await survey.refresh()
        #expect(!survey.isListed("2ship"))
        #expect(survey.knowsEntry("2ship"))
        #expect(survey.entry("2ship")?.name == "2 Ship 2 Harkinian")
        #expect(survey.updates["2ship"] == nil)
        #expect(survey.libraryPorts.map(\.id) == ["2ship"])
    }

    /// A Port installed from Frontport's Catalog that only an added Catalog now lists stays unlisted, with no update
    /// from that Catalog; one installed from the added Catalog is listed by it (ADR 0012).
    @Test func portsStayWithTheCatalogTheyWereInstalledFrom() async {
        let added = URL(string: "https://example.org/catalog/")!
        var document = Self.catalogWithout2Ship
        var taken = LineupTests.catalog.entry("2ship")!
        taken.catalog = added
        document.ports.append(taken)
        await catalog.set(cached: document, published: document)
        await library.set([Self.installation("2ship", "2.0.0", entry: LineupTests.catalog.entry("2ship"))])
        await releases.set(LineupTests.release("2ship", "2.1.0", published: nil))
        await survey.refresh()
        #expect(!survey.isListed("2ship"))
        #expect(survey.updates["2ship"] == nil)

        await library.set([Self.installation("2ship", "2.0.0", entry: taken)])
        await survey.refresh()
        #expect(survey.isListed("2ship"))
        #expect(survey.updates["2ship"]?.version == "2.1.0")
    }

    /// A reading of Matching that finishes after a later one is dropped.
    @Test func staleMatchingIsDropped() async throws {
        let gate = Gate()
        await roms.set(Matching(askingAgain: ["old": ["soh"]]))
        await roms.hold(gate)
        let survey = survey
        let first = Task { await survey.romsChanged() }
        let held = await eventually { await gate.isWaiting }
        try #require(held)
        await roms.set(Matching(askingAgain: ["new": ["soh"]]))
        await survey.romsChanged()
        await gate.open()
        await first.value
        #expect(survey.matching.askingAgain(for: "new") == ["soh"])
        #expect(survey.matching.askingAgain(for: "old").isEmpty)
    }

    // MARK: Releases

    /// A lookup that fails keeps the Release found before.
    @Test func failedLookupKeepsTheKnownRelease() async {
        await releases.set(LineupTests.release("soh", "9.3.0", published: "2025-01-01"))
        await survey.refresh()
        await releases.fail("soh")
        await survey.refresh()
        #expect(survey.releases.map(\.version) == ["9.3.0"])
        #expect(survey.latestRelease(for: "soh")?.version == "9.3.0")
    }

    /// Releases of Catalog Ports only, newest first: a Port the Catalog drops leaves them.
    @Test func releasesOfCatalogPortsNewestFirst() async {
        await releases.set(LineupTests.release("soh", "9.3.0", published: "2025-01-01"))
        await releases.set(LineupTests.release("2ship", "2.0.0", published: "2025-06-01"))
        await survey.refresh()
        #expect(survey.releases.map(\.port) == ["2ship", "soh"])

        await catalog.set(cached: Self.catalogWithout2Ship, published: Self.catalogWithout2Ship)
        await survey.refresh()
        #expect(survey.releases.map(\.port) == ["soh"])
    }

    /// After a change to a Port's Release, only its newest Release is looked up again; other changes look up none.
    @Test func changesLookUpOnlyThatPortsRelease() async {
        await library.set([Self.installation("soh")])
        await survey.refresh()
        await releases.forget()
        await releases.set(LineupTests.release("soh", "9.3.1", published: "2025-02-01"))

        await survey.changed("soh", by: .update)
        #expect(await releases.looked == ["soh"])
        #expect(survey.updates["soh"]?.version == "9.3.1")

        await releases.forget()
        await survey.changed("soh", by: .permissions)
        #expect(await releases.looked.isEmpty)
    }
}

// MARK: Fakes

/// Yields until `condition` holds, a bounded number of times; false if it never did.
@MainActor func eventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<10_000 {
        if await condition() { return true }
        await Task.yield()
    }
    return await condition()
}

struct Unused: Error {}

/// Holds a fake's call until the test opens it.
actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    var isWaiting: Bool { continuation != nil }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

/// A Catalog cached on disk and published online; offline when nothing is published.
actor FakeCatalog: CatalogProviding {
    private var cached: CatalogDocument?
    private var published: CatalogDocument?
    private var gate: Gate?

    init(_ catalog: CatalogDocument) {
        cached = catalog
        published = catalog
    }

    func set(cached: CatalogDocument?, published: CatalogDocument?) {
        self.cached = cached
        self.published = published
    }

    /// Holds the next refresh until the gate opens.
    func hold(_ gate: Gate) { self.gate = gate }

    func current() throws -> CatalogDocument {
        guard let cached else { throw URLError(.fileDoesNotExist) }
        return cached
    }

    func refresh() async throws -> CatalogDocument {
        if let gate {
            self.gate = nil
            await gate.wait()
        }
        guard let published else { throw URLError(.notConnectedToInternet) }
        cached = published
        return published
    }

    func recipe(for entry: CatalogEntry) throws -> URL { throw Unused() }
    func recipe(at path: String, sha256: String, in catalog: URL?) throws -> URL { throw Unused() }
}

/// Installation records, and Blocks that disable some of them.
actor FakeLibrary: LibraryManaging {
    private var records: [Installation] = []
    private var blocked: Set<PortID> = []
    private var blocksFail = false

    func set(_ records: [Installation]) { self.records = records }
    func block(_ port: PortID) { blocked.insert(port) }
    func failBlocks() { blocksFail = true }

    func installations() -> [Installation] { records }
    func installation(for port: PortID) -> Installation? { records.first { $0.port == port } }

    func enforceBlocks(_ catalog: CatalogDocument) throws -> [Installation] {
        if blocksFail { throw URLError(.cannotWriteToFile) }
        var changed: [Installation] = []
        for index in records.indices where blocked.contains(records[index].port) && !records[index].disabled {
            records[index].disabled = true
            changed.append(records[index])
        }
        return changed
    }

    func install(_ entry: CatalogEntry, channel: Channel, progress: @escaping ProgressHandler) throws -> Installation {
        throw Unused()
    }
    func update(_ entry: CatalogEntry, to release: Release?, progress: @escaping ProgressHandler) throws -> Installation {
        throw Unused()
    }
    func rollback(_ entry: CatalogEntry, progress: @escaping ProgressHandler) throws -> Installation { throw Unused() }
    func switchChannel(
        _ entry: CatalogEntry, to channel: Channel, progress: @escaping ProgressHandler
    ) throws -> Installation {
        throw Unused()
    }
    func setPermissions(_ permissions: Permissions, for entry: CatalogEntry) throws -> Installation { throw Unused() }
    func applyROMs(to entry: CatalogEntry, progress: @escaping ProgressHandler) throws { throw Unused() }
    func uninstall(_ entry: CatalogEntry) throws { throw Unused() }
    func deleteData(_ entry: CatalogEntry) throws { throw Unused() }
    func removeBuildFolder(_ entry: CatalogEntry) throws { throw Unused() }
    func removeLeftovers() {}
    func snapshots(for port: PortID) -> [Snapshot] { [] }
    func restore(_ snapshot: Snapshot, entry: CatalogEntry) throws { throw Unused() }
}

/// ROMs whose Matching is set by the test, as of when a reading starts.
actor FakeROMs: ROMStoring {
    private var reading = Matching.empty
    private var gate: Gate?

    func set(_ reading: Matching) { self.reading = reading }

    /// Holds the next reading until the gate opens.
    func hold(_ gate: Gate) { self.gate = gate }

    func matching(_ entries: [CatalogEntry], installations: [PortID: Installation]) async -> Matching {
        let reading = reading
        if let gate {
            self.gate = nil
            await gate.wait()
        }
        return reading
    }

    func add(_ files: [URL], catalog: CatalogDocument) -> [ROMIntake] { [] }
    func assign(_ file: URL, as sha1: String, catalog: CatalogDocument) -> [ROMIntake] { [] }
    func remove(_ sha1: String) throws { throw Unused() }
    func seed(_ entry: CatalogEntry) throws { throw Unused() }
}

/// The newest Release of each Port, none by default; lookups fail for Ports set to fail, or all when offline.
actor FakeReleases: ReleaseDiscovering {
    private var newest: [PortID: Release] = [:]
    private var failing: Set<PortID> = []
    private var offline = false
    /// The Ports looked up, in order.
    private(set) var looked: [PortID] = []

    func set(_ release: Release) {
        newest[release.port] = release
        failing.remove(release.port)
    }
    func fail(_ port: PortID) { failing.insert(port) }
    func goOffline() { offline = true }
    func forget() { looked = [] }

    func latest(for entry: CatalogEntry, channel: Channel) throws -> Release? {
        looked.append(entry.id)
        if offline || failing.contains(entry.id) { throw URLError(.notConnectedToInternet) }
        return newest[entry.id]
    }

    func releases(for entry: CatalogEntry, channel: Channel) throws -> [Release] { throw Unused() }
}
