import AppKit
import FrontportCore
import FrontportReleases
import Observation
import os

/// What the detail column shows.
enum Screen: Hashable {
    case catalog
    case releases
    case roms
    /// A Port's page on this Mac: Overview, Snapshots and Runs. Opening it for a Port only on Devices opens its first
    /// Device's page instead (`page(for:)`).
    case port(PortID)
    /// A Port's page on one Device: its app there, its ROMs there and what the Device needs.
    case portOnDevice(PortID, DeviceID)
    /// One Platform's Ports to install, by Game.
    case platform(PlatformID)
    /// One Genre's Ports to install, by Game.
    case genre(GenreID)
    /// A Game's Ports to choose from, for a Game the Catalog has more than one Port of.
    case game(GameID)
    /// A Catalog entry's store page, under its Game.
    case store(PortID)
    /// A Project's Games and Releases, by its repository.
    case project(String)
}

/// Where switching an Installation's Channel would land, for confirming it first.
struct ChannelSwitch: Hashable {
    var channel: Channel
    /// To the newest Release on the Channel, when it could be looked up. A back Move may not load the Data.
    var move: Move?
}

/// A Requirement of a Library Port that ROMs can't satisfy yet, or whose ROMs aren't Seeded into its Data yet.
struct NeededROM: Hashable, Identifiable {
    var port: PortID
    var requirement: Requirement
    /// In ROMs, but not yet Seeded.
    var isUnseeded = false
    var id: String { "\(port)/\(requirement.id)" }
}

/// A failure to present.
struct Failure: Identifiable {
    let id = UUID()
    var port: PortID?
    var error: FrontportError
}

/// The services the model drives.
struct AppServices: Sendable {
    var catalog: any CatalogProviding
    var catalogs: any CatalogManaging
    var releases: any ReleaseDiscovering
    var roms: any ROMStoring
    var library: any LibraryManaging
    var launcher: any PortLaunching
    var artwork: any ArtworkProviding
    /// Installations on iPhones and iPads, `devicectl` and the user's Apple Teams; nil where Frontport doesn't install
    /// on Devices.
    var devices: (any DeviceLibraryManaging)? = nil
    var deviceControl: (any DeviceControlling)? = nil
    var provisioning: (any Provisioning)? = nil
}

/// What views talk to: every intent the UI can trigger, and the state it shows, read here or from the modules it
/// exposes (`survey`, `activities`).
@Observable @MainActor
final class AppModel {
    // MARK: Navigation

    /// Going anywhere ends a search, so a picked search result shows.
    var selection: Screen? {
        didSet { searchText = "" }
    }
    var searchText = ""

    // MARK: State

    /// ROMs a Requirement accepts that Steam has installed and ROMs doesn't hold yet, read when Frontport loads, comes
    /// to the front or its ROMs change.
    private(set) var steamOffers: [SteamOffer] = []
    /// ROMs a Requirement accepts that Steam can download at the build the Catalog pins, read with `steamOffers`.
    private(set) var steamDownloads: [String] = []
    /// The ROM Steam is downloading for Frontport.
    private(set) var steamDownload: SteamDownload?

    /// A ROM Steam is downloading for Frontport.
    struct SteamDownload: Equatable {
        var sha1: String
        /// The Game's name, as the Catalog lists it.
        var name: String
        /// 0...1, or nil until Steam says how much it downloads.
        var fraction: Double?
    }

