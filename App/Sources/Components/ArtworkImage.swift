import AppKit
import FrontportCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// SteamGridDB artwork for a Port or a Game. It decodes off the main thread and is cached in memory; while artwork the
/// Catalog names loads it shows a skeleton, and without artwork a flat color from the Game with the Game's name.
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
    /// What the last load found, and whose it is; a nil image when there's no artwork to show.
    @State private var loaded: (key: ArtworkCache.Key, image: NSImage?)?

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
    }

    private var key: ArtworkCache.Key { ArtworkCache.Key(kind: kind, subject: subject) }

    var body: some View {
        let key = key
        // The view may be reused for another subject: show only this one's image, straight from memory when it's there.
        let image = loaded?.key == key ? loaded?.image : ArtworkCache.shared.cached(key)
        Rectangle()
            .fill(.clear)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: kind == .logo ? .fit : .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: kind == .logo ? .bottomLeading : .center)
                } else if isPinned, loaded?.key != key, !ArtworkCache.shared.isMissing(key) {
                    // The Catalog names SteamGridDB art for it, still loading: its shape, not a stand-in that then
                    // changes. A logo has no shape of its own.
                    if kind != .logo { Skeleton() }
                } else {
                    fallback
                }
            }
            .clipped()
            .accessibilityHidden(true)
            .task(id: key) {
                let image = await ArtworkCache.shared.load(key, model: model)
                if !Task.isCancelled { loaded = (key, image) }
            }
    }

    /// Whether the Catalog names SteamGridDB art for the Port or Game, so there's likely some to wait for.
    private var isPinned: Bool {
        switch subject {
        case .port(let id):
            guard let artwork = model.survey.entry(id)?.artwork else { return false }
            return artwork.steamgriddb != nil || artwork.fallback != nil
        case .game(let id): return model.survey.catalog?.game(id)?.steamgriddb != nil
        }
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

/// A placeholder in the frame of something still loading, gently pulsing.
struct Skeleton: View {
    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .phaseAnimator([0.55, 1]) { content, phase in
                content.opacity(phase)
            } animation: { _ in .easeInOut(duration: 0.8) }
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

/// Decoded artwork, keyed by Port or Game and kind, kept in memory up to a budget. The Artwork store keeps it on disk
/// already scaled to the size it's shown at.
@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()

    struct Key: Hashable {
        var kind: ArtworkKind
        var subject: ArtworkImage.Subject
    }

    /// The file an image was decoded from, and when it last changed.
    private struct Source {
        var url: URL
        var stamp: Date?
    }

    private let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 256 * 1024 * 1024
        return cache
    }()
    private var sources: [Key: Source] = [:]
    /// Looked up and found to have no artwork, so views show their stand-in at once. Forgotten after each refresh,
    /// since a failed fetch looks the same.
    private var missing: Set<Key> = []
    /// Loads under way, so callers asking together share one.
    private var loading: [Key: Task<NSImage?, Never>] = [:]
    private var isPrefetching = false

    private static func name(_ key: Key) -> NSString {
        switch key.subject {
        case .port(let id): "port/\(id)/\(key.kind.rawValue)" as NSString
        case .game(let id): "game/\(id)/\(key.kind.rawValue)" as NSString
        }
    }

    func cached(_ key: Key) -> NSImage? {
        images.object(forKey: Self.name(key))
    }

    func isMissing(_ key: Key) -> Bool { missing.contains(key) }

    func forgetMissing() { missing = [] }

    /// The image for `key`, decoded unless the same file, unchanged, already is. Callers asking together share one load.
    func load(_ key: Key, model: AppModel, priority: TaskPriority = .userInitiated) async -> NSImage? {
        if let running = loading[key] { return await running.value }
        let task = Task(priority: priority) { await self.decode(key, model: model, priority: priority) }
        loading[key] = task
        let image = await task.value
        loading[key] = nil
        return image
    }

    private func decode(_ key: Key, model: AppModel, priority: TaskPriority) async -> NSImage? {
        // A second look, for a file replaced between finding it and reading it, as when the store scales it.
        for _ in 0..<2 {
            let url: URL? =
                switch key.subject {
                case .port(let id): await model.artwork(key.kind, for: id)
                case .game(let id): await model.artwork(key.kind, for: id)
                }
            guard let url else {
                if cached(key) == nil { missing.insert(key) }
                return cached(key)
            }
            missing.remove(key)
            let current = cached(key) != nil ? sources[key].flatMap { $0.url == url ? $0.stamp : nil } : nil
            let maxPixels = key.kind.maxPixels
            let decoded = await Task.detached(priority: priority) {
                DecodedArtwork.load(url, unlessStamped: current, maxPixels: maxPixels)
            }.value
            guard let decoded else {
                if let cached = cached(key) { return cached }
                continue
            }
            let image = NSImage(cgImage: decoded.image, size: .zero)
            images.setObject(image, forKey: Self.name(key), cost: decoded.image.bytesPerRow * decoded.image.height)
            sources[key] = Source(url: url, stamp: decoded.stamp)
            return image
        }
        return nil
    }

    /// Decodes, one at a time in the background, what shows first: the sidebar's icons, the heroes and logos of the
    /// Library's Port pages, and the Catalog's Port of the Day and New Ports. Each is for a Port a screen shows, so
    /// nothing is fetched for one no screen asks about, and it stays well within the memory budget.
    func prefetch(_ model: AppModel) async {
        guard !isPrefetching else { return }
        isPrefetching = true
        defer { isPrefetching = false }
        var keys: [Key] = []
        for entry in model.survey.libraryPorts {
            keys += [.icon, .hero, .logo].map { Key(kind: $0, subject: .port(entry.id)) }
        }
        if let entry = model.survey.lineup.portOfTheDay() {
            keys += [.hero, .logo].map { Key(kind: $0, subject: .port(entry.id)) }
        }
        keys += model.survey.lineup.newPorts().map { Key(kind: .grid, subject: .port($0.id)) }
        for key in keys where cached(key) == nil {
            guard !Task.isCancelled else { return }
            _ = await load(key, model: model, priority: .utility)
        }
    }
}

