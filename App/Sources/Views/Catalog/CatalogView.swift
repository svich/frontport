import FrontportCore
import SwiftUI

/// Ports not in the Library: the Port of the Day, New Ports, every Platform, Genre and Project, each opening its
/// page, then All Games.
struct CatalogView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                if model.survey.lineup.toInstall.isEmpty {
                    ContentUnavailableView(
                        "Everything’s Installed", systemImage: "checkmark.circle",
                        description: Text("Every Port you can install is in your Library."))
                } else if let entry = model.survey.lineup.portOfTheDay() {
                    PortOfTheDay(entry: entry)
                }
                NewPortsSection()
                PlatformSection()
                GenreSection()
                ProjectSection()
                AllGamesSection()
                Credits()
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .testContainer("screen.catalog")
        .navigationTitle("Catalog")
        .navigationSubtitle(
            Format.count(model.survey.lineup.games.count, "Game") + " · "
                + Format.count(model.survey.lineup.toInstall.count, "Port") + " to install")
    }
}

/// The hero: one installable Port, changing daily. Its art keeps SteamGridDB's 1920×620 shape at any width, as
/// Steam's library shows it, so it's never cropped; one row below names it and offers Install.
private struct PortOfTheDay: View {
    @Environment(AppModel.self) private var model
    @Environment(ViewState.self) private var viewState
    let entry: CatalogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                model.open(.store(entry.id))
            } label: {
                ArtworkImage(.hero, port: entry.id)
                    .aspectRatio(1920 / 620, contentMode: .fit)
                    .overlay(alignment: .bottomLeading) {
                        ArtworkImage(.logo, port: entry.id)
                            .frame(maxWidth: 320, maxHeight: 120, alignment: .bottomLeading)
                            .padding(24)
                    }
                    .overlay(alignment: .topLeading) {
                        Text("PORT OF THE DAY")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(0.7)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(16)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.gameName(for: entry))
                        .font(.title2.bold())
                        .lineLimit(1)
                    Text(byline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                let status = model.status(of: entry.id)
                if case .addROM(let stage)? = status.main {
                    Button(status.title(.addROM(stage))) { viewState.run(.addROM(stage), for: entry.id, in: model) }
                        .buttonStyle(.addROM)
                        .controlSize(.large)
                        .help("Frontport needs the ROM to build this Port")
                } else {
                    Button(status.title(.install)) { viewState.run(.install, for: entry.id, in: model) }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .disabled(!status.allows(.install))
                        .help(model.help(.install, for: entry.id) ?? "")
                }
                Button("Details") { model.open(.store(entry.id)) }
                    .buttonStyle(.glass)
                    .controlSize(.large)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .groupedBackground(cornerRadius: 18)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// "Ghostship · by HarbourMasters · Decomp · 1 of 2 Ports".
    private var byline: String {
        let ports = model.survey.lineup.ports(of: entry.game).count
        return ["\(entry.name) · by \(entry.developer) · \(entry.kind.name)", ports > 1 ? "1 of \(ports) Ports" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// Ports to install the Catalog added lately, as cards, with All opening every new Port on the Releases screen.
/// Hidden when there are none.
private struct NewPortsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(ViewState.self) private var viewState

    var body: some View {
        let ports = model.survey.lineup.newPorts()
        if !ports.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    SectionHeader(title: "New Ports")
                    Button("All") {
                        viewState.releasesTab = .newPorts
                        model.open(.releases)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tint)
                    .fixedSize()
                    .accessibilityIdentifier("catalog.new.all")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 20, alignment: .top)], spacing: 26) {
                    ForEach(ports) { CatalogCard(entry: $0) }
                }
            }
        }
    }
}

private struct PlatformSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Platforms")
            LazyVGrid(columns: tileColumns, spacing: 14) {
                ForEach(model.survey.lineup.platforms, id: \.platform.id) { platform, count, unsupported in
                    CatalogTile(
                        name: platform.name, detail: tileCountText(count, unsupported: unsupported),
                        identifier: "catalog.platform.\(platform.id.rawValue)"
                    ) {
                        model.open(.platform(platform.id))
                    } icon: {
                        Image("PlatformIcons/\(platform.id.rawValue)")
                            .resizable()
                            .scaledToFit()
                    }
                }
            }
            PlatformIconCredit()
        }
    }
}

private struct GenreSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let genres = model.survey.lineup.genres
        if !genres.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Genres")
                LazyVGrid(columns: tileColumns, spacing: 14) {
                    ForEach(genres, id: \.genre.id) { genre, count, unsupported in
                        CatalogTile(
                            name: genre.name, detail: tileCountText(count, unsupported: unsupported),
                            identifier: "catalog.genre.\(genre.id.rawValue)"
                        ) {
                            model.open(.genre(genre.id))
                        } icon: {
                            GenreBadge(genre: genre.id, size: 44)
                        }
                    }
                }
            }
        }
    }
}