    /// What Frontport last found in the Catalog, the Library, ROMs and Releases.
    let survey: Survey
    /// Ports running from a launch through Frontport.
    private var launched: Set<PortID> = []
    /// Ports macOS reports running, however they were opened (the Dock, Finder or Frontport).
    private var opened: Set<PortID> = []
    /// Each Port's change under way, and why Seeding last failed after one, kept while the Port has unseeded
    /// Requirements.
    let activities: Activities
    /// When ROMs added for each Port are Seeded: once it quits, for one that runs.
    private(set) var seedingWait = SeedingWait()
    /// Bumped when a Port's Data may have changed: after each change to the Port, and after it quits.
    private(set) var revisions: [PortID: Int] = [:]
    /// The Snapshot from before a Channel switch that landed on an older Release, offered until used or dismissed.
    private(set) var switchSnapshots: [PortID: Snapshot] = [:]
    /// Newest first; loaded by `loadHistory(for:)`.
    private(set) var snapshots: [PortID: [Snapshot]] = [:]
    /// Newest first; loaded by `loadHistory(for:)`.
    private(set) var runs: [PortID: [Run]] = [:]
    /// Whether `load()` has read the Catalog, the Library and ROMs once; until then screens show skeletons.
    private(set) var isLoaded = false
    /// Whose SteamGridDB key artwork is fetched with; nil when there is none.
    private(set) var steamGridDBKey: APIKeySource?
    /// The Catalogs the user added, for Settings and the store page.
    private(set) var addedCatalogs: [CatalogSummary] = []
    /// Bumped when artwork may have changed (a new SteamGridDB key), so artwork views look again.
    private(set) var artworkGeneration = 0
    /// The paired Devices as last read, the Apple Team chosen, and what Frontport Seeds and Renews on them on its own.
    let deviceUpkeep: DeviceUpkeep
    /// Which Devices to install a Port's prepared iOS version on, asked in a sheet on the main window once it's
    /// prepared, whatever screen shows then.
    var devicePicker: DevicePicker?
    /// The sheets for other Ports prepared while one shows, first first: each shows once the one before is closed.
    var waitingDevicePickers: [DevicePicker] = []
    /// The previews' prepared iOS versions, by Port, for the snapshot driver's sheet.
    @ObservationIgnored let previewPreparedApps: [PortID: PreparedDeviceApp]
    var failure: Failure?

    let paths: AppPaths
    /// Nil for previews. Read by the extensions in other files, which change Ports only through `perform`.
    let services: AppServices?
    /// Frontport's own updates, checked along with the Ports'.
    private let updater: AppUpdater?
    private var history: [Screen] = []
    /// Notes summaries by `Release.id`, made once per Release, when first shown.
    @ObservationIgnored private var summaries: [String: String?] = [:]
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var updateChecks: Task<Void, Never>?
    @ObservationIgnored private var launches: Task<Void, Never>?
    @ObservationIgnored private var workspaceObservers: [any NSObjectProtocol] = []
    private let log = Logger(subsystem: "dev.frontport.Frontport", category: "AppModel")

    /// Update checks run at launch and then this often, only while Frontport is open.
    static let checkInterval = Duration.seconds(6 * 60 * 60)

    /// A model over fixed sample data, for the Debug snapshot driver. Its intents do nothing.
    init(preview: PreviewData, paths: AppPaths = .default) {
        self.paths = paths
        services = nil
        updater = nil
        previewPreparedApps = preview.preparedDeviceApps
        activities = Activities(preview.activities)
        survey = Survey(
            preview: preview.catalog, installations: preview.installations, matching: preview.matching,
            releases: preview.releases, updates: preview.updates, lastChecked: preview.lastChecked,
            activities: activities, paths: paths, deviceInstallations: preview.deviceInstallations,
            devices: preview.deviceReadings.map(\.device), iosReleases: preview.iosReleases)
        deviceUpkeep = DeviceUpkeep(
            preview: preview.deviceReadings, teams: preview.appleTeams, seedFailures: preview.deviceSeedFailures,
            survey: survey, activities: activities)
        launched = preview.running
        snapshots = preview.snapshots
        runs = preview.runs
        addedCatalogs = preview.addedCatalogs
        isLoaded = true
        selection = .catalog
    }

    /// A model over real services. State loads in `start()`.
    init(services: AppServices, paths: AppPaths = .default, updater: AppUpdater? = nil) {
        self.paths = paths
        self.services = services
        self.updater = updater
        activities = Activities()
        previewPreparedApps = [:]
        survey = Survey(
            .init(
                catalog: services.catalog, library: services.library, roms: services.roms, releases: services.releases,
                devices: services.devices),
            activities: activities, paths: paths)
        deviceUpkeep = DeviceUpkeep(
            services: services.devices.flatMap { devices in
                services.deviceControl.map { control in
                    let provisioning = services.provisioning
                    return .init(
                        devices: devices, readings: { try await control.readings() },
                        teams: { await provisioning?.teams() ?? [] })
                }
            },
            survey: survey, activities: activities, preferences: DefaultsDevicePreferences())
        survey.onFailure = { [weak self] in self?.present($0) }
        deviceUpkeep.perform = { [weak self] kind, port, work, end in self?.run(kind, on: port, work, end: end) }
    }

