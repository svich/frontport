import AppKit
import FrontportCore
import ImageIO
import SwiftUI

/// SteamGridDB artwork for a Port or a Game. It decodes off the main thread and is cached in memory;
/// without artwork it shows a flat color from the Game with the Game's name.
///
/// It fills the frame it's given, so set the shape with `.aspectRatio` or `.frame` and clip it.
struct ArtworkImage: View {
    enum Subject: Hashable {
        case port(PortID)
        case game(GameID)
    }

    @Environment(AppModel.self) private var model
    let kind: ArtworkKind
    let subject: Subject
    /// Whether the fallback names the Game. Off where the name sits right next to it.
    var showsName: Bool
    @State private var image: NSImage?

    init(_ kind: ArtworkKind, port: PortID, showsName: Bool = true) {
        self.init(kind, subject: .port(port), showsName: showsName)
    }

    init(_ kind: ArtworkKind, game: GameID, showsName: Bool = true) {
        self.init(kind, subject: .game(game), showsName: showsName)
    }

    private init(_ kind: ArtworkKind, subject: Subject, showsName: Bool) {
        self.kind = kind
        self.subject = subject
        self.showsName = showsName
        _image = State(initialValue: ArtworkCache.shared.cached(kind, subject))
    }

    var body: some View {
        Rectangle()
            .fill(.clear)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: kind == .logo ? .fit : .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: kind == .logo ? .bottomLeading : .center)
                } else {
                    fallback
                }
            }
            .clipped()
            .accessibilityHidden(true)
            .task(id: TaskID(kind: kind, subject: subject, generation: model.artworkGeneration)) {
                // The view may be reused for another subject: start from what's known about this one.
                let cached = ArtworkCache.shared.cached(kind, subject)
                if image !== cached { image = cached }
                let url: URL? =
                    switch subject {
                    case .port(let id): await model.artwork(kind, for: id)
                    case .game(let id): await model.artwork(kind, for: id)
                    }
                guard let url, !Task.isCancelled else { return }
                if let loaded = await ArtworkCache.shared.image(at: url, kind: kind, subject: subject),
                    !Task.isCancelled
                {
                    image = loaded
                }
            }
    }

    private struct TaskID: Hashable {
        var kind: ArtworkKind
        var subject: Subject
        var generation: Int
    }

    @ViewBuilder private var fallback: some View {
        switch subject {
        case .port(let id):
            let entry = model.survey.entry(id)
            let game = entry.flatMap { model.survey.game(for: $0) }
            ArtworkFallback(
                kind: kind, game: entry?.game ?? GameID(id.rawValue),
                gameName: game?.displayName ?? entry?.name ?? id.rawValue,
                portName: entry?.name ?? id.rawValue, showsName: showsName)
        case .game(let id):
            let game = model.survey.catalog?.game(id)
            ArtworkFallback(
                kind: kind, game: id, gameName: game?.displayName ?? id.rawValue, portName: nil, showsName: showsName)
        }
    }
}

/// A flat color picked from the Game id, with the Game's name on it. For a logo, the Port's name.
struct ArtworkFallback: View {
    let kind: ArtworkKind
    let game: GameID
    let gameName: String
    let portName: String?
    var showsName = true

    var body: some View {
        if kind == .logo {
            Text(portName ?? gameName)
                .font(.system(size: 52, weight: .heavy))
                .tracking(-1)
                .lineLimit(2)
                .minimumScaleFactor(0.4)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 12, y: 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        } else {
            GeometryReader { proxy in
                ZStack {
                    Self.color(for: game)
                    LinearGradient(
                        colors: [.white.opacity(0.10), .clear, .black.opacity(0.12)],
                        startPoint: .top, endPoint: .bottom)
                    if showsName { label(in: proxy.size) }
                }
            }
        }
    }

