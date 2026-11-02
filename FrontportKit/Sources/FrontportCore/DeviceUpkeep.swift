import Foundation
import Observation
import os

/// Where the Apple Team chosen in Settings › Devices and whether Frontport Renews on its own are kept between launches.
@MainActor
public protocol DevicePreferences: AnyObject {
    /// The Apple Team chosen; nil leaves it to the only one in the keychain.
    var team: AppleTeamID? { get set }
    /// On unless the user turned it off.
    var renewsOnItsOwn: Bool { get set }
}

/// Device preferences kept in memory only: for previews and tests.
@MainActor
public final class HeldDevicePreferences: DevicePreferences {
    public var team: AppleTeamID?
    public var renewsOnItsOwn: Bool

    public init(team: AppleTeamID? = nil, renewsOnItsOwn: Bool = true) {
        self.team = team
        self.renewsOnItsOwn = renewsOnItsOwn
    }
}

/// Every change Frontport makes to the Ports on iPhones and iPads, and what it keeps doing for them while it's open
/// (DESIGN › Devices): it reads the paired Devices and the Apple Teams; prepares, installs, updates, uninstalls, Seeds and
/// Renews as the user asks; Seeds what waited for a Device to be ready or for a Port to quit there, and what was just
/// installed; and Renews on its own what's due, holding back one that failed. The rules are Core's pure ones
/// (`DeviceUpkeepState`, `DeviceStatus`, `DeviceInstallStatus`); this wires them, so a change the rules don't allow now
/// never starts. The App tells it what happened (ROMs were added, Frontport came to the front, the user asked) and it
/// starts each change through `perform`, the App's way of running one as the Port's Activity, on the Device as it's
/// read when the change's turn comes, handing along what the change calls for once it ended. It hears of every Activity
/// that starts or ends from `Activities`. What it says of each Port on each Device (`status`) is what the App's screens
/// show of Devices.
///
/// Readings are live and never stored, unlike the records the Survey reads, and read apart from it, so a slow
/// `devicectl` never holds the Survey up. A reading started after another wins: only the latest lands.
@MainActor @Observable
public final class DeviceUpkeep {
    /// What it reads and changes Devices through.
    public struct Services: Sendable {
        public var devices: any DeviceLibraryManaging
        /// Reads every paired Device now (`DeviceControlling.readings`).
        public var readings: @Sendable () async throws -> [DeviceReading]
        /// The Apple Teams in the keychain (`Provisioning.teams`).
        public var teams: @Sendable () async -> [AppleTeam]

        public init(
            devices: any DeviceLibraryManaging, readings: @escaping @Sendable () async throws -> [DeviceReading],
            teams: @escaping @Sendable () async -> [AppleTeam]
        ) {
            self.devices = devices
            self.readings = readings
            self.teams = teams
        }
    }

    /// Runs a change as the Port's Activity, as the App runs every change, then, once the Port's state is reloaded, its
    /// Activity still showing, tells `End` what came of it and presents the failure it returns, if any.
    public typealias Perform = @MainActor (Activity.Kind, PortID, @escaping Activities.Work, @escaping End) -> Void
    /// What a change calls for once it ended and its Port's state was reloaded; it returns the failure to present, if
    /// any.
    public typealias End = @MainActor (Activities.Outcome) -> (any Error)?
    private typealias Key = DeviceUpkeepState.Key

    /// Devices are read this often while a screen that shows them is open.
    public static let interval = Duration.seconds(10)
    /// A screen that opens within this of a reading's start doesn't start another.
    static let recent = Duration.seconds(5)

    // MARK: State