/// A CGImage decoded off the main thread.
private struct DecodedArtwork: @unchecked Sendable {
    var stamp: Date?
    var image: CGImage

    /// Nil when the file is missing, unreadable, or unchanged since `unlessStamped`.
    static func load(_ url: URL, unlessStamped previous: Date?, maxPixels: Int) -> DecodedArtwork? {
        let stamp = modified(url)
        if let previous, previous == stamp { return nil }
        guard let image = ScaledImage.decode(url, maxPixels: maxPixels) else { return nil }
        return DecodedArtwork(stamp: stamp, image: image)
    }

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

/// Decoding an image at no more than the size it's shown at, and keeping such a copy on disk.
enum ScaledImage {
    static func decode(_ url: URL, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return decode(source, maxPixels: maxPixels)
    }

    static func decode(_ data: Data, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return decode(source, maxPixels: maxPixels)
    }

    private static func decode(_ source: CGImageSource, maxPixels: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Writes HEIC, or PNG for an image with transparency, beside `url` with that extension; the other one goes.
    static func write(_ image: CGImage, to url: URL) {
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let (type, ext, other): (UTType, String, String) = hasAlpha ? (.png, "png", "heic") : (.heic, "heic", "png")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = url.appendingPathExtension(ext)
        let temporary = url.appendingPathExtension("\(UUID().uuidString).\(ext)")
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, type.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: temporary)
            return
        }
        _ = try? FileManager.default.replaceItemAt(file, withItemAt: temporary)
        try? FileManager.default.removeItem(at: url.appendingPathExtension(other))
    }
}

/// Screenshots from the Catalog, downloaded once and kept in `AppPaths.imageCache` at the size the store page shows
/// them.
@MainActor
final class ScreenshotCache {
    static let shared = ScreenshotCache()

    private let images: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
    private var loading: [URL: Task<NSImage?, Never>] = [:]
    /// Twice the store page's 480-point screenshots.
    private nonisolated static let maxPixels = 960

    func cached(_ url: URL) -> NSImage? { images.object(forKey: url as NSURL) }

    /// Nil when it can't be downloaded or decoded.
    func image(at url: URL, cache: URL) async -> NSImage? {
        if let image = cached(url) { return image }
        if let running = loading[url] { return await running.value }
        let task = Task(priority: .userInitiated) { () -> NSImage? in
            let file = cache.appending(path: "screenshots/\(Hashing.sha256(Data(url.absoluteString.utf8)))")
            let decoded = await Task.detached(priority: .userInitiated) { () -> CGImageBox? in
                for kept in ["heic", "png"].map({ file.appendingPathExtension($0) }) {
                    if let image = ScaledImage.decode(kept, maxPixels: Self.maxPixels) { return CGImageBox(image: image) }
                }
                guard url.scheme == "https", let (data, response) = try? await URLSession.shared.data(from: url),
                    (response as? HTTPURLResponse)?.statusCode == 200,
                    let image = ScaledImage.decode(data, maxPixels: Self.maxPixels)
                else { return nil }
                ScaledImage.write(image, to: file)
                // It can all be downloaded again, so Time Machine needn't keep it.
                var root = cache
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? root.setResourceValues(values)
                return CGImageBox(image: image)
            }.value
            return decoded.map { NSImage(cgImage: $0.image, size: .zero) }
        }
        loading[url] = task
        let image = await task.value
        loading[url] = nil
        if let image { images.setObject(image, forKey: url as NSURL, cost: Int(image.size.width * image.size.height) * 4) }
        return image
    }

    private struct CGImageBox: @unchecked Sendable {
        var image: CGImage
    }
}
