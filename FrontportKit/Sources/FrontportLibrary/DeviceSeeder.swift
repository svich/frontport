import FrontportCore
import Foundation

/// Seeding on a Device carried out (DESIGN › Seeding on a Device): what `DeviceSeeding` plans from the container's
/// listing and the record, put into the container, and recorded as the Device holds it afterwards.
///
/// The record never claims more than the Device may hold. Before anything is put, a ROM a put overwrites is no longer
/// recorded as Seeded, and the folder ROMs' files to put are noted as `filling`, so a put that stops part way leaves the
/// next Seed to put only the rest, and to put again a file cut short. Files go before the folder ROMs' markers, so a
/// marker never names a folder still missing files. Afterwards the container is listed again, and only what it holds is
/// recorded. The Device Library runs it, one operation per Port at a time.
struct DeviceSeeder {
    /// The Installation's folder, where the record is written.
    let folder: DeviceFolder
    /// The Device, as far as its apps' containers.
    let control: any DeviceControlling

    /// What Seeding `staged` would put, as the container and `current`, the Installation's record, stand now.
    func plan(_ staged: [StagedSeed], for current: DeviceInstallation) async throws -> DeviceSeedingPlan {
        DeviceSeeding.plan(
            staged, on: try await list(staged, of: current), seeded: current.seeded, filling: current.filling ?? [])
    }

    /// Seeds `staged`, laid out in `root` as in the container: plans, prunes `root` to exactly what the plan puts, puts
    /// it, and records what the container holds then over `current`, the Installation's record. Returns the plan as the
    /// Device stands afterwards. `root` is used up.
    func seed(
        _ staged: [StagedSeed], from root: URL, over current: DeviceInstallation, progress: ProgressHandler
    ) async throws -> DeviceSeedingPlan {
        let listing = try await list(staged, of: current)
        let plan = DeviceSeeding.plan(staged, on: listing, seeded: current.seeded, filling: current.filling ?? [])
        // Record-only changes: the app on the Device stays as it is.
        var record = current
        var after = plan
        if !plan.copiesNothing {
            try Task.checkCancellation()
            var putting = record
            putting.seeded = plan.found(over: current.seeded)
            putting.filling = plan.folderFiles.isEmpty ? nil : plan.folderFiles
            if putting != record {
                try folder.write(putting)
                record = putting
            }
            progress(ProgressUpdate(.transferring))
            try Self.prune(root, keeping: Set(plan.files + plan.markers))
            try await control.put(root, markers: plan.markers, over: listing, of: current.bundleId, on: current.device)
            // What the container holds now decides: a file it skipped, or one gone meanwhile, isn't recorded. The
            // markers just put aren't read again.
            var markers = listing.markers
            for item in plan.items {
                if case .copy(_, let marker?) = item.step { markers[marker] = item.seed.fileSHA1 }
            }
            let relisted = try await list(staged, of: current, markers: markers)
            after = DeviceSeeding.plan(staged, on: relisted, seeded: plan.carriedOut(over: current.seeded))
        }
        var updated = record
        updated.seeded = after.found(over: current.seeded)
        updated.filling = nil
        if updated != record { try folder.write(updated) }
        return after
    }

    /// The container where `staged` go, with what each folder ROM's marker there names: `known` markers are taken as
    /// naming what they say, while still listed as files, rather than read again.
    private func list(
        _ staged: [StagedSeed], of installation: DeviceInstallation, markers known: [String: String] = [:]
    ) async throws -> DeviceListing {
        let unread = staged.compactMap(\.markerPath).filter { known[$0] == nil }
        var listing = try await control.list(staged, markers: unread, of: installation.bundleId, on: installation.device)
        for (marker, named) in known where listing.isFile(marker) { listing.markers[marker] = named }
        return listing
    }

    /// Removes every file under `folder` whose path isn't in `kept`, then every folder left empty.
    static func prune(_ folder: URL, keeping kept: Set<String>) throws {
        let names = FileManager.default.enumerator(atPath: folder.path(percentEncoded: false))?.allObjects as? [String] ?? []
        var folders: [String] = []
        for name in names {
            let url = folder.appending(path: name)
            if FileOperations.isDirectory(url) {
                folders.append(name)
            } else if !kept.contains(name) {
                try FileOperations.removeUntrusted(url)
            }
        }
        // Deepest first, so a folder whose folders went is empty in its turn.
        for name in folders.sorted(by: { $0.count > $1.count }) {
            let url = folder.appending(path: name)
            if (try? FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false)))?.isEmpty == true {
                try FileOperations.removeUntrusted(url)
            }
        }
    }
}
