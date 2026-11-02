import Foundation
import Testing
@testable import FrontportCore

/// The Survey with Installations on Devices: they put their Ports in the Library, and iOS Releases stay apart from the
/// Mac's. Without a `devices` source it reads as before.
@MainActor @Suite struct DeviceSurveyTests {
    let catalog = FakeCatalog(Self.catalog)
    let library = FakeLibrary()
    let roms = FakeROMs()
    let releases = FakeIOSReleases()
    let devices = FakeDeviceLibrary()
    let activities = Activities()
    let folder: TemporaryDirectory
    let paths: AppPaths

    init() throws {
        folder = try TemporaryDirectory()
        paths = AppPaths(root: folder.url.appending(path: "Frontport"), containers: folder.url.appending(path: "Containers"))
    }

    func survey(devices: (any DeviceRecords)?) -> Survey {
        Survey(
            .init(catalog: catalog, library: library, roms: roms, releases: releases, devices: devices),
            activities: activities, paths: paths)
    }

    /// The Lineup's Catalog, with an iOS version for Ship of Harkinian.
    static let catalog = {
        var catalog = LineupTests.catalog
        let index = catalog.ports.firstIndex { $0.id == "soh" }!
        catalog.ports[index].ios = IOSSpec(releases: .githubRelease(GitHubReleaseSource(repo: "HarbourMasters/Shipwright", asset: "*.ipa")))
        return catalog
    }()

    static let iPhone = Device(
        id: DeviceInstallationTests.device, name: "Test iPhone", model: "iPhone 13", osVersion: "27.0.1", families: [1])

    /// The Port on the iPhone, its record keeping `entry`.
    static func onDevice(_ entry: CatalogEntry, version: String = "1.1.0", installedAt: Date = .now) -> DeviceInstallation {
        var installation = DeviceInstallationTests.installation(profileExpires: .distantFuture, certificateExpires: .distantFuture)
        installation.port = entry.id
        installation.release = Release(port: entry.id, version: version)
        installation.bundleId = entry.id.deviceBundleID(team: DeviceInstallationTests.team)
        installation.installedAt = installedAt
        installation.entry = entry
        return installation
    }

    // MARK: Library

    /// A Port only a Device has is in the Library, listed, with no Installation on this Mac.
    @Test func aPortOnlyADeviceHasIsInTheLibrary() async throws {
        let soh = try #require(Self.catalog.entry("soh"))
        await devices.set([Self.onDevice(soh)], remembered: [Self.iPhone])
        let survey = survey(devices: devices)
        await survey.load()

        #expect(survey.libraryPorts.map(\.id) == ["soh"])
        #expect(survey.installation("soh") == nil)
        #expect(survey.isListed("soh"))
        #expect(survey.deviceInstallations(of: "soh").map(\.device) == [Self.iPhone.id])
        #expect(survey.deviceInstallation("soh", on: Self.iPhone.id)?.release.version == "1.1.0")
        #expect(survey.devices == [Self.iPhone])
        #expect(!survey.lineup.toInstall.contains { $0.id == "soh" })
    }

    /// The sidebar's sections: This Mac has its own Installations and first installs here, a Device its own and first
    /// installs there, and a Port on both is in each.
    @Test func eachSectionHasItsOwnPorts() async throws {
        let soh = try #require(Self.catalog.entry("soh"))
        await library.set([SurveyTests.installation("2ship"), SurveyTests.installation("soh")])
        await devices.set([Self.onDevice(soh)], remembered: [Self.iPhone])
        let survey = survey(devices: devices)
        await survey.load()
        #expect(survey.macPorts.map(\.id) == ["2ship", "soh"])
        #expect(survey.ports(on: Self.iPhone.id).map(\.id) == ["soh"])
        #expect(survey.ports(on: "00008110-0000000000000001").isEmpty)

        activities.run(.device(.install, Self.iPhone.id), on: "zelda64recomp") { _ in try await Task.sleep(for: .seconds(60)) } end: { _ in }
        activities.run(.install, on: "spaghettikart") { _ in try await Task.sleep(for: .seconds(60)) } end: { _ in }
        #expect(survey.ports(on: Self.iPhone.id).map(\.id).contains("zelda64recomp"))
        #expect(!survey.macPorts.map(\.id).contains("zelda64recomp"))
        #expect(survey.macPorts.map(\.id).contains("spaghettikart"))
        #expect(!survey.ports(on: Self.iPhone.id).map(\.id).contains("spaghettikart"))
        activities.cancel("zelda64recomp")
        activities.cancel("spaghettikart")
    }

