import FrontportCore
import SwiftUI

/// Library Ports as a grid of covers or a list.
struct LibraryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.survey.libraryPorts.isEmpty {
                ContentUnavailableView {
                    Label("No Ports Yet", systemImage: "square.grid.2x2")
                } description: {
                    Text("Ports you install from the Catalog appear here.")
                } actions: {
                    Button("Browse the Catalog") { model.open(.catalog) }
                        .buttonStyle(.glassProminent)
                }
            } else {
                switch model.libraryLayout {
                case .grid: LibraryGrid()
                case .list: LibraryTable()
                }
            }
        }
        .testContainer("screen.library")
        .navigationTitle("Library")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("View", selection: $model.libraryLayout) {
                    Label("Grid", systemImage: "square.grid.2x2").tag(LibraryLayout.grid)
                    Label("List", systemImage: "list.bullet").tag(LibraryLayout.list)
                }
                .pickerStyle(.segmented)
                .help("Show as grid or list")
            }
        }
    }

    private var subtitle: String {
        var parts = [Format.count(model.survey.libraryPorts.count, "Port")]
        if model.survey.updates.count > 0 { parts.append(Format.count(model.survey.updates.count, "update")) }
        return parts.joined(separator: " · ")
    }
}

private struct LibraryGrid: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 24, alignment: .top)], spacing: 28) {
                ForEach(model.survey.libraryPorts) { entry in
                    LibraryTile(entry: entry)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
    }
}

private struct LibraryTile: View {
    @Environment(AppModel.self) private var model
    let entry: CatalogEntry

    var body: some View {
        let running = model.isRunning(entry.id)
        VStack(alignment: .leading, spacing: 10) {
            Button {
                model.open(.port(entry.id))
            } label: {
                ArtworkImage(.grid, port: entry.id)
                    .aspectRatio(92 / 43, contentMode: .fit)
                    .overlay(alignment: .topTrailing) {
                        if model.survey.isListed(entry.id) {
                            KindBadge(kind: entry.kind).padding(10)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        if running {
                            RoundedRectangle(cornerRadius: 17, style: .continuous)
                                .strokeBorder(.green, lineWidth: 2.5)
                                .padding(-4)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(entry.name)
            .accessibilityIdentifier("library.tile.\(entry.id.rawValue)")

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    PortStatusLine(port: entry.id)
                        .font(.callout)
                        .lineLimit(1)
                    if case .working(let activity) = model.status(of: entry.id).state {
                        ProgressView(value: activity.progress.fraction)
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                            .padding(.top, 5)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { model.open(.port(entry.id)) }
                PortActionButton(port: entry.id)
            }
        }
        .contextMenu { PortContextMenu(entry: entry) }
    }
}

private struct LibraryTable: View {
    @Environment(AppModel.self) private var model
    @Environment(ViewState.self) private var viewState
    @State private var selection: PortID?

    var body: some View {
        Table(model.survey.libraryPorts, selection: $selection) {
            TableColumn("Port") { entry in
                HStack(spacing: 12) {
                    ArtworkImage(.grid, port: entry.id, showsName: false)
                        .frame(width: 64, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.name).fontWeight(.semibold)
                        Text(model.gameName(for: entry))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                .cellEnvironment(model, viewState)
            }
            .width(min: 220, ideal: 280)
            TableColumn("Kind") { entry in
                Text(model.survey.isListed(entry.id) ? entry.kind.name : "—")
            }
            .width(min: 70, ideal: 80)
            TableColumn("Release") { entry in
                Text(model.survey.installation(entry.id)?.release.version ?? model.survey.latestRelease(for: entry.id)?.version ?? "")
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 70)
            TableColumn("Permissions") { entry in
                Text((model.survey.installation(entry.id)?.permissions ?? entry.permissions).summary)
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 120)
            TableColumn("Status") { entry in
                VStack(alignment: .leading, spacing: 5) {
                    LibraryStatusText(port: entry.id)
                    if case .working(let activity) = model.status(of: entry.id).state {
                        ProgressView(value: activity.progress.fraction)
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                            .frame(maxWidth: 160)
                    }
                }
                .cellEnvironment(model, viewState)
            }
            .width(min: 120, ideal: 170)
            TableColumn("") { entry in
                HStack {
                    Spacer(minLength: 0)
                    PortActionButton(port: entry.id, controlSize: .small)
                }
                .cellEnvironment(model, viewState)
            }
            .width(min: 90, ideal: 100)
        }
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: PortID.self) { ids in
            if let id = ids.first, let entry = model.survey.entry(id) {
                PortContextMenu(entry: entry)
            }
        } primaryAction: { ids in
            if let id = ids.first { model.open(.port(id)) }
        }
    }
}

/// The Status column: "Ready", "Running", "9.3.1 available", "Needs ROM", "Not Seeded", "Building from source…".
private struct LibraryStatusText: View {
    @Environment(AppModel.self) private var model
    let port: PortID

    var body: some View {
        switch model.status(of: port).state {
        case .ready, .available, .needsBuildROM:
            Text("Ready").foregroundStyle(.secondary)
        case .running:
            HStack(spacing: 6) {
                Circle().fill(.green).frame(width: 7, height: 7)
                Text("Running")
            }
            .foregroundStyle(.green)
        case .updateAvailable(let release):
            Text("\(release.version) available").foregroundStyle(.tint)
        case .needsROM:
            Text("Needs ROM").foregroundStyle(.orange)
        case .unseeded:
            Text("Not Seeded").foregroundStyle(.orange)
        case .working(let activity):
            Text(model.activityText(activity, for: port)).foregroundStyle(.secondary)
        case .blocked(let block):
            Text(block.severity == .stop ? "Disabled" : "Blocked")
                .foregroundStyle(block.severity == .stop ? .red : .orange)
                .help(block.reason)
        case .unsupported:
            Text("Unsupported").foregroundStyle(.secondary)
        }
    }
}

/// Shortcuts shared by Library tiles and rows.
struct PortContextMenu: View {
    @Environment(AppModel.self) private var model
    let entry: CatalogEntry

    var body: some View {
        Button("Open") { model.open(.port(entry.id)) }
        if model.survey.isListed(entry.id) {
            Button("Store Page") { model.open(.store(entry.id)) }
        }
        Divider()
        if model.survey.installation(entry.id) != nil {
            Button("Show Data in Finder") { model.revealData(for: entry.id) }
            Button("Show Logs in Finder") { model.openLogs(for: entry.id) }
        }
    }
}

#if DEBUG
#Preview("Library · Grid") {
    ScreenPreview(.library) { model, _ in model.libraryLayout = .grid }
}

#Preview("Library · List") {
    ScreenPreview(.library) { model, _ in model.libraryLayout = .list }
}

#Preview("Library · Empty") {
    ScreenPreview(.library, data: .empty())
}
#endif
