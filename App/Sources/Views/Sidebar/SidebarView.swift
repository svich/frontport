import FrontportCore
import SwiftUI

/// Catalog, Releases and ROMs, then the Ports on This Mac and on each of the user's Devices, by Game, with
/// their Project and status there.
struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section {
                Label("Catalog", systemImage: "book")
                    .accessibilityIdentifier("sidebar.catalog")
                    .tag(Screen.catalog)
                Label("Releases", systemImage: "arrow.down.circle")
                    .badge(model.survey.lineup.projectUpdates.count)
                    .badgeProminence(.increased)
                    .accessibilityIdentifier("sidebar.releases")
                    .tag(Screen.releases)
                Label("ROMs", systemImage: "sdcard")
                    .badge(model.survey.roms.count)
                    .accessibilityIdentifier("sidebar.roms")
                    .tag(Screen.roms)
            }
            ports("This Mac", model.survey.macPorts, device: nil)
            ForEach(model.knownDevices, id: \.device.id) { reading in
                ports(reading.device.name, model.survey.ports(on: reading.device.id), device: reading.device.id)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { ActivityFooter() }
    }

    /// A section of Ports on this Mac, or with `device`, on that Device; none while it has none. A Port on both shows
    /// in each, opening its page there.
    @ViewBuilder private func ports(_ title: String, _ entries: [CatalogEntry], device: DeviceID?) -> some View {
        if !entries.isEmpty {
            Section {
                ForEach(byGame(entries)) { entry in
                    PortRow(entry: entry, device: device)
                        .tag(device.map { Screen.portOnDevice(entry.id, $0) } ?? .port(entry.id))
                        .contextMenu { PortContextMenu(entry: entry, device: device) }
                }
            } header: {
                HStack {
                    Text(title)
                    Spacer()
                    Text("\(entries.count)").monospacedDigit()
                }
                .padding(.trailing, 10)
                .accessibilityIdentifier(device.map { "sidebar.device.\($0.rawValue)" } ?? "sidebar.mac")
            }
        }
    }

    /// Ports by Game, then Project, so two Ports of one Game sit together.
    private func byGame(_ entries: [CatalogEntry]) -> [CatalogEntry] {
        entries.sorted {
            let a = model.gameName(for: $0), b = model.gameName(for: $1)
            return a != b ? a.localizedStandardCompare(b) == .orderedAscending
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

private struct PortRow: View {
    @Environment(AppModel.self) private var model
    let entry: CatalogEntry
    /// The Device whose section it's in; nil for This Mac.
    let device: DeviceID?

    var body: some View {
        HStack(spacing: 10) {
            ArtworkImage(.icon, port: entry.id)
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(model.gameName(for: entry))
                    .lineLimit(1)
                Text(entry.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let device {
                DeviceStatusIcon(port: entry.id, device: device)
            } else {
                StatusIcon(port: entry.id)
            }
        }
        .padding(.vertical, 2)
        .testContainer(device.map { "sidebar.device.\($0.rawValue).port.\(entry.id.rawValue)" } ?? "sidebar.port.\(entry.id.rawValue)")
    }
}

/// Play, Stop or Update where the Port's state offers them on this Mac, then shortcuts to its pages and folders.
private struct PortContextMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(ViewState.self) private var viewState
    let entry: CatalogEntry
    /// The Device whose section it's in; nil for This Mac, where the Mac's actions apply.
    let device: DeviceID?
    private var onMac: Bool { device == nil }

    var body: some View {
        if onMac {
            let status = model.status(of: entry.id)
            let actions = ([status.main].compactMap { $0 } + status.others).filter { [.play, .stop, .update].contains($0) }
            ForEach(actions, id: \.self) { action in
                Button(model.title(action, for: entry.id)) { viewState.run(action, for: entry.id, in: model) }
                    .disabled(!status.allows(action))
            }
            if !actions.isEmpty { Divider() }
        }
        Button("Open") { model.open(device.map { .portOnDevice(entry.id, $0) } ?? .port(entry.id)) }
        if model.survey.isListed(entry.id) {
            Button("Store Page") { model.open(.store(entry.id)) }
        }
        if onMac, model.survey.installation(entry.id) != nil {
            Divider()
            Button("Show Data in Finder") { model.revealData(for: entry.id) }
            Button("Show Logs in Finder") { model.openLogs(for: entry.id) }
        }
    }
}

/// Builds, installs and Steam's download in progress, pinned under the sidebar.
private struct ActivityFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let working = model.activities.underWay
            .compactMap { port, activity in model.survey.entry(port).map { ($0, activity) } }
            .sorted { $0.0.name < $1.0.name }
        if !working.isEmpty || model.steamDownload != nil {
            VStack(spacing: 8) {
                ForEach(working, id: \.0.id) { entry, activity in
                    ActivityCard(entry: entry, activity: activity)
                }
                if let download = model.steamDownload {
                    SteamDownloadCard(download: download)
                }
            }
            .padding(10)
        }
    }
}

/// Steam downloading a ROM for Frontport, which opens ROMs.
private struct SteamDownloadCard: View {
    @Environment(AppModel.self) private var model
    let download: AppModel.SteamDownload

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(download.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if let percent = model.steamDownloadPercent(download) {
                    Text(percent)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: download.fraction)
                .progressViewStyle(.linear)
                .controlSize(.small)
            Text(download.fraction == nil ? "Waiting for Steam…" : "Downloading from Steam…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { model.open(.roms) }
        .accessibilityIdentifier("sidebar.steamDownload")
    }
}

private struct ActivityCard: View {
    @Environment(AppModel.self) private var model
    let entry: CatalogEntry
    let activity: Activity

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(model.gameName(for: entry))
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if let fraction = activity.progress.fraction {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: activity.progress.fraction)
                .progressViewStyle(.linear)
                .controlSize(.small)
            Text([model.activityText(activity, for: entry.id), activity.progress.message].compactMap { $0 }
                .joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { model.open(.port(entry.id)) }
    }
}
