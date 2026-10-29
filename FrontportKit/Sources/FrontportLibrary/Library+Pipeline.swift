import FrontportCore
import Foundation

extension Library {
    // MARK: Install and update pipeline

    /// Resolve: the newest Release on the Channel that isn't Blocked.
    func resolve(_ entry: CatalogEntry, channel: Channel, progress: ProgressHandler) async throws -> Release {
        progress(ProgressUpdate(.resolving))
        guard let release = try await releases.latest(for: entry, channel: channel) else {
            throw FrontportError.noRelease(entry.id, channel)
        }
        try refuseBlocked(entry, release)
        return release
    }

    func refuseBlocked(_ entry: CatalogEntry, _ release: Release) throws {
        if let block = entry.block(for: release) {
            throw FrontportError.blocked(entry.id, release: release.version, reason: block.reason)
        }
    }

    /// Runs a Move that goes somewhere. A back Move goes through `previous/` when it holds that Release, and otherwise
    /// fetches it.
    func run(
        _ move: Move, _ entry: CatalogEntry, from current: Installation, reason: Snapshot.Reason,
        progress: @escaping ProgressHandler
    ) async throws -> Installation {
        if move.direction == .back, current.previous?.tag == move.to.tag,
            folder(entry.id).kept(entry, expecting: current.previous) != nil
        {
            return try await rollBack(entry, move, from: current, reason: reason, channel: move.channel, progress: progress)
        }
        return try await change(
            entry, from: current, to: move.to, channel: move.channel, reason: reason,
            back: move.direction == .back ? move : nil, progress: progress)
    }

    /// Moves an Installation (or nothing) to `release`: Requirements, fetch or build, package and sign, then `land`.
    /// With a `back` Move, the change is handled like a Rollback: the Data from when the Port was last on that Release
    /// comes back, and no previous Release is kept.
    func change(
        _ entry: CatalogEntry, from current: Installation?, to release: Release, channel: Channel,
        reason: Snapshot.Reason, back: Move? = nil, progress: @escaping ProgressHandler
    ) async throws -> Installation {
        let port = entry.id
        let folder = folder(port)

        // Requirements. A missing Runtime ROM doesn't stop the install; it's Seeded once added.
        let plan = try await buildAssets(entry).plan(from: current)

        let staging = try folder.freshStaging()
        defer { try? DataFolder.remove(staging) }
        // The Recipe's output, once the app and Build Assets are cloned out of it and packaged: the next build starts
        // without it anyway.
        defer { if entry.isSourceBuilt { discard(paths.buildOutput(for: port)) } }

        // Fetch or build.
        let app: URL
        var assets: BuildAssets.Ready?
        if entry.isSourceBuilt {
            let product = try await build(entry, release: release, roms: plan.roms, progress: progress)
            app = staging.appending(path: product.app.lastPathComponent, directoryHint: .isDirectory)
            try FileOperations.clone(product.app, to: app)
            // The build folder stays writable by the build sandbox, so it's the copy here that must hold no link
            // leading out of it.
            guard FileOperations.isDirectory(app) else {
                throw FrontportError.appNotFound("The Recipe left \(app.lastPathComponent), which isn’t an app folder.")
            }
            try FileOperations.refuseEscapingLinks(in: app)
            assets = plan.ready(product)
        } else {
            app = try await fetcher.fetch(release, into: staging, progress: progress)
        }
        try Task.checkCancellation()

        // Package and sign. The Build Assets go beside the app, in staging until the swap.
        progress(ProgressUpdate(.packaging))
        let permissions = current?.permissions ?? entry.permissions
        try await packager.package(
            app, entry: entry, permissions: permissions, assets: assets?.url, installedAssets: paths.assets(for: port))
        try Task.checkCancellation()

        let installation = try await land(
            app,
            recording: Installation(
                port: port, release: release, channel: channel, installedAt: Date().wholeSeconds,
                appName: app.lastPathComponent, permissions: permissions, buildAssets: assets?.record, entry: entry),
            from: current, back: back, entry: entry, reason: reason, progress: progress)
        // The Release is installed, so its download is no use any more; a failed change keeps it for another try.
        discard(paths.downloads(for: port))
        return installation
    }

    // MARK: Rollback

    /// Runs a back Move to the previous Release: re-signs `previous/`'s app for the current Permissions when they
    /// differ, then lands it. `channel` overrides the Channel the previous Release was on.
    func rollBack(
        _ entry: CatalogEntry, _ move: Move, from current: Installation, reason: Snapshot.Reason, channel: Channel?,
        progress: @escaping ProgressHandler
    ) async throws -> Installation {
        let port = entry.id
        let folder = folder(port)
        // The Release comes from previous/'s own record, which must be the one install.json says is kept.
        guard let kept = folder.kept(entry, expecting: current.previous) else { throw FrontportError.noPreviousRelease(port) }
        let previous = kept.record.release
        try refuseBlocked(entry, previous)
        if kept.record.permissions != current.permissions {
            progress(ProgressUpdate(.signing))
            // Signed to read its Build Assets where they're going, if it links to them.
            try await packager.resign(
                kept.app, entry: entry, permissions: current.permissions, installedAssets: paths.assets(for: port))
        }
        try Task.checkCancellation()

        // Swapped in from previous/, which then holds nothing.
        defer { try? DataFolder.remove(paths.staging(for: port)) }
        return try await land(
            kept.app,
            recording: Installation(
                port: port, release: previous, channel: channel ?? kept.record.channel,
                installedAt: Date().wholeSeconds, appName: kept.record.appName, permissions: current.permissions,
                buildAssets: kept.record.buildAssets, entry: entry),
            from: current, back: move, entry: entry, reason: reason, progress: progress)
    }

