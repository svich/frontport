import FrontportCore
import SwiftUI

/// A destructive or state-changing step on a Port that asks first, wherever it's offered.
struct PortConfirmation: Hashable {
    enum Action: Hashable {
        case uninstall, rollback, deleteData, removeBuildFolder
        case restore(Snapshot)
        case switchChannel(ChannelSwitch)
        /// The way off a Blocked Release when nothing newer or previous is there: an older Release.
        case install(Release)
    }

    var port: PortID
    var action: Action
}

extension View {
    /// Presents `ViewState.confirmation`. Attach once, to the main window's content.
    func portConfirmations() -> some View {
        modifier(PortConfirmationDialog())
    }
}

private struct PortConfirmationDialog: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(ViewState.self) private var viewState

    func body(content: Content) -> some View {
        let confirmation = viewState.confirmation
        content.confirmationDialog(
            confirmation.map(title) ?? "",
            isPresented: Binding(
                get: { viewState.confirmation != nil }, set: { if !$0 { viewState.confirmation = nil } }),
            presenting: confirmation
        ) { confirmation in
            let port = confirmation.port
            switch confirmation.action {
            case .uninstall:
                Button("Uninstall", role: .destructive) { model.uninstall(port) }
            case .rollback:
                Button("Roll Back") { model.rollback(port) }
            case .deleteData:
                Button("Delete Data", role: .destructive) { model.deleteData(port) }
            case .removeBuildFolder:
                Button("Remove", role: .destructive) { model.removeBuildFolder(port) }
            case .restore(let snapshot):
                Button("Restore") { model.restore(snapshot) }
            case .switchChannel(let plan):
                Button("Switch to \(plan.channel.name)") { model.switchChannel(port, to: plan) }
            case .install(let release):
                Button("Install \(release.version)") { model.update(port, to: release) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(message(confirmation))
        }
    }

    private func name(_ port: PortID) -> String { model.survey.entry(port)?.name ?? port.rawValue }

    private func title(_ confirmation: PortConfirmation) -> String {
        let name = name(confirmation.port)
        switch confirmation.action {
        case .uninstall:
            return "Uninstall \(name)?"
        case .rollback:
            let previous = model.survey.installation(confirmation.port)?.previous?.version ?? "the previous Release"
            return "Roll Back \(name) to \(previous)?"
        case .deleteData:
            return "Delete \(name)’s Data?"
        case .removeBuildFolder:
            return "Remove \(name)’s build folder?"
        case .restore(let snapshot):
            return "Restore “\(snapshot.title)”?"
        case .switchChannel(let plan):
            return "Switch \(name) to the \(plan.channel.name) Channel?"
        case .install(let release):
            return "Install \(name) \(release.version)?"
        }
    }

    private func message(_ confirmation: PortConfirmation) -> String {
        let port = confirmation.port
        let name = name(port)
        let current = model.survey.installation(port)?.release.version ?? ""
        switch confirmation.action {
        case .uninstall:
            let kept = "Frontport keeps its Data and Snapshots, so reinstalling picks up where you left off."
            guard model.survey.entry(port)?.isSourceBuilt == true else { return kept + " Its run logs go with it." }
            return kept + " Its build folder and run logs go with it, so installing it again builds everything again."
        case .rollback:
            let previous = model.survey.installation(port)?.previous?.version ?? "its previous Release"
            guard let snapshot = model.rollbackSnapshot(for: port) else {
                return "Frontport takes a Snapshot of your current Data and returns \(name) to \(previous). "
                    + "It has no Snapshot from \(previous) to restore, so your current Data stays."
            }
            return "Frontport takes a Snapshot of your current Data, restores “\(snapshot.title)”, and returns \(name) to \(previous)."
        case .deleteData:
            return "This removes its progress, settings and ROMs it keeps, and every Snapshot. It can’t be undone."
        case .removeBuildFolder:
            guard model.survey.installation(port) != nil else {
                return "Installing \(name) then fetches the source and builds everything again."
            }
            return "\(name) keeps working. Its next build fetches the source and builds everything again, which can take a while."
        case .restore:
            return "Frontport takes a Snapshot of your current Data first, then replaces it with this one."
        case .switchChannel(let plan):
            guard let move = plan.move else {
                return "Frontport installs the newest Release on \(plan.channel.name), taking a Snapshot of your Data first."
            }
            let target = move.to
            guard move.direction == .back else {
                return "Frontport installs \(target.version), taking a Snapshot of your Data first."
            }
            return "\(target.version) is older than \(current), so \(name) may not load your current Data. Frontport "
                + "takes a Snapshot of it first, and brings back your Data from when you last had \(target.version), "
                + "if it has a Snapshot of it. Afterwards it offers the Snapshot from before the switch."
        case .install(let release):
            return "\(current) is Blocked, and there’s no newer Release or previous one to roll back to. "
                + "\(release.version) is the newest that isn’t. It’s older, so \(name) may not load your current "
                + "Data. Frontport takes a Snapshot of it first."
        }
    }
}
