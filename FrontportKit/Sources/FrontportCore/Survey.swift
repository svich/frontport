import Foundation
import Observation
import os

/// What Frontport last found in the Catalog, the Library, ROMs and Releases, and in the records of Installations on
/// Devices: taken at launch, every 6 hours and after each Activity. The Lineup, Matching and offers every screen shows
/// are read here. Whether a Device is reachable now isn't: `devicectl` is read apart, so a slow one never holds this up.
///
/// Reads land as they finish, so between them a screen may see a new Catalog with the Library read before it; each
/// read brings unlisted entries, offers and the Lineup up to date with everything read so far.
@MainActor @Observable
public final class Survey {
    /// The services a Survey reads.
    public struct Sources: Sendable {
        public var catalog: any CatalogProviding
        public var library: any LibraryManaging
        public var roms: any ROMStoring
        public var releases: any ReleaseDiscovering
        /// Installations on Devices; without it, the Survey reads only this Mac's.
        public var devices: (any DeviceRecords)?

        public init(
            catalog: any CatalogProviding, library: any LibraryManaging, roms: any ROMStoring,
            releases: any ReleaseDiscovering, devices: (any DeviceRecords)? = nil
        ) {
            self.catalog = catalog
            self.library = library
            self.roms = roms
            self.releases = releases
            self.devices = devices
        }
    }

    /// The Catalogs read as one, without the Ports installed, here or on a Device, from another Catalog than the one now
    /// listing them.
    public private(set) var catalog: CatalogDocument?
    public private(set) var installations: [PortID: Installation] = [:]
    /// Installations on Devices, by Port, each Port's by Device.
    public private(set) var deviceInstallations: [PortID: [DeviceInstallation]] = [:]
    /// The Devices remembered in their records, by name, reachable now or not.
    public private(set) var devices: [Device] = []
    /// Stand-in entries, from their install records, for Installations the Catalog doesn't list, here or on a Device.
    public private(set) var unlisted: [PortID: CatalogEntry] = [:]
    /// Where every Port's Requirements stand, from ROMs and the Library Ports' Data.
    public private(set) var matching = Matching.empty
    /// The newest Release of every Catalog Port on its default (or installed) Channel, newest first. Never an iOS one.
    public private(set) var releases: [Release] = []
    /// The newest iOS Release of every Catalog Port with an iOS version, on that version's default Channel, kept apart
    /// from `releases`, which the Lineup and the Releases screen show. Looked up only with a `devices` source.
    public private(set) var iosReleases: [PortID: Release] = [:]
    /// The newest iOS Release on each other Channel an Installation on a Device follows, by Port then Channel, so it's
    /// offered its Updates once the iOS version's default Channel is another.
    public private(set) var followedIOSReleases: [PortID: [Channel: Release]] = [:]
    /// What each installed Port is offered from the newest Release on its Channel: an Update, or a Fallback.
    public private(set) var offers: [PortID: Move.Offer] = [:]
    /// What every Catalog screen shows, from the Catalog, the Library and the known Releases.
    public private(set) var lineup = Lineup(catalog: nil)
    /// When the Catalog or a Release lookup was last reached.
    public private(set) var lastChecked: Date?
    /// Told of a failure to present: reading the cached Catalog, or enforcing its Blocks.
    @ObservationIgnored public var onFailure: @MainActor (any Error) -> Void = { _ in }

    private let sources: Sources?
    /// The Catalog as last read, before `catalog` leaves out Ports installed from other Catalogs.
    @ObservationIgnored private var read: CatalogDocument?
    private let activities: Activities
    private let paths: AppPaths
    /// The newest Release found per Port on the Channel looked at; nil when it has none.
    @ObservationIgnored private var newest: [PortID: Release?] = [:]
    /// Counts readings of `matching` started, so only the latest lands.
    @ObservationIgnored private var readings = 0
    @ObservationIgnored private var isRefreshing = false
    private let log = Logger(subsystem: "dev.frontport.Frontport", category: "Survey")

