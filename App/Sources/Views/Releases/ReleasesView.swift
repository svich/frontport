import FrontportCore
import SwiftUI

/// New Ports, every Port by its first Release, and Updates, picked in the toolbar.
struct ReleasesView: View {
    @Environment(AppModel.self) private var model
    @Environment(ViewState.self) private var viewState

    var body: some View {
        @Bindable var viewState = viewState
        ScrollView {
            Group {
                switch viewState.releasesTab {
                case .newPorts: NewPortsTab()
                case .updates: UpdatesTab()
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 36)
        }
        .testContainer("screen.releases")
        .navigationTitle("Releases")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Section", selection: $viewState.releasesTab) {
                    ForEach(ViewState.ReleasesTab.allCases, id: \.self) { tab in
                        Text(tab.title)
                            .accessibilityIdentifier("releases.tab.\(tab.rawValue)")
                            .tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("releases.tabs")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Check for Updates", systemImage: "arrow.clockwise") {
                    Task { await model.refresh() }
                }
                .help("Check for new Releases")
            }
        }
    }

    private var subtitle: String {
        switch viewState.releasesTab {
        case .newPorts:
            return Format.count(model.survey.catalog?.ports.count ?? 0, "Port") + " in the Catalog"
        case .updates:
            let projects = model.survey.lineup.projectUpdates.count
            let updates = model.survey.updates.count == 0
                ? "Your Ports are up to date"
                : "\(Format.count(projects, "Project")) \(projects == 1 ? "has" : "have") updates for \(Format.count(model.survey.updates.count, "of your Ports", "of your Ports"))"
            return "\(updates) · \(model.lastCheckedText)"
        }
    }
}

/// Every Catalog Port by the year of its first Release, newest first.
private struct NewPortsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            ForEach(model.survey.lineup.years) { group in
                VStack(alignment: .leading, spacing: 12) {
                    Text(group.label.uppercased())
                        .font(.callout.weight(.semibold))
                        .tracking(0.5)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                        .accessibilityIdentifier("releases.year")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 20, alignment: .top)], spacing: 26) {
                        ForEach(group.ports) { CatalogCard(entry: $0) }
                    }
                }
            }
        }
    }
}