    /// One the Catalog no longer lists keeps the entry its newest record there kept.
    @Test func anUnlistedPortOnADeviceKeepsTheEntryItsRecordKept() async {
        var gone = LineupTests.entry("gone", "Gone Port", game: "oot", repo: "someone/gone")
        gone.ios = Self.catalog.entry("soh")?.ios
        var older = gone
        older.name = "Gone Port (older)"
        var other = Self.onDevice(older, installedAt: Date(timeIntervalSince1970: 1_700_000_000))
        other.device = "00008112-0000000000000000"
        await devices.set([Self.onDevice(gone), other], remembered: [])
        let survey = survey(devices: devices)
        await survey.load()

        #expect(survey.entry("gone")?.name == "Gone Port")
        #expect(!survey.isListed("gone"))
        #expect(survey.libraryPorts.map(\.id) == ["gone"])
    }

    /// A Port installed on a Device from another Catalog than the one now listing it isn't taken over by that one.
    @Test func aPortOnADeviceFromAnotherCatalogStaysWithItsOwn() async throws {
        var added = try #require(Self.catalog.entry("2ship"))
        added.catalog = URL(string: "https://example.com/other/catalog.json")
        await devices.set([Self.onDevice(added)], remembered: [])
        let survey = survey(devices: devices)
        await survey.load()

        #expect(survey.catalog?.entry("2ship") == nil)
        #expect(survey.entry("2ship")?.catalog == added.catalog)
        #expect(survey.libraryPorts.map(\.id) == ["2ship"])
    }

    /// A first install on a Device counts as in the Library from when it starts, as one on this Mac does.
    @Test func aFirstInstallOnADeviceIsInTheLibraryWhileUnderWay() async {
        let survey = survey(devices: devices)
        await survey.load()
        activities.run(.device(.install, Self.iPhone.id), on: "soh") { _ in try await Task.sleep(for: .seconds(60)) } end: { _ in }
        #expect(survey.lineup.library.contains("soh"))

        activities.cancel("soh")
        let ended = await eventually { !survey.lineup.library.contains("soh") }
        #expect(ended)
    }

    /// So does preparing its iOS version for Devices, which leaves the Library again when nothing ends up installed.
    @Test func preparingForDevicesIsInTheLibraryWhileUnderWay() async {
        let survey = survey(devices: devices)
        await survey.load()
        activities.run(.prepareForDevices, on: "soh") { _ in } end: { _ in }
        #expect(survey.lineup.library.contains("soh"))

        let ended = await eventually { !survey.lineup.library.contains("soh") }
        #expect(ended)
        #expect(survey.libraryPorts.isEmpty)
    }

    /// This Mac's Installations and the Devices' land together: while the Devices are still being read, neither shows,
    /// so no screen sees a Library that has one and not the other.
    @Test func thisMacsAndTheDevicesInstallationsLandTogether() async throws {
        let soh = try #require(Self.catalog.entry("soh"))
        await library.set([SurveyTests.installation("2ship")])
        await devices.set([Self.onDevice(soh)], remembered: [Self.iPhone])
        let gate = Gate()
        await devices.hold(gate)
        let survey = survey(devices: devices)
        let loading = Task { await survey.load() }

        let held = await eventually { await gate.isWaiting }
        #expect(held)
        #expect(survey.installations.isEmpty && survey.deviceInstallations.isEmpty)
        #expect(survey.lineup.library.isEmpty)

        await gate.open()
        await loading.value
        #expect(survey.installations.keys.sorted() == ["2ship"])
        #expect(survey.devices == [Self.iPhone])
        #expect(survey.lineup.library == ["2ship", "soh"])
    }