    /// A Survey over the services, empty until `load()`. It keeps the Lineup current as first installs in `activities`
    /// start and end.
    public init(_ sources: Sources, activities: Activities, paths: AppPaths) {
        self.sources = sources
        self.activities = activities
        self.paths = paths
        activities.onChange { [weak self] _ in self?.updateLineup() }
    }

    /// A fixed Survey, for previews: `load()` and the other reads do nothing, and `refresh()` only sets `lastChecked`.
    public init(
        preview catalog: CatalogDocument, installations: [Installation], matching: Matching, releases: [Release],
        updates: [PortID: Release], lastChecked: Date?, activities: Activities, paths: AppPaths,
        deviceInstallations: [DeviceInstallation] = [], devices: [Device] = [], iosReleases: [PortID: Release] = [:]
    ) {
        sources = nil
        self.activities = activities
        self.paths = paths
        self.installations = Dictionary(uniqueKeysWithValues: installations.map { ($0.port, $0) })
        self.deviceInstallations = Dictionary(grouping: deviceInstallations, by: \.port)
        self.devices = devices
        self.iosReleases = iosReleases
        read = catalog
        self.catalog = catalog.excludingPorts(installedFromOtherCatalogs: self.installations)
            .excludingPorts(installedOnDevicesFromOtherCatalogs: self.deviceInstallations)
        self.matching = matching
        self.releases = releases
        offers = updates.mapValues { .update($0) }
        self.lastChecked = lastChecked
        updateUnlisted()
        updateLineup()
    }

    // MARK: Reading

    /// Reads the cached Catalog, the Library and Matching, without the network.
    public func load() async {
        guard let sources else { return }
        do {
            read = try await sources.catalog.current()
            updateDerived()
        } catch {
            onFailure(error)
        }
        await readLibrary()
    }

    /// Refreshes the Catalog, enforces its Blocks, reads the Library and Matching, and looks up every Catalog Port's
    /// newest Release. Offline, the cached Catalog stays in use. Returns whether it ran: not when one is already under
    /// way, once cancelled, or with no Catalog, cached or refreshed, to read.
    @discardableResult
    public func refresh() async -> Bool {
        guard let sources else {
            lastChecked = .now
            return true
        }
        guard !isRefreshing else { return false }
        isRefreshing = true
        defer { isRefreshing = false }

        var reached = true
        do {
            read = try await sources.catalog.refresh()
            updateDerived()
        } catch is CancellationError {
            return false
        } catch {
            // Offline or not yet published: the cached Catalog stays in use.
            reached = false
            log.error("Catalog refresh failed: \(error.localizedDescription, privacy: .public)")
        }
        guard let catalog else { return false }
        do {
            _ = try await sources.library.enforceBlocks(catalog)
        } catch {
            onFailure(error)
        }
        await readLibrary()
        if await discoverReleases(catalog.ports) || reached { lastChecked = .now }
        await discoverIOSReleases(catalog.ports)
        return true
    }

    /// Reads what a change of this kind to the Port may have touched: the Library, the records of Installations on
    /// Devices and Matching, and the Port's newest Release, or iOS Release for a change on a Device, when the change was
    /// to its Release or Channel.
    public func changed(_ port: PortID, by kind: Activity.Kind) async {
        await readLibrary()
        if kind.changesRelease, let entry = entry(port) {
            if kind.isForDevices {
                await discoverIOSReleases([entry])
            } else {
                _ = await discoverReleases([entry])
            }
        }
    }

    /// Reads the records of Installations on Devices again: after a Device was remembered or forgotten.
    public func devicesChanged() async {
        land(await readDevices())
        updateDerived()
    }

    /// Reads Matching again: after ROMs were added or removed, or a Port quit, so its Data may have changed.
    public func romsChanged() async {
        await readMatching()
    }

    /// Shows new Permissions on the Port's Installation while the Library re-signs it; the next read of the Library
    /// has them once it has.
    public func setPermissions(_ permissions: Permissions, for port: PortID) {
        installations[port]?.permissions = permissions
    }

    // MARK: Lookups