/// Updates for Library Ports, one per Project, then every other Catalog Release by month.
private struct UpdatesTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let updates = model.survey.lineup.projectUpdates
        VStack(alignment: .leading, spacing: 30) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Updates")
                if updates.isEmpty {
                    Label("Your Ports are up to date.", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(updates) { UpdateCard(update: $0) }
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Recent Releases", subtitle: "Every other Project in the Catalog, newest first")
                ForEach(model.survey.lineup.months()) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.label.uppercased())
                            .font(.callout.weight(.semibold))
                            .tracking(0.5)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 4)
                            .accessibilityIdentifier("releases.group")
                        GroupedSection {
                            ForEach(group.releases) { release in
                                ReleaseRow(release: release, showsYear: group.isEarlier)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// A Project's update for Library Ports: its notes, each Port it updates, and Update for all of them.
private struct UpdateCard: View {
    @Environment(AppModel.self) private var model
    let update: ProjectUpdate

    var body: some View {
        let release = update.release
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Button(update.project.name) { model.open(.project(update.project.id)) }
                        .buttonStyle(.plain)
                    Text(release.version).monospacedDigit()
                }
                .font(.title3.weight(.semibold))
                Text(metadata)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let summary = model.notesSummary(release) {
                    Text(summary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                        .catalogContent("notes.\(release.port.rawValue)")
                }
                Text(update.project.isSourceBuilt
                    ? "Frontport rebuilds each Port from source and takes a Snapshot of its Data first, so you can roll back."
                    : "Frontport takes a Snapshot of the Port’s Data before updating, so you can roll back.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 10) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Updates \(Format.count(update.ports.count, "of your Ports", "of your Ports"))")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 6)
                    ForEach(update.ports) { entry in
                        HStack(spacing: 10) {
                            ArtworkImage(.icon, game: entry.game)
                                .frame(width: 26, height: 26)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            Button(model.gameName(for: entry)) { model.open(.port(entry.id)) }
                                .buttonStyle(.plain)
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(model.survey.installation(entry.id)?.release.version ?? "") → \(release.version)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 5)
                    }
                }
                .frame(width: 300)
                HStack(spacing: 14) {
                    if let url = release.notesURL {
                        Link("Release Notes", destination: url)
                    }
                    Button(update.ports.count > 1 ? "Update \(update.ports.count)" : "Update") {
                        for entry in update.ports { model.update(entry.id) }
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .calloutBackground(.accentColor)
    }

    private var metadata: String {
        var parts = ["by \(update.project.developer)"]
        if let title = update.release.title { parts.append(title) }
        if let published = update.release.published { parts.append(Format.date(published)) }
        return parts.joined(separator: " · ")
    }
}

private struct ReleaseRow: View {
    @Environment(AppModel.self) private var model
    let release: Release
    let showsYear: Bool

    var body: some View {
        let entry = model.survey.entry(release.port)
        HStack(alignment: .center, spacing: 14) {
            Button {
                model.open(.store(release.port))
            } label: {
                ArtworkImage(.grid, port: release.port)
                    .frame(width: 150, height: 70)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(entry?.name ?? release.port.rawValue)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Button(entry?.name ?? release.port.rawValue) { model.open(.store(release.port)) }
                        .buttonStyle(.plain)
                    Text(release.version).monospacedDigit()
                }
                .font(.system(size: 14, weight: .semibold))
                if let entry {
                    Text(forLine(entry))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                notes
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 5)
                    .catalogContent("notes.\(release.port.rawValue)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(date)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Group {
                if let entry, let project = model.survey.lineup.project(for: entry), project.ports.count > 1 {
                    Button(Format.count(project.ports.count, "Game")) { model.open(.project(project.id)) }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                } else {
                    ReleaseAction(port: release.port)
                }
            }
            .frame(width: 104, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .testContainer("releases.row.\(release.port.rawValue)")
    }

    /// "by HarbourMasters · for Super Mario 64 · Nintendo 64", every Game of the Project named.
    private func forLine(_ entry: CatalogEntry) -> String {
        guard model.survey.isListed(entry.id) else { return AppModel.unlistedText }
        let games = model.survey.lineup.project(for: entry).map { model.gameNames(of: $0) } ?? model.gameName(for: entry)
        return ["by \(entry.developer)", "for \(games)", model.survey.platform(for: entry)?.name].compactMap { $0 }
            .joined(separator: " · ")
    }

    /// The notes summary followed by an inline "Release Notes" link.
    private var notes: Text {
        var text = AttributedString(model.notesSummary(release) ?? "")
        if let url = release.notesURL {
            if !text.characters.isEmpty { text.append(AttributedString(" ")) }
            var link = AttributedString("Release Notes")
            link.link = url
            text.append(link)
        }
        return Text(text)
    }

    private var date: String {
        guard let published = release.published else { return "" }
        return showsYear ? Format.date(published) : published.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// Install, Add ROM…, Update, "In Library" or what's in progress, for a Release's Port.
private struct ReleaseAction: View {
    @Environment(AppModel.self) private var model
    @Environment(ViewState.self) private var viewState
    let port: PortID

    var body: some View {
        let status = model.status(of: port)
        switch (status.state, status.main) {
        case (.working(let activity), _):
            Text(model.activityText(activity, for: port))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        case (.unsupported, _):
            Text("Unsupported").foregroundStyle(.secondary)
        case (_, .install?):
            button(.install, status).buttonStyle(.glass)
        case (_, .addROM(.build)?):
            button(.addROM(.build), status)
                .buttonStyle(.addROM)
                .help("Frontport needs the ROM to build this Port")
        case (_, .update?):
            button(.update, status).buttonStyle(.glassProminent)
        default:
            if status.isInLibrary { InLibraryLink(port: port) }
        }
    }

    private func button(_ action: Status.Action, _ status: Status) -> some View {
        Button(model.title(action, for: port)) { viewState.run(action, for: port, in: model) }
            .disabled(!status.allows(action))
            .controlSize(.small)
    }
}

#if DEBUG
#Preview("Releases") {
    ScreenPreview(.releases)
}

#Preview("Releases · Nothing Installed") {
    ScreenPreview(.releases, data: .empty())
}

#Preview("Releases · New Ports") {
    ScreenPreview(.releases) { _, viewState in viewState.releasesTab = .newPorts }
}
#endif