    // MARK: iOS Releases

    /// iOS Releases are looked up on the iOS view and kept apart: never in `releases`, the Lineup or this Mac's offers.
    @Test func iOSReleasesAreKeptApartFromTheMacs() async throws {
        await releases.set(mac: LineupTests.release("soh", "9.3.0", published: "2026-10-01"))
        await releases.set(ios: LineupTests.release("soh", "9.9.9", published: "2026-10-20"))
        await library.set([SurveyTests.installation("soh", "9.3.0")])
        let survey = survey(devices: devices)
        await survey.refresh()

        #expect(survey.latestIOSRelease(for: "soh")?.version == "9.9.9")
        #expect(survey.iosReleases.keys.sorted() == ["soh"], "only Ports with an iOS version")
        #expect(survey.releases.map(\.version) == ["9.3.0"])
        #expect(survey.lineup.otherReleases.allSatisfy { $0.version != "9.9.9" })
        #expect(survey.lineup.projectUpdates.isEmpty)
        #expect(survey.updates["soh"] == nil, "an iOS Release isn't an update on this Mac")
        #expect(await releases.looked.filter(\.isIOS).map(\.port) == ["soh"])
    }

    /// An iOS Release goes once the Catalog drops the Port's iOS version, the last one it had included.
    @Test func anIOSReleaseGoesWithItsIOSVersion() async {
        await releases.set(ios: LineupTests.release("soh", "9.9.9", published: "2026-10-20"))
        let survey = survey(devices: devices)
        await survey.refresh()
        #expect(survey.latestIOSRelease(for: "soh")?.version == "9.9.9")

        await catalog.set(cached: LineupTests.catalog, published: LineupTests.catalog)
        await survey.refresh()
        #expect(survey.iosReleases.isEmpty)
    }

    /// An Installation on a Device follows its own Channel: once the iOS version's default Channel is another, the
    /// newest iOS Release on the Installation's is looked up too, so it's still offered an Update.
    @Test func anInstallationsOwnChannelIsLookedUpToo() async throws {
        var catalog = Self.catalog
        let index = catalog.ports.firstIndex { $0.id == "soh" }!
        catalog.ports[index].ios = IOSSpec(releases: .githubRelease(GitHubReleaseSource(
            repo: "HarbourMasters/Shipwright", asset: "*.ipa", channels: ["nightly", .stable])))
        await self.catalog.set(cached: catalog, published: catalog)
        let soh = try #require(catalog.entry("soh"))
        var installed = Self.onDevice(soh, version: "1.0.0")
        installed.release.published = LineupTests.date("2026-09-01")
        await devices.set([installed], remembered: [Self.iPhone])
        let nightly = Release(port: "soh", version: "2.0.0-nightly", channel: "nightly", published: LineupTests.date("2026-10-30"))
        let stable = Release(port: "soh", version: "1.5.0", channel: .stable, published: LineupTests.date("2026-10-20"))
        await releases.set(ios: nightly, on: "nightly")
        await releases.set(ios: stable, on: .stable)
        let survey = survey(devices: devices)
        await survey.refresh()

        #expect(survey.latestIOSRelease(for: "soh") == nightly, "the default Channel's, for installing")
        let newest = survey.latestIOSRelease(for: "soh", channel: installed.channel)
        #expect(newest == stable)
        #expect(IOSVersion(soh)?.update(for: installed, newest: newest) == stable)
    }

    /// A change on a Device looks up its iOS Release again, not the Mac's; a change here, the other way round.
    @Test func aChangeOnADeviceLooksUpItsIOSRelease() async {
        let survey = survey(devices: devices)
        await survey.load()
        await releases.set(ios: LineupTests.release("soh", "9.9.9", published: nil))
        await survey.changed("soh", by: .device(.install, Self.iPhone.id))
        #expect(survey.latestIOSRelease(for: "soh")?.version == "9.9.9")
        #expect(await releases.looked.map(\.isIOS) == [true])

        await releases.forget()
        await survey.changed("soh", by: .device(.uninstall, Self.iPhone.id))
        await survey.changed("soh", by: .update)
        #expect(await releases.looked.map(\.isIOS) == [false])
    }