    /// By UDID, from the latest reading. A Device it didn't find is away.
    public private(set) var readings: [DeviceID: DeviceReading] = [:]
    /// Whether Xcode with its iOS platform was there at the latest reading; nil before the first.
    public private(set) var hasXcode: Bool?
    /// The Apple Teams with an Apple Development certificate in the keychain, by name.
    public private(set) var teams: [AppleTeam] = []
    /// The Apple Team chosen in Settings › Devices. Nil leaves it to `team`. Choosing one lets a failed Renew be tried
    /// again.
    public var chosenTeam: AppleTeamID? {
        didSet {
            preferences.team = chosenTeam
            change { $0.teamChanged() }
            renewDue()
        }
    }
    /// Whether Frontport Renews Ports on Devices on its own, as Settings › Devices says.
    public var renewsOnItsOwn: Bool {
        didSet {
            preferences.renewsOnItsOwn = renewsOnItsOwn
            renewDue()
        }
    }
    /// What's kept for each Installation on a Device: the plan Seeding last read there, what Seeding waits for, and why
    /// Seeding or a Renew last failed, which holds the next Renew on its own back.
    private var state = DeviceUpkeepState()

    /// Set by the App before anything happens.
    @ObservationIgnored public var perform: Perform = { _, _, _, _ in }

    @ObservationIgnored private let services: Services?
    @ObservationIgnored private let survey: Survey
    @ObservationIgnored private let activities: Activities
    @ObservationIgnored private let preferences: any DevicePreferences
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let interval: Duration
    /// Counts readings started, so only the latest lands.
    @ObservationIgnored private var count = 0
    @ObservationIgnored private var lastStarted: Date?
    /// The screens watching, and the one loop that reads while any is.
    @ObservationIgnored private(set) var watchers = 0
    @ObservationIgnored private var poll: Task<Void, Never>?
    private let log = Logger(subsystem: "dev.frontport.Frontport", category: "Devices")

    /// Over the services, nil where Frontport doesn't install on Devices. `now` is the clock Renew goes by, `interval`
    /// how often a watched screen reads.
    public init(
        services: Services?, survey: Survey, activities: Activities, preferences: any DevicePreferences,
        now: @escaping @MainActor () -> Date = { .now }, interval: Duration = DeviceUpkeep.interval
    ) {
        self.services = services
        self.survey = survey
        self.activities = activities
        self.preferences = preferences
        self.now = now
        self.interval = interval
        chosenTeam = preferences.team
        renewsOnItsOwn = preferences.renewsOnItsOwn
        // Once the Activity has cleared, and the next one waiting, if any, started, a Renew on its own held off while it
        // was under way may be due, whatever the change, on this Mac or a Device.
        activities.onChange { [weak self] _ in Task { [weak self] in self?.renewDue() } }
    }

    /// Fixed readings, for previews: with Xcode, the Apple Team chosen when there's only one, and Renewing on its own.
    /// Nothing is read, Seeded or Renewed.
    public init(
        preview readings: [DeviceReading], teams: [AppleTeam], seedFailures: [PortID: [DeviceID: String]], survey: Survey,
        activities: Activities
    ) {
        services = nil
        self.survey = survey
        self.activities = activities
        preferences = HeldDevicePreferences()
        now = { .now }
        interval = Self.interval
        self.readings = Dictionary(readings.map { ($0.device.id, $0) }) { first, _ in first }
        hasXcode = true
        self.teams = teams
        state = DeviceUpkeepState(seedFailures: Dictionary(
            seedFailures.flatMap { port, byDevice in byDevice.map { (Key(port, on: $0.key), $0.value) } }) { first, _ in first })
        renewsOnItsOwn = true
    }

    // MARK: Derived state

    /// The Apple Team Frontport signs with: the one chosen, while its certificate is in the keychain, or the only one
    /// there when none was chosen.
    public var team: AppleTeam? {
        guard let chosenTeam else { return teams.count == 1 ? teams.first : nil }
        return teams.first { $0.id == chosenTeam }
    }

    /// Whether there's anything to read Devices for at launch and when Frontport comes to the front: a Catalog Port with
    /// an iOS version, or a Device remembered. Otherwise `devicectl` runs only while a screen watches.
    public var hasDevicesToRead: Bool {
        guard services != nil else { return false }
        return !survey.devices.isEmpty || !survey.deviceInstallations.isEmpty
            || survey.catalog?.ports.contains { $0.ios != nil } == true
    }

