import FrontportCore
import Foundation

/// An Installation's folder, `Library/<port>/`: its app, the Build Assets beside it, `install.json`, the previous Release
/// in `previous/`, the app a stop Block moved aside into `blocked/`, and `staging/`, where a new Release waits for the
/// swap.
///
/// It keeps them in step, so that whatever fails part way, the record says what's there. The Build Assets go in just
/// before the app, and the record follows the app; should either fail, everything goes back as it was. `previous/`
/// follows the record, and `kept` refuses it as long as it isn't the Release the record expects. Only the Library
/// changes it, one operation per Port at a time.
struct InstallationFolder: Sendable {
    let paths: AppPaths
    let port: PortID

    /// What `previous/` holds once the current Release is replaced.
    enum Previous: Sendable {
        /// What it holds now: the same Release, packaged again.
        case same
        /// The Release being replaced, for a Rollback to it.
        case replaced
        /// Nothing, as after a back Move.
        case nothing
    }

    private var folder: URL { paths.library(for: port) }
    private var staging: URL { paths.staging(for: port) }
    private var blocked: URL { paths.blocked(for: port) }
    private var previousFolder: URL { paths.previous(for: port) }

    // MARK: Reading

    /// `install.json`, when it can be read.
    var record: Installation? { try? JSON.read(Installation.self, from: paths.installRecord(for: port)) }

    /// True when `install.json` is there, whether or not it can be read: the folder belongs to an Installation.
    var isRecorded: Bool { FileOperations.exists(paths.installRecord(for: port)) }

    /// Where the Installation's app is now: moved aside while a stop Block disables it.
    func app(_ installation: Installation) -> URL {
        guard installation.disabled else { return paths.app(for: installation) }
        return blocked.appending(path: installation.appName, directoryHint: .isDirectory)
    }

    /// `assets`, when a file or folder is there, not a link.
    var assets: URL? {
        let assets = paths.assets(for: port)
        return FileOperations.isFileOrFolder(assets) ? assets : nil
    }

    /// True when the app holds the Packager's link to Build Assets beside it. That, not what's beside it, says how the
    /// Release keeps them: Installations from before Frontport kept them beside the app have them inside it.
    static func linksAssets(_ app: URL) -> Bool {
        ((try? PortLinks.assetsLink(in: app)) ?? nil) != nil
    }

    /// The Release kept in `previous/`, with its record and app, when it's the one `expected` names and its Build
    /// Assets are kept too: beside the app, or inside it from before Frontport kept them beside it.
    func kept(_ entry: CatalogEntry, expecting expected: Release?) -> (record: Installation, app: URL)? {
        guard let expected, let record = try? JSON.read(Installation.self, from: previousFolder.appending(path: "install.json")),
            record.release.tag == expected.tag, record.release.version == expected.version
        else { return nil }
        let app = previousFolder.appending(path: record.appName, directoryHint: .isDirectory)
        guard DataFolder.exists(app) else { return nil }
        if Self.linksAssets(app) {
            guard FileOperations.isFileOrFolder(paths.previousAssets(for: port)) else { return nil }
        } else if record.buildAssets != nil, let spec = (record.entry ?? entry).buildAssets,
            !FileOperations.isFileOrFolder(app.appending(path: spec.path))
        {
            return nil
        }
        return (record, app)
    }

    /// What nothing reads again while no change is under way: `staging/`, or the whole folder when it holds no record,
    /// as a first install that failed leaves it.
    var leftovers: URL { isRecorded ? staging : folder }

    // MARK: Changing

    /// An empty `staging/`, on the Library's volume, where a Release is packaged before the swap.
    func freshStaging() throws -> URL {
        try DataFolder.remove(staging)
        try FileOperations.createDirectory(staging, mode: 0o755)
        return staging
    }

    /// Records the Installation, whose app and Build Assets are already in place.
    func write(_ installation: Installation) throws {
        try FileOperations.createDirectory(folder, mode: 0o755)
        try JSON.write(installation, to: paths.installRecord(for: port))
    }

    /// Puts `app`, and the Build Assets beside it, in place of the current Release's, records `installation` with the
    /// app's name, enabled and with the Release `previous/` now holds, and returns that record. A stop Block's
    /// `blocked/` goes.
    ///
    /// The replaced app and Build Assets end up where the new ones were, or in `staging/`, to go with that folder.
    /// Should the swap or the record fail, both go back, and the record stays as it was.
    func replace(_ current: Installation?, with app: URL, recording installation: Installation, previous: Previous)
        throws -> Installation
    {
        var installation = installation
        installation.appName = app.lastPathComponent
        installation.disabled = false
        var kept: URL?
        switch previous {
        case .same:
            installation.previous = current?.previous
        case .replaced:
            installation.previous = current?.release
            kept = try current.map(stagePrevious)
        case .nothing:
            installation.previous = nil
        }

        // Each step's undo, run in reverse when a later one fails.
        var undo: [() throws -> Void] = []
        do {
            let stagedAssets = app.deletingLastPathComponent().appending(path: AppPaths.assetsName)
            let installedAssets = paths.assets(for: port)
            try Self.exchange(stagedAssets, installedAssets)
            undo.append { try Self.exchange(stagedAssets, installedAssets) }
            try replaceApp(of: current, with: app, undo: &undo)
            try write(installation)
        } catch {
            for step in undo.reversed() { try? step() }
            throw error
        }
        if previous != .same { try replacePrevious(with: kept) }
        try DataFolder.remove(blocked)
        return installation
    }

