import Foundation
import FrontportCore
import Synchronization
import Testing
@testable import FrontportArtwork

final class MemoryKeyStore: APIKeyStoring {
    let key: Mutex<String?>
    init(_ key: String? = nil) { self.key = Mutex(key) }
    func read() throws -> String? { key.withLock { $0 } }
    func write(_ key: String?) throws { self.key.withLock { $0 = key } }
}

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
    let keys: MemoryKeyStore
    let clock = TestClock()
    let store: ArtworkStore

    init(key: String? = "secret", builtInKey: String? = nil) throws {
        directory = try TemporaryDirectory()
        paths = AppPaths(root: try directory.folder("Frontport"), containers: try directory.folder("Containers"))
        keys = MemoryKeyStore(key)
        let clock = clock
        store = ArtworkStore(
            paths: paths, keyStore: keys, builtInKey: builtInKey, session: server.session, apiBase: server.url("api/v2/"),
            now: { clock.now() })
    }

    var entry: CatalogEntry {
        CatalogEntry(
            id: "shipwright", name: "Ship of Harkinian", kind: .decomp, game: "ocarina-of-time",
            developer: "HarbourMasters", summary: "", description: "",
            source: URL(string: "https://github.com/HarbourMasters/Shipwright")!, bundleId: "dev.frontport.port.shipwright",
            releases: .githubRelease(GitHubReleaseSource(repo: "HarbourMasters/Shipwright", asset: "SoH-*-Mac.zip")),
            artwork: Artwork(steamgriddb: Self.portID, fallback: Self.gameID))
    }

    /// Serves `images` (id, width, height) for a kind and game, each downloadable as PNG bytes of its id.
    func serve(_ kind: String, game: Int, _ images: [(id: Int, width: Int, height: Int)], author: String = "artist") {
        let data = images.map { image in
            """
            { "id": \(image.id), "score": 0, "style": "alternate", "width": \(image.width), "height": \(image.height),
              "nsfw": false, "humor": false, "mime": "image/png", "language": "en",
              "url": "\(server.url("file/\(image.id).png"))", "thumb": "\(server.url("thumb/\(image.id).png"))",
              "lock": false, "epilepsy": false, "upvotes": 0, "downvotes": 0,
              "author": { "name": "\(author)", "steam64": "1", "avatar": "https://example.org/a.png" } }
            """
        }
        server.set("api/v2/\(kind)/game/\(game)", body: Data(#"{ "success": true, "data": [\#(data.joined(separator: ","))] }"#.utf8))
        for image in images {
            server.set("file/\(image.id).png", body: Data("png \(image.id)".utf8), contentType: "image/png")
        }
    }

    func apiRequests() -> [URLRequest] { server.requests.filter { $0.url?.path.hasPrefix("/api/") == true } }
}

@Suite struct ArtworkStoreTests {
    @Test(arguments: [nil, "", " \n"])
    func withoutAKeyNeverCallsTheAPI(builtInKey: String?) async throws {
        // A build without a key of its own has an empty one in its Info.plist.
        let fixture = try ArtworkFixture(key: nil, builtInKey: builtInKey)
        fixture.serve("grids", game: ArtworkFixture.portID, [(1, 920, 430)])
        #expect(await fixture.store.artwork(.grid, for: fixture.entry) == nil)
        await fixture.store.refresh([fixture.entry])
        #expect(fixture.server.requests.isEmpty)
        #expect(await fixture.store.apiKeySource() == nil)
    }

    @Test func usesTheBuiltInKeyUntilTheUserSavesOne() async throws {
        let fixture = try ArtworkFixture(key: nil, builtInKey: " frontport\n")
        fixture.serve("grids", game: ArtworkFixture.portID, [(1, 920, 430)])
        fixture.serve("logos", game: ArtworkFixture.portID, [(2, 800, 300)])
        fixture.serve("icons", game: ArtworkFixture.portID, [(3, 256, 256)])
        #expect(await fixture.store.apiKeySource() == .builtIn)
        _ = try #require(await fixture.store.artwork(.grid, for: fixture.entry))
        #expect(fixture.apiRequests().last?.value(forHTTPHeaderField: "Authorization") == "Bearer frontport")

        try await fixture.store.setAPIKey("mine")
        #expect(await fixture.store.apiKeySource() == .user)
        _ = try #require(await fixture.store.artwork(.logo, for: fixture.entry))
        #expect(fixture.apiRequests().last?.value(forHTTPHeaderField: "Authorization") == "Bearer mine")

        // Removing the user's key goes back to the built-in one.
        try await fixture.store.setAPIKey(nil)
        #expect(await fixture.store.apiKeySource() == .builtIn)
        _ = try #require(await fixture.store.artwork(.icon, for: fixture.entry))
        #expect(fixture.apiRequests().last?.value(forHTTPHeaderField: "Authorization") == "Bearer frontport")
    }

    @Test func withoutAKeyStillReturnsCachedArtwork() async throws {
        let fixture = try ArtworkFixture()
        fixture.serve("grids", game: ArtworkFixture.portID, [(1, 920, 430)])
        let cached = try #require(await fixture.store.artwork(.grid, for: fixture.entry))

        try await fixture.store.setAPIKey(nil)
        let requests = fixture.server.requests.count
        #expect(await fixture.store.artwork(.grid, for: fixture.entry) == cached)
        #expect(fixture.server.requests.count == requests)
    }

    @Test func fetchesTheLandscapeGridOfThePortsOwnEntry() async throws {
        let fixture = try ArtworkFixture()
        fixture.serve("grids", game: ArtworkFixture.portID, [(10, 460, 215), (11, 920, 430), (12, 920, 430)])

        let file = try #require(await fixture.store.artwork(.grid, for: fixture.entry))
        #expect(file == fixture.paths.artwork(steamgriddb: ArtworkFixture.portID).appending(path: "grid.png"))
        #expect(try Data(contentsOf: file) == Data("png 11".utf8))

        let api = try #require(fixture.apiRequests().first)
        #expect(api.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(api.value(forHTTPHeaderField: "User-Agent") == "Frontport")
        let apiURL = try #require(api.url)
        let query = try #require(URLComponents(url: apiURL, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains(URLQueryItem(name: "dimensions", value: "920x430,460x215")))
        #expect(query.contains(URLQueryItem(name: "types", value: "static")))
        #expect(query.contains(URLQueryItem(name: "nsfw", value: "false")))
        // The key goes only to the API, never to the image host.
        let download = try #require(fixture.server.requests(to: "file/11.png").first)
        #expect(download.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(download.value(forHTTPHeaderField: "User-Agent") == "Frontport")

        let record = try #require(await fixture.store.record(.grid, for: fixture.entry))
        #expect(record.assetID == 11)
        #expect(record.author == "artist")
        #expect(record.fetched == fixture.clock.now())

        // Cached: no more requests.
        let count = fixture.server.requests.count
        #expect(await fixture.store.artwork(.grid, for: fixture.entry) == file)
        #expect(fixture.server.requests.count == count)
    }

    @Test func fallsBackToTheGameWhenThePortHasNone() async throws {
        let fixture = try ArtworkFixture()
        fixture.serve("heroes", game: ArtworkFixture.portID, [])
        fixture.serve("heroes", game: ArtworkFixture.gameID, [(20, 1920, 620)])

        let file = try #require(await fixture.store.artwork(.hero, for: fixture.entry))
        #expect(file == fixture.paths.artwork(steamgriddb: ArtworkFixture.gameID).appending(path: "hero.png"))
        #expect(fixture.apiRequests().count == 2)

        // The Port's empty answer is remembered for a while.
        #expect(await fixture.store.artwork(.hero, for: fixture.entry) == file)
        #expect(fixture.apiRequests().count == 2)
    }

    @Test func unknownGamesAndRejectedKeysCacheNothingUseful() async throws {
        let fixture = try ArtworkFixture()
        // Nothing served: SteamGridDB answers 404, meaning it has no such game.
        #expect(await fixture.store.artwork(.logo, for: fixture.entry) == nil)

        fixture.server.set("api/v2/icons/game/\(ArtworkFixture.portID)", status: 401, body: Data("{}".utf8))
        fixture.server.set("api/v2/icons/game/\(ArtworkFixture.gameID)", status: 401, body: Data("{}".utf8))
        #expect(await fixture.store.artwork(.icon, for: fixture.entry) == nil)
        let folder = fixture.paths.artwork(steamgriddb: ArtworkFixture.portID)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "icon.json").path(percentEncoded: false)))
    }

    @Test func refreshRefetchesOnlyStaleArtworkItWasAskedFor() async throws {
        let fixture = try ArtworkFixture()
        fixture.serve("grids", game: ArtworkFixture.portID, [(1, 920, 430)])
        _ = try #require(await fixture.store.artwork(.grid, for: fixture.entry))
        let initial = fixture.server.requests.count

        // Fresh: nothing to do.
        await fixture.store.refresh([fixture.entry])
        #expect(fixture.server.requests.count == initial)

        // Stale, same asset: the record is renewed without downloading the image again.
        fixture.clock.advance(days: 8)
        await fixture.store.refresh([fixture.entry])
        #expect(fixture.apiRequests().count == 2)
        #expect(fixture.server.requests(to: "file/1.png").count == 1)
        #expect(await fixture.store.record(.grid, for: fixture.entry)?.fetched == fixture.clock.now())

        // Stale, new asset: replaced.
        fixture.clock.advance(days: 8)
        fixture.serve("grids", game: ArtworkFixture.portID, [(2, 920, 430)], author: "someone else")
        await fixture.store.refresh([fixture.entry])
        let file = try #require(await fixture.store.artwork(.grid, for: fixture.entry))
        #expect(try Data(contentsOf: file) == Data("png 2".utf8))
        #expect(await fixture.store.record(.grid, for: fixture.entry)?.author == "someone else")

        // Kinds never asked for are never fetched.
        #expect(fixture.server.requests.allSatisfy { $0.url?.path.contains("/grids/") == true || $0.url?.path.hasPrefix("/file/") == true })
    }

    @Test func concurrentRequestsShareOneFetch() async throws {
        let fixture = try ArtworkFixture()
        fixture.serve("logos", game: ArtworkFixture.portID, [(5, 800, 300)])
        let store = fixture.store
        let entry = fixture.entry
        let results = await withTaskGroup(of: URL?.self) { group in
            for _ in 0..<8 { group.addTask { await store.artwork(.logo, for: entry) } }
            return await group.reduce(into: [URL?]()) { $0.append($1) }
        }
        #expect(Set(results).count == 1)
        #expect(results.first! != nil)
        #expect(fixture.apiRequests().count == 1)
    }

    @Test func looksUpGamesByTheirOwnEntry() async throws {
        let fixture = try ArtworkFixture()
        fixture.serve("icons", game: 34302, [(7, 256, 256)])
        let game = Game(id: "majoras-mask", name: "Majora’s Mask", platform: "n64", steamgriddb: 34302)
        let file = try #require(await fixture.store.artwork(.icon, for: game))
        #expect(file.lastPathComponent == "icon.png")
        let query = try #require(fixture.apiRequests().first?.url?.query())
        #expect(query.contains("mimes=image/png"))
        #expect(await fixture.store.artwork(.icon, for: Game(id: "x", name: "X", platform: "n64")) == nil)
    }

    @Test func storesTheKeyInItsKeyStore() async throws {
        let fixture = try ArtworkFixture(key: nil)
        try await fixture.store.setAPIKey("  abc \n")
        #expect(try fixture.keys.read() == "abc")
        #expect(await fixture.store.apiKeySource() == .user)
        try await fixture.store.setAPIKey("")
        #expect(try fixture.keys.read() == nil)
        #expect(await fixture.store.apiKeySource() == nil)
    }

    @Test func choosesFileExtensionsFromTheMimeType() {
        let url = URL(string: "https://cdn.example/a/b.webp")!
        #expect(SteamGridDB.fileExtension(mime: "image/jpeg", url: url) == "jpg")
        #expect(SteamGridDB.fileExtension(mime: "image/png", url: url) == "png")
        #expect(SteamGridDB.fileExtension(mime: nil, url: url) == "webp")
    }
}