/// Every Project, each opening its page with its Games and Releases.
private struct ProjectSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let projects = model.survey.lineup.projects
        if !projects.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(
                    title: "Projects", count: projects.count,
                    subtitle: "A Port is a Game built by a Project. Releases and updates come from the Project.")
                LazyVGrid(columns: tileColumns, spacing: 14) {
                    ForEach(projects) { project in
                        CatalogTile(
                            name: project.name, detail: model.gamesText(of: project),
                            identifier: "catalog.project.\(project.id)"
                        ) {
                            model.open(.project(project.id))
                        } icon: {
                            ProjectIcon(project: project)
                        }
                    }
                }
            }
        }
    }
}

/// A Project's Games' icons, overlapping when it has more than one.
struct ProjectIcon: View {
    let project: Project

    var body: some View {
        let ports = project.ports.prefix(3)
        ZStack {
            ForEach(Array(ports.enumerated().reversed()), id: \.element.id) { offset, entry in
                ArtworkImage(.icon, game: entry.game)
                    .frame(width: ports.count == 1 ? 52 : 36, height: ports.count == 1 ? 52 : 36)
                    .clipShape(RoundedRectangle(cornerRadius: ports.count == 1 ? 12 : 9, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: ports.count == 1 ? 12 : 9, style: .continuous)
                            .strokeBorder(.background, lineWidth: ports.count == 1 ? 0 : 2)
                    }
                    .offset(x: offsets(ports.count)[offset].width, y: offsets(ports.count)[offset].height)
            }
        }
        .frame(width: 52, height: 52)
    }

    private func offsets(_ count: Int) -> [CGSize] {
        switch count {
        case 1: [.zero]
        case 2: [CGSize(width: -8, height: -8), CGSize(width: 8, height: 8)]
        default: [CGSize(width: -9, height: -9), CGSize(width: 0, height: 0), CGSize(width: 9, height: 9)]
        }
    }
}

/// The Platform, Genre and Project tiles' grid.
private let tileColumns = [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 14)]

/// A Platform's, Genre's or Project's icon, name and one line, opening its page.
private struct CatalogTile<Icon: View>: View {
    let name: String
    let detail: String
    let identifier: String
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                icon()
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    // One line, so every tile keeps the same height.
                    Text(name)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.background.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.separator.opacity(0.6), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name), \(detail)")
        .accessibilityIdentifier(identifier)
    }
}

/// "3 Games" with Ports to install; "1 Unsupported" when it has only Unsupported Ports.
private func tileCountText(_ count: Int, unsupported: Int) -> String {
    count == 0 && unsupported > 0 ? "\(unsupported) Unsupported" : Format.count(count, "Game")
}

/// Every Game with Ports to install, by name.
private struct AllGamesSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let games = model.survey.lineup.games
        if !games.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "All Games", count: games.count)
                GameGrid(games: games)
            }
        }
    }
}

/// Game cards in a grid, as All Games and the Platform and Genre pages show them.
struct GameGrid: View {
    @Environment(AppModel.self) private var model
    let games: [(game: Game, ports: [CatalogEntry])]
    /// The line under each Game's name; its Platform and Genre by default.
    var detail: ((Game) -> String)?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 20, alignment: .top)], spacing: 26) {
            ForEach(games, id: \.game.id) { game, ports in
                GameCard(game: game, ports: ports, detail: detail?(game) ?? defaultDetail(game))
            }
        }
    }

    private func defaultDetail(_ game: Game) -> String {
        let genre = game.genres.first.flatMap { model.survey.catalog?.genre($0)?.name }
        return [model.survey.catalog?.platform(game.platform)?.name, genre].compactMap { $0 }.joined(separator: " · ")
    }
}

