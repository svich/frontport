import Foundation
import FrontportCore
import ImageIO
import Synchronization
import Testing
@testable import FrontportArtwork

final class TestClock: Sendable {
    let date = Mutex(Date(timeIntervalSince1970: 1_792_800_000))
    func now() -> Date { date.withLock { $0 } }
    func advance(days: Double) { date.withLock { $0 += days * 24 * 60 * 60 } }
}

struct ArtworkFixture {
    static let portID = 5335518
    static let gameID = 21202

    let directory: TemporaryDirectory
    let paths: AppPaths
    let server = StubServer()
    let clock = TestClock()
    let store: ArtworkStore

    init() throws {
        directory = try TemporaryDirectory()
        paths = AppPaths(root: try directory.folder("Frontport"), containers: try directory.folder("Containers"))
        let clock = clock
        store = ArtworkStore(paths: paths, session: server.session, base: server.url("v1/"), now: { clock.now() })
    }

    var entry: CatalogEntry {
        CatalogEntry(
            id: "shipwright", name: "Ship of Harkinian", kind: .decomp, game: "ocarina-of-time",
            developer: "HarbourMasters", summary: "", description: "",
            source: URL(string: "https://github.com/HarbourMasters/Shipwright")!, bundleId: "dev.frontport.port.shipwright",
            releases: .githubRelease(GitHubReleaseSource(repo: "HarbourMasters/Shipwright", asset: "SoH-*-Mac.zip")),
            artwork: Artwork(steamgriddb: Self.portID, fallback: Self.gameID))
    }

    static func path(_ kind: ArtworkKind, game: Int) -> String { "v1/\(game)/\(kind.rawValue)" }

    /// The Worker's answer for a kind and game: the image, as PNG bytes of its asset id unless given.
    func serve(_ kind: ArtworkKind, game: Int, asset: Int, author: String = "artist", data: Data? = nil) {
        server.set(
            Self.path(kind, game: game), body: data ?? Data("png \(asset)".utf8), contentType: "image/png",
            headers: credit(asset: asset, author: author))
    }

