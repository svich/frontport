import FrontportCore
import Observation
import SwiftUI

/// UI-only state shared across screens: the Port page and Releases sections, ROM intake and the confirmation being
/// asked.
@Observable @MainActor
final class ViewState {
    enum PortTab: String, CaseIterable, Hashable {
        case overview, snapshots, runs

        var title: String {
            switch self {
            case .overview: "Overview"
            case .snapshots: "Snapshots"
            case .runs: "Runs"
            }
        }
    }

    enum ReleasesTab: String, CaseIterable, Hashable {
        case newPorts, updates

        var title: String {
            switch self {
            case .newPorts: "New Ports"
            case .updates: "Updates"
            }
        }
    }

    /// The results of one Add ROMs…, shown in a sheet. Keeping a file Unverified replaces its result with the outcome.
    struct IntakeReport: Identifiable {
        let id = UUID()
        var results: [ROMIntake]
    }

    /// A `frontport://add-catalog` link the app was opened with, shown in the Add Catalog sheet.
    struct CatalogLinkRequest: Identifiable {
        let id = UUID()
        var url: URL
    }

    var catalogLink: CatalogLinkRequest?
    var portTab = PortTab.overview
    var releasesTab = ReleasesTab.updates
    var isImportingROMs = false
    var isAddingROMs = false
    var intakeReport: IntakeReport?
    /// Shown by `portConfirmations()` on the main window.
    var confirmation: PortConfirmation?

    /// Asks before a step on a Port, with its Snapshots loaded so the question can name the right one.
    func confirm(_ action: PortConfirmation.Action, for port: PortID, in model: AppModel) {
        Task {
            await model.loadHistory(for: port)
            confirmation = PortConfirmation(port: port, action: action)
        }
    }

    /// Looks up where a Channel switch lands, then asks before it.
    func confirmSwitch(_ port: PortID, to channel: Channel, in model: AppModel) {
        Task {
            guard let plan = await model.channelSwitch(port, to: channel) else { return }
            confirm(.switchChannel(plan), for: port, in: model)
        }
    }

    /// Takes an action the Port's Status offers, asking first before one that changes its Release or removes
    /// something. Add ROM… adds what Steam installed when it has the ROMs, or has Steam download one, else opens the
    /// file importer for a Build ROM, which installing needs, and the ROMs screen for a Runtime ROM. Restore, Channel switches and Permissions
    /// need a Snapshot, a Channel or Permissions, so their own controls take them.
    func run(_ action: Status.Action, for port: PortID, in model: AppModel) {
        switch action {
        case .install: model.install(port)
        case .addROM where !model.steamOffers(for: port).isEmpty:
            Task { await addFromSteam(model.steamOffers(for: port), to: model) }
        case .addROM where model.steamDownload(for: port) != nil:
            if let sha1 = model.steamDownload(for: port) { Task { await downloadFromSteam(sha1, to: model) } }
        case .addROM(.build): isImportingROMs = true
        case .addROM(.runtime): model.open(.roms)
        case .play: model.play(port)
        case .stop: model.stop(port)
        case .cancel: model.cancel(port)
        case .update: model.update(port)
        case .installFallback:
            if let fallback = model.status(of: port).fallback { confirm(.install(fallback), for: port, in: model) }
        case .rollBack: confirm(.rollback, for: port, in: model)
        case .seed: model.applyROMs(port)
        case .uninstall: confirm(.uninstall, for: port, in: model)
        case .deleteData: confirm(.deleteData, for: port, in: model)
        case .removeBuildFolder: confirm(.removeBuildFolder, for: port, in: model)
        case .restore, .switchChannel, .setPermissions: break
        }
    }

    func addROMs(_ urls: [URL], to model: AppModel) async {
        guard !urls.isEmpty else { return }
        isAddingROMs = true
        defer { isAddingROMs = false }
        let results = await model.addROMs(urls)
        intakeReport = IntakeReport(results: results)
    }

    func addFromSteam(_ offers: [SteamOffer], to model: AppModel) async {
        guard !offers.isEmpty, !isAddingROMs else { return }
        isAddingROMs = true
        defer { isAddingROMs = false }
        let results = await model.addFromSteam(offers)
        intakeReport = IntakeReport(results: results)
    }

    func downloadFromSteam(_ sha1: String, to model: AppModel) async {
        guard !isAddingROMs else { return }
        isAddingROMs = true
        defer { isAddingROMs = false }
        let results = await model.downloadFromSteam(sha1)
        intakeReport = IntakeReport(results: results)
    }

    /// Keeps the file of the report's result at `index` as the ROM `sha1` names, Unverified, and shows the outcome in
    /// its place.
    func keep(_ index: Int, of report: IntakeReport.ID, as sha1: String, in model: AppModel) async {
        guard intakeReport?.id == report, let results = intakeReport?.results, results.indices.contains(index),
            case .unknown(let file, _, _, _) = results[index]
        else { return }
        let outcome = await model.assignROM(file, as: sha1)
        guard intakeReport?.id == report, intakeReport?.results.indices.contains(index) == true else { return }
        intakeReport?.results.replaceSubrange(index...index, with: outcome)
    }
}
