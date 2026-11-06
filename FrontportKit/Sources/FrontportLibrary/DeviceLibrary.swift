import FrontportCore
import Foundation
import os

/// The Ports installed on Devices, and everything that changes them. Talks to the other components only through their
/// FrontportCore protocols: Releases, the Fetcher, the Builder and the Catalog's Recipes read the iOS version's `view`
/// as they read a Mac entry, the Device Packager signs with what Provisioning gives, and `devicectl` installs.
///
/// One operation runs per Port at a time, whichever Device it's for; others for the same Port wait their turn. Any entry
/// whose id or bundle ID could name a folder other than its own is refused, and so is a UDID that could. Only it writes
/// `Devices/` and the `<port>.ios` folders in Downloads, Builds and Logs, which the Mac's Library never sweeps. ROMs lays
/// out what it Seeds on a Device in `Devices/`, never in a Port's Data on this Mac.
public actor DeviceLibrary: DeviceLibraryManaging {
    let paths: AppPaths
    let catalog: any CatalogProviding
    let releases: any ReleaseDiscovering
    let fetcher: any AssetFetching
    let builder: any RecipeBuilding
    let packager: any DevicePackaging
    let control: any DeviceControlling
    let provisioning: any Provisioning
    let roms: any ROMStoring
    /// The Catalog icon each app gets on Devices; none keeps the app's own.
    let artwork: (any ArtworkProviding)?
    /// Where what goes wrong after an operation has done its work is reported.
    static let log = Logger(subsystem: "dev.frontport.Frontport", category: "DeviceLibrary")

    private let queue = PortQueue()

    public init(
        paths: AppPaths, catalog: any CatalogProviding, releases: any ReleaseDiscovering, fetcher: any AssetFetching,
        builder: any RecipeBuilding, packager: any DevicePackaging, control: any DeviceControlling,
        provisioning: any Provisioning, roms: any ROMStoring, artwork: (any ArtworkProviding)? = nil
    ) {
        self.paths = paths
        self.catalog = catalog
        self.releases = releases
        self.fetcher = fetcher
        self.builder = builder
        self.packager = packager
        self.control = control
        self.provisioning = provisioning
        self.roms = roms
        self.artwork = artwork
    }

    // MARK: Reading

    public func installations() async -> [DeviceInstallation] {
        deviceIDs().flatMap { device in ports(on: device).compactMap { folder($0, on: device).record } }
    }

    /// The Port's Installation on the Device, if it has one.
    public func installation(for port: PortID, on device: DeviceID) async -> DeviceInstallation? {
        guard port.isWellFormed, device.isWellFormed else { return nil }
        return folder(port, on: device).record
    }

    public func devices() async -> [Device] {
        deviceIDs()
            .compactMap { id in (try? JSON.read(Device.self, from: paths.deviceRecord(id))).flatMap { $0.id == id ? $0 : nil } }
            .sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    // MARK: Devices

    public func remember(_ device: Device) async throws {
        try Self.check(device.id)
        try FileOperations.createDirectory(paths.device(device.id), mode: 0o755)
        try JSON.write(device, to: paths.deviceRecord(device.id))
    }

    /// Waits for each operation under way on the Device, one that starts meanwhile included: each makes its Port's
    /// folder before anything else. The next launch's `removeLeftovers` takes the iOS build folders and logs no Device
    /// needs any more.
    public func forget(_ device: DeviceID) async throws {
        try Self.check(device)
        while let port = ports(on: device).first {
            try await exclusive(port) { try folder(port, on: device).remove() }
        }
        try DataFolder.remove(paths.device(device))
    }

    // MARK: Preparing

    public func prepare(
        _ version: IOSVersion, channel: Channel, progress: @escaping ProgressHandler
    ) async throws -> PreparedDeviceApp {
        try Self.check(version)
        return try await exclusive(version.id) {
            try await preparing(version, channel: channel, progress: progress)
        }
    }

    public func prepared(_ port: PortID) async -> PreparedDeviceApp? {
        guard port.isWellFormed else { return nil }
        return preparedApp(port)
    }

    /// Resolves the newest iOS Release on the Channel, then prepares it.
    private func preparing(
        _ version: IOSVersion, channel: Channel, progress: @escaping ProgressHandler
    ) async throws -> PreparedDeviceApp {
        let release = try await resolve(version, channel: channel, progress: progress)
        return try await preparing(release, version: version, channel: channel, progress: progress)
    }

    /// The newest iOS Release on the Channel, refused unless the iOS version offers it (`IOSVersion.check`).
    private func resolve(
        _ version: IOSVersion, channel: Channel, progress: @escaping ProgressHandler
    ) async throws -> Release {
        progress(ProgressUpdate(.resolving))
        guard let release = try await releases.latest(for: version.view, channel: channel) else {
            throw FrontportError.noRelease(version.id, channel)
        }
        try version.check(release, on: channel)
        return release
    }

    /// Keeps the prepared app if it's for `release`, or fetches and unpacks it into `preparing/`, or builds it and
    /// clones it there, reads it, and puts it in `prepared/`'s place.
    private func preparing(
        _ release: Release, version: IOSVersion, channel: Channel, progress: @escaping ProgressHandler
    ) async throws -> PreparedDeviceApp {
        let port = version.id
        let recipeSHA256 = version.recipeSHA256
        if let prepared = preparedApp(port), prepared.isFor(release, on: channel, recipeSHA256: recipeSHA256) {
            return prepared
        }
        try Task.checkCancellation()

        // Fetch into `Downloads/<port>.ios/`, which the Mac's Library never sweeps, or build in the iOS build folder, and
        // unpack or clone beside `prepared/`, in that folder itself: a link or file in its place goes, never followed.
        let workspace = paths.builds(for: port.deviceWorkspace)
        if FileOperations.exists(workspace), !FileOperations.isDirectory(workspace) { try DataFolder.remove(workspace) }
        // The Recipe's output, once its app is cloned out: the next build starts without it anyway.
        defer { if version.isSourceBuilt { discard(paths.buildOutput(for: port.deviceWorkspace)) } }
        var built: URL?
        if version.isSourceBuilt { built = try await build(version, release: release, progress: progress) }
        // Made afresh after a build, which may write anywhere in the iOS build folder.
        let preparing = paths.devicePreparing(for: port)
        try DataFolder.remove(preparing)
        try FileOperations.createDirectory(preparing, mode: 0o755)
        defer { discard(preparing) }
        let app: URL
        if let built {
            app = preparing.appending(path: built.lastPathComponent, directoryHint: .isDirectory)
            try FileOperations.clone(built, to: app)
            // The build folder stays writable by the build sandbox, so it's the copy here that must hold no link leading
            // out of it.
            guard FileOperations.isDirectory(app) else {
                throw FrontportError.appNotFound("The iOS Recipe left \(app.lastPathComponent), which isn’t an app folder.")
            }
            try FileOperations.refuseEscapingLinks(in: app)
        } else {
            app = try await fetcher.fetch(release, into: preparing, downloads: port.deviceWorkspace, progress: progress)
            guard app.deletingLastPathComponent().standardizedFileURL == preparing.standardizedFileURL,
                DeviceFolder.isAppName(app.lastPathComponent)
            else {
                throw FrontportError.extractionFailed("\(release.asset?.name ?? release.version) held no app Frontport can use.")
            }
        }
        let info = try await packager.inspect(app, version: version)
        try Task.checkCancellation()

        // The record goes in last, so a `prepared/` without one is never taken for a whole app.
        let prepared = PreparedDeviceApp(
            port: port, release: release, channel: channel, appName: app.lastPathComponent, minimumOS: info.minimumOS,
            families: info.families, recipeSHA256: recipeSHA256)
        let destination = paths.devicePrepared(for: port)
        try DataFolder.remove(destination)
        try FileOperations.createDirectory(destination, mode: 0o755)
        try DataFolder.move(app, to: paths.devicePreparedApp(prepared))
        do {
            try JSON.write(prepared, to: paths.devicePreparedRecord(for: port))
        } catch {
            throw FrontportError.fileOperation("The app couldn’t be kept for Devices. \(error.localizedDescription)")
        }
        // Unpacked, the download is no use any more.
        discard(paths.downloads(for: port.deviceWorkspace))
        return prepared
    }

    /// Runs the iOS Recipe in `Builds/<port>.ios/`, logging to `Logs/<port>.ios/build.log`, and returns the one app it
    /// left in its output folder, refusing anything else there that could be taken for one.
    private func build(
        _ version: IOSVersion, release: Release, progress: @escaping ProgressHandler
    ) async throws -> URL {
        let view = version.view
        let workspace = view.id.deviceWorkspace
        // Xcode's own tools build it, so the Command Line Tools aren't asked for.
        if await builder.toolchainStatus(for: .iphoneos) != .ready {
            try await builder.prepareToolchain(for: .iphoneos, progress: progress)
        }
        let recipe = try await catalog.recipe(for: view)
        let product = try await builder.build(
            view, ref: release.tag, recipe: recipe, roms: .none, sdk: .iphoneos, log: paths.buildLog(for: workspace),
            progress: progress)
        let output = paths.buildOutput(for: workspace)
        let apps = ((try? FileManager.default.contentsOfDirectory(atPath: output.path(percentEncoded: false))) ?? [])
            .filter { $0.hasSuffix(".app") }.sorted()
        guard apps == [product.app.lastPathComponent],
            product.app.deletingLastPathComponent().standardizedFileURL == output.standardizedFileURL,
            DeviceFolder.isAppName(product.app.lastPathComponent)
        else {
            let found = apps.isEmpty ? "none" : apps.joined(separator: ", ")
            throw FrontportError.appNotFound("The iOS Recipe must leave exactly one app in its output folder; found \(found).")
        }
        try Task.checkCancellation()
        return product.app
    }

    /// `prepared.json` with its app beside it, when the record can be read and names only an app in `prepared/`. An iOS
    /// Recipe's build step may write there, so a link in place of either is never followed.
    private func preparedApp(_ port: PortID) -> PreparedDeviceApp? {
        let folder = paths.devicePrepared(for: port)
        guard FileOperations.isDirectory(paths.builds(for: port.deviceWorkspace)), FileOperations.isDirectory(folder),
            let record = try? FileOperations.readRegularFile(paths.devicePreparedRecord(for: port)),
            let prepared = try? JSON.decode(PreparedDeviceApp.self, from: record),
            prepared.port == port, DeviceFolder.isAppName(prepared.appName),
            FileOperations.isDirectory(paths.devicePreparedApp(prepared))
        else { return nil }
        return prepared
    }

    // MARK: Installing

    /// Runs a first install of the prepared app (`preparedToInstall`) on the Device, as the Port's one operation:
    /// refused when the Port is on it already or it can't take an install now, before anything is fetched.
    public func installPrepared(
        _ version: IOSVersion, on reading: DeviceReading, team: AppleTeamID, progress: @escaping ProgressHandler
    ) async throws -> DeviceInstallation {
        try Self.check(version)
        try Self.check(reading.device.id)
        let device = reading.device
        return try await exclusive(version.id) {
            let folder = folder(version.id, on: device.id)
            guard !folder.isRecorded else { throw FrontportError.alreadyInstalled(version.id) }
            try Self.refuse(.install, on: reading, team: team)
            do {
                // First, so forgetting the Device meanwhile waits for this.
                try folder.create()
                try await remember(device)
                let prepared = try await preparedToInstall(version, progress: progress)
                return try await installing(
                    prepared, version: version, on: reading, team: team, from: nil, progress: progress)
            } catch {
                // A first install that failed leaves a folder without a record; the prepared app stays for another
                // try, until no Device has the Port.
                if !folder.isRecorded {
                    for leftover in folder.leftovers { discard(leftover) }
                }
                throw error
            }
        }
    }

    /// Refuses an iOS version whose entry's id or bundle ID could name another folder, and one whose iOS Recipe makes
    /// Build Assets.
    private static func check(_ version: IOSVersion) throws {
        let entry = version.entry
        try entry.checkIdentity()
        guard version.view.buildAssets == nil else {
            throw FrontportError.cantInstallOnDevice(
                "\(entry.name)’s iOS version makes Build Assets from a ROM, which this version of Frontport can’t do for Devices.")
        }
    }

    /// The prepared app, as the iOS version as it is now decides, as resolving would (`IOSVersion.check`): one
    /// Blocked or off its Channel since stays prepared. Gone since it was asked about, as when the last Device's
    /// uninstall took it, it's prepared again on the iOS version's default Channel.
    private func preparedToInstall(
        _ version: IOSVersion, progress: @escaping ProgressHandler
    ) async throws -> PreparedDeviceApp {
        guard let prepared = preparedApp(version.id) else {
            return try await preparing(version, channel: version.defaultChannel, progress: progress)
        }
        try version.check(prepared.release, on: prepared.channel)
        return prepared
    }

    /// Moves an Installation on the Device (or nothing) to the prepared app: check it against the Device, then package
    /// and sign a clone of it, so the prepared app stays unsigned for the next Device, check what was signed against
    /// the Device, and send it.
    private func installing(
        _ prepared: PreparedDeviceApp, version: IOSVersion, on reading: DeviceReading, team: AppleTeamID,
        from current: DeviceInstallation?, progress: @escaping ProgressHandler
    ) async throws -> DeviceInstallation {
        let (port, entry) = (version.id, version.entry)
        let device = reading.device
        // What the Device can't run costs no Provisioning Profile.
        try Self.check(minimumOS: prepared.minimumOS, families: prepared.families, of: entry, on: device)
        let bundleId = port.deviceBundleID(team: team)
        let icon = await artwork?.artwork(.icon, for: entry)
        return try await send(
            paths.devicePreparedApp(prepared), to: folder(port, on: device.id), over: current, as: bundleId, team: team,
            outlasting: nil, progress: progress
        ) { app, signing in
            let info = try await packager.package(app, version: version, signing: signing, icon: icon)
            try Self.check(minimumOS: info.minimumOS, families: info.families, of: entry, on: device)
        } record: { signing in
            DeviceInstallation(
                port: port, device: device.id, release: prepared.release, channel: prepared.channel,
                installedAt: Date().wholeSeconds, appName: prepared.appName, bundleId: bundleId, team: team,
                certificate: signing.certificate.sha1, certificateExpires: signing.certificate.expires.wholeSeconds,
                profile: DeviceInstallation.Profile(signing.profile), seeded: current?.seeded ?? [:],
                filling: current?.filling, recipeSHA256: prepared.recipeSHA256, entry: entry)
        }
    }

    /// Takes a Provisioning Profile for `bundleId` that names the Device, and with its certificate outlasts
    /// `outlasting`; has `sign` sign a clone of `app` with it in a fresh `staging/`, so `app` stays as it was; then
    /// installs the clone and swaps it in, recording what `record` makes of the signing: the record follows the
    /// install. Installed over the app there, it keeps that one's Data, and with it what was Seeded there.
    private func send(
        _ app: URL, to folder: DeviceFolder, over current: DeviceInstallation?, as bundleId: String, team: AppleTeamID,
        outlasting: Date?, progress: @escaping ProgressHandler, sign: (URL, DeviceSigning) async throws -> Void,
        record: (DeviceSigning) -> DeviceInstallation
    ) async throws -> DeviceInstallation {
        // The Provisioning Profile names the Device, so it's taken for each one.
        progress(ProgressUpdate(.provisioning))
        let signing = try await provisioning.signing(for: bundleId, team: team, device: folder.device, outlasting: outlasting)
        if let outlasting, min(signing.profile.expires, signing.certificate.expires) <= outlasting {
            throw FrontportError.provisioningFailed(
                "Its certificate expires \(signing.certificate.expires.formatted(date: .abbreviated, time: .omitted)), "
                    + "no later than the app’s signature does now.")
        }
        try Task.checkCancellation()

        progress(ProgressUpdate(.packaging))
        let staging = try folder.freshStaging()
        defer { discard(staging) }
        let clone = staging.appending(path: app.lastPathComponent, directoryHint: .isDirectory)
        try FileOperations.clone(app, to: clone)
        try await sign(clone, signing)
        try Task.checkCancellation()

        let installation = record(signing)
        progress(ProgressUpdate(.transferring))
        let (control, device) = (control, folder.device)
        return try await folder.replace(current, with: clone, recording: installation) { app in
            try await control.install(app, on: device)
        }
    }

    // MARK: Updating and Renewing

    public func update(
        _ version: IOSVersion, on reading: DeviceReading, team: AppleTeamID, channel: Channel,
        progress: @escaping ProgressHandler
    ) async throws -> DeviceInstallation {
        try Self.check(version)
        return try await withInstallation(version.id, on: reading.device.id) { _, current in
            try Self.refuse(.install, on: reading, team: team, signed: current.team)
            // Forward only, decided before anything is fetched: a Device keeps no previous Release to go back to, nor a
            // Snapshot of its Data.
            let release = try await resolve(version, channel: channel, progress: progress)
            if release.tag == current.release.tag, channel == current.channel,
                current.recipeSHA256 == version.recipeSHA256
            {
                return current
            }
            guard version.isForward(current, to: release) else {
                throw FrontportError.cantInstallOnDevice(
                    "\(release.version) is older than \(current.release.version), which \(reading.device.name) has.")
            }
            let prepared = try await preparing(release, version: version, channel: channel, progress: progress)
            return try await installing(
                prepared, version: version, on: reading, team: team, from: current, progress: progress)
        }
    }

    public func renew(
        _ port: PortID, on reading: DeviceReading, team: AppleTeamID, progress: @escaping ProgressHandler
    ) async throws -> DeviceInstallation {
        let device = reading.device
        return try await withInstallation(port, on: device.id) { folder, current in
            try Self.refuse(.renew, on: reading, team: team, signed: current.team)
            let kept = folder.app(current)
            guard FileOperations.isDirectory(kept) else {
                throw FrontportError.cantInstallOnDevice(
                    "The app installed on \(device.name) isn’t kept on this Mac any more. Uninstall it, then install it again.")
            }
            // Installing over nothing would put back an app the user deleted there, with no Data; over one running
            // there, it would stop it.
            guard try await control.apps(on: device.id).contains(current.bundleId) else {
                throw FrontportError.deviceUnavailable(
                    .notInstalled, detail: "\(current.bundleId) isn’t on \(device.name) any more: it was deleted there.")
            }
            if try await isRunning(current) { throw FrontportError.running(port) }

            // A Provisioning Profile for its own bundle ID that outlasts the signature it has, and a certificate that
            // does too, to sign a clone of the kept app again, so the kept one matches the record until the new one is
            // installed.
            return try await send(
                kept, to: folder, over: current, as: current.bundleId, team: team, outlasting: current.expires,
                progress: progress
            ) { app, signing in
                _ = try await packager.resign(app, signing: signing)
            } record: { signing in
                var renewed = current
                renewed.certificate = signing.certificate.sha1
                renewed.certificateExpires = signing.certificate.expires.wholeSeconds
                renewed.profile = DeviceInstallation.Profile(signing.profile)
                return renewed
            }
        }
    }

    /// Refuses an app the Device can't run: one needing a newer iOS than it has, or one made only for the other kind
    /// of Device. What the Device didn't say isn't checked.
    static func check(minimumOS: String, families: [Int], of entry: CatalogEntry, on device: Device) throws {
        switch DeviceInstallStatus.fit(minimumOS: minimumOS, families: families, on: device) {
        case .needsNewerIOS?:
            throw FrontportError.cantInstallOnDevice(
                "\(entry.name) needs iOS \(minimumOS) or later, and \(device.name) has iOS \(device.osVersion).")
        case .otherDevices?:
            let kinds = families.map { [1: "iPhone", 2: "iPad"][$0] ?? "other devices" }
            throw FrontportError.cantInstallOnDevice(
                "\(entry.name) is made for \(kinds.joined(separator: " and ")) only, and \(device.name) is \(device.model).")
        default:
            break
        }
    }

    /// Refuses `operation` when `DeviceReadiness` says it can't run on the Device as `reading` found it, before
    /// anything is fetched or asked of the Device. Xcode is left to `devicectl`, which says when it's missing.
    private static func refuse(
        _ operation: DeviceReadiness.Operation, on reading: DeviceReading, team: AppleTeamID?,
        signed: AppleTeamID? = nil
    ) throws {
        try DeviceReadiness(hasXcode: true, team: team).check(operation, on: reading, signed: signed)
    }

    // MARK: Removing

    public func uninstall(_ port: PortID, from device: DeviceID) async throws {
        try await withInstallation(port, on: device) { folder, current in
            // One deleted on the Device already counts as removed.
            try await control.uninstall(current.bundleId, from: device)
            try folder.remove()
            // A download is kept only until its Release is prepared; the iOS build folder, the prepared app in it, and
            // the logs, only while a Device has the Port.
            discard(paths.downloads(for: port.deviceWorkspace))
            if !isInstalled(port) {
                discard(paths.builds(for: port.deviceWorkspace))
                discard(paths.logs(for: port.deviceWorkspace))
            }
        }
    }

    // MARK: Seeding

    public func seed(
        _ version: IOSVersion, on reading: DeviceReading, progress: @escaping ProgressHandler
    ) async throws -> DeviceSeedingPlan? {
        try version.entry.checkIdentity()
        return try await withInstallation(version.id, on: reading.device.id) { folder, current in
            guard !version.requirements.isEmpty else { return nil }
            try Self.refuse(.seed, on: reading, team: nil)
            if try await isRunning(current) { throw FrontportError.running(version.id) }
            progress(ProgressUpdate(.seeding))
            return try await staging(version, in: folder) { staged, root in
                try await DeviceSeeder(folder: folder, control: control)
                    .seed(staged, from: root, over: current, progress: progress)
            }
        }
    }

    public func seedingPlan(for version: IOSVersion, on reading: DeviceReading) async throws -> DeviceSeedingPlan? {
        try version.entry.checkIdentity()
        return try await withInstallation(version.id, on: reading.device.id) { folder, current in
            guard !version.requirements.isEmpty else { return nil }
            try Self.refuse(.list, on: reading, team: nil)
            return try await staging(version, in: folder) { staged, _ in
                try await DeviceSeeder(folder: folder, control: control).plan(staged, for: current)
            }
        }
    }

    public func isRunning(_ port: PortID, on device: DeviceID) async throws -> Bool {
        guard port.isWellFormed, device.isWellFormed, let current = folder(port, on: device).record else { return false }
        return try await isRunning(current)
    }

    private func isRunning(_ installation: DeviceInstallation) async throws -> Bool {
        installation.isRunning(in: try await control.processes(on: installation.device))
    }

    /// Lays the iOS version's ROMs out for the Device in a fresh `seeds/` in the Installation's folder, as in the
    /// container, and runs `body` with them and that folder, which goes afterwards.
    private func staging<T>(
        _ version: IOSVersion, in folder: DeviceFolder, _ body: ([StagedSeed], URL) async throws -> T
    ) async throws -> T {
        let seeds = paths.deviceSeeds(for: folder.port, on: folder.device)
        try DataFolder.remove(seeds)
        try FileOperations.createDirectory(seeds, mode: 0o700)
        defer { discard(seeds) }
        return try await body(try await roms.stage(version, into: seeds), seeds)
    }

    // MARK: Leftovers

    public func removeLeftovers() async {
        let fm = FileManager.default
        var ports: Set<PortID> = []
        for folder in [paths.downloads, paths.builds, paths.logs] {
            for name in (try? fm.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? [] {
                if let port = PortID(deviceWorkspace: name) { ports.insert(port) }
            }
        }
        for device in deviceIDs() { ports.formUnion(self.ports(on: device)) }

        for port in ports.sorted() {
            try? await exclusive(port) {
                // A record that can't be read still marks an Installation, whose folders stay.
                for device in deviceIDs() where folder(port, on: device).exists {
                    for leftover in folder(port, on: device).leftovers { discard(leftover) }
                }
                discard(paths.downloads(for: port.deviceWorkspace))
                // A link or file in place of the iOS build folder goes, never followed into.
                let workspace = paths.builds(for: port.deviceWorkspace)
                if FileOperations.isDirectory(workspace) {
                    discard(paths.devicePreparing(for: port))
                } else {
                    discard(workspace)
                }
                // The prepared app with the rest: only for the next Device while one has the Port.
                if !isInstalled(port) {
                    discard(paths.builds(for: port.deviceWorkspace))
                    discard(paths.logs(for: port.deviceWorkspace))
                }
            }
        }
        // A Device's folder left with nothing: no record of it and no Installation on it.
        for device in deviceIDs() where !FileOperations.exists(paths.deviceRecord(device)) && self.ports(on: device).isEmpty {
            discard(paths.device(device))
        }
    }

    /// Removes what nothing reads again. What it follows is complete, so a failure is only logged: uninstalling or the
    /// next launch's `removeLeftovers` tries again.
    private func discard(_ url: URL) {
        do {
            try FileOperations.removeUntrusted(url)
        } catch {
            let reason = (error as? FrontportError)?.errorDescription ?? error.localizedDescription
            Self.log.error("\(url.path(percentEncoded: false), privacy: .public) couldn’t be removed. \(reason, privacy: .public)")
        }
    }

    // MARK: Folders

    func folder(_ port: PortID, on device: DeviceID) -> DeviceFolder {
        DeviceFolder(paths: paths, port: port, device: device)
    }

    /// True when any Device's folder for the Port holds a record, readable or not.
    private func isInstalled(_ port: PortID) -> Bool {
        deviceIDs().contains { folder(port, on: $0).isRecorded }
    }

    /// The Devices with a folder in `Devices/`, by UDID.
    private func deviceIDs() -> [DeviceID] {
        Self.folders(in: paths.devices).map { DeviceID($0) }.filter(\.isWellFormed)
    }

    /// The Ports with a folder on the Device, by id.
    private func ports(on device: DeviceID) -> [PortID] {
        Self.folders(in: paths.device(device)).map { PortID($0) }.filter(\.isWellFormed)
    }

    /// The names of the folders in `folder`, sorted, links left out.
    private static func folders(in folder: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        return names.filter { FileOperations.isDirectory(folder.appending(path: $0)) }.sorted()
    }

    /// Refuses a UDID that could name a folder other than the Device's own.
    private static func check(_ device: DeviceID) throws {
        guard device.isWellFormed else { throw FrontportError.fileOperation("“\(device)” isn’t a Device’s UDID.") }
    }

    // MARK: Per-Port exclusion

    /// Runs `body` alone for the Port, with its Installation on the Device and the folder that holds it. Refuses a UDID
    /// that could name another folder, and throws `notInstalled` without the Installation.
    private func withInstallation<T>(
        _ port: PortID, on device: DeviceID, _ body: (DeviceFolder, DeviceInstallation) async throws -> T
    ) async throws -> T {
        try Self.check(device)
        guard port.isWellFormed else { throw FrontportError.notInstalled(port) }
        return try await exclusive(port) {
            let folder = folder(port, on: device)
            guard let current = folder.record else { throw FrontportError.notInstalled(port) }
            return try await body(folder, current)
        }
    }

    private func exclusive<T>(_ port: PortID, _ body: () async throws -> T) async throws -> T {
        await queue.acquire(port)
        defer { queue.release(port) }
        return try await body()
    }
}

extension DeviceInstallation.Profile {
    /// What the record keeps of a Provisioning Profile, to whole seconds as JSON keeps dates.
    init(_ profile: ProvisioningProfile) {
        self.init(uuid: profile.uuid, name: profile.name, expires: profile.expires.wholeSeconds)
    }
}