    // MARK: Derived state

    var running: Set<PortID> { launched.union(opened) }
    func isRunning(_ port: PortID) -> Bool { launched.contains(port) || opened.contains(port) }
    /// Changes whenever the Port's Data may have, so views that measure it look again.
    func revision(of port: PortID) -> Int { revisions[port] ?? 0 }

    /// What Library Ports still need, for the ROMs screen: ROMs to add, then ROMs to Seed. A Port only Devices have
    /// needs the ROMs its iOS version Seeds there.
    var neededROMs: [NeededROM] {
        survey.libraryPorts.flatMap { entry in
            let onDevices = survey.deviceInstallations(of: entry.id)
            if survey.installation(entry.id) == nil, !onDevices.isEmpty {
                var missing: [Requirement] = []
                for installation in onDevices {
                    for requirement in deviceMatching(of: installation, isReachable: false)?.requirements(.missing) ?? []
                    where !missing.contains(requirement) {
                        missing.append(requirement)
                    }
                }
                return missing.map { NeededROM(port: entry.id, requirement: $0) }
            }
            let state = survey.matching(for: entry.id)
            return state.missing().map { NeededROM(port: entry.id, requirement: $0) }
                + state.unseeded.map { NeededROM(port: entry.id, requirement: $0, isUnseeded: true) }
        }
    }

    /// Library Ports whose Requirements accept the ROM: the ROMs screen's "Used by".
    func ports(using sha1: String) -> [CatalogEntry] {
        survey.libraryPorts.filter { $0.acceptedROMs.contains(sha1) }
    }

    /// Library Ports that would ask for the ROM again, were it removed, on an update that rebuilds their Build Assets.
    func portsAffected(byRemoving sha1: String) -> [CatalogEntry] {
        survey.matching.askingAgain(for: sha1).compactMap { survey.entry($0) }.sorted(by: Self.byName)
    }

    /// What the Port is doing or needs, and what the user can do with it now. Every view and intent asks it.
    func status(of port: PortID) -> Status {
        guard let entry = survey.entry(port) else { return .unknown }
        return Status(
            entry: entry, installation: survey.installation(port), matching: survey.matching(for: port),
            offer: survey.offers[port], activity: activities[port], isRunning: isRunning(port),
            isListed: survey.isListed(port))
    }

    var canGoBack: Bool { !history.isEmpty }

