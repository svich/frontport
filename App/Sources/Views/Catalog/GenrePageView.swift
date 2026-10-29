import FrontportCore
import SwiftUI

/// One Genre's Ports to install, by Game, most Ports first, then its Unsupported ones apart.
struct GenrePageView: View {
    @Environment(AppModel.self) private var model
    let genre: GenreID

    var body: some View {
        if let genre = model.survey.catalog?.genre(genre) {
            GamesPage(
                name: genre.name, kind: "genre", id: genre.id.rawValue,
                games: model.survey.lineup.games(in: genre.id), count: model.survey.lineup.toInstall(in: genre.id).count,
                unsupported: model.survey.lineup.unsupported(in: genre.id),
                detail: { game in model.survey.catalog?.platform(game.platform)?.name ?? "" }
            ) {
                GenreBadge(genre: genre.id, size: 112)
            } credits: {
                EmptyView()
            }
        } else {
            ContentUnavailableView(
                "Not in the Catalog", systemImage: "questionmark.circle",
                description: Text("The Catalog no longer lists this Genre."))
        }
    }
}

/// The Genre's symbol, white on its colour. Frontport draws these itself, so a Genre the Catalog adds later gets a
/// controller until a build knows it.
struct GenreBadge: View {
    let genre: GenreID
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch genre.rawValue {
        case "platformer": "figure.run"
        case "adventure": "map.fill"
        case "racing": "flag.checkered"
        case "shooter": "scope"
        default: "gamecontroller.fill"
        }
    }

    private var color: Color {
        switch genre.rawValue {
        case "platformer": .orange
        case "adventure": .green
        case "racing": .red
        case "shooter": .indigo
        default: .gray
        }
    }
}

#if DEBUG
#Preview("Genre · Platformer") {
    ScreenPreview(.genre("platformer"))
}

#Preview("Genre · Adventure") {
    ScreenPreview(.genre("adventure"))
}
#endif
