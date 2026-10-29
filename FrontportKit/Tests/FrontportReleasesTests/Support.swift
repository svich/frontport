import Foundation
import FrontportCore
import Synchronization
import Testing

@testable import FrontportReleases

/// A unique scratch folder, removed when the test drops it.
final class TemporaryDirectory: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "FrontportReleasesTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    // Folder ROMs and some tests leave read-only folders, which a plain removal stops at.
    deinit { try? FileOperations.removeUntrusted(url) }

    func folder(_ name: String) throws -> URL {
        let folder = url.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    var paths: AppPaths {
        AppPaths(
            root: url.appending(path: "Frontport", directoryHint: .isDirectory),
            containers: url.appending(path: "Containers", directoryHint: .isDirectory))
    }
}

// MARK: Stub HTTP

/// What a stubbed request answers.
struct StubResponse: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var body = Data()
    /// Bytes per delivery; nil sends the body at once.
    var chunkSize: Int?
    /// Pause between chunks, so the client sees them one at a time.
    var chunkDelay: TimeInterval = 0
    /// Sends the first chunk, then never finishes until cancelled.
    var stalls = false
    /// Fails the request instead.
    var error: URLError?

    static func json(_ object: Any, headers: [String: String] = [:]) -> StubResponse {
        json(jsonData(object), headers: headers)
    }

    static func json(_ body: Data, headers: [String: String] = [:]) -> StubResponse {
        StubResponse(headers: headers.merging(["Content-Type": "application/json"]) { a, _ in a }, body: body)
    }

    static let notFound = StubResponse(status: 404, body: Data(#"{"message":"Not Found"}"#.utf8))
}

/// Answers requests to hosts registered by tests; any other host fails as unreachable, so tests never touch
/// the network. Each test registers its own host, so tests can run in parallel.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> StubResponse

    private static let routes = Mutex<[String: Handler]>([:])

    /// A new host answered by `handler`, and the requests it received.
    static func host(_ handler: @escaping Handler) -> (host: String, requests: RequestLog) {
        let host = "stub-\(UUID().uuidString.lowercased()).test"
        return (host, route(host, handler))
    }

    /// Answers `host` with `handler` from now on; returns the requests it receives.
    @discardableResult
    static func route(_ host: String, _ handler: @escaping Handler) -> RequestLog {
        let log = RequestLog()
        routes.withLock {
            $0[host] = { request in
                log.append(request)
                return handler(request)
            }
        }
        return log
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
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
        let stub = handler(request)
        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        var headers = stub.headers
        headers["Content-Length"] = String(stub.body.count)
        let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let size = max(stub.chunkSize ?? stub.body.count, 1)
        var offset = 0
        while offset < stub.body.count {
            let end = min(offset + size, stub.body.count)
            client?.urlProtocol(self, didLoad: stub.body.subdata(in: offset..<end))
            offset = end
            if stub.stalls { return }
            if stub.chunkDelay > 0 { Thread.sleep(forTimeInterval: stub.chunkDelay) }
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class RequestLog: Sendable {
    private let storage = Mutex<[URLRequest]>([])

    func append(_ request: URLRequest) { storage.withLock { $0.append(request) } }
    var all: [URLRequest] { storage.withLock { $0 } }
    var count: Int { storage.withLock { $0.count } }
}

// MARK: Progress and cancellation

final class ProgressLog: Sendable {
    private let storage = Mutex<[ProgressUpdate]>([])

    var handler: ProgressHandler { { [self] update in storage.withLock { $0.append(update) } } }
    var all: [ProgressUpdate] { storage.withLock { $0 } }
}

/// Cancels a Task from a progress handler, even one that fires before the Task is known.
final class Canceller<Success: Sendable>: Sendable {
    private struct State {
        var task: Task<Success, any Error>?
        var requested = false
    }

    private let state = Mutex(State())

    func attach(_ task: Task<Success, any Error>) {
        state.withLock {
            $0.task = task
            if $0.requested { task.cancel() }
        }
    }

    func cancel() {
        state.withLock {
            $0.requested = true
            $0.task?.cancel()
        }
    }
}

// MARK: Catalog

func makeEntry(_ releases: ReleaseSource, blocked: [Block] = []) -> CatalogEntry {
    CatalogEntry(
        id: "shipwright", name: "Ship of Harkinian", kind: .decomp, game: "ocarina-of-time",
        developer: "HarbourMasters", summary: "Ocarina of Time, native.", description: "",
        source: URL(string: "https://github.com/HarbourMasters/Shipwright")!,
        bundleId: "dev.frontport.port.shipwright", releases: releases, blocked: blocked)
}

func jsonData(_ object: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

func date(_ iso: String) -> Date {
    try! Date(iso, strategy: .iso8601)
}

// MARK: Processes

@discardableResult
func shell(_ tool: String, _ arguments: [String]) async throws -> ProcessResult {
    try await ProcessRunner().run(URL(filePath: tool), arguments: arguments).check(tool)
}

func path(_ url: URL) -> String { url.path(percentEncoded: false) }

func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: path(url)) }