    /// The Catalog's entry, or for an Installation the Catalog doesn't list, a stand-in from its install record.
    public func entry(_ port: PortID) -> CatalogEntry? { catalog?.entry(port) ?? unlisted[port] }
    /// False for an Installation the Catalog doesn't list, here or on a Device (or before it loads): it has no store page
    /// and no updates.
    public func isListed(_ port: PortID) -> Bool { catalog?.entry(port) != nil }
    /// Whether Frontport knows the Port's entry, the Catalog's or the one its install record kept, and so its
    /// Requirements and code-signing exceptions: what re-signing it (Permissions, Rollback) and applying ROMs need.
    /// False only for a record from before Frontport kept the entry, whose Port the Catalog no longer lists.
    public func knowsEntry(_ port: PortID) -> Bool { isListed(port) || installations[port]?.entry != nil }
    public func installation(_ port: PortID) -> Installation? { installations[port] }
    /// The Port's Installations on Devices, by Device.
    public func deviceInstallations(of port: PortID) -> [DeviceInstallation] { deviceInstallations[port] ?? [] }
    /// Every Installation on Devices, or only those on `device`, by Port, then Device.
    public func deviceInstallations(on device: DeviceID? = nil) -> [DeviceInstallation] {
        deviceInstallations.values.flatMap(\.self).filter { device == nil || $0.device == device }
            .sorted { ($0.port, $0.device) < ($1.port, $1.device) }
    }
    public func deviceInstallation(_ port: PortID, on device: DeviceID) -> DeviceInstallation? {
        deviceInstallations[port]?.first { $0.device == device }
    }
    /// The newest known iOS Release of a Port with an iOS version, on that version's default Channel.
    public func latestIOSRelease(for port: PortID) -> Release? { iosReleases[port] }
    /// The newest known iOS Release on `channel`, such as the one an Installation on a Device follows.
    public func latestIOSRelease(for port: PortID, channel: Channel) -> Release? {
        channel == entry(port).flatMap({ IOSVersion($0) })?.defaultChannel
            ? iosReleases[port] : followedIOSReleases[port]?[channel]
    }
    public func game(for entry: CatalogEntry) -> Game? { catalog?.game(for: entry) }
    public func platform(for entry: CatalogEntry) -> Platform? { catalog?.platform(for: entry) }
    /// Every ROM in ROMs, newest first.
    public var roms: [ROMRecord] { matching.roms }

    /// Where the Port's Requirements stand, as the last reading found them. Before the first, every one is missing.
    public func matching(for port: PortID) -> PortMatching {
        matching[port]
            ?? PortMatching(
                port: port, isInstalled: installations[port] != nil,
                requirements: (entry(port)?.requirements ?? []).map {
                    RequirementState(requirement: $0, rom: nil, accepted: .missing)
                })
    }

    /// Newer non-Blocked Releases for installed Ports.
    public var updates: [PortID: Release] {
        offers.compactMapValues { if case .update(let release) = $0 { release } else { nil } }
    }

    /// The newest known Release of a Port.
    public func latestRelease(for port: PortID) -> Release? {
        updates[port] ?? releases.first { $0.port == port }
    }

