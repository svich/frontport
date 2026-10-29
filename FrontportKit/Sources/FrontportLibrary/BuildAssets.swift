import FrontportCore
import Foundation

/// A Port's Build Assets, as the Library changes its Installation: carried forward to another Release when Matching
/// says they can be, made by the Recipe otherwise, and made again, and put in place, once ROMs are added. It knows both
/// places an Installation keeps them: beside the app, which links to them, or, from before Frontport kept them there,
/// inside it. The Library only runs the Recipe.
struct BuildAssets: Sendable {
    let entry: CatalogEntry
    let folder: InstallationFolder
    let roms: any ROMStoring
    let packager: any PortPackaging

    /// Build Assets ready to go beside an app, with what's recorded of them.
    struct Ready: Hashable, Sendable {
        let url: URL
        let record: BuildAssetsRecord
    }

    /// Where a Release's Build Assets come from: the current ones, carried forward, or the Recipe, from `roms`.
    struct Plan: Sendable {
        /// What the Recipe makes them from: nothing when they're carried forward, so it skips making them.
        let roms: BuildROMs
        fileprivate let carried: Ready?
        fileprivate let format: String?

        /// Those to put beside the app the Recipe left: the ones carried forward, or the ones it made.
        func ready(_ product: BuildProduct) -> Ready? {
            guard let format else { return nil }
            if let carried { return carried }
            return product.assets.map { Ready(url: $0, record: BuildAssetsRecord(roms: roms.sha1s, format: format)) }
        }
    }

    // MARK: Changing Releases

    /// For a change to another Release: carries the current Build Assets forward when Matching says they can be
    /// (`PortMatching.carriesBuildAssets`) and they're there, and otherwise has the Recipe make them from every Build
    /// Match's ROMs. Throws `romMissing` for a Build Requirement without a Match.
    func plan(from current: Installation?) async throws -> Plan {
        let state = await roms.matching(of: entry, current)
        let carried = state.carriesBuildAssets ? current.flatMap(carried) : nil
        return Plan(roms: carried == nil ? try state.buildROMs() : .none, carried: carried, format: entry.buildAssets?.format)
    }

    /// The current Build Assets, to carry forward: beside the app when it links to them, and otherwise inside it. Either
    /// way only a file or folder counts, not a link.
    private func carried(_ current: Installation) -> Ready? {
        guard let spec = entry.buildAssets, let record = current.buildAssets else { return nil }
        let app = folder.app(current)
        if InstallationFolder.linksAssets(app) { return folder.assets.map { Ready(url: $0, record: record) } }
        let inside = app.appending(path: spec.path)
        return FileOperations.isFileOrFolder(inside) ? Ready(url: inside, record: record) : nil
    }

    // MARK: Adding ROMs

    /// Once ROMs are added: makes the Installation's Build Assets again when a Build Match has a ROM they weren't made
    /// from. Not while the Catalog's Recipe makes them in another format: the installed app wasn't built for that one,
    /// and the update the format change comes with makes them again from every ROM present. Nor while a stop Block has
    /// the app aside, or a Build Requirement has no Match.
    func regeneration(of current: Installation) async -> Plan? {
        guard entry.isSourceBuilt, let spec = entry.buildAssets, let record = current.buildAssets,
            record.format == spec.format, !current.disabled
        else { return nil }
        let state = await roms.matching(of: entry, current)
        guard !state.carriesBuildAssets, let roms = try? state.buildROMs() else { return nil }
        return Plan(roms: roms, carried: nil, format: spec.format)
    }

    /// Puts Build Assets made again for the installed Release in place of its own, and records them. Beside the app
    /// they change without it, re-signed only when its exception changes: when they turn from a file into a folder or
    /// back, or were missing. An app that keeps them inside is packaged again, which moves them out. Should anything
    /// fail, the Installation stays as it was.
    func install(_ ready: Ready, in current: Installation, progress: ProgressHandler) async throws -> Installation {
        var changed = current
        changed.buildAssets = ready.record
        changed.entry = entry
        let installed = folder.paths.assets(for: entry.id)
        let app = folder.app(current)
        let staging = try folder.freshStaging()
        defer { try? DataFolder.remove(staging) }

        guard InstallationFolder.linksAssets(app) else {
            let staged = staging.appending(path: current.appName, directoryHint: .isDirectory)
            try FileOperations.clone(app, to: staged)
            progress(ProgressUpdate(.packaging))
            try await packager.package(
                staged, entry: entry, permissions: current.permissions, assets: ready.url, installedAssets: installed)
            try Task.checkCancellation()
            progress(ProgressUpdate(.swapping))
            return try folder.replace(current, with: staged, recording: changed, previous: .same)
        }

        // The build folder stays writable by the build sandbox, so it's the copy here that must hold no link leading
        // out of it.
        let staged = staging.appending(path: AppPaths.assetsName)
        try FileOperations.clone(ready.url, to: staged)
        try FileOperations.refuseEscapingLinks(in: staged)
        try FileOperations.removeQuarantine(staged)
        let reform = folder.assets == nil || FileOperations.isDirectory(installed) != FileOperations.isDirectory(staged)
        progress(ProgressUpdate(.swapping))
        try folder.exchangeAssets(with: staged)
        var resigned = false
        do {
            if reform {
                progress(ProgressUpdate(.signing))
                try await resign(app, current)
                resigned = true
            }
            try folder.write(changed)
        } catch {
            try? folder.exchangeAssets(with: staged)
            // An app that can't be signed again for the ones put back keeps the new ones, which it's signed for: only
            // the record is behind, and the next extra makes them again.
            if resigned, (try? await resign(app, current)) == nil { try? folder.exchangeAssets(with: staged) }
            throw error
        }
        return changed
    }

    /// Signs the app to read the Build Assets now beside it.
    private func resign(_ app: URL, _ current: Installation) async throws {
        try await packager.resign(
            app, entry: entry, permissions: current.permissions, installedAssets: folder.paths.assets(for: entry.id))
    }
}

extension ROMStoring {
    /// Where one Port's Requirements stand in ROMs and its Data now.
    func matching(of entry: CatalogEntry, _ installation: Installation?) async -> PortMatching {
        let reading = await matching([entry], installations: installation.map { [entry.id: $0] } ?? [:])
        // A reading always has the entries it was given; without one, every Requirement counts as missing.
        return reading[entry.id]
            ?? PortMatching(
                port: entry.id, isInstalled: installation != nil,
                requirements: entry.requirements.map { RequirementState(requirement: $0, rom: nil, accepted: .missing) })
    }
}