/// A Game with Ports to install: its art and name, opening its Game page when it has more than one Port and its Port
/// otherwise, and a chip for each Port's Project.
struct GameCard: View {
    @Environment(AppModel.self) private var model
    let game: Game
    let ports: [CatalogEntry]
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                open()
            } label: {
                ArtworkImage(.grid, game: game.id)
                    .aspectRatio(92 / 43, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        if model.survey.lineup.ports(of: game.id).count > 1 {
                            Text(Format.count(model.survey.lineup.ports(of: game.id).count, "Port"))
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.black.opacity(0.58), in: Capsule())
                                .padding(10)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(game.displayName)
            .accessibilityIdentifier("catalog.game.\(game.id.rawValue)")
            VStack(alignment: .leading, spacing: 2) {
                Text(game.displayName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture { open() }
            FlowLayout(spacing: 6) {
                ForEach(ports) { PortChip(entry: $0) }
            }
        }
    }

    private func open() {
        if let screen = model.screen(for: game.id) { model.open(screen) }
    }
}

/// A Port's Project with its latest version, opening the Port's store page.
struct PortChip: View {
    @Environment(AppModel.self) private var model
    let entry: CatalogEntry

    var body: some View {
        Button {
            model.open(.store(entry.id))
        } label: {
            HStack(spacing: 5) {
                Text(entry.name).fontWeight(.semibold)
                if let version = model.survey.latestRelease(for: entry.id)?.version {
                    Text(version).monospacedDigit().foregroundStyle(.secondary)
                } else if entry.isSourceBuilt {
                    Image(systemName: "hammer").imageScale(.small).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.6), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("\(entry.name) by \(entry.developer) · \(entry.kind.name)")
        .accessibilityIdentifier("catalog.port.\(entry.id.rawValue)")
    }
}

/// The Platform's photo. The photos are on white, so the panel stays white in Dark Mode too.
struct PlatformPhoto: View {
    let platform: PlatformID

    var body: some View {
        Color.white
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                Image("Platforms/\(platform.rawValue)")
                    .resizable()
                    .scaledToFit()
                    .padding(.horizontal, 22)
                    .padding(.top, 16)
                    .padding(.bottom, 10)
            }
    }
}

/// RetroArch's icons are CC BY 4.0, so they're credited where they show.
private struct PlatformIconCredit: View {
    var body: some View {
        HStack(spacing: 4) {
            Text("Platform icons from")
            Link("RetroArch", destination: URL(string: "https://github.com/libretro/retroarch-assets")!)
            Text("under CC BY 4.0")
        }
        .font(.callout)
        .foregroundStyle(.tertiary)
    }
}

struct PlatformPhotoCredit: View {
    var body: some View {
        Text("Platform photos: Evan-Amos and others, public domain, via Wikimedia Commons.")
            .font(.callout)
            .foregroundStyle(.tertiary)
    }
}

/// A Catalog entry: landscape grid art, its Game, its Project line, Install and Pills.
struct CatalogCard: View {
    @Environment(AppModel.self) private var model
    let entry: CatalogEntry
    /// In place of the Game, where the Game is already named: the Project's name.
    var title: String?
    /// In place of the Project line.
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                open()
            } label: {
                ArtworkImage(.grid, port: entry.id)
                    .aspectRatio(92 / 43, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(entry.name)
            .accessibilityIdentifier("catalog.card.\(entry.id.rawValue)")
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title ?? model.gameName(for: entry))
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text(detail ?? projectLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { open() }
                if model.status(of: entry.id).isInLibrary {
                    InLibraryLink(port: entry.id)
                } else {
                    PortActionButton(port: entry.id, controlSize: .small)
                }
            }
            EntryPills(entry: entry)
        }
    }

    /// "Ghostship · Nintendo 64 · Decomp".
    private var projectLine: String {
        guard model.survey.isListed(entry.id) else { return AppModel.unlistedText }
        return [entry.name, model.survey.platform(for: entry)?.name, entry.kind.name].compactMap { $0 }.joined(separator: " · ")
    }

    private func open() {
        model.open(model.survey.installation(entry.id) == nil ? .store(entry.id) : .port(entry.id))
    }
}

/// Catalog entries that can't work in the sandbox, each with why, opening its store page.
struct UnsupportedSection: View {
    let entries: [CatalogEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "Unsupported", count: entries.count,
                subtitle: "Listed in the Catalog, but they can’t run inside the macOS sandbox, so Frontport never installs them.",
                identifier: "catalog.unsupported")
            GroupedSection {
                ForEach(entries) { UnsupportedRow(entry: $0) }
            }
        }
    }
}

private struct UnsupportedRow: View {
    @Environment(AppModel.self) private var model
    let entry: CatalogEntry

    var body: some View {
        Button {
            model.open(.store(entry.id))
        } label: {
            HStack(spacing: 12) {
                ArtworkImage(.icon, port: entry.id)
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name).fontWeight(.semibold)
                    Text(model.detailLine(for: entry))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 280, alignment: .leading)
                Text(entry.unsupported ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(entry.unsupported ?? "")
        .accessibilityLabel("\(entry.name), Unsupported")
        .accessibilityIdentifier("catalog.unsupported.\(entry.id.rawValue)")
    }
}

/// "✓ In Library", opening the Port page.
struct InLibraryLink: View {
    @Environment(AppModel.self) private var model
    let port: PortID

    var body: some View {
        Button {
            model.open(.port(port))
        } label: {
            Label("In Library", systemImage: "checkmark")
                .font(.callout)
                .foregroundStyle(.green)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("action.inLibrary.\(port.rawValue)")
    }
}

/// The artwork credit.
struct Credits: View {
    var body: some View {
        HStack(spacing: 4) {
            Text("Artwork from")
            Link("SteamGridDB", destination: URL(string: "https://www.steamgriddb.com")!)
        }
        .font(.callout)
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
#Preview("Catalog") {
    ScreenPreview(.catalog)
}

#Preview("Catalog · Nothing Installed") {
    ScreenPreview(.catalog, data: .empty())
}
#endif