    @ViewBuilder private func label(in size: CGSize) -> some View {
        switch kind {
        case .icon:
            Text(Self.initials(gameName))
                .font(.system(size: max(9, size.width * 0.36), weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
        case .hero:
            Text(gameName)
                .font(.system(size: size.height * 0.34, weight: .black))
                .tracking(-2)
                .lineLimit(1)
                .minimumScaleFactor(0.3)
                .foregroundStyle(.white.opacity(0.09))
                .padding(.horizontal, size.width * 0.04)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, size.height * 0.08)
        default:
            Text(gameName)
                .font(.system(size: max(10, min(size.width * 0.085, size.height * 0.2)), weight: .bold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .foregroundStyle(.white.opacity(0.94))
                .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                .padding(size.width * 0.08)
        }
    }

    // Thirteen, ordered so the launch Catalog's Games each get their own color.
    private static let palette: [Color] = [
        Color(red: 0.31, green: 0.42, blue: 0.17),  // olive
        Color(red: 0.55, green: 0.30, blue: 0.09),  // rust
        Color(red: 0.18, green: 0.23, blue: 0.31),  // slate
        Color(red: 0.48, green: 0.18, blue: 0.33),  // plum
        Color(red: 0.18, green: 0.37, blue: 0.23),  // pine
        Color(red: 0.24, green: 0.29, blue: 0.61),  // indigo
        Color(red: 0.42, green: 0.34, blue: 0.16),  // bronze
        Color(red: 0.66, green: 0.20, blue: 0.17),  // red
        Color(red: 0.35, green: 0.20, blue: 0.45),  // purple
        Color(red: 0.61, green: 0.24, blue: 0.12),  // brick
        Color(red: 0.12, green: 0.29, blue: 0.53),  // blue
        Color(red: 0.12, green: 0.44, blue: 0.47),  // teal
        Color(red: 0.29, green: 0.36, blue: 0.45),  // steel
    ]

    /// Stable across launches, unlike `hashValue`.
    static func color(for game: GameID) -> Color {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in game.rawValue.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return palette[Int(hash % UInt64(palette.count))]
    }

    /// "Ocarina of Time" → "OT"; skips little words.
    static func initials(_ name: String) -> String {
        let minor: Set<String> = ["the", "of", "a", "an", "to", "and", "&", "-"]
        let words = name.split(whereSeparator: { $0 == " " || $0 == ":" || $0 == "-" })
            .filter { !minor.contains($0.lowercased()) }
        let letters = words.prefix(2).compactMap(\.first)
        return letters.isEmpty ? String(name.prefix(1)) : String(letters).uppercased()
    }
}

/// Decoded artwork kept for the session, keyed by Port or Game and kind.
@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()

    private struct Entry {
        var url: URL
        var stamp: Date?
        var image: NSImage
    }

    private var entries: [String: Entry] = [:]

    private static func key(_ kind: ArtworkKind, _ subject: ArtworkImage.Subject) -> String {
        switch subject {
        case .port(let id): "port/\(id)/\(kind.rawValue)"
        case .game(let id): "game/\(id)/\(kind.rawValue)"
        }
    }

    func cached(_ kind: ArtworkKind, _ subject: ArtworkImage.Subject) -> NSImage? {
        entries[Self.key(kind, subject)]?.image
    }

    /// Decodes the file unless the same file, unchanged, is already cached.
    func image(at url: URL, kind: ArtworkKind, subject: ArtworkImage.Subject) async -> NSImage? {
        let key = Self.key(kind, subject)
        let cached = entries[key].flatMap { $0.url == url ? $0.stamp : nil }
        let maxPixels = Self.maxPixels(kind)
        let loaded = await Task.detached(priority: .utility) {
            DecodedArtwork.load(url, unlessStamped: cached, maxPixels: maxPixels)
        }.value
        guard let loaded else { return entries[key]?.image }
        let image = NSImage(cgImage: loaded.image, size: .zero)
        entries[key] = Entry(url: url, stamp: loaded.stamp, image: image)
        return image
    }

    private static func maxPixels(_ kind: ArtworkKind) -> Int {
        switch kind {
        case .icon: 192
        case .grid: 1100
        case .hero: 2400
        case .logo: 1200
        }
    }
}

/// A CGImage decoded off the main thread.
private struct DecodedArtwork: @unchecked Sendable {
    var stamp: Date?
    var image: CGImage

    /// Nil when the file is missing, unreadable, or unchanged since `unlessStamped`.
    static func load(_ url: URL, unlessStamped previous: Date?, maxPixels: Int) -> DecodedArtwork? {
        let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let previous, previous == stamp { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return DecodedArtwork(stamp: stamp, image: image)
    }
}