    /// Exchanges the Build Assets beside the app for those at `staged`, so doing it again undoes it.
    func exchangeAssets(with staged: URL) throws {
        try Self.exchange(staged, paths.assets(for: port))
    }

    /// Moves the app aside into `blocked/`, where a stop Block keeps it, and records the Installation disabled. Only
    /// the app moves: its link to the Build Assets leads nowhere until it's back.
    func disable(_ installation: Installation) throws -> Installation {
        guard !installation.disabled else { return installation }
        var disabled = installation
        disabled.disabled = true
        try DataFolder.remove(blocked)
        try FileOperations.createDirectory(blocked, mode: 0o755)
        try DataFolder.move(app(installation), to: app(disabled))
        do {
            try write(disabled)
        } catch {
            try? DataFolder.move(app(disabled), to: app(installation))
            throw error
        }
        return disabled
    }

    /// Puts the app a stop Block moved aside back, and records the Installation enabled.
    func enable(_ installation: Installation) throws -> Installation {
        guard installation.disabled else { return installation }
        var enabled = installation
        enabled.disabled = false
        try DataFolder.move(app(installation), to: app(enabled))
        do {
            try write(enabled)
        } catch {
            try? DataFolder.move(app(enabled), to: app(installation))
            throw error
        }
        try DataFolder.remove(blocked)
        return enabled
    }

    /// Removes the folder, and the Installation with it.
    func remove() throws {
        try DataFolder.remove(folder)
    }

    // MARK: Steps

    /// A copy of the current app, the Build Assets beside it and its record in `staging/previous`, ready to become
    /// `previous/`.
    private func stagePrevious(_ current: Installation) throws -> URL {
        let staged = staging.appending(path: "previous", directoryHint: .isDirectory)
        try FileOperations.createDirectory(staged, mode: 0o755)
        try FileOperations.clone(app(current), to: staged.appending(path: current.appName, directoryHint: .isDirectory))
        if let assets {
            try FileOperations.clone(assets, to: staged.appending(path: AppPaths.assetsName))
        }
        try JSON.write(current, to: staged.appending(path: "install.json"))
        return staged
    }

    /// Puts the staged `previous/` in place of the old one, or removes `previous/` when nothing is kept.
    private func replacePrevious(with staged: URL?) throws {
        guard let staged else {
            try DataFolder.remove(previousFolder)
            return
        }
        if DataFolder.exists(previousFolder) {
            try FileOperations.swap(staged, previousFolder)  // staged now holds the old one, removed with staging
        } else {
            try DataFolder.move(staged, to: previousFolder)
        }
    }

    /// Moves `app` into the folder in place of the current app, adding each step's undo to `undo`.
    ///
    /// The same name, enabled: one atomic swap. Otherwise the current app first goes aside into staging, so two names
    /// that differ only in case, which a case-insensitive volume treats as one, can't remove the new app.
    private func replaceApp(of current: Installation?, with app: URL, undo: inout [() throws -> Void]) throws {
        let destination = paths.app(for: port, named: app.lastPathComponent)
        try FileOperations.createDirectory(folder, mode: 0o755)
        if let current, !current.disabled, current.appName == app.lastPathComponent {
            try FileOperations.swap(app, destination)  // `app` now holds the old one
            undo.append { try FileOperations.swap(app, destination) }
            return
        }
        if let current, DataFolder.exists(self.app(current)) {
            let installed = self.app(current)
            let aside = staging.appending(path: "replaced", directoryHint: .isDirectory)
            try DataFolder.remove(aside)
            try FileOperations.createDirectory(aside, mode: 0o755)
            let moved = aside.appending(path: current.appName, directoryHint: .isDirectory)
            try DataFolder.move(installed, to: moved)
            undo.append { try DataFolder.move(moved, to: installed) }
        }
        try DataFolder.remove(destination)
        try DataFolder.move(app, to: destination)
        undo.append { try DataFolder.move(destination, to: app) }
    }

    /// Exchanges what's at two paths on one volume, either of which may be empty, so doing it again undoes it.
    private static func exchange(_ a: URL, _ b: URL) throws {
        switch (FileOperations.exists(a), FileOperations.exists(b)) {
        case (true, true): try FileOperations.swap(a, b)
        case (true, false): try DataFolder.move(a, to: b)
        case (false, true): try DataFolder.move(b, to: a)
        case (false, false): break
        }
    }
}
