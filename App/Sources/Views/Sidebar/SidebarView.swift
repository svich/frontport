import FrontportCore
import SwiftUI

/// Catalog, Library, Releases and ROMs, then every Library Port by its Game, with its Project and status.
struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section {
                Label("Catalog", systemImage: "book")
                    .accessibilityIdentifier("sidebar.catalog")
                    .tag(Screen.catalog)
                Label("Library", systemImage: "square.grid.2x2")
                    .accessibilityIdentifier("sidebar.library")
                    .tag(Screen.library)
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
            if !model.survey.libraryPorts.isEmpty {
                Section {
                    ForEach(byGame) { entry in
                        PortRow(entry: entry)
                            .tag(Screen.port(entry.id))
                    }
                } header: {
                    HStack {
                        Text("Ports")
                        Spacer()
                        Text("\(model.survey.libraryPorts.count)").monospacedDigit()
                    }
                    .padding(.trailing, 10)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { ActivityFooter() }
    }

    /// Library Ports by Game, then Project, so two Ports of one Game sit together.
    private var byGame: [CatalogEntry] {
        model.survey.libraryPorts.sorted {
            let a = model.gameName(for: $0), b = model.gameName(for: $1)
            return a != b ? a.localizedStandardCompare(b) == .orderedAscending
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

private struct PortRow: View {
    @Environment(AppModel.self) private var model
    let entry: CatalogEntry

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
            StatusIcon(port: entry.id)
        }
        .padding(.vertical, 2)
        .testContainer("sidebar.port.\(entry.id.rawValue)")
    }
}

/// Builds and installs in progress, pinned under the sidebar.
private struct ActivityFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let working = model.activities.underWay
            .compactMap { port, activity in model.survey.entry(port).map { ($0, activity) } }
            .sorted { $0.0.name < $1.0.name }
        if !working.isEmpty {
            VStack(spacing: 8) {
                ForEach(working, id: \.0.id) { entry, activity in
                    ActivityCard(entry: entry, activity: activity)
                }
            }
            .padding(10)
        }
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