    /// Installed Ports plus first installs in progress, by name: the sidebar's Ports and the Library screen. A Port on a
    /// Device only is one of them. Installations the Catalog doesn't list stay, so they can still be played, uninstalled
    /// or have their Data deleted.
    public var libraryPorts: [CatalogEntry] {
        lineup.library.compactMap { entry($0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Ports installed on this Mac plus first installs in progress here, by name: the sidebar's This Mac.
    public var macPorts: [CatalogEntry] { byName(Set(installations.keys), installing: nil) }

    /// Ports installed on the Device plus first installs in progress there, by name: its section in the sidebar.
    public func ports(on device: DeviceID) -> [CatalogEntry] {
        byName(Set(deviceInstallations(on: device).map(\.port)), installing: device)
    }

    /// `installed` plus the Ports being installed for the first time on `device`, or on this Mac for nil, by name.
    private func byName(_ installed: Set<PortID>, installing device: DeviceID?) -> [CatalogEntry] {
        let first: Activity.Kind = device.map { .device(.install, $0) } ?? .install
        let installing = activities.underWay.filter { $0.value.kind == first }.keys
        return installed.union(installing).compactMap { entry($0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Reads

    private func readLibrary() async {
        guard let sources else { return }
        let list = await sources.library.installations()
        let onDevices = await readDevices()
        // Set together, with no wait between them and the derived state, so no screen sees one without the other.
        installations = Dictionary(uniqueKeysWithValues: list.map { ($0.port, $0) })
        land(onDevices)
        updateDerived()
        await readMatching()
    }

    /// The records of Installations on Devices and the Devices remembered, with a `devices` source; nil without one.
    private func readDevices() async -> (installations: [DeviceInstallation], devices: [Device])? {
        guard let devices = sources?.devices else { return nil }
        return (await devices.installations(), await devices.devices())
    }

    /// Sets what `readDevices` read, only where it changed.
    private func land(_ read: (installations: [DeviceInstallation], devices: [Device])?) {
        guard let read else { return }
        let byPort = Dictionary(grouping: read.installations, by: \.port)
        if byPort != deviceInstallations { deviceInstallations = byPort }
        if read.devices != devices { devices = read.devices }
    }

    /// Reads where every Port's Requirements stand, from ROMs and the installed Ports' Data, so a Seeding that failed
    /// stays visible until it's fixed. A reading that finishes after a later one is dropped.
    private func readMatching() async {
        guard let sources else { return }
        readings += 1
        let reading = readings
        let entries = (catalog?.ports ?? []) + unlisted.values
        let installed = installations.filter { knowsEntry($0.key) }
        let result = await sources.roms.matching(entries, installations: installed)
        guard reading == readings else { return }
        matching = result
        activities.keepSeedingFailures { result[$0]?.unseeded.isEmpty == false }
    }

    /// Looks up the newest Release of each entry on its Installation's Channel, or its default one. Returns whether
    /// any lookup succeeded; entries whose lookup failed keep what was known.
    private func discoverReleases(_ entries: [CatalogEntry]) async -> Bool {
        guard let sources else { return false }
        let wanted = entries.map { ($0, installations[$0.id]?.channel ?? $0.defaultChannel) }
        let found = await withTaskGroup(of: (PortID, Result<Release?, any Error>).self) { group in
            for (entry, channel) in wanted {
                group.addTask {
                    do {
                        return (entry.id, .success(try await sources.releases.latest(for: entry, channel: channel)))
                    } catch {
                        return (entry.id, .failure(error))
                    }
                }
            }
            var results: [(PortID, Result<Release?, any Error>)] = []
            for await result in group { results.append(result) }
            return results
        }
        var succeeded = false
        for (port, result) in found {
            switch result {
            case .success(let release):
                succeeded = true
                newest[port] = release
            case .failure(let error):
                log.error("Release discovery for \(port, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        releases = newest.filter { catalog?.entry($0.key) != nil }.values.compactMap(\.self)
            .sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
        updateDerived()
        return succeeded
    }

    /// Looks up the newest iOS Release of each entry with an iOS version, on that version's default Channel and on each
    /// other one of its Channels an Installation on a Device follows, with a `devices` source. Entries whose lookup
    /// failed keep what was known.
    private func discoverIOSReleases(_ entries: [CatalogEntry]) async {
        guard let sources, sources.devices != nil else { return }
        // With none left, what was known still goes for the Ports whose iOS version the Catalog dropped.
        let wanted = entries.compactMap { IOSVersion($0) }.flatMap { version in
            let followed = Set((deviceInstallations[version.id] ?? []).map(\.channel))
                .filter { $0 != version.defaultChannel && version.channels.contains($0) }
            return ([version.defaultChannel] + followed.sorted { $0.rawValue < $1.rawValue }).map { (version.view, $0) }
        }
        let found = await withTaskGroup(of: (PortID, Channel, Result<Release?, any Error>).self) { group in
            for (view, channel) in wanted {
                group.addTask {
                    do {
                        return (view.id, channel, .success(try await sources.releases.latest(for: view, channel: channel)))
                    } catch {
                        return (view.id, channel, .failure(error))
                    }
                }
            }
            var results: [(PortID, Channel, Result<Release?, any Error>)] = []
            for await result in group { results.append(result) }
            return results
        }
        var releases = iosReleases
        var followed = followedIOSReleases
        for (port, channel, result) in found {
            switch result {
            case .success(let release) where channel == catalog?.entry(port).flatMap({ IOSVersion($0) })?.defaultChannel:
                releases[port] = release
            case .success(let release):
                followed[port, default: [:]][channel] = release
            case .failure(let error):
                log.error("iOS Release discovery for \(port, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        releases = releases.filter { catalog?.entry($0.key)?.ios != nil }
        if releases != iosReleases { iosReleases = releases }
        // Only the Channels other than the default that an Installation still follows.
        var kept: [PortID: [Channel: Release]] = [:]
        for (port, byChannel) in followed {
            guard let version = catalog?.entry(port).flatMap({ IOSVersion($0) }) else { continue }
            let channels = byChannel.filter { channel, _ in
                channel != version.defaultChannel && deviceInstallations[port]?.contains { $0.channel == channel } == true
            }
            if !channels.isEmpty { kept[port] = channels }
        }
        if kept != followedIOSReleases { followedIOSReleases = kept }
    }

    // MARK: Derived

    /// Brings unlisted entries, offers and the Lineup up to date with what was read.
    private func updateDerived() {
        let listed = read?.excludingPorts(installedFromOtherCatalogs: installations)
            .excludingPorts(installedOnDevicesFromOtherCatalogs: deviceInstallations)
        if listed != catalog { catalog = listed }
        updateUnlisted()
        var offers: [PortID: Move.Offer] = [:]
        for (port, installation) in installations {
            guard let entry = catalog?.entry(port) else { continue }
            offers[port] = Move.offer(entry, for: installation, newest: newest[port] ?? nil)
        }
        self.offers = offers
        updateLineup()
    }

    private func updateUnlisted() {
        var result: [PortID: CatalogEntry] = [:]
        for (port, installation) in installations where catalog?.entry(port) == nil {
            result[port] = .unlisted(installation, paths: paths)
        }
        // A Port only Devices have: the entry its latest change there kept.
        for (port, onDevices) in deviceInstallations where catalog?.entry(port) == nil && result[port] == nil {
            result[port] = onDevices.max { $0.installedAt < $1.installedAt }?.entry
        }
        unlisted = result
    }

    private func updateLineup() {
        let installing = activities.underWay.filter { $0.value.kind.isFirstInstall }.keys
        let library = Set(installations.keys).union(installing).union(deviceInstallations.keys)
        lineup = Lineup(
            catalog: catalog, library: library, releases: releases, updates: updates,
            installed: installations.values.map(\.release))
    }
}

extension CatalogEntry {
    /// The entry for an Installation the Catalog no longer lists: the one its install record kept, so launching,
    /// Permissions and Rollback work as before. Older records have none; for those, a stand-in from the record and
    /// the app's Info.plist, which carries the bundle ID the Packager set, without Requirements, Blocks or
    /// code-signing exceptions.
    static func unlisted(_ installation: Installation, paths: AppPaths) -> CatalogEntry {
        if let entry = installation.entry { return entry }
        let app = installation.disabled
            ? paths.blocked(for: installation.port).appending(path: installation.appName, directoryHint: .isDirectory)
            : paths.app(for: installation)
        let plist = (try? Data(contentsOf: app.appending(path: "Contents/Info.plist")))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
        let name = plist["CFBundleDisplayName"] as? String ?? plist["CFBundleName"] as? String
            ?? (installation.appName as NSString).deletingPathExtension
        let port = installation.port
        return CatalogEntry(
            id: port, name: name, kind: .decomp, game: GameID(port.rawValue), developer: "", summary: "",
            description: "", source: installation.release.notesURL ?? paths.library(for: port),
            bundleId: plist["CFBundleIdentifier"] as? String ?? port.conventionalBundleID,
            releases: .githubRelease(GitHubReleaseSource(repo: "", asset: "", channels: [installation.channel])),
            permissions: installation.permissions)
    }
}