    // MARK: Landing a Move

    /// Every Move ends here once its app is ready and signed: chooses the Snapshot a `back` Move brings back, takes one
    /// of the Data as it is, swaps the app in and records `installation`, brings the chosen Data back, prunes, then
    /// `settle`s. The current Release is kept in previous/, unless the Move goes back.
    ///
    /// The Snapshot to bring back is chosen before one is taken, so it's never the one just taken. The Data comes back
    /// only once the app it belongs to is in place: a failure before that leaves the Data next to the app it belongs
    /// to. A failed restore throws, leaving the Release with the Data it was given; the Snapshot just taken holds that
    /// Data whole.
    func land(
        _ app: URL, recording installation: Installation, from current: Installation?, back: Move?, entry: CatalogEntry,
        reason: Snapshot.Reason, progress: @escaping ProgressHandler
    ) async throws -> Installation {
        let port = entry.id
        let before = back?.restores(from: snapshotStore.list(port))
        if let current {
            progress(ProgressUpdate(.snapshotting))
            _ = try snapshotStore.take(
                port, data: paths.data(for: entry.bundleId), reason: reason, release: current.release.version,
                target: installation.release.version)
        }

        progress(ProgressUpdate(.swapping))
        let installed = try await replace(current, with: app, recording: installation, previous: back == nil ? .replaced : .nothing)

        if let before { try await restoreData(before, entry, progress: progress) }
        if current != nil { snapshotStore.prune(port) }
        await settle(entry, installed, phase: before == nil ? .swapping : .restoring, progress: progress)
        return installed
    }

    /// Once the Installation's Data may have changed under its app, as after a Move or a restore: makes the folders the
    /// app's Redirects lead to, which Data from before the Port had them lacks, or which the Port removed, then Seeds.
    /// Neither undoes what came before, so a failure is reported as progress, or, without any, in the log.
    func settle(_ entry: CatalogEntry, _ installation: Installation, phase: ProgressUpdate.Phase, progress: ProgressHandler?)
        async
    {
        await prepareRedirectsAfterChange(of: folder(entry.id).app(installation), for: entry, phase: phase, progress: progress)
        await seedAfterChange(entry, installation, progress: progress ?? { _ in })
    }

    // MARK: Building

    func build(
        _ entry: CatalogEntry, release: Release, roms: BuildROMs, progress: @escaping ProgressHandler
    ) async throws -> BuildProduct {
        if await builder.toolchainStatus() != .ready {
            try await builder.prepareToolchain(progress: progress)
        }
        let recipe = try await catalog.recipe(for: entry)
        return try await builder.build(
            entry, ref: release.tag, recipe: recipe, roms: roms, log: paths.buildLog(for: entry.id), progress: progress)
    }

    // MARK: Redirects

    /// Makes the folders the app's Redirects lead to once Data has changed under a change that is otherwise complete
    /// (`PortData.prepareRedirectsAfterChange`), reporting a failure as progress or, for an operation without any, in
    /// the log: the Launcher makes them again before each launch.
    func prepareRedirectsAfterChange(
        of app: URL, for entry: CatalogEntry, phase: ProgressUpdate.Phase, progress: ProgressHandler?
    ) async {
        guard let message = await data.prepareRedirectsAfterChange(of: app, for: entry) else { return }
        if let progress {
            progress(ProgressUpdate(phase, message: message))
        } else {
            Self.log.error("\(message, privacy: .public)")
        }
    }

    // MARK: Data

    /// Replaces the Port's Data with the Snapshot's. Runs once the app the Data belongs to is in place.
    func restoreData(_ snapshot: Snapshot, _ entry: CatalogEntry, progress: ProgressHandler?) async throws {
        progress?(ProgressUpdate(.restoring))
        try await data.prepare(entry)
        try snapshotStore.restore(snapshot, into: paths.data(for: entry.bundleId))
    }

    // MARK: Seeding

    /// Seeds the Installation's Runtime Requirements whose ROMs are in ROMs but not yet all in its Data. Matching says
    /// what and how; the Library only when, and makes sure Data can be written to first.
    func seed(_ entry: CatalogEntry, _ installation: Installation) async throws {
        guard await !roms.matching(of: entry, installation).unseeded.isEmpty, try await data.prepare(entry) else { return }
        try await roms.seed(entry)
    }

    /// Seeds once a change is complete. A failure doesn't undo the change, so it's reported as progress rather
    /// than thrown; a reading of `ROMStoring.matching` says what's left for the next `applyROMs`.
    func seedAfterChange(_ entry: CatalogEntry, _ installation: Installation, progress: ProgressHandler) async {
        progress(ProgressUpdate(.seeding))
        do {
            try await seed(entry, installation)
        } catch {
            let reason = (error as? FrontportError)?.errorDescription ?? error.localizedDescription
            progress(ProgressUpdate(.seeding, message: "\(entry.name)’s ROMs couldn’t be added to its Data. \(reason)"))
        }
    }
}
