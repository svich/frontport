import FrontportCore
import SwiftUI

/// An installed Port's page: Overview, Snapshots and Runs, picked in the toolbar.
struct PortPageView: View {
    @Environment(AppModel.self) private var model
    @Environment(ViewState.self) private var viewState
    let port: PortID

    var body: some View {
        @Bindable var viewState = viewState
        Group {
            if let entry = model.survey.entry(port) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        BlockedBanner(entry: entry)
                        switch viewState.portTab {
                        case .overview: PortOverview(entry: entry)
                        case .snapshots: SnapshotsList(entry: entry)
                        case .runs: RunsList(entry: entry)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .padding(.bottom, 36)
                }
                .testContainer("screen.port.\(port.rawValue)")
            } else {
                ContentUnavailableView("Not in the Catalog", systemImage: "questionmark.square.dashed")
            }
        }
        .navigationTitle(model.survey.entry(port)?.name ?? port.rawValue)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back", systemImage: "chevron.left") { model.back() }
                    .disabled(!model.canGoBack)
                    .help("Back")
            }
            ToolbarItem(placement: .principal) {
                Picker("Section", selection: $viewState.portTab) {
                    ForEach(ViewState.PortTab.allCases, id: \.self) { tab in
                        Text(tab.title)
                            .accessibilityIdentifier("port.tab.\(tab.rawValue)")
                            .tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("port.tabs")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if viewState.portTab != .overview {
                    PortActionButton(port: port, playsWhenUpdatable: true)
                }
                PortMenu(port: port)
            }
        }
        .task(id: port) { await model.loadHistory(for: port) }
    }
}

extension Snapshot {
    /// "Before 9.3.0", or "On 9.3.0" for one taken before a restore, which changes no Release.
    var title: String { reason == .restore ? "On \(release)" : "Before \(target ?? release)" }
}

/// Roll Back, Uninstall and shortcuts, in the toolbar.
private struct PortMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(ViewState.self) private var viewState
    let port: PortID

    var body: some View {
        let status = model.status(of: port)
        let isListed = model.survey.isListed(port)
        Menu {
            if status.check(.rollBack) != .unavailable {
                item(.rollBack, status)
            }
            item(.uninstall, status)
            Divider()
            if isListed {
                Button("Store Page") { model.open(.store(port)) }
            }
            Button("Show Data in Finder") { model.revealData(for: port) }
            Button("Show Logs in Finder") { model.openLogs(for: port) }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .menuIndicator(.hidden)
        .help("More")
    }

    private func item(_ action: Status.Action, _ status: Status) -> some View {
        Button(model.title(action, for: port)) { viewState.run(action, for: port, in: model) }
            .disabled(!status.allows(action))
    }
}

/// Shown while the installed Release is Blocked: warn, or stop.
private struct BlockedBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(ViewState.self) private var viewState
    let entry: CatalogEntry

    var body: some View {
        if let installation = model.survey.installation(entry.id), let block = entry.block(for: installation.release) {
            let isStop = block.severity == .stop
            let tint: Color = isStop ? .red : .orange
            let status = model.status(of: entry.id)
            HStack(spacing: 14) {
                Image(systemName: isStop ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(isStop ? "\(block.release) was disabled by the Catalog" : "\(block.release) is Blocked")
                        .font(.headline)
                    Text(block.reason + " " + advice(isStop: isStop, status: status))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Rollback beside the best of the other ways off, which stands out.
                if status.waysOff.contains(.rollBack) {
                    button(.rollBack, status).buttonStyle(.glass)
                }
                if let way = status.waysOff.first(where: { $0 != .rollBack }) {
                    button(way, status).buttonStyle(.glassProminent)
                }
            }
            .padding(16)
            .calloutBackground(tint)
        }
    }

    private func button(_ action: Status.Action, _ status: Status) -> some View {
        Button(model.title(action, for: entry.id)) { viewState.run(action, for: entry.id, in: model) }
            .disabled(!status.allows(action))
            .help(model.help(action, for: entry.id) ?? "")
    }

    private func advice(isStop: Bool, status: Status) -> String {
        if let fallback = status.fallback, status.update == nil {
            return isStop
                ? "It won’t open until you install \(fallback.version), the newest Release that isn’t Blocked."
                : "\(fallback.version) is the newest Release that isn’t Blocked."
        }
        return isStop
            ? "It won’t open until you update or roll back."
            : "Update, or roll back to the Release you had before."
    }
}

#if DEBUG
#Preview("Port · Overview") {
    ScreenPreview(.port("shipwright"))
}

#Preview("Port · Snapshots") {
    ScreenPreview(.port("shipwright")) { _, viewState in viewState.portTab = .snapshots }
}

#Preview("Port · Runs") {
    ScreenPreview(.port("shipwright")) { _, viewState in viewState.portTab = .runs }
}

#Preview("Port · Running") {
    ScreenPreview(.port("2ship"))
}

#Preview("Port · Building") {
    ScreenPreview(.port("starship"))
}

#Preview("Port · Needs ROM") {
    ScreenPreview(.port("spaghettikart"))
}

#Preview("Port · Unseeded") {
    ScreenPreview(.port("zelda64recomp"))
}

#Preview("Port · Blocked") {
    ScreenPreview(.port("shipwright"), data: .standard().changing("shipwright") {
        $0.blocked = [Block(release: "9.3.0", severity: .warn, reason: "It can corrupt save files on Apple silicon.")]
    })
}

#Preview("Port · Disabled") {
    ScreenPreview(.port("shipwright"), data: .standard().changing("shipwright") {
        $0.blocked = [Block(release: "9.3.0", severity: .stop, reason: "It deletes save files on first launch.")]
    })
}
#endif