    // MARK: Without Devices

    /// Without a `devices` source, the Survey reads only this Mac: no iOS lookups, no Devices.
    @Test func withoutADevicesSourceNothingChanges() async {
        await releases.set(mac: LineupTests.release("soh", "9.3.0", published: "2026-10-01"))
        await releases.set(ios: LineupTests.release("soh", "9.9.9", published: "2026-10-20"))
        await devices.set([Self.onDevice(Self.catalog.entry("soh")!)], remembered: [Self.iPhone])
        let survey = survey(devices: nil)
        await survey.refresh()

        #expect(survey.iosReleases.isEmpty)
        #expect(survey.deviceInstallations.isEmpty && survey.devices.isEmpty)
        #expect(survey.libraryPorts.isEmpty)
        #expect(survey.releases.map(\.version) == ["9.3.0"])
        let looked = await releases.looked
        #expect(!looked.contains { $0.isIOS })
        #expect(looked.map(\.port).sorted() == Self.catalog.ports.map(\.id).sorted())
        #expect(await devices.reads == 0)
    }
}

// MARK: Fakes

/// Installation records on Devices and the Devices remembered, set by the test, and changes that do only what the test
/// says: an install records what the test gave it, an uninstall drops the record, and preparing keeps what the test gave.
actor FakeDeviceLibrary: DeviceLibraryManaging {
    private var records: [DeviceInstallation] = []
    private var remembered: [Device] = []
    /// How many times the records were read.
    private(set) var reads = 0
    private var gate: Gate?
    /// What each Seed comes to, first first; once used up, a Seed succeeds with no plan.
    private var seedResults: [Result<DeviceSeedingPlan?, any Error>] = []
    /// What each Renew throws; nil lets it succeed.
    private var renewError: (any Error)?
    /// Each Seed and Renew started, in order.
    private(set) var seeds: [DeviceUpkeepState.Key] = []
    private(set) var renews: [DeviceUpkeepState.Key] = []
    /// Each Device forgotten, in order.
    private(set) var forgotten: [DeviceID] = []
    /// The record an install writes, on the Device it's given; none fails it.
    private var installing: DeviceInstallation?
    /// The app preparing comes to, and the one prepared.
    private var preparing: PreparedDeviceApp?
    private var preparedApp: PreparedDeviceApp?
    /// Each install and update started, with the Device as it was given, each uninstall, and each preparing, in order.
    private(set) var installs: [DeviceReading] = []
    private(set) var updates: [DeviceReading] = []
    private(set) var uninstalls: [DeviceUpkeepState.Key] = []
    private(set) var preparations: [PortID] = []
    /// What reading Seeding's plan comes to; each Device remembered again, and each plan read, in order.
    private var plan: DeviceSeedingPlan?
    private(set) var rememberings: [Device] = []
    private(set) var plans: [DeviceUpkeepState.Key] = []
    /// The Ports running on every Device, and how many times that was asked.
    private var running: Set<PortID> = []
    private(set) var runningChecks = 0

    func script(seeds results: [Result<DeviceSeedingPlan?, any Error>]) { seedResults = results }
    func failRenews(with error: (any Error)?) { renewError = error }
    func script(plan: DeviceSeedingPlan?) { self.plan = plan }
    func run(_ ports: Set<PortID>) { running = ports }
    func script(install record: DeviceInstallation) { installing = record }
    func script(prepare app: PreparedDeviceApp, prepared: PreparedDeviceApp? = nil) {
        preparing = app
        preparedApp = prepared
    }

    func set(_ records: [DeviceInstallation], remembered: [Device]) {
        self.records = records
        self.remembered = remembered
    }

    /// Holds the next reading of the Devices remembered until the gate opens.
    func hold(_ gate: Gate) { self.gate = gate }

    func installations() -> [DeviceInstallation] {
        reads += 1
        return records
    }
    private func installation(for port: PortID, on device: DeviceID) -> DeviceInstallation? {
        records.first { $0.port == port && $0.device == device }
    }
    func devices() async -> [Device] {
        if let gate {
            self.gate = nil
            await gate.wait()
        }
        return remembered
    }
    func remember(_ device: Device) {
        rememberings.append(device)
        remembered = remembered.map { $0.id == device.id ? device : $0 }
    }
    func forget(_ device: DeviceID) { forgotten.append(device) }
    func prepare(_ version: IOSVersion, channel: Channel, progress: @escaping ProgressHandler) throws -> PreparedDeviceApp {
        preparations.append(version.id)
        guard let preparing else { throw Unused() }
        preparedApp = preparing
        return preparing
    }
    func prepared(_ port: PortID) -> PreparedDeviceApp? { preparedApp?.port == port ? preparedApp : nil }
    func installPrepared(
        _ version: IOSVersion, on device: DeviceReading, team: AppleTeamID, progress: @escaping ProgressHandler
    ) throws -> DeviceInstallation {
        installs.append(device)
        guard var record = installing else { throw Unused() }
        record.device = device.device.id
        records.append(record)
        return record
    }
    func update(
        _ version: IOSVersion, on device: DeviceReading, team: AppleTeamID, channel: Channel,
        progress: @escaping ProgressHandler
    ) throws -> DeviceInstallation {
        updates.append(device)
        guard let record = installation(for: version.id, on: device.device.id) else { throw Unused() }
        return record
    }
    func renew(
        _ port: PortID, on device: DeviceReading, team: AppleTeamID, progress: @escaping ProgressHandler
    ) throws -> DeviceInstallation {
        renews.append(DeviceUpkeepState.Key(port, on: device.device.id))
        if let renewError { throw renewError }
        guard let record = installation(for: port, on: device.device.id) else { throw Unused() }
        return record
    }
    func uninstall(_ port: PortID, from device: DeviceID) {
        uninstalls.append(DeviceUpkeepState.Key(port, on: device))
        records.removeAll { $0.port == port && $0.device == device }
    }
    func seed(_ version: IOSVersion, on device: DeviceReading, progress: @escaping ProgressHandler) throws -> DeviceSeedingPlan? {
        seeds.append(DeviceUpkeepState.Key(version.id, on: device.device.id))
        return try seedResults.isEmpty ? nil : seedResults.removeFirst().get()
    }
    func seedingPlan(for version: IOSVersion, on device: DeviceReading) -> DeviceSeedingPlan? {
        plans.append(DeviceUpkeepState.Key(version.id, on: device.device.id))
        return plan
    }
    func isRunning(_ port: PortID, on device: DeviceID) -> Bool {
        runningChecks += 1
        return running.contains(port)
    }
    func removeLeftovers() {}
}

