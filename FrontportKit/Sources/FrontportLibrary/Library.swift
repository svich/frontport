import FrontportCore
import Foundation
import os

/// The Ports installed on this Mac, and everything that changes them. Talks to the other components only
/// through their FrontportCore protocols.
///
/// One operation runs per Port at a time; others for the same Port wait their turn. Any change of Release,
/// Permissions or Data is refused while the Port runs, and so is any entry whose id or bundle ID could name a
/// folder other than its own.
public actor Library: LibraryManaging {
    let paths: AppPaths
    let catalog: any CatalogProviding
    let releases: any ReleaseDiscovering
    let fetcher: any AssetFetching
    let builder: any RecipeBuilding
    let roms: any ROMStoring
    let packager: any PortPackaging
    let launcher: any PortLaunching
    /// Each Port's Data, made again when it's gone, through the primer when macOS manages it, so Seeding can go ahead.
    let data: PortData
    let snapshotStore: SnapshotStore
    /// Where what goes wrong after an operation without progress has done its work is reported.
    static let log = Logger(subsystem: "dev.frontport.Frontport", category: "Library")

    private var records: [PortID: Installation]?
    private var busy: Set<PortID> = []
    private var waiting: [PortID: [CheckedContinuation<Void, Never>]] = [:]

    public init(
        paths: AppPaths, catalog: any CatalogProviding, releases: any ReleaseDiscovering, fetcher: any AssetFetching,
        builder: any RecipeBuilding, roms: any ROMStoring, packager: any PortPackaging, launcher: any PortLaunching,
        primer: (any ContainerPriming)? = nil
    ) {
        self.paths = paths
        self.catalog = catalog
        self.releases = releases
        self.fetcher = fetcher
        self.builder = builder
        self.roms = roms
        self.packager = packager
        self.launcher = launcher
        data = PortData(paths: paths, primer: primer)
        snapshotStore = SnapshotStore(paths: paths)
    }

    // MARK: Reading

    public func installations() async -> [Installation] {
        loaded().values.sorted { $0.port < $1.port }
    }

    public func installation(for port: PortID) async -> Installation? {
        loaded()[port]
    }

    public func snapshots(for port: PortID) async -> [Snapshot] {
        snapshotStore.list(port)
    }

    // MARK: Changing Releases

    public func install(_ entry: CatalogEntry, channel: Channel, progress: @escaping ProgressHandler) async throws
        -> Installation
    {
        if let reason = entry.unsupported { throw FrontportError.unsupported(entry.id, reason: reason) }
        return try await exclusive(entry) {
            guard loaded()[entry.id] == nil else { throw FrontportError.alreadyInstalled(entry.id) }
            try await refuseWhileRunning(entry)
            let hadContainer = FileOperations.exists(paths.container(for: entry.bundleId))
            do {
                let release = try await resolve(entry, channel: channel, progress: progress)
                return try await change(entry, from: nil, to: release, channel: channel, reason: .update, progress: progress)
            } catch {
                removeFailedInstall(entry, hadContainer: hadContainer)
                throw error
            }
        }
    }

    public func update(_ entry: CatalogEntry, to release: Release?, progress: @escaping ProgressHandler) async throws
        -> Installation
    {
        if let reason = entry.unsupported { throw FrontportError.unsupported(entry.id, reason: reason) }
        return try await exclusive(entry) {
            let current = try require(entry.id)
            try await refuseWhileRunning(entry)
            let target: Release
            if let release {
                try refuseBlocked(entry, release)
                target = release
            } else {
                target = try await resolve(entry, channel: current.channel, progress: progress)
            }
            let move = Move(entry, from: current, to: target, on: current.channel)
            if move.direction == .none { return current }
            return try await run(move, entry, from: current, reason: .update, progress: progress)
        }
    }

    public func rollback(_ entry: CatalogEntry, progress: @escaping ProgressHandler) async throws -> Installation {
        try await exclusive(entry) {
            let current = try require(entry.id)
            try await refuseWhileRunning(entry)
            guard let move = Move.rollback(from: current) else { throw FrontportError.noPreviousRelease(entry.id) }
            return try await rollBack(entry, move, from: current, reason: .rollback, channel: nil, progress: progress)
        }
    }

    public func switchChannel(_ entry: CatalogEntry, to channel: Channel, progress: @escaping ProgressHandler)
        async throws -> Installation
    {
        try await exclusive(entry) {
            var current = try require(entry.id)
            guard channel != current.channel else { return current }
            guard entry.channels.contains(channel) else { throw FrontportError.noRelease(entry.id, channel) }
            try await refuseWhileRunning(entry)
            let target = try await resolve(entry, channel: channel, progress: progress)

            let move = Move(entry, from: current, to: target, on: channel)
            if move.direction == .none {
                current.channel = channel
                current.entry = entry
                try await save(current)
                return current
            }
            return try await run(move, entry, from: current, reason: .channelSwitch, progress: progress)
        }
    }

    // MARK: Permissions and ROMs

    public func setPermissions(_ permissions: Permissions, for entry: CatalogEntry) async throws -> Installation {
        try await exclusive(entry) {
            var current = try require(entry.id)
            try await refuseWhileRunning(entry)
            guard permissions != current.permissions else { return current }
            try await packager.resign(
                folder(entry.id).app(current), entry: entry, permissions: permissions,
                installedAssets: paths.assets(for: entry.id))
            current.permissions = permissions
            current.entry = entry
            try await save(current)
            return current
        }
    }

    public func applyROMs(to entry: CatalogEntry, progress: @escaping ProgressHandler) async throws {
        try await exclusive(entry) {
            let current = try require(entry.id)
            try await refuseWhileRunning(entry)
            progress(ProgressUpdate(.seeding))
            try await seed(entry, current)

            // Build Assets, made again when a Build Match has a ROM they weren't made from.
            let assets = buildAssets(entry)
            guard let plan = await assets.regeneration(of: current) else { return }
            let product = try await build(entry, release: current.release, roms: plan.roms, progress: progress)
            defer { discard(paths.buildOutput(for: entry.id)) }
            guard let ready = plan.ready(product) else { return }
            _ = try await recording(entry.id) { _ in try await assets.install(ready, in: current, progress: progress) }
        }
    }

    // MARK: Removing

    public func uninstall(_ entry: CatalogEntry) async throws {
        try await exclusive(entry) {
            _ = try require(entry.id)
            try await refuseWhileRunning(entry)
            try folder(entry.id).remove()
            records?[entry.id] = nil
            // The build folder keeps the source tree and what the Recipe makes there, the extracted game for some,
            // only so the next build can reuse them. A download is kept only until its Release is installed, and the
            // logs are shown only for an Installation.
            do {
                for folder in [paths.builds(for: entry.id), paths.downloads(for: entry.id), paths.logs(for: entry.id)] {
                    try FileOperations.removeUntrusted(folder)
                }
            } catch {
                throw FrontportError.fileOperation(
                    "\(entry.name) is uninstalled, but some of its files couldn’t be removed. \(error.localizedDescription)")
            }
        }
    }

    /// Removes the Data folder itself, not just its contents: macOS rebuilds a container's standard layout
    /// (`Library/Application Support`, `tmp`, …) only when it creates `Data/` itself, on the Port's next launch.
    /// The container folder and its metadata plist stay. A container macOS doesn't manage yet, which Frontport made
    /// before the Port's first launch, goes whole: nothing has run there. An installed Port's Redirects must lead
    /// somewhere even when it's launched from the Dock, so their folders come back right away, after the primer;
    /// failing that, the Launcher makes them before its next launch.
    public func deleteData(_ entry: CatalogEntry) async throws {
        try await exclusive(entry) {
            try await refuseWhileRunning(entry)
            let managed = data.isManaged(entry)
            try DataFolder.remove(managed ? paths.data(for: entry.bundleId) : paths.container(for: entry.bundleId))
            try snapshotStore.removeAll(entry.id)
            if let current = loaded()[entry.id] {
                await prepareRedirectsAfterChange(of: folder(entry.id).app(current), for: entry, phase: .removing, progress: nil)
            }
        }
    }

    /// Waits for any change under way, such as a build, which would otherwise lose its folder part way.
    public func removeBuildFolder(_ entry: CatalogEntry) async throws {
        try await exclusive(entry) {
            do {
                try FileOperations.removeUntrusted(paths.builds(for: entry.id))
            } catch {
                throw FrontportError.fileOperation(
                    "\(entry.name)’s build folder couldn’t be removed. \(error.localizedDescription)")
            }
        }
    }

    public func restore(_ snapshot: Snapshot, entry: CatalogEntry) async throws {
        try await exclusive(entry) {
            // Only one of this Port's own Snapshots, as listed in its folder.
            guard snapshot.port == entry.id, let snapshot = snapshotStore.list(entry.id).first(where: { $0.id == snapshot.id })
            else {
                throw FrontportError.fileOperation("That Snapshot isn’t one of \(entry.name)’s.")
            }
            try await refuseWhileRunning(entry)
            let current = loaded()[entry.id]
            _ = try snapshotStore.take(
                entry.id, data: paths.data(for: entry.bundleId), reason: .restore,
                release: current?.release.version ?? snapshot.release, target: nil)
            try await restoreData(snapshot, entry, progress: nil)
            snapshotStore.prune(entry.id)
            // Without an Installation, there's no app and no Redirect.
            if let current { await settle(entry, current, phase: .restoring, progress: nil) }
        }
    }

    // MARK: Blocks

    public func enforceBlocks(_ catalog: CatalogDocument) async throws -> [Installation] {
        var changed: [Installation] = []
        for port in loaded().keys.sorted() {
            guard let entry = catalog.entry(port), (try? entry.checkIdentity()) != nil else { continue }
            let result: Installation? = try await exclusive(port) {
                // Only the Catalog the Port was installed from Blocks it (ADR 0012).
                guard var current = loaded()[port], current.entry?.catalog == entry.catalog else { return nil }
                let stop = entry.block(for: current.release)?.severity == .stop
                guard stop != current.disabled else { return nil }
                current.entry = entry
                return try await recording(port) { try stop ? $0.disable(current) : $0.enable(current) }
            }
            if let result { changed.append(result) }
        }
        return changed
    }

    // MARK: Leftovers

    public func removeLeftovers() async {
        let fm = FileManager.default
        var ports: Set<PortID> = []
        for folder in [paths.library, paths.downloads, paths.builds, paths.logs] {
            for name in (try? fm.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? [] {
                let port = PortID(name)
                // An unpack Recipe's workspace keeps the unpacker it built for the next installer.
                if port.isWellFormed, !name.hasPrefix(PortID.unpackPrefix) { ports.insert(port) }
            }
        }
        for port in ports.sorted() {
            try? await exclusive(port) {
                // A record that can't be read still marks an Installation, whose folders stay.
                let folder = folder(port)
                let installed = folder.isRecorded
                discard(folder.leftovers)
                discard(paths.downloads(for: port))
                if !installed {
                    discard(paths.builds(for: port))
                    discard(paths.logs(for: port))
                }
            }
        }
    }

    /// After a first install fails: `Library/<port>/`, which holds no record, and a container Frontport made for it
    /// that nothing has run in. The download, build folder and build log stay for another try, until
    /// `removeLeftovers` at the next launch.
    private func removeFailedInstall(_ entry: CatalogEntry, hadContainer: Bool) {
        let folder = folder(entry.id)
        guard !folder.isRecorded else { return }
        discard(folder.leftovers)
        if !hadContainer, !data.isManaged(entry) { discard(paths.container(for: entry.bundleId)) }
    }

    /// Removes what nothing reads again. What it follows is complete, so a failure is only logged: uninstalling or the
    /// next launch's `removeLeftovers` tries again.
    func discard(_ url: URL) {
        do {
            try FileOperations.removeUntrusted(url)
        } catch {
            let reason = (error as? FrontportError)?.errorDescription ?? error.localizedDescription
            Self.log.error("\(url.path(percentEncoded: false), privacy: .public) couldn’t be removed. \(reason, privacy: .public)")
        }
    }

    // MARK: Per-Port exclusion

    /// Runs `body` alone for the entry's Port, once the entry is known to name only its own folders.
    private func exclusive<T>(_ entry: CatalogEntry, _ body: () async throws -> T) async throws -> T {
        try entry.checkIdentity()
        return try await exclusive(entry.id, body)
    }

    private func exclusive<T>(_ port: PortID, _ body: () async throws -> T) async throws -> T {
        await acquire(port)
        defer { release(port) }
        return try await body()
    }

    private func acquire(_ port: PortID) async {
        if busy.insert(port).inserted { return }
        await withCheckedContinuation { waiting[port, default: []].append($0) }
    }

    private func release(_ port: PortID) {
        guard var queue = waiting[port], !queue.isEmpty else {
            busy.remove(port)
            return
        }
        let next = queue.removeFirst()
        waiting[port] = queue.isEmpty ? nil : queue
        next.resume()
    }

    // MARK: Records

    func loaded() -> [PortID: Installation] {
        if let records { return records }
        var found: [PortID: Installation] = [:]
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: paths.library.path(percentEncoded: false))) ?? []
        for name in folders {
            let port = PortID(name)
            if let installation = folder(port).record { found[port] = installation }
        }
        records = found
        return found
    }

    func require(_ port: PortID) throws -> Installation {
        guard let installation = loaded()[port] else { throw FrontportError.notInstalled(port) }
        return installation
    }

    func save(_ installation: Installation) async throws {
        _ = try await recording(installation.port) {
            try $0.write(installation)
            return installation
        }
    }

    /// Puts `app`, and the Build Assets beside it, in place of the current Release's and records `installation`
    /// (`InstallationFolder.replace`).
    func replace(
        _ current: Installation?, with app: URL, recording installation: Installation,
        previous: InstallationFolder.Previous
    ) async throws -> Installation {
        try await recording(installation.port) {
            try $0.replace(current, with: app, recording: installation, previous: previous)
        }
    }

    /// Runs a change to the Port's folder that records its Installation, and holds what it recorded. A change that
    /// fails after writing the record leaves it to be read back: the one on disk, when it can be read, is the truth.
    private func recording(
        _ port: PortID, _ change: (InstallationFolder) async throws -> Installation
    ) async throws -> Installation {
        _ = loaded()
        let folder = folder(port)
        do {
            let installation = try await change(folder)
            records?[port] = installation
            return installation
        } catch {
            if let recorded = folder.record { records?[port] = recorded }
            throw error
        }
    }

    func folder(_ port: PortID) -> InstallationFolder {
        InstallationFolder(paths: paths, port: port)
    }

    func buildAssets(_ entry: CatalogEntry) -> BuildAssets {
        BuildAssets(entry: entry, folder: folder(entry.id), roms: roms, packager: packager)
    }

    func refuseWhileRunning(_ entry: CatalogEntry) async throws {
        if await launcher.isRunning(entry) { throw FrontportError.running(entry.id) }
    }
}
