import FrontportCore
import Foundation

/// An Installation's folder on a Device, `Devices/<udid>/<port>/`: the app as it was signed and installed, kept for
/// Renew, `install.json`, `staging/`, where a new app is fetched, packaged and installed from before the swap, and
/// `seeds/`, where ROMs are laid out for the Device.
///
/// It keeps them in step with the Device, so that whatever fails part way, the record says what's there. Nothing in the
/// folder changes until `devicectl` has installed the new app; then the app goes in, and the record follows it. Should
/// either fail after the install, the app goes back, the record stays as it was, and the app it describes is installed
/// again. Only the Device Library changes it, one operation per Port at a time.
struct DeviceFolder: Sendable {
    let paths: AppPaths
    let port: PortID
    let device: DeviceID

    private var folder: URL { paths.deviceInstallation(for: port, on: device) }
    private var staging: URL { paths.deviceStaging(for: port, on: device) }
    private var recordFile: URL { paths.deviceInstallRecord(for: port, on: device) }

    // MARK: Reading

    /// `install.json`, when it can be read and describes this Port's own app: its bundle ID, which `devicectl` removes
    /// with its Data on uninstall, and an app in this folder. Any other record counts as one that can't be read.
    var record: DeviceInstallation? {
        guard isRecorded, let record = try? JSON.read(DeviceInstallation.self, from: recordFile),
            record.port == port, record.bundleId == port.deviceBundleID(team: record.team),
            Self.isAppName(record.appName)
        else { return nil }
        return record
    }

    /// True when the folder itself, not a link to one, holds `install.json`, whether or not it can be read: the folder
    /// belongs to an Installation.
    var isRecorded: Bool { FileOperations.isDirectory(folder) && FileOperations.exists(recordFile) }

    /// True when anything is in the folder.
    var exists: Bool { FileOperations.exists(folder) }

    func app(_ installation: DeviceInstallation) -> URL { paths.deviceApp(for: installation) }

    /// What nothing reads again while no change is under way: `staging/` and `seeds/`, or the whole folder when it holds
    /// no record, as a first install that failed leaves it. A link in the folder's place is removed, never followed.
    var leftovers: [URL] { isRecorded ? [staging, paths.deviceSeeds(for: port, on: device)] : [folder] }

    /// True when `name` names an app in the folder, such as "Tiny.app", and nothing outside it.
    static func isAppName(_ name: String) -> Bool {
        !name.contains("/") && !name.hasPrefix(".") && name.lowercased().hasSuffix(".app")
    }

    // MARK: Changing

    /// Makes the folder, as every operation does before anything else, so that forgetting the Device waits for one
    /// under way. A link or file in its place goes, never followed.
    func create() throws {
        if FileOperations.exists(folder), !FileOperations.isDirectory(folder) { try DataFolder.remove(folder) }
        try FileOperations.createDirectory(folder, mode: 0o755)
    }

    /// An empty `staging/`, on the folder's volume, where a Release is fetched and packaged before the swap.
    func freshStaging() throws -> URL {
        try create()
        try DataFolder.remove(staging)
        try FileOperations.createDirectory(staging, mode: 0o755)
        return staging
    }

    /// Records the Installation, whose app is already in place.
    func write(_ installation: DeviceInstallation) throws {
        try FileOperations.createDirectory(folder, mode: 0o755)
        do {
            try JSON.write(installation, to: recordFile)
        } catch {
            throw FrontportError.fileOperation("The Installation couldn’t be recorded. \(error.localizedDescription)")
        }
    }

    /// Installs `app`, signed and in `staging/`, through `install`, then puts it in place of the current app and records
    /// `installation` with the app's name. Returns that record.
    ///
    /// A failed install changes nothing here. Should the swap or the record fail after it, the current app and record
    /// stay, and the current app is installed again, as far as that works, so the Device runs what the record says; a
    /// first install leaves the app on the Device unrecorded, for the next install to go over. The replaced app ends up
    /// in `staging/`, to go with that folder.
    func replace(
        _ current: DeviceInstallation?, with app: URL, recording installation: DeviceInstallation,
        installing install: @Sendable (URL) async throws -> Void
    ) async throws -> DeviceInstallation {
        var installation = installation
        installation.appName = app.lastPathComponent
        try await install(app)

        // Each step's undo, run in reverse when a later one fails.
        var undo: [() throws -> Void] = []
        do {
            try replaceApp(of: current, with: app, undo: &undo)
            try write(installation)
        } catch {
            for step in undo.reversed() { try? step() }
            if let current, FileOperations.isDirectory(self.app(current)) { try? await install(self.app(current)) }
            throw error
        }
        return installation
    }

    /// Removes the folder, and the Installation with it.
    func remove() throws {
        try DataFolder.remove(folder)
    }

    // MARK: Steps

    /// Moves `app` into the folder in place of the current app, adding each step's undo to `undo`.
    ///
    /// The same name: one atomic swap. Otherwise the current app first goes aside into staging, so two names that differ
    /// only in case, which a case-insensitive volume treats as one, can't remove the new app.
    private func replaceApp(of current: DeviceInstallation?, with app: URL, undo: inout [() throws -> Void]) throws {
        let destination = paths.deviceApp(for: port, on: device, named: app.lastPathComponent)
        if let current, current.appName == app.lastPathComponent, FileOperations.isDirectory(destination) {
            try FileOperations.swap(app, destination)  // `app` now holds the old one
            undo.append { try FileOperations.swap(app, destination) }
            return
        }
        if let current, FileOperations.isDirectory(self.app(current)) {
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
}