    /// Every Device the user has, by name: those the latest reading found, and those remembered, as away when it didn't
    /// find them.
    public var knownDevices: [DeviceReading] {
        var byID = readings
        for device in survey.devices where byID[device.id] == nil {
            byID[device.id] = DeviceReading(device: device, connection: .away)
        }
        return byID.values.sorted { ($0.device.name, $0.device.id) < ($1.device.name, $1.device.id) }
    }

    /// The Device as last read, or as remembered and away.
    public func reading(_ device: DeviceID) -> DeviceReading? {
        readings[device] ?? survey.devices.first { $0.id == device }.map { DeviceReading(device: $0, connection: .away) }
    }

    /// What the Port has on the Device and can do there now, with where its ROMs stand there and when it's due to
    /// Renew: everything its row shows.
    public func status(of port: PortID, on reading: DeviceReading) -> DeviceStatus {
        let device = reading.device.id
        let installation = survey.deviceInstallation(port, on: device)
        return DeviceStatus(
            reading: reading, installation: installation,
            // Before the first reading, every Device is away, which says more than Xcode might be missing.
            hasXcode: hasXcode ?? true, team: team?.id, hasAppleTeams: !teams.isEmpty, activity: activities[port],
            matching: matching(of: port, on: reading), update: installation.flatMap(update(of:)),
            upkeep: state.facts(Key(port, on: device), on: reading), isListed: survey.isListed(port), now: now())
    }

    /// Install on iPhone or iPad…: whether the Port's button can be clicked now, and which Devices it names. Nil without
    /// its entry.
    public func installStatus(of port: PortID) -> DeviceInstallStatus? {
        guard let entry = survey.entry(port) else { return nil }
        return DeviceInstallStatus(
            entry: entry, readings: knownDevices, hasXcode: hasXcode ?? true, team: team?.id, hasAppleTeams: !teams.isEmpty,
            activity: activities[port], isListed: survey.isListed(port))
    }

    /// The newer iOS Release the Installation's Channel offers, for a Port the Catalog lists.
    public func update(of installation: DeviceInstallation) -> Release? {
        guard let version = survey.catalog?.entry(installation.port).flatMap({ IOSVersion($0) }) else { return nil }
        return version.update(
            for: installation, newest: survey.latestIOSRelease(for: installation.port, channel: installation.channel))
    }

    /// Where the Port's ROMs stand on the Device; nil when it isn't there, or its iOS version Seeds nothing.
    public func matching(of port: PortID, on reading: DeviceReading) -> DeviceMatching? {
        survey.deviceInstallation(port, on: reading.device.id).flatMap { matching(of: $0, isReachable: reading.isReachable) }
    }

    /// Where an Installation's ROMs stand on its Device, from the latest plan read there while it's reachable.
    public func matching(of installation: DeviceInstallation, isReachable: Bool) -> DeviceMatching? {
        guard let version = seedingVersion(of: installation), !version.requirements.isEmpty else { return nil }
        return DeviceMatching(
            version: version, matching: survey.matching(for: installation.port), roms: survey.roms,
            installation: installation, plan: state.plan(Key(installation.port, on: installation.device)),
            isReachable: isReachable)
    }

    /// The iOS version Seeding the Installation goes by, which the Device Library is given.
    private func seedingVersion(of installation: DeviceInstallation) -> IOSVersion? {
        IOSVersion(seeding: installation, listed: survey.entry(installation.port))
    }

    /// The Port's iOS version, as its entry has it; nil without one.
    private func iosVersion(of port: PortID) -> IOSVersion? { survey.entry(port).flatMap { IOSVersion($0) } }

    // MARK: Reading

