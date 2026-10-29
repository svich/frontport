import Foundation
import FrontportCore
import Synchronization

/// A fake HTTP server on its own `.test` host, reached through `StubURLProtocol`. Each test makes its own, so
/// tests can run in parallel.
final class StubServer: Sendable {
    struct Response: Sendable {
        var status: Int
        var body: Data
        var contentType: String?
    }

    let host = "\(UUID().uuidString.lowercased()).test"
    let session: URLSession
    private let routes = Mutex<[String: Response]>([:])
    private let log = Mutex<[URLRequest]>([])

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
        StubURLProtocol.servers.withLock { $0[host] = WeakServer(self) }
    }

    deinit {
        session.finishTasksAndInvalidate()
        let host = host
        StubURLProtocol.servers.withLock { _ = $0.removeValue(forKey: host) }
    }

    /// `https://<host>/<path>`.
    func url(_ path: String = "") -> URL { URL(string: "https://\(host)/\(path)")! }

    func set(_ path: String, status: Int = 200, body: Data, contentType: String? = nil) {
        routes.withLock { $0["/" + path] = Response(status: status, body: body, contentType: contentType) }
    }

    func remove(_ path: String) {
        routes.withLock { _ = $0.removeValue(forKey: "/" + path) }
    }

    /// Requests received so far, oldest first.
    var requests: [URLRequest] { log.withLock { $0 } }

    func requests(to path: String) -> [URLRequest] { requests.filter { $0.url?.path == "/" + path } }

    fileprivate func respond(to request: URLRequest) -> Response {
        log.withLock { $0.append(request) }
        return routes.withLock { $0[request.url?.path ?? ""] } ?? Response(status: 404, body: Data("{}".utf8))
    }
}

private struct WeakServer: Sendable {
    weak var server: StubServer?
    init(_ server: StubServer) { self.server = server }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    fileprivate static let servers = Mutex<[String: WeakServer]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host() ?? ""
        guard let url = request.url, let server = Self.servers.withLock({ $0[host]?.server }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let response = server.respond(to: request)
        var headers: [String: String] = [:]
        if let contentType = response.contentType { headers["Content-Type"] = contentType }
        let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A unique scratch folder, removed when the test drops it.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "FrontportTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    // Folder ROMs and some tests leave read-only folders, which a plain removal stops at.
    deinit { try? FileOperations.removeUntrusted(url) }

    func folder(_ name: String) throws -> URL {
        let folder = url.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
