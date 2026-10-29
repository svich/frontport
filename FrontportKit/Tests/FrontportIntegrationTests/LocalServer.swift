import CryptoKit
import Foundation
import Network
import Synchronization

/// A small HTTP/1.1 server on the loopback interface, so tests reach the real modules over real HTTP: one GET per
/// connection, answered from a table of paths the test changes as it goes. Every 200 carries an ETag, and a matching
/// `If-None-Match` gets a 304, as GitHub's API does.
final class LocalServer: Sendable {
    struct Response: Sendable {
        var status: Int
        var body: Data
        var contentType: String

        static func ok(_ body: Data, type: String = "application/octet-stream") -> Response {
            Response(status: 200, body: body, contentType: type)
        }

        static func json(_ body: Data) -> Response { ok(body, type: "application/json") }
    }

    /// One request and how it was answered.
    struct Hit: Sendable, CustomStringConvertible {
        var path: String
        var status: Int
        var description: String { "\(status) \(path)" }
    }

    private let listener: NWListener
    private let table = Table()
    let baseURL: URL

    init() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "LocalServer")
        let table = table
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            Self.read(connection, received: Data(), table: table)
        }
        let ready = Once<CheckedContinuation<UInt16, any Error>>()
        let port = try await withCheckedThrowingContinuation { continuation in
            ready.set(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: ready.take()?.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error): ready.take()?.resume(throwing: error)
                case .cancelled: ready.take()?.resume(throwing: CancellationError())
                default: break
                }
            }
            listener.start(queue: queue)
        }
        self.listener = listener
        baseURL = URL(string: "http://127.0.0.1:\(port)/")!
    }

    deinit { listener.cancel() }

    /// The URL of a path on this server, such as `catalog/catalog.json`.
    func url(_ path: String) -> URL { baseURL.appending(path: path) }

    /// Answers GET `path` (with or without its leading slash) with `response` from now on; nil answers 404.
    func serve(_ path: String, _ response: Response?) {
        table.set(path.hasPrefix("/") ? path : "/" + path, response)
    }

    /// Every request so far, oldest first.
    var hits: [Hit] { table.hits }

    // MARK: Connections

    private static func read(_ connection: NWConnection, received: Data, table: Table) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
            var buffer = received
            if let data { buffer.append(data) }
            guard let end = buffer.firstRange(of: Data("\r\n\r\n".utf8)) else {
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    read(connection, received: buffer, table: table)
                }
                return
            }
            let reply = table.reply(to: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    /// The paths served and the requests received.
    private final class Table: Sendable {
        private struct State {
            var responses: [String: Response] = [:]
            var hits: [Hit] = []
        }

        private let state = Mutex(State())

        func set(_ path: String, _ response: Response?) { state.withLock { $0.responses[path] = response } }

        var hits: [Hit] { state.withLock { $0.hits } }

        /// The raw HTTP response to a request head.
        func reply(to head: String) -> Data {
            let lines = head.components(separatedBy: "\r\n")
            let requestLine = lines.first?.split(separator: " ") ?? []
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let target = requestLine.count >= 2 ? String(requestLine[1]) : "/"
            let path = String(target.split(separator: "?", maxSplits: 1).first ?? "/")

            var status = 404
            var body = Data(#"{"message":"Not Found"}"#.utf8)
            var contentType = "application/json"
            var etag: String?
            if requestLine.first != "GET" {
                status = 405
                body = Data()
            } else if let response = state.withLock({ $0.responses[path] }) {
                (status, body, contentType) = (response.status, response.body, response.contentType)
                if status == 200 {
                    etag = "\"\(SHA256.hash(data: body).prefix(12).map { String(format: "%02x", $0) }.joined())\""
                    if headers["if-none-match"] == etag {
                        status = 304
                        body = Data()
                    }
                }
            }
            state.withLock { $0.hits.append(Hit(path: path, status: status)) }

            let reason = [200: "OK", 304: "Not Modified", 404: "Not Found", 405: "Method Not Allowed"][status] ?? "Status"
            var reply = ["HTTP/1.1 \(status) \(reason)", "Content-Length: \(body.count)", "Content-Type: \(contentType)"]
            if let etag { reply.append("ETag: \(etag)") }
            reply.append("Connection: close")
            return Data((reply.joined(separator: "\r\n") + "\r\n\r\n").utf8) + body
        }
    }
}

/// A value handed out once, from any thread.
final class Once<Value: Sendable>: Sendable {
    private let value = Mutex<Value?>(nil)

    func set(_ newValue: Value) { value.withLock { $0 = newValue } }

    func take() -> Value? { value.withLock { $0.take() } }
}
