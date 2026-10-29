import FrontportCore
import SwiftUI

/// A Project's page: what it is, its Games, each a Port to install or play, and its Releases, which every one of its
/// Ports follows.
struct ProjectPageView: View {
    @Environment(AppModel.self) private var model
    let project: String

    var body: some View {
        Group {
            if let project = model.survey.lineup.project(project) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        HStack(spacing: 6) {
                            Button("Catalog") { model.open(.catalog) }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                            Text(project.name).fontWeight(.semibold)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("PROJECT")
                                .font(.system(size: 11, weight: .bold))
                                .tracking(0.7)
                                .foregroundStyle(.tint)
                            Text(project.name)
                                .font(.system(size: 28, weight: .heavy))
                                .tracking(-0.5)
                            Text(byline(project))
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                        if let update = model.survey.lineup.projectUpdates.first(where: { $0.project.id == project.id }) {
                            ProjectUpdateBanner(update: update)
                        }
                        HStack(alignment: .top, spacing: 32) {
                            VStack(alignment: .leading, spacing: 10) {
                                SectionHeader(title: "About")
                                ForEach(paragraphs(project), id: \.self) { paragraph in
                                    Text(paragraph)
                                        .font(.system(size: 14))
                                        .lineSpacing(4)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                        .catalogContent("description")
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            ProjectDetails(project: project)
                                .frame(width: 320)
                        }
                        VStack(alignment: .leading, spacing: 14) {
                            SectionHeader(
                                title: "Games", count: project.ports.count,
                                subtitle: "Each Game is its own Port, with its own Installation, Data and Snapshots. All of them follow \(project.name)’s Releases.")
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 260), spacing: 20, alignment: .top)], spacing: 26
                            ) {
                                ForEach(project.ports) { CatalogCard(entry: $0, detail: gameDetail($0)) }
                            }
                        }
                        ProjectReleases(project: project)
                        Credits()
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 36)
                }
                .testContainer("screen.project")
            } else {
                ContentUnavailableView("Not in the Catalog", systemImage: "questionmark.square.dashed")
            }
        }
        .navigationTitle(model.survey.lineup.project(project)?.name ?? project)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back", systemImage: "chevron.left") { model.back() }
                    .disabled(!model.canGoBack)
                    .help("Back")
            }
        }
    }

    /// "by OpenGOAL · Decomp · 3 Games on PlayStation 2".
    private func byline(_ project: Project) -> String {
        var platforms: [String] = []
        for entry in project.ports {
            if let name = model.survey.platform(for: entry)?.name, !platforms.contains(name) { platforms.append(name) }
        }
        let games = Format.count(project.ports.count, "Game")
        let on = platforms.isEmpty ? games : "\(games) on \(platforms.formatted(.list(type: .and)))"
        return "by \(project.developer) · \(project.kind.name) · \(on)"
    }

    private func paragraphs(_ project: Project) -> [String] {
        project.about.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// "In your Library · OpenGOAL 0.3.8", or "PlayStation 2 · Decomp".
    private func gameDetail(_ entry: CatalogEntry) -> String {
        if let installed = model.survey.installation(entry.id)?.release.version {
            return "In your Library · \(entry.name) \(installed)"
        }
        return [model.survey.platform(for: entry)?.name, entry.kind.name].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The Project's Release that updates Library Ports, with Update for all of them.
struct ProjectUpdateBanner: View {
    @Environment(AppModel.self) private var model
    let update: ProjectUpdate

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(update.project.name) \(update.release.version) is ready for \(Format.count(update.ports.count, "of your Ports", "of your Ports"))")
                    .font(.system(size: 16, weight: .bold))
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 14) {
                if let url = update.release.notesURL {
                    Link("Release Notes", destination: url)
                }
                Button(update.ports.count > 1 ? "Update \(update.ports.count)" : "Update") {
                    for entry in update.ports { model.update(entry.id) }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .calloutBackground(.accentColor)
    }

    private var detail: String {
        let names = update.ports.map { model.gameName(for: $0) }.formatted(.list(type: .and))
        let installed = Set(update.ports.compactMap { model.survey.installation($0.id)?.release.version })
        let have = installed.count == 1 ? " \(update.ports.count == 1 ? "has" : "have") \(installed.first!)." : "."
        let how = update.project.isSourceBuilt
            ? "Frontport rebuilds each from source and takes a Snapshot of its Data first, so you can roll back."
            : "Frontport takes a Snapshot of each Port’s Data first, so you can roll back."
        return "\(names)\(have) \(how)"
    }
}

/// Developer, source, website, Channels and where Releases come from.
private struct ProjectDetails: View {
    let project: Project

    var body: some View {
        GroupedSection("Details") {
            GroupedRow("Developer", value: project.developer)
            GroupedRow("Source") {
                Link(project.source.shortDisplay, destination: project.source)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let website = project.website {
                GroupedRow("Website") { Link(website.shortDisplay, destination: website) }
            }
            if let entry = project.ports.first {
                GroupedRow("Channels", value: entry.releases.channels.map(\.name).formatted(.list(type: .and)))
            }
            GroupedRow(
                "Releases",
                value: project.isSourceBuilt ? "Pinned by the Catalog, built from source" : "From GitHub Releases")
        }
    }
}

/// Every known Release of the Project, newest first, marking the latest and the one Library Ports have.
private struct ProjectReleases: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        let releases = model.survey.lineup.releases(of: project)
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Releases", subtitle: "Every Port of \(project.name) follows these.")
            if releases.isEmpty {
                Label(
                    project.isSourceBuilt
                        ? "\(project.name) has no Releases yet. Frontport builds the commit the Catalog pins."
                        : "No \(project.name) Releases found yet. Frontport looks for them when it checks for updates.",
                    systemImage: project.isSourceBuilt ? "hammer" : "clock")
                    .foregroundStyle(.secondary)
            } else {
                GroupedSection {
                    ForEach(Array(releases.enumerated()), id: \.element.id) { offset, release in
                        row(release, isLatest: offset == 0)
                    }
                }
            }
        }
    }

    private func row(_ release: Release, isLatest: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(project.name) \(release.version)")
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                if let published = release.published {
                    Text(Format.date(published))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 170, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                notes(release)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .catalogContent("notes.\(release.version)")
                HStack(spacing: 6) {
                    if isLatest { Pill(text: "Latest") }
                    let installed = model.libraryPorts(of: project)
                        .filter { model.survey.installation($0.id)?.release.version == release.version }
                    if !installed.isEmpty {
                        Pill(
                            text: "Installed for " + installed.map { model.gameName(for: $0) }.formatted(.list(type: .and)),
                            systemImage: "checkmark", style: .positive)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// The notes summary followed by an inline "Release Notes" link.
    private func notes(_ release: Release) -> Text {
        var text = AttributedString(model.notesSummary(release) ?? "")
        if let url = release.notesURL {
            if !text.characters.isEmpty { text.append(AttributedString(" ")) }
            var link = AttributedString("Release Notes")
            link.link = url
            text.append(link)
        }
        return Text(text)
    }
}

#if DEBUG
#Preview("Project · OpenGOAL") {
    ScreenPreview(.project("open-goal/jak-project"))
}

#Preview("Project · nxnative") {
    ScreenPreview(.project("seedds/nxnative"))
}
#endif