    private static func byName(_ a: CatalogEntry, _ b: CatalogEntry) -> Bool {
        a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    // MARK: Navigation intents

    func open(_ screen: Screen) {
        searchText = ""
        let screen = if case .port(let port) = screen { page(for: port) } else { screen }
        guard screen != selection else { return }
        if let selection { history.append(selection) }
        selection = screen
    }

    func back() {
        guard let previous = history.popLast() else { return }
        selection = previous
    }

    // MARK: Loading and update checks

    /// Called when the window appears: loads state, applies the launch rule, then checks for updates, Frontport's
    /// own included, now and every 6 hours while Frontport is open. Later calls do nothing.
    func start() async {
        guard let services, !isStarted else { return }
        isStarted = true
        watchLaunches(services.launcher)
        watchWorkspace()
        // What an earlier session's failed or interrupted operations left; it may take a while for a build folder.
        Task { await services.library.removeLeftovers() }
        Task { await services.devices?.removeLeftovers() }
        await load()
        if selection == nil { selection = .catalog }
        Task {
            await services.artwork.compact()
            await ArtworkCache.shared.prefetch(self)
        }
        Task { await deviceUpkeep.refreshIfNeeded() }
        updateChecks = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                updater?.checkInBackground()
                await refresh()
                // A Port on a Device may be due to be Renewed, though no screen that shows Devices is open.
                await deviceUpkeep.refreshIfNeeded(unlessReadWithin: DeviceUpkeep.interval)
                try? await Task.sleep(for: Self.checkInterval)
            }
        }
    }

    /// Reads the Catalog, the Library, ROMs and what's running, without the network.
    func load() async {
        guard let services else { return }
        await survey.load()
        isLoaded = true
        launched = await services.launcher.running()
        refreshOpened()
        steamGridDBKey = await services.artwork.apiKeySource()
        addedCatalogs = await services.catalogs.added()
        await refreshSteamOffers()
    }

    /// Refreshes the Survey (the Catalog and its Blocks, the Library, and every entry's newest Release) and cached
    /// artwork. A refresh asked for while one runs, artwork included, does nothing.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        guard await survey.refresh(), let services else { return }
        addedCatalogs = await services.catalogs.added()
        await refreshSteamOffers()
        guard let catalog = survey.catalog else { return }
        await services.artwork.refresh(catalog.ports)
        // What failed to load before may load now; decoding it needn't hold up the next refresh.
        ArtworkCache.shared.forgetMissing()
        Task { await ArtworkCache.shared.prefetch(self) }
    }

    // MARK: Changing Ports

    /// Installs a Port on a Channel (the entry's default when nil).
    func install(_ port: PortID, channel: Channel? = nil) {
        guard status(of: port).allows(.install) else { return }
        perform(.install, on: port) { services, entry, progress in
            _ = try await services.library.install(entry, channel: channel ?? entry.defaultChannel, progress: progress)
        }
    }

    /// Updates to `release`, by default the update found for the Port, or its fallback off a Blocked Release.
    func update(_ port: PortID, to release: Release? = nil) {
        let status = status(of: port)
        guard status.allows(status.update != nil ? .update : .installFallback) else { return }
        let release = release ?? status.update ?? status.fallback
        perform(.update, on: port) { services, entry, progress in
            _ = try await services.library.update(entry, to: release, progress: progress)
        }
    }

    func rollback(_ port: PortID) {
        guard status(of: port).allows(.rollBack) else { return }
        perform(.rollback, on: port) { services, entry, progress in
            _ = try await services.library.rollback(entry, progress: progress)
        }
    }

    /// Keeps Data and Snapshots.
    func uninstall(_ port: PortID) {
        guard status(of: port).allows(.uninstall) else { return }
        perform(.uninstall, on: port) { services, entry, _ in
            try await services.library.uninstall(entry)
        }
    }

    /// Removes Data and Snapshots.
    func deleteData(_ port: PortID) {
        guard status(of: port).allows(.deleteData) else { return }
        perform(.deleteData, on: port) { services, entry, _ in
            try await services.library.deleteData(entry)
        }
    }

    /// Keeps the Installation; its next build starts from scratch.
    func removeBuildFolder(_ port: PortID) {
        guard status(of: port).allows(.removeBuildFolder) else { return }
        perform(.removeBuildFolder, on: port) { services, entry, _ in
            try await services.library.removeBuildFolder(entry)
        }
    }

    /// Cancels the Port's install, update or build, and any change waiting its turn. The work clears its Activity
    /// when it stops.
    func cancel(_ port: PortID) {
        guard status(of: port).allows(.cancel) else { return }
        activities.cancel(port)
    }

    /// Re-signs the Port; applies on its next launch.
    func setPermissions(_ permissions: Permissions, for port: PortID) {
        guard status(of: port).allows(.setPermissions) else { return }
        survey.setPermissions(permissions, for: port)
        perform(.permissions, on: port) { services, entry, _ in
            _ = try await services.library.setPermissions(permissions, for: entry)
        }
    }

    /// Looks up where switching to `channel` would land, so the switch can be confirmed first. Nil when there's
    /// nothing to switch.
    func channelSwitch(_ port: PortID, to channel: Channel) async -> ChannelSwitch? {
        guard let entry = survey.entry(port), let installation = survey.installation(port), channel != installation.channel
        else { return nil }
        let target = try? await services?.releases.latest(for: entry, channel: channel)
        return ChannelSwitch(channel: channel, move: target.map { Move(entry, from: installation, to: $0, on: channel) })
    }

    /// Switches Channel. One that lands on an older Release offers the Snapshot taken before it afterwards.
    func switchChannel(_ port: PortID, to plan: ChannelSwitch) {
        guard status(of: port).allows(.switchChannel) else { return }
        switchSnapshots[port] = nil
        perform(.switchChannel, on: port) { services, entry, progress in
            _ = try await services.library.switchChannel(entry, to: plan.channel, progress: progress)
        } then: { model in
            guard let move = plan.move, move.direction == .back, let taken = move.taken(in: model.snapshots[port] ?? [])
            else { return }
            model.switchSnapshots[port] = taken
        }
    }

    func dismissSwitchSnapshot(for port: PortID) {
        switchSnapshots[port] = nil
    }

    func restore(_ snapshot: Snapshot) {
        guard status(of: snapshot.port).allows(.restore) else { return }
        switchSnapshots[snapshot.port] = nil
        perform(.restore, on: snapshot.port) { services, entry, _ in
            try await services.library.restore(snapshot, entry: entry)
        }
    }

    /// Runs one change to a Port on this Mac as its Activity (`run`), given the services and the Port's entry; `then`
    /// runs after a success. Changes on Devices start in `deviceUpkeep`.
    func perform(
        _ kind: Activity.Kind, on port: PortID,
        _ work: @escaping @Sendable (AppServices, CatalogEntry, @escaping ProgressHandler) async throws -> Void,
        then: (@MainActor (AppModel) -> Void)? = nil
    ) {
        guard let services, let entry = survey.entry(port) else { return }
        run(kind, on: port, { progress in try await work(services, entry, progress) }, then: then)
    }

    /// Runs one change to a Port as its Activity, after the one under way if there is one (`Activities`), on this Mac
    /// or a Device. The Port's state is reloaded before the Activity clears; `then` runs after a success. A failure is
    /// presented, or, for a change given its `end`, the one `end` returns once the state is reloaded.
    ///
    /// Applying ROMs that the Library refuses because the Port runs waits for it to quit, and `seedingWait` hears of
    /// every Activity that ends.
    private func run(
        _ kind: Activity.Kind, on port: PortID, _ work: @escaping Activities.Work, end: DeviceUpkeep.End? = nil,
        then: (@MainActor (AppModel) -> Void)? = nil
    ) {
        activities.run(kind, on: port, work) { [weak self] outcome in
            guard let self else { return }
            var succeeded = false
            switch outcome {
            case .succeeded: succeeded = true
            case .failed(FrontportError.running) where kind == .applyROMs: seedingWait.refused(port)
            case .failed(let error) where end == nil: present(error, port: port)
            case .failed, .cancelled: break
            }
            await reload(port, after: kind)
            if let error = end?(outcome) { present(error, port: port) }
            if succeeded { then?(self) }
            revisions[port, default: 0] += 1
            carryOut(seedingWait.ended(port, seeded: kind == .applyROMs && succeeded, running: isRunning(port)), for: port)
        }
    }

    /// State that a change to the Port may have touched. After an uninstall, the page of the place it left closes: to
    /// the Port's page on this Mac or another Device while it's still there, else to the Catalog.
    private func reload(_ port: PortID, after kind: Activity.Kind) async {
        await survey.changed(port, by: kind)
        let left: Screen? = switch kind {
        case .uninstall: .port(port)
        case .device(.uninstall, let device): .portOnDevice(port, device)
        default: nil
        }
        if let left, selection == left {
            let next = page(for: port)
            selection = next == left || !survey.lineup.library.contains(port) ? .catalog : next
        }
        await loadHistory(for: port)
    }

    func present(_ error: any Error, port: PortID? = nil) {
        if error is CancellationError { return }
        log.error("\(error.localizedDescription, privacy: .public)")
        failure = Failure(port: port, error: error as? FrontportError ?? .fileOperation(error.localizedDescription))
    }

    // MARK: Running

    func play(_ port: PortID) {
        guard status(of: port).allows(.play), let services, let entry = survey.entry(port), let installation = survey.installation(port)
        else { return }
        Task {
            do {
                _ = try await services.launcher.launch(entry, installation: installation)
            } catch {
                present(error, port: port)
            }
        }
    }

    func stop(_ port: PortID) {
        guard status(of: port).allows(.stop), let services, let entry = survey.entry(port) else { return }
        Task { await services.launcher.stop(entry) }
    }

    /// Keeps `running` and `runs` current from the Launcher's events.
    private func watchLaunches(_ launcher: any PortLaunching) {
        launches = Task { [weak self] in
            for await event in await launcher.events() {
                guard let self else { return }
                switch event {
                case .started(let run):
                    launched.insert(run.port)
                    runs[run.port] = [run] + (runs[run.port] ?? []).filter { $0.id != run.id }
                case .ended(let run):
                    launched.remove(run.port)
                    revisions[run.port, default: 0] += 1
                    runs[run.port] = await launcher.runs(for: run.port)
                    await didQuit([run.port])
                }
            }
        }
    }

    /// Keeps `running` current for Ports opened from the Dock or Finder too, which the Launcher never sees.
    private func watchWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        let names = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification]
        workspaceObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let bundleId = app?.bundleIdentifier, bundleId.hasPrefix(Self.portBundlePrefix) else { return }
                let ended = name == NSWorkspace.didTerminateApplicationNotification ? app?.processIdentifier : nil
                MainActor.assumeIsolated {
                    guard let model = self else { return }
                    let wasRunning = model.opened
                    model.refreshOpened(excluding: ended)
                    let quit = wasRunning.subtracting(model.opened)
                    for port in quit { model.revisions[port, default: 0] += 1 }
                    if !quit.isEmpty { Task { await model.didQuit(quit) } }
                }
            }
        }
        // Steam may have installed a game while Frontport was in the background, and a Device may have come or gone.
        let activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let model = self else { return }
                Task { await model.refreshSteamOffers() }
                model.deviceUpkeep.activated()
            }
        }
        workspaceObservers.append(activation)
    }

    private nonisolated static let portBundlePrefix = "dev.frontport.port."

    /// Once a Port has quit, however it was opened: its Data may have changed, and ROMs added while it ran apply now.
    private func didQuit(_ ports: Set<PortID>) async {
        let quit = ports.filter { !isRunning($0) }
        guard !quit.isEmpty else { return }
        await survey.romsChanged()
        for port in quit where seedingWait.quit(port) { applyROMs(port) }
    }

    /// Ports among the running applications; `ended` is one that just quit but may still be listed.
    private func refreshOpened(excluding ended: pid_t? = nil) {
        let ports = NSWorkspace.shared.runningApplications.compactMap { app -> PortID? in
            guard !app.isTerminated, app.processIdentifier != ended, let bundleId = app.bundleIdentifier,
                bundleId.hasPrefix(Self.portBundlePrefix)
            else { return nil }
            return port(forBundleID: bundleId)
        }
        opened = Set(ports)
    }

    /// The Port with this bundle ID: by its entry, else by the `dev.frontport.port.<id>` convention.
    private func port(forBundleID bundleId: String) -> PortID {
        if let entry = (survey.catalog?.ports ?? []).first(where: { $0.bundleId == bundleId }) { return entry.id }
        if let entry = survey.unlisted.values.first(where: { $0.bundleId == bundleId }) { return entry.id }
        return PortID(String(bundleId.dropFirst(Self.portBundlePrefix.count)))
    }

    // MARK: ROMs

    /// Adds ROM files and returns one result per file; accepted ROMs are applied to Library Ports, or to a running one
    /// once it quits.
    func addROMs(_ urls: [URL]) async -> [ROMIntake] {
        guard let services else { return [] }
        guard let catalog = survey.catalog else {
            return urls.map { .rejected(file: $0, sha1: nil, reason: "The Catalog isn’t loaded.") }
        }
        return await applied(await services.roms.add(urls, catalog: catalog))
    }

    /// Keeps a file the Catalog doesn't list as the ROM `sha1` names, Unverified, and applies it as `addROMs` does.
    func assignROM(_ file: URL, as sha1: String) async -> [ROMIntake] {
        guard let services, let catalog = survey.catalog else {
            return [.rejected(file: file, sha1: nil, reason: "The Catalog isn’t loaded.")]
        }
        return await applied(await services.roms.assign(file, as: sha1, catalog: catalog))
    }

    /// Applies the ROMs an intake added to the installed Library Ports that accept them.
    private func applied(_ results: [ROMIntake]) async -> [ROMIntake] {
        let added = Set(results.compactMap { result -> String? in
            if case .added(let record) = result { return record.sha1 }
            return nil
        })
        for entry in survey.libraryPorts where survey.installation(entry.id) != nil && !entry.acceptedROMs.isDisjoint(with: added) {
            applyROMs(entry.id)
        }
        deviceUpkeep.romsAdded(added)
        await survey.romsChanged()
        await refreshSteamOffers()
        return results
    }

    /// Adds the ROMs Steam installed, as Steam installed them, and applies them as `addROMs` does.
    func addFromSteam(_ offers: [SteamOffer]) async -> [ROMIntake] {
        guard let services, let catalog = survey.catalog else { return [] }
        var results: [ROMIntake] = []
        for offer in offers { results += await services.roms.addFromSteam(offer.sha1, catalog: catalog) }
        return await applied(results)
    }

    /// Reads which ROMs Steam has installed that ROMs doesn't hold yet. Cheap: it reads Steam's own lists, not the
    /// Game's files.
    func refreshSteamOffers() async {
        guard let services, let catalog = survey.catalog else { return }
        let offers = await services.roms.steamOffers(catalog: catalog)
        if offers != steamOffers { steamOffers = offers }
        let downloads = await services.roms.steamDownloads(catalog: catalog)
        if downloads != steamDownloads { steamDownloads = downloads }
    }

    /// The ROM Steam can download for the Port when it hasn't installed one the Port accepts: the first its
    /// Requirements list.
    func steamDownload(for port: PortID) -> String? {
        guard steamOffers(for: port).isEmpty, let entry = survey.entry(port) else { return nil }
        return entry.requirements.flatMap(\.oneOf).first { steamDownloads.contains($0) }
    }

    #if DEBUG
    /// Shows Steam downloading `download`, or nothing, for the snapshot driver.
    func previewSteamDownload(_ download: SteamDownload?) {
        steamDownloads = download.map { [$0.sha1] } ?? []
        steamDownload = download
    }
    #endif

    /// Whether Steam is downloading the ROM the Port would download.
    func isDownloadingFromSteam(for port: PortID) -> Bool {
        guard let steamDownload else { return false }
        return steamDownload.sha1 == self.steamDownload(for: port)
    }

    /// Whether Steam could download a ROM the Port accepts once it's installed: the Catalog pins a ROM's depots, but
    /// Steam can't download it now.
    func needsSteamToDownload(for port: PortID) -> Bool {
        guard steamOffers(for: port).isEmpty, steamDownload(for: port) == nil, let entry = survey.entry(port),
            let catalog = survey.catalog
        else { return false }
        let pinned = Set(catalog.roms.filter { $0.steam?.depots != nil }.map(\.sha1))
        return !entry.acceptedROMs.isDisjoint(with: pinned)
    }

    /// Has Steam download the ROM, adds it as Steam installed it, and applies it as `addROMs` does.
    func downloadFromSteam(_ sha1: String) async -> [ROMIntake] {
        guard let services, let catalog = survey.catalog, steamDownload == nil else { return [] }
        let known = catalog.roms.first { $0.sha1 == sha1 }
        let name = known?.game.flatMap { catalog.game($0)?.name } ?? known?.name ?? "the ROM"
        steamDownload = SteamDownload(sha1: sha1, name: name)
        defer { steamDownload = nil }
        let results = await services.roms.downloadFromSteam(sha1, catalog: catalog) { fraction in
            Task { @MainActor [weak self] in
                if self?.steamDownload?.sha1 == sha1 { self?.steamDownload?.fraction = fraction }
            }
        }
        return await applied(results)
    }

    /// The ROMs Steam installed, as the Catalog lists them, that the Port accepts.
    func steamOffers(for port: PortID) -> [SteamOffer] {
        guard let entry = survey.entry(port) else { return [] }
        return steamOffers.filter { $0.matches && entry.acceptedROMs.contains($0.sha1) }
    }

    /// Seeds the Port's Runtime ROMs that aren't in its Data and regenerates Build Assets for a new Build-Stage ROM.
    /// Seeding never happens while the Port runs, so for a running Port this waits until it quits (`SeedingWait`).
    func applyROMs(_ port: PortID) {
        guard status(of: port).allows(.seed) else { return }
        carryOut(seedingWait.requested(port, running: isRunning(port)), for: port)
    }

    /// Does what `seedingWait` says comes next for the Port, and tells it what came of it.
    private func carryOut(_ step: SeedingWait.Step, for port: PortID) {
        switch step {
        case .wait:
            return
        case .seed:
            // During another change, as the next Activity: the Library takes one change per Port at a time.
            perform(.applyROMs, on: port) { services, entry, progress in
                try await services.library.applyROMs(to: entry, progress: progress)
            }
        case .retry(let wait):
            Task { [weak self] in
                try? await Task.sleep(for: wait)
                guard let self, seedingWait.due(port, running: isRunning(port)) else { return }
                applyROMs(port)
            }
        }
    }

    func removeROM(_ sha1: String) {
        guard let services else { return }
        Task {
            do {
                try await services.roms.remove(sha1)
            } catch {
                present(error)
            }
            await survey.romsChanged()
            await refreshSteamOffers()
        }
    }

    // MARK: History and artwork

    /// Loads Snapshots and Runs for a Port page.
    func loadHistory(for port: PortID) async {
        guard let services else { return }
        snapshots[port] = await services.library.snapshots(for: port)
        runs[port] = await services.launcher.runs(for: port)
    }

    func setSteamGridDBKey(_ key: String?) async {
        guard let services else { return }
        do {
            try await services.artwork.setAPIKey(key)
        } catch {
            present(error)
        }
        steamGridDBKey = await services.artwork.apiKeySource()
        ArtworkCache.shared.forgetMissing()
        artworkGeneration += 1
    }

    // MARK: Catalogs

    /// The name of the added Catalog that lists the Port; nil for Frontport's own.
    func catalogName(for entry: CatalogEntry) -> String? {
        entry.catalog.map { url in addedCatalogs.first { $0.id == url }?.name ?? url.host() ?? url.absoluteString }
    }

    /// Fetches and verifies the Catalog a link names, for the Add Catalog sheet to show before the user adds it.
    func previewCatalog(_ link: URL) async throws -> CatalogSummary {
        guard let services else { throw FrontportError.catalogNotAdded("This preview can’t add Catalogs.") }
        return try await services.catalogs.preview(link)
    }

    /// Adds a Catalog the user confirmed, then reads the Catalogs again and looks up its Ports' Releases.
    func addCatalog(_ catalog: AddedCatalog) async throws {
        guard let services else { return }
        try await services.catalogs.add(catalog)
        await catalogsChanged(services)
    }

    /// Forgets an added Catalog. Ports installed from it stay in the Library, no longer in the Catalog.
    func removeCatalog(_ url: URL) async {
        guard let services else { return }
        do {
            try await services.catalogs.remove(url)
        } catch {
            present(error)
        }
        await catalogsChanged(services)
    }

    private func catalogsChanged(_ services: AppServices) async {
        addedCatalogs = await services.catalogs.added()
        await survey.load()
        await refresh()
    }

    /// A cached artwork file, or nil to fall back to a flat color with the Game's name.
    func artwork(_ kind: ArtworkKind, for port: PortID) async -> URL? {
        guard let services, let entry = survey.entry(port) else { return nil }
        return await services.artwork.artwork(kind, for: entry)
    }

    func artwork(_ kind: ArtworkKind, for game: GameID) async -> URL? {
        guard let services, let game = survey.catalog?.game(game) else { return nil }
        return await services.artwork.artwork(kind, for: game)
    }

    /// The short plain-text summary of a Release's notes, for lists.
    func notesSummary(_ release: Release) -> String? {
        if let summary = summaries[release.id] { return summary }
        let summary = release.notes.map { ReleaseNotes.summary($0) }.flatMap { $0.isEmpty ? nil : $0 }
        summaries[release.id] = summary
        return summary
    }

    // MARK: Finder

    func openLogs(for port: PortID) { reveal(paths.logs(for: port)) }

    func openLog(_ run: Run) {
        if FileManager.default.fileExists(atPath: run.log.path(percentEncoded: false)) {
            NSWorkspace.shared.open(run.log)
        }
    }

    func revealData(for port: PortID) {
        guard let entry = survey.entry(port) else { return }
        reveal(paths.data(for: entry.bundleId))
    }

    func revealSnapshot(_ snapshot: Snapshot) { reveal(paths.snapshot(snapshot.id, for: snapshot.port)) }

    /// Opens a folder in a Finder window of its own, never running what it is, even a folder named like an app.
    func openFolder(_ url: URL) {
        guard FileOperations.isDirectory(url) else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path(percentEncoded: false))
    }

    private func reveal(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
