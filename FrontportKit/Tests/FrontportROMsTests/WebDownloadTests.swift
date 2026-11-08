import Foundation
import FrontportCore
import Synchronization
import Testing
@testable import FrontportROMs

@Suite struct WebDownloadTests {
    /// A freeware game's WAD, as its download serves it.
    static let wad = Data("IWAD".utf8) + Data(repeating: 7, count: 4096)
    static let sha1 = Hashing.sha1(wad)

    func catalog(host: String, size: Int64? = nil) -> CatalogDocument {
        CatalogDocument(
            issued: Date(timeIntervalSince1970: 0),
            platforms: [Platform(id: "dos", name: "MS-DOS", shortName: "DOS", medium: .file)],
            games: [Game(id: "freedoom", name: "Freedoom", platform: "dos")],
            roms: [
                KnownROM(
                    sha1: Self.sha1, game: "freedoom", name: "0.13", format: "wad",
                    download: KnownROM.Download(url: URL(string: "https://\(host)/files/freedoom.wad")!, size: size))
            ],
            ports: [Catalogs.entry("doomport", game: "freedoom", requirements: [
                Requirement(label: "Freedoom", stage: .runtime, oneOf: [Self.sha1], seedPath: "freedoom.wad"),
            ])])
    }

    @Test func aDownloadableROMIsOfferedUntilItIsAdded() async throws {
        let tmp = try TemporaryDirectory()
        let (host, requests) = WebStub.host { _ in (200, Self.wad) }
        let store = ROMStore(paths: tmp.paths, session: WebStub.session())
        #expect(await store.webDownloads(catalog: catalog(host: host)) == [Self.sha1])

        let fractions = Fractions()
        let results = await store.downloadFromWeb(Self.sha1, catalog: catalog(host: host)) { fractions.append($0) }
        guard case .added(let record) = results.first else { Issue.record("\(results)"); return }
        #expect(record.sha1 == Self.sha1)
        #expect(requests.paths == ["/files/freedoom.wad"])
        #expect(fractions.values.last == 1)
        #expect(await store.webDownloads(catalog: catalog(host: host)).isEmpty)
    }

    @Test func aDownloadThatIsntTheROMIsRefused() async throws {
        let tmp = try TemporaryDirectory()
        let (host, _) = WebStub.host { _ in (200, Data("IWAD".utf8) + Data(repeating: 8, count: 4096)) }
        let store = ROMStore(paths: tmp.paths, session: WebStub.session())

        let results = await store.downloadFromWeb(Self.sha1, catalog: catalog(host: host)) { _ in }
        guard case .rejected(_, _, let reason) = results.first, results.count == 1 else { Issue.record("\(results)"); return }
        #expect(reason.contains("isn’t what the Catalog says it is"))
        #expect(await store.webDownloads(catalog: catalog(host: host)) == [Self.sha1])
    }

    @Test func aFailedDownloadSaysWhy() async throws {
        let tmp = try TemporaryDirectory()
        let (host, _) = WebStub.host { _ in (404, Data()) }
        let store = ROMStore(paths: tmp.paths, session: WebStub.session())

        let results = await store.downloadFromWeb(Self.sha1, catalog: catalog(host: host)) { _ in }
        guard case .rejected(_, _, let reason) = results.first else { Issue.record("\(results)"); return }
        #expect(reason.contains("HTTP 404"))
    }

    @Test func aROMTheCatalogDoesntSayWhereToDownloadIsRefused() async throws {
        let tmp = try TemporaryDirectory()
        var catalog = catalog(host: "example.org")
        catalog.roms[0].download = nil
        let store = ROMStore(paths: tmp.paths, session: WebStub.session())
        #expect(await store.webDownloads(catalog: catalog).isEmpty)
        let results = await store.downloadFromWeb(Self.sha1, catalog: catalog) { _ in }
        guard case .rejected = results.first else { Issue.record("\(results)"); return }
    }

    final class Fractions: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [Double] = []
        func append(_ value: Double) { lock.withLock { all.append(value) } }
        var values: [Double] { lock.withLock { all } }
    }
}

/// Answers requests to hosts registered by a test with a status and a body; any other host fails as unreachable.
final class WebStub: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (status: Int, body: Data)

    private static let routes = Mutex<[String: Handler]>([:])

    final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [URLRequest] = []
        func append(_ request: URLRequest) { lock.withLock { all.append(request) } }
        var paths: [String] { lock.withLock { all.compactMap { $0.url?.path() } } }
    }

    static func host(_ handler: @escaping Handler) -> (host: String, requests: Requests) {
        let host = "stub-\(UUID().uuidString.lowercased()).test"
        let requests = Requests()
        routes.withLock {
            $0[host] = { request in
                requests.append(request)
                return handler(request)
            }
        }
        return (host, requests)
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebStub.self]
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host(), let handler = Self.routes.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let (status, body) = handler(request)
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(body.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