/// Each Port's newest Release on this Mac and its newest iOS Release, told apart as the Mac's Library tells them apart:
/// the iOS version's view fails `checkIdentity`.
actor FakeIOSReleases: ReleaseDiscovering {
    private var mac: [PortID: Release] = [:]
    private var ios: [PortID: Release] = [:]
    /// The lookups, in order.
    private(set) var looked: [(port: PortID, isIOS: Bool)] = []

    /// iOS Releases by Channel, for Ports set with `set(ios:on:)`: these answer only for their Channels.
    private var iosOn: [PortID: [Channel: Release]] = [:]

    func set(mac release: Release) { mac[release.port] = release }
    func set(ios release: Release) { ios[release.port] = release }
    func set(ios release: Release, on channel: Channel) { iosOn[release.port, default: [:]][channel] = release }
    func forget() { looked = [] }

    func latest(for entry: CatalogEntry, channel: Channel) -> Release? {
        let isIOS = (try? entry.checkIdentity()) == nil
        looked.append((entry.id, isIOS))
        if isIOS, let byChannel = iosOn[entry.id] { return byChannel[channel] }
        return isIOS ? ios[entry.id] : mac[entry.id]
    }

    func releases(for entry: CatalogEntry, channel: Channel) throws -> [Release] { throw Unused() }
}
