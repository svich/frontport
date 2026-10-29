import FrontportCore
import SwiftUI

/// One Platform's Ports to install, by Game, most Ports first, then its Unsupported ones apart.
struct PlatformPageView: View {
    @Environment(AppModel.self) private var model
    let platform: PlatformID

    var body: some View {
        if let platform = model.survey.catalog?.platform(platform) {
            GamesPage(
                name: platform.name, kind: "platform", id: platform.id.rawValue,
                games: model.survey.lineup.games(on: platform.id), count: model.survey.lineup.toInstall(on: platform.id).count,
                unsupported: model.survey.lineup.unsupported(on: platform.id),
                detail: { game in game.genres.compactMap { model.survey.catalog?.genre($0)?.name }.joined(separator: ", ") }
            ) {
                PlatformPhoto(platform: platform.id)
                    .frame(width: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.separator.opacity(0.6), lineWidth: 1)
                    }
            } credits: {
                PlatformPhotoCredit()
            }
        } else {
            ContentUnavailableView(
                "Not in the Catalog", systemImage: "questionmark.circle",
                description: Text("The Catalog no longer lists this Platform."))
        }
    }
}

/// A Platform's or Genre's page: "Catalog ›", its art, name and counts, then its Games, each with chips for its Ports
/// to install, then its Unsupported Ports.
struct GamesPage<Art: View, MoreCredits: View>: View {
    @Environment(AppModel.self) private var model
    let name: String
    /// "platform" or "genre", for the UI tests' identifiers.
    let kind: String
    let id: String
    let games: [(game: Game, ports: [CatalogEntry])]
    /// Ports to install.
    let count: Int
    let unsupported: [CatalogEntry]
    /// The line under each Game's name.
    let detail: (Game) -> String
    @ViewBuilder let art: () -> Art
    @ViewBuilder let credits: () -> MoreCredits

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 6) {
                        Button("Catalog") { model.open(.catalog) }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                        Text(name).fontWeight(.semibold)
                    }
                    HStack(spacing: 20) {
                        art()
                        VStack(alignment: .leading, spacing: 4) {
                            Text(name)
                                .font(.system(size: 28, weight: .heavy))
                                .tracking(-0.5)
                            HStack(spacing: 0) {
                                if !games.isEmpty {
                                    Text(Format.count(games.count, "Game") + " · ")
                                }
                                Text(Format.count(count, "Port") + " to install")
                                    .accessibilityIdentifier("\(kind).available")
                            }
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                GameGrid(games: games, detail: detail)
                if !unsupported.isEmpty {
                    UnsupportedSection(entries: unsupported)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Credits()
                    credits()
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .testContainer("screen.\(kind).\(id)")
        .navigationTitle(name)
        .navigationSubtitle(Format.count(count, "Port") + " to install")
    }
}

#if DEBUG
#Preview("Platform · Nintendo 64") {
    ScreenPreview(.platform("n64"))
}

#Preview("Platform · PlayStation 2, Unsupported") {
    ScreenPreview(.platform("ps2"), data: .standard().withOpenGOALUnsupported())
}

#Preview("Platform · Super Nintendo") {
    ScreenPreview(.platform("snes"))
}
#endif