    /// The Worker's answer when SteamGridDB has no artwork of the kind for the game.
    func serveNone(_ kind: ArtworkKind, game: Int) {
        server.set(Self.path(kind, game: game), status: 404, body: Data(#"{"error":"none"}"#.utf8), contentType: "application/json")
    }

    /// The Worker's answer when the app already has SteamGridDB's pick.
    func serveUnchanged(_ kind: ArtworkKind, game: Int, asset: Int, author: String = "artist") {
        server.set(Self.path(kind, game: game), status: 304, body: Data(), headers: credit(asset: asset, author: author))
    }

    private func credit(asset: Int, author: String) -> [String: String] {
        [
            "ETag": "\"\(asset)\"", "X-Artwork-Asset": "\(asset)",
            "X-Artwork-Author": author.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!,
            "X-Artwork-Source": "https://cdn.example/\(asset).png",
        ]
    }

    func requests(_ kind: ArtworkKind, game: Int) -> [URLRequest] { server.requests(to: Self.path(kind, game: game)) }
}

@Suite struct ArtworkStoreTests {
    @Test func fetchesFromTheWorkerAndCachesWithTheCredit() async throws {
        let fixture = try ArtworkFixture()
        fixture.serve(.grid, game: ArtworkFixture.portID, asset: 11, author: "Zoë Q")

        let file = try #require(await fixture.store.artwork(.grid, for: fixture.entry))
        #expect(file == fixture.paths.artwork(steamgriddb: ArtworkFixture.portID).appending(path: "grid.png"))
        #expect(try Data(contentsOf: file) == Data("png 11".utf8))

        let request = try #require(fixture.requests(.grid, game: ArtworkFixture.portID).first)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Frontport")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)

        let record = try #require(await fixture.store.record(.grid, for: fixture.entry))
        #expect(record.assetID == 11)
        #expect(record.author == "Zoë Q")
        #expect(record.source == URL(string: "https://cdn.example/11.png"))
        #expect(record.fetched == fixture.clock.now())

        // Cached: no more requests.
        let count = fixture.server.requests.count
        #expect(await fixture.store.artwork(.grid, for: fixture.entry) == file)
        #expect(fixture.server.requests.count == count)
    }

    @Test func fallsBackToTheGameWhenThePortHasNone() async throws {
        let fixture = try ArtworkFixture()
        fixture.serveNone(.hero, game: ArtworkFixture.portID)
        fixture.serve(.hero, game: ArtworkFixture.gameID, asset: 20)

        let file = try #require(await fixture.store.artwork(.hero, for: fixture.entry))
        #expect(file == fixture.paths.artwork(steamgriddb: ArtworkFixture.gameID).appending(path: "hero.png"))
        #expect(fixture.server.requests.count == 2)

        // The Port's empty answer is remembered for a while.
        #expect(await fixture.store.artwork(.hero, for: fixture.entry) == file)
        #expect(fixture.server.requests.count == 2)
    }

    @Test func failuresCacheNothing() async throws {
        let fixture = try ArtworkFixture()
        // A 404 that isn't the Worker's "none", such as a wrong address, isn't taken as having no artwork.
        #expect(await fixture.store.artwork(.logo, for: fixture.entry) == nil)
        fixture.server.set(ArtworkFixture.path(.icon, game: ArtworkFixture.portID), status: 502, body: Data("{}".utf8))
        fixture.server.set(ArtworkFixture.path(.icon, game: ArtworkFixture.gameID), status: 502, body: Data("{}".utf8))
        #expect(await fixture.store.artwork(.icon, for: fixture.entry) == nil)
        let folder = fixture.paths.artwork(steamgriddb: ArtworkFixture.portID)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "logo.json").path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "icon.json").path(percentEncoded: false)))
    }

    @Test func refreshAsksAgainOnlyForStaleArtworkItWasAskedFor() async throws {
        let fixture = try ArtworkFixture()
        fixture.serve(.grid, game: ArtworkFixture.portID, asset: 1)
        _ = try #require(await fixture.store.artwork(.grid, for: fixture.entry))
        let initial = fixture.server.requests.count

        // Fresh: nothing to do.
        await fixture.store.refresh([fixture.entry])
        #expect(fixture.server.requests.count == initial)

        // Stale, same asset: the app names what it has, and the record is renewed without the image.
        fixture.clock.advance(days: 8)
        fixture.serveUnchanged(.grid, game: ArtworkFixture.portID, asset: 1, author: "renamed")
        await fixture.store.refresh([fixture.entry])
        let asked = try #require(fixture.requests(.grid, game: ArtworkFixture.portID).last)
        #expect(asked.value(forHTTPHeaderField: "If-None-Match") == "\"1\"")
        let renewed = try #require(await fixture.store.record(.grid, for: fixture.entry))
        #expect(renewed.fetched == fixture.clock.now())
        #expect(renewed.author == "renamed")
        let file = try #require(await fixture.store.artwork(.grid, for: fixture.entry))
        #expect(try Data(contentsOf: file) == Data("png 1".utf8))

        // Stale, new asset: replaced.
        fixture.clock.advance(days: 8)
        fixture.serve(.grid, game: ArtworkFixture.portID, asset: 2, author: "someone else")
        await fixture.store.refresh([fixture.entry])
        #expect(try Data(contentsOf: try #require(await fixture.store.artwork(.grid, for: fixture.entry))) == Data("png 2".utf8))
        #expect(await fixture.store.record(.grid, for: fixture.entry)?.author == "someone else")

        // Kinds never asked for are never fetched.
        #expect(fixture.server.requests.allSatisfy { $0.url?.path.hasSuffix("/grid") == true })
    }

    @Test func aStaleRefreshThatFailsKeepsTheCachedArtwork() async throws {
        let fixture = try ArtworkFixture()
        fixture.serve(.icon, game: ArtworkFixture.portID, asset: 3)
        let file = try #require(await fixture.store.artwork(.icon, for: fixture.entry))
        fixture.clock.advance(days: 8)
        fixture.server.set(ArtworkFixture.path(.icon, game: ArtworkFixture.portID), status: 502, body: Data())
        await fixture.store.refresh([fixture.entry])
        #expect(await fixture.store.artwork(.icon, for: fixture.entry) == file)
    }

    @Test func concurrentRequestsShareOneFetch() async throws {
        let fixture = try ArtworkFixture()
        fixture.serve(.logo, game: ArtworkFixture.portID, asset: 5)
        let store = fixture.store
        let entry = fixture.entry
        let results = await withTaskGroup(of: URL?.self) { group in
            for _ in 0..<8 { group.addTask { await store.artwork(.logo, for: entry) } }
            return await group.reduce(into: [URL?]()) { $0.append($1) }
        }
        #expect(Set(results).count == 1)
        #expect(results.first! != nil)
        #expect(fixture.server.requests.count == 1)
    }

    @Test func looksUpGamesByTheirOwnEntry() async throws {
        let fixture = try ArtworkFixture()
        fixture.serve(.icon, game: 34302, asset: 7)
        let game = Game(id: "majoras-mask", name: "Majora’s Mask", platform: "n64", steamgriddb: 34302)
        let file = try #require(await fixture.store.artwork(.icon, for: game))
        #expect(file.lastPathComponent == "icon.png")
        #expect(await fixture.store.artwork(.icon, for: Game(id: "x", name: "X", platform: "n64")) == nil)
    }

    @Test func choosesFileExtensionsFromTheMimeType() {
        let source = URL(string: "https://cdn.example/a/b.webp")!
        #expect(ArtworkWorker.fileExtension(mime: "image/jpeg", source: source) == "jpg")
        #expect(ArtworkWorker.fileExtension(mime: "image/png", source: source) == "png")
        #expect(ArtworkWorker.fileExtension(mime: nil, source: source) == "webp")
        #expect(ArtworkWorker.fileExtension(mime: nil, source: nil) == "img")
    }

    @Test func scalesLargeArtworkDownToTheSizeItsShownAt() async throws {
        let fixture = try ArtworkFixture()
        fixture.serve(.hero, game: ArtworkFixture.portID, asset: 30, data: try PNG.make(width: 3840, height: 1240, opaque: true))
        fixture.serve(.logo, game: ArtworkFixture.portID, asset: 31, data: try PNG.make(width: 3000, height: 400, opaque: false))

        let hero = try #require(await fixture.store.artwork(.hero, for: fixture.entry))
        #expect(hero.lastPathComponent == "hero.heic")
        #expect(try PNG.size(of: hero) == (ArtworkKind.hero.maxPixels, 827))
        // A logo keeps its transparency.
        let logo = try #require(await fixture.store.artwork(.logo, for: fixture.entry))
        #expect(logo.lastPathComponent == "logo.png")
        #expect(try PNG.size(of: logo).width == ArtworkKind.logo.maxPixels)
    }

    @Test func compactScalesArtworkCachedAsItCame() async throws {
        let fixture = try ArtworkFixture()
        let folder = fixture.paths.artwork(steamgriddb: ArtworkFixture.portID)
        try FileOperations.createDirectory(folder)
        try PNG.make(width: 3840, height: 1240, opaque: true).write(to: folder.appending(path: "hero.png"))
        try JSON.write(
            ArtworkRecord(kind: .hero, steamgriddb: ArtworkFixture.portID, assetID: 30, file: "hero.png", fetched: fixture.clock.now()),
            to: folder.appending(path: "hero.json"))

        await fixture.store.compact()
        let hero = try #require(await fixture.store.artwork(.hero, for: fixture.entry))
        #expect(hero.lastPathComponent == "hero.heic")
        #expect(try PNG.size(of: hero).width == ArtworkKind.hero.maxPixels)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "hero.png").path(percentEncoded: false)))
        // Already scaled, it's left as it is.
        let stamp = try hero.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        await fixture.store.compact()
        #expect(try hero.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == stamp)
    }
}

/// Real images, for the tests that scale them.
enum PNG {
    static func make(width: Int, height: Int, opaque: Bool) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.3, alpha: opaque ? 1 : 0.5)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func size(of url: URL) throws -> (width: Int, height: Int) {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (properties[kCGImagePropertyPixelWidth] as? Int ?? 0, properties[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }
}