    /// Reads the Devices every `interval` for as long as the calling task runs: the `.task` of a screen that shows
    /// them. However many watch, one loop reads; one that starts watching reads now, unless a reading just started.
    public func watch() async {
        watchers += 1
        defer {
            watchers -= 1
            if watchers == 0 {
                poll?.cancel()
                poll = nil
            }
        }
        if poll == nil {
            poll = Task { [weak self, interval] in
                while !Task.isCancelled {
                    await self?.refresh(unlessReadWithin: Self.recent)
                    try? await Task.sleep(for: interval)
                }
            }
        } else {
            await refresh(unlessReadWithin: Self.recent)
        }
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(60 * 60)) }
    }

    /// At launch, on Frontport's update checks and when it comes to the front: reads the Devices when there's anything
    /// to read them for (`hasDevicesToRead`), unless a reading started within `recent`.
    public func refreshIfNeeded(unlessReadWithin recent: Duration? = nil) async {
        guard hasDevicesToRead else { return }
        await refresh(unlessReadWithin: recent)
    }

    /// Reads the paired Devices and the Apple Teams now, unless a reading started within `recent`. Once it lands, what's
    /// due is Renewed on its own, Seeding that waits for a Device it finds ready is tried again, queued behind any Renew
    /// rather than holding it off, and each Device remembered is remembered as the reading found it.
    public func refresh(unlessReadWithin recent: Duration? = nil) async {
        guard await read(unlessWithin: recent) else { return }
        renewDue()
        retrySeeds()
        await rememberAsRead()
    }

    /// Reads the Devices and the Apple Teams, unless a reading started within `recent`. True when this reading landed,
    /// rather than one started after it, or none.
    private func read(unlessWithin recent: Duration?) async -> Bool {
        guard let services else { return false }
        let started = now()
        if let recent, let lastStarted, started.timeIntervalSince(lastStarted) < recent.timeInterval { return false }
        count += 1
        let reading = count
        lastStarted = started
        async let teams = services.teams()
        let result: Result<[DeviceReading], any Error>
        do {
            result = .success(try await services.readings())
        } catch {
            result = .failure(error)
        }
        let read = await teams
        guard reading == count else { return false }
        switch result {
        case .success(let list):
            land(list, hasXcode: true)
        case .failure(FrontportError.xcodeMissing), .failure(FrontportError.noIOSPlatform):
            land([], hasXcode: false)
        case .failure(is CancellationError):
            return false
        case .failure(let error):
            // Every Device counts as away until `devicectl` answers again.
            log.error("Reading Devices failed: \(error.localizedDescription, privacy: .public)")
            land([], hasXcode: true)
        }
        if read != self.teams { self.teams = read }
        return true
    }

    /// Sets only what changed, so a reading that found the same leaves the screens alone.
    private func land(_ list: [DeviceReading], hasXcode: Bool) {
        let byID = Dictionary(list.map { ($0.device.id, $0) }) { first, _ in first }
        if byID != readings { readings = byID }
        if self.hasXcode != hasXcode { self.hasXcode = hasXcode }
    }

    /// Keeps `device.json` up to date: a Device remembered that the reading reached is remembered again with the name,
    /// model, iOS version and kinds of app it said, should they differ.
    private func rememberAsRead() async {
        guard let devices = services?.devices else { return }
        var changed = false
        for remembered in survey.devices {
            guard let reading = readings[remembered.id], reading.isReachable else { continue }
            var device = remembered
            let read = reading.device
            if !read.name.isEmpty { device.name = read.name }
            if !read.model.isEmpty { device.model = read.model }
            if !read.osVersion.isEmpty { device.osVersion = read.osVersion }
            if !read.families.isEmpty { device.families = read.families }
            guard device != remembered else { continue }
            do {
                try await devices.remember(device)
                changed = true
            } catch {
                log.error("\(device.name, privacy: .public) couldn’t be remembered: \(error.localizedDescription, privacy: .public)")
            }
        }
        if changed { await survey.devicesChanged() }
    }

    // MARK: Events

    /// Frontport came to the front: a Renew that failed on its own is tried again, and the Devices are read, as one may
    /// have come or gone.
    public func activated() {
        change { $0.activated() }
        guard hasDevicesToRead else { return }
        Task { await refresh() }
    }

    /// ROMs were added: Seeds them on each Device whose Port's iOS version takes one, or once the Device is ready.
    public func romsAdded(_ added: Set<String>) {
        guard !added.isEmpty else { return }
        for installation in survey.deviceInstallations() {
            let accepted = (seedingVersion(of: installation)?.requirements ?? []).flatMap { $0.oneOf + $0.extras }
            guard !Set(accepted).isDisjoint(with: added) else { continue }
            requestSeed(installation.port, on: installation.device)
        }
    }

    /// Reads what Seeding would copy to each Device the Port is on that can be listed, locked or not, for its rows.
    /// Called while its Devices show, and again when one comes or goes.
    public func readSeeding(of port: PortID) async {
        guard let devices = services?.devices else { return }
        for installation in survey.deviceInstallations(of: port) {
            guard activities[port] == nil, let reading = reading(installation.device),
                DeviceReadiness.reason(.list, on: reading) == nil
            else { continue }
            guard let version = seedingVersion(of: installation), !version.requirements.isEmpty else { continue }
            do {
                keep(try await devices.seedingPlan(for: version, on: reading), for: port, on: installation.device)
            } catch {
                // The row keeps what it showed: the record says what was last Seeded.
            }
        }
    }

    /// Forgets a Device that's away, with the records of the Ports Frontport installed there and what was kept for them;
    /// they stay on it, with their Data.
    public func forget(_ device: DeviceID) async throws {
        guard let devices = services?.devices, reading(device)?.isReachable != true else { return }
        let ports = survey.deviceInstallations(on: device).map(\.port)
        do {
            try await devices.forget(device)
        } catch {
            await survey.devicesChanged()
            throw error
        }
        for port in ports { change { $0.forget(Key(port, on: device)) } }
        await survey.devicesChanged()
    }

    // MARK: Changing Ports on Devices

    /// Install on iPhone or iPad…: prepares the Port's iOS version on its default Channel, as the Port's Activity, then
    /// hands the prepared app to `then`, which asks which Devices to install it on. One already prepared for the newest
    /// iOS Release, which the iOS version still offers, is handed over at once.
    public func prepare(_ port: PortID, then: @escaping @MainActor (PreparedDeviceApp) -> Void) {
        guard let devices = services?.devices, installStatus(of: port)?.isAllowed == true,
            let channel = iosVersion(of: port)?.defaultChannel
        else { return }
        Task {
            if let prepared = await devices.prepared(port), let version = iosVersion(of: port),
                prepared.isCurrent(for: version, latest: survey.latestIOSRelease(for: port))
            {
                then(prepared)
                return
            }
            // Asked again, after the wait, so a second click meanwhile prepares nothing more.
            guard installStatus(of: port)?.isAllowed == true, let version = iosVersion(of: port) else { return }
            let app = OSAllocatedUnfairLock<PreparedDeviceApp?>(initialState: nil)
            perform(.prepareForDevices, port, { progress in
                let prepared = try await devices.prepare(version, channel: channel, progress: progress)
                app.withLock { $0 = prepared }
            }, { outcome in
                // Once its Activity has cleared, so the sheet can install.
                if case .succeeded = outcome, let prepared = app.withLock({ $0 }) { Task { then(prepared) } }
                return Self.failure(of: outcome)
            })
        }
    }

    /// The sheet's Install: installs the Port's prepared iOS version on each of the Devices chosen that can take it, one
    /// after another, signed with the Apple Team, then Seeds what ROMs hold for it there. False when it installs on
    /// none, such as when Install can't be taken now (`DeviceInstallStatus.isInstallAllowed`), so the sheet stays and
    /// says why.
    @discardableResult
    public func install(_ port: PortID, prepared app: PreparedDeviceApp, on chosen: Set<DeviceID>) -> Bool {
        guard services != nil, installStatus(of: port)?.isInstallAllowed == true, let team = team?.id,
            let version = iosVersion(of: port)
        else { return false }
        let choices = DeviceInstallStatus.choices(
            for: app, readings: knownDevices, installations: survey.deviceInstallations(of: port))
        let readings = choices.filter { $0.isEligible && chosen.contains($0.id) }.map(\.reading)
        for reading in readings {
            // One after another: each on the Device as it is after the install on the one before.
            perform(.install, of: port, on: reading) { devices, reading, progress in
                _ = try await devices.installPrepared(version, on: reading, team: team, progress: progress)
            }
        }
        return !readings.isEmpty
    }

    /// Update on the Port's row for the Device: installs the newer iOS Release on its Channel over it, keeping its Data
    /// there, then Seeds what ROMs hold for it.
    public func update(_ port: PortID, on device: DeviceID) {
        guard let reading = reading(allowing: .update, of: port, on: device), let team = team?.id,
            let channel = survey.deviceInstallation(port, on: device)?.channel, let version = iosVersion(of: port)
        else { return }
        perform(.update, of: port, on: reading) { devices, reading, progress in
            _ = try await devices.update(version, on: reading, team: team, channel: channel, progress: progress)
        }
    }

    /// Uninstall on the Port's row for the Device, once confirmed: removes its app from the Device, and its Data there
    /// with it.
    public func uninstall(_ port: PortID, from device: DeviceID) {
        guard let reading = reading(allowing: .uninstall, of: port, on: device) else { return }
        perform(.uninstall, of: port, on: reading) { devices, _, _ in
            try await devices.uninstall(port, from: device)
        }
    }

    /// Seed or Try Again on the Port's row for the Device.
    public func seed(_ port: PortID, on device: DeviceID) {
        guard reading(allowing: .seed, of: port, on: device) != nil else { return }
        requestSeed(port, on: device)
    }

    /// Renew on the Port's row for the Device: signs its app again with a Provisioning Profile that lasts longer and
    /// installs it over, keeping its Data there.
    public func renew(_ port: PortID, on device: DeviceID) {
        renew(port, on: device, onItsOwn: false)
    }

    /// The Device as last read, when the Port's status there allows `action` now.
    private func reading(allowing action: DeviceStatus.Action, of port: PortID, on device: DeviceID) -> DeviceReading? {
        guard let reading = reading(device), status(of: port, on: reading).allows(action) else { return nil }
        return reading
    }

    /// Runs the change to the Port on the Device as the Port's Activity: `work` gets the Device Library and the Device
    /// as it's read when the change's turn comes, after any change under way, or as `reading` had it. Once it ended,
    /// `state` sorts out what it leaves there (`DeviceUpkeepState.ended`), and an install or update that succeeded Seeds
    /// what ROMs hold for the Port there, as an Activity of its own, so a Seeding that fails leaves it installed.
    private func perform(
        _ change: DeviceChange, of port: PortID, on reading: DeviceReading,
        _ work: @escaping @Sendable (any DeviceLibraryManaging, DeviceReading, @escaping ProgressHandler) async throws -> Void
    ) {
        guard let devices = services?.devices else { return }
        let device = reading.device.id
        perform(.device(change, device), port, { [weak self] progress in
            try await work(devices, await self?.reading(device) ?? reading, progress)
        }) { [weak self] outcome in
            guard let self else { return Self.failure(of: outcome) }
            let key = Key(port, on: device)
            let onItsOwn = state.isRenewing(key)
            let presented = Self.failure(of: outcome).flatMap { Self.alerts($0, of: change, renewingOnItsOwn: onItsOwn) ? $0 : nil }
            let date = now()
            self.change { $0.ended(change, of: key, outcome, at: date) }
            if case .succeeded = outcome, change == .install || change == .update { installed(port, on: device) }
            return presented
        }
    }

    /// Whether a failure of the change is presented as an alert: not Seeding on a Device refused because the Device
    /// isn't ready or the Port runs there, which waits instead, nor a Renew started on its own, whose failure shows on
    /// the Port's row and is tried again later.
    private static func alerts(_ error: any Error, of change: DeviceChange, renewingOnItsOwn: Bool) -> Bool {
        switch change {
        case .seed: DeviceUpkeepState.Wait(refusal: error) == nil
        case .renew: !renewingOnItsOwn
        case .install, .update, .uninstall: true
        }
    }

    private static func failure(of outcome: Activities.Outcome) -> (any Error)? {
        if case .failed(let error) = outcome { error } else { nil }
    }

    // MARK: Seeding

    /// The Port was installed or updated on the Device: Seeds what ROMs hold for it there.
    private func installed(_ port: PortID, on device: DeviceID) {
        guard let reading = reading(device), matching(of: port, on: reading)?.hasUnseeded == true else { return }
        requestSeed(port, on: device)
    }

    /// Seeds the Port on the Device now, as the Port's Activity, when the Device is ready; otherwise `state` keeps it
    /// for a reading that finds the Device ready.
    private func requestSeed(_ port: PortID, on device: DeviceID) {
        guard services != nil, let installation = survey.deviceInstallation(port, on: device),
            let version = seedingVersion(of: installation), let reading = reading(device)
        else { return }
        guard change({ $0.requested(Key(port, on: device), ready: DeviceUpkeepState.isReady(reading)) }) else { return }
        perform(.seed, of: port, on: reading) { [weak self] devices, reading, progress in
            do {
                let plan = try await devices.seed(version, on: reading, progress: progress)
                await self?.keep(plan, for: port, on: device)
            } catch FrontportError.notInstalled(_) {
                // Uninstalled from the Device, or the Device forgotten, while this waited its turn: nothing to Seed.
            }
        }
    }

    /// After a reading: Seeding that waits for a Device it found ready is requested again, and where it waits for the
    /// Port to quit, once the Device says nothing of the Port runs. At most once per reading, so never in a tight loop.
    /// A wait ends when Frontport quits, so what a record says isn't on a Device found ready yet is requested once a
    /// launch.
    private func retrySeeds() {
        let unseeded = survey.deviceInstallations()
            .filter { matching(of: $0, isReachable: false)?.hasUnseeded == true }
            .map { Key($0.port, on: $0.device) }
        let due = state.seedsDue(readings: readings, unseeded: unseeded)
        for key in due.seed { requestSeed(key.port, on: key.device) }
        guard !due.check.isEmpty, let devices = services?.devices else { return }
        Task {
            for key in due.check {
                guard survey.deviceInstallation(key.port, on: key.device) != nil,
                    (try? await devices.isRunning(key.port, on: key.device)) == false, state.wait(key) == .running
                else { continue }
                requestSeed(key.port, on: key.device)
            }
        }
    }

    /// Keeps the plan Seeding last read from the Device.
    private func keep(_ plan: DeviceSeedingPlan?, for port: PortID, on device: DeviceID) {
        change { $0.read(plan, for: Key(port, on: device)) }
    }

    /// Changes `state`, setting it only when that changed it, so the screens are left alone otherwise.
    @discardableResult
    private func change<Result>(_ body: (inout DeviceUpkeepState) -> Result) -> Result {
        var changed = state
        let result = body(&changed)
        if changed != state { state = changed }
        return result
    }

    // MARK: Renewing

    /// Renews on its own each Installation `state` says is due, as the Port's Activity: after each reading, once a
    /// Port's Activity clears, as one held off while it was under way, and once the user turns Renewing on its own back
    /// on or chooses another Apple Team.
    private func renewDue() {
        guard services != nil else { return }
        let due = state.renewsDue(
            survey.deviceInstallations(), readings: readings, busy: Set(activities.underWay.keys),
            team: team?.id, hasXcode: hasXcode == true, enabled: renewsOnItsOwn, now: now())
        for key in due { renew(key.port, on: key.device, onItsOwn: true) }
    }

    private func renew(_ port: PortID, on device: DeviceID, onItsOwn: Bool) {
        guard services != nil, let reading = reading(allowing: .renew, of: port, on: device), let team = team?.id else { return }
        if onItsOwn { change { $0.renewStarted(Key(port, on: device)) } }
        perform(.renew, of: port, on: reading) { devices, reading, progress in
            _ = try await devices.renew(port, on: reading, team: team, progress: progress)
        }
    }
}

extension Duration {
    /// In seconds, as `Date` counts them.
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}
