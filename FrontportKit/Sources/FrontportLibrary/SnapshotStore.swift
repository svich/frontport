import FrontportCore
import Foundation

/// Snapshots of Port Data in `Snapshots/<port>/`, each an APFS clone of the Data folder's contents.
///
/// Only the contents of `Data/` are ever read or replaced: macOS protects the container folder and its
/// `.com.apple.containermanagerd.metadata.plist`.
struct SnapshotStore: Sendable {
    static let kept = 3

    let paths: AppPaths

    /// Newest first.
    func list(_ port: PortID) -> [Snapshot] {
        let folder = paths.snapshots(for: port)
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        return ids.compactMap { try? JSON.read(Snapshot.self, from: paths.snapshotRecord($0, for: port)) }
            .sorted { $0.created != $1.created ? $0.created > $1.created : $0.id > $1.id }
    }

    /// Clones the Data's contents into a new Snapshot. Nil when the Port has no Data yet. Doesn't prune, so a
    /// Snapshot about to be restored survives; call `prune` afterwards.
    func take(
        _ port: PortID, data: URL, reason: Snapshot.Reason, release: String, target: String?
    ) throws -> Snapshot? {
        guard DataFolder.exists(data) else { return nil }
        let now = Date()
        let id = Self.id(now)
        let destination = paths.snapshotData(id, for: port)
        do {
            try DataFolder.cloneContents(of: data, into: destination)
            var snapshot = Snapshot(
                id: id, port: port, created: now.wholeSeconds, reason: reason, release: release, target: target)
            snapshot.size = try? FileOperations.size(of: destination)
            try JSON.write(snapshot, to: paths.snapshotRecord(id, for: port))
            return snapshot
        } catch {
            try? DataFolder.remove(paths.snapshot(id, for: port))
            throw error as? FrontportError ?? .fileOperation("Couldn’t take a Snapshot: \(error.localizedDescription)")
        }
    }

    /// Replaces the contents of `data` with the Snapshot's.
    func restore(_ snapshot: Snapshot, into data: URL) throws {
        let source = paths.snapshotData(snapshot.id, for: snapshot.port)
        guard DataFolder.exists(source) else {
            throw FrontportError.fileOperation("The Snapshot from \(snapshot.created.formatted()) is missing.")
        }
        try DataFolder.empty(data)
        try DataFolder.cloneContents(of: source, into: data)
    }

    /// Keeps the newest `kept` Snapshots, and removes any folder without a record, which no list shows: what a removal
    /// that stopped part way left. Operations on a Port run one at a time, so none is a Snapshot being taken.
    func prune(_ port: PortID) {
        let listed = list(port)
        let kept = Set(listed.prefix(Self.kept).map(\.id))
        let folder = paths.snapshots(for: port)
        for id in (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        where !kept.contains(id) {
            try? DataFolder.remove(paths.snapshot(id, for: port))
        }
    }

    func removeAll(_ port: PortID) throws {
        try DataFolder.remove(paths.snapshots(for: port))
    }

    /// Sortable and unique: "20261024-153012-123-a1b2".
    static func id(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        let suffix = UUID().uuidString.prefix(4).lowercased()
        return String(
            format: "%04d%02d%02d-%02d%02d%02d-%03d-%@", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!,
            c.nanosecond! / 1_000_000, String(suffix))
    }
}

/// File operations on a Port's Data folder and the Library's own folders.
enum DataFolder {
    static func exists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Removes everything inside the folder, keeping the folder itself.
    static func empty(_ url: URL) throws {
        guard exists(url) else { return }
        let items: [URL]
        do {
            items = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        } catch {
            throw FrontportError.fileOperation("Couldn’t read \(url.lastPathComponent): \(error.localizedDescription)")
        }
        for item in items { try remove(item) }
    }

    /// Clones each item in `source` into `destination`, creating it (mode 0700) if needed.
    static func cloneContents(of source: URL, into destination: URL) throws {
        try FileOperations.createDirectory(destination)
        let items: [URL]
        do {
            items = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        } catch {
            throw FrontportError.fileOperation("Couldn’t read \(source.lastPathComponent): \(error.localizedDescription)")
        }
        for item in items {
            try FileOperations.clone(item, to: destination.appending(path: item.lastPathComponent))
        }
    }

    /// Removes a file or folder; absent is fine. Symlinks are removed, never followed. A folder left read-only inside
    /// it, by a Port in its Data or a Recipe in its Build Assets, is made writable first, so it can't stop the removal
    /// part way and leave the rest behind.
    static func remove(_ url: URL) throws {
        try FileOperations.removeUntrusted(url)
    }

    /// Renames within a volume.
    static func move(_ source: URL, to destination: URL) throws {
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            throw FrontportError.fileOperation("Couldn’t move \(source.lastPathComponent): \(error.localizedDescription)")
        }
    }
}

extension Date {
    /// Records store whole seconds; in-memory values match what's on disk.
    var wholeSeconds: Date { Date(timeIntervalSinceReferenceDate: timeIntervalSinceReferenceDate.rounded(.down)) }
}
