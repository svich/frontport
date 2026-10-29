import FrontportCore
import SwiftUI

/// A Game the Catalog has more than one Port of: its art and name, then each Port as a tile with its Project, what sets
/// it apart and its action, opening the Port's store page. A Game with one Port opens that Port instead.
struct GamePageView: View {
    @Environment(AppModel.self) private var model
    let game: GameID

    var body: some View {
        Group {
            if let game = model.survey.catalog?.game(game) {
                let ports = model.survey.lineup.ports(of: game.id)
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        HStack(spacing: 6) {
                            crumb("Catalog", .catalog)
                            if let platform = model.survey.catalog?.platform(game.platform) {
                                crumb(platform.name, .platform(platform.id))
                            }
                            Text(game.displayName).fontWeight(.semibold)
                        }
                        HStack(alignment: .center, spacing: 20) {
                            ArtworkImage(.grid, game: game.id)
                                .aspectRatio(92 / 43, contentMode: .fit)
                                .frame(width: 280)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            VStack(alignment: .leading, spacing: 6) {
                                Text(game.name)
                                    .font(.system(size: 28, weight: .heavy))
                                    .tracking(-0.5)
                                Text(line(game, ports: ports.count))
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                                Text("Each Port is built by its own Project and follows that Project’s Releases. One \(game.displayName) ROM works with all of them.")
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader(title: "Ports", count: ports.count)
                            PortTiles(ports: ports)
                        }
                        Credits()
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 36)
                }
                .testContainer("screen.game.\(game.id.rawValue)")
                .navigationTitle(game.displayName)
                .navigationSubtitle(Format.count(ports.count, "Port"))
            } else {
                ContentUnavailableView("Not in the Catalog", systemImage: "questionmark.square.dashed")
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back", systemImage: "chevron.left") { model.back() }
                    .disabled(!model.canGoBack)
                    .help("Back")
            }
        }
    }

    /// "Nintendo 64 · Platformer · 2 Ports".
    private func line(_ game: Game, ports: Int) -> String {
        let genre = game.genres.first.flatMap { model.survey.catalog?.genre($0)?.name }
        return [model.survey.catalog?.platform(game.platform)?.name, genre, Format.count(ports, "Port")].compactMap { $0 }
            .joined(separator: " · ")
    }

    private func crumb(_ title: String, _ screen: Screen) -> some View {
        HStack(spacing: 6) {
            Button(title) { model.open(screen) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }
}

/// The Ports side by side, up to three in a row, each row's tiles as tall as its tallest.
private struct PortTiles: View {
    let ports: [CatalogEntry]

    var body: some View {
        let columns = min(ports.count, 3)
        let rows = stride(from: 0, to: ports.count, by: columns).map { Array(ports[$0..<min($0 + columns, ports.count)]) }
        Grid(horizontalSpacing: 16, verticalSpacing: 16) {
            ForEach(rows, id: \.first?.id) { row in
                GridRow {
                    ForEach(row) { GamePortTile(entry: $0) }
                }
            }
        }
    }
}

/// One Port of the Game: its Project, developer and Kind, summary and Pills, then a way to its store page and the
/// action its state calls for.
private struct GamePortTile: View {
    @Environment(AppModel.self) private var model
    let entry: CatalogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.title2.weight(.bold))
                Text("by \(entry.developer) · \(entry.kind.name)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text(entry.summary)
                .lineSpacing(2)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .catalogContent("summary.\(entry.id.rawValue)")
            EntryPills(entry: entry, showsPermissions: true)
            Spacer(minLength: 4)
            Divider()
            HStack {
                Button("About \(entry.name)") { model.open(.store(entry.id)) }
                    .buttonStyle(.link)
                Spacer()
                if model.status(of: entry.id).isInLibrary {
                    InLibraryLink(port: entry.id)
                } else {
                    PortActionButton(port: entry.id, controlSize: .small)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .groupedBackground(cornerRadius: 14)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { model.open(.store(entry.id)) }
        .testContainer("game.port.\(entry.id.rawValue)")
    }
}

#if DEBUG
#Preview("Game · Super Mario 64") {
    ScreenPreview(.game("super-mario-64"))
}
#endif
