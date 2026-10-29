import Foundation
import FrontportCore
import Synchronization

/// Streams one HTTP GET into a file, reporting bytes as they arrive. Cancelling the calling Task cancels the
/// request and throws `CancellationError`.
final class Download: NSObject, URLSessionDataDelegate, Sendable {
    /// Bytes received so far and the expected total.
    typealias BytesHandler = @Sendable (_ received: Int64, _ total: Int64) -> Void

    private struct State {
        var received: Int64 = 0
        var total: Int64
        var failure: (any Error)?
        var continuation: CheckedContinuation<Void, any Error>?
        var finished = false
    }

    private let name: String
    private let handle: FileHandle
    private let onBytes: BytesHandler
    private let state: Mutex<State>

    private init(name: String, handle: FileHandle, expectedSize: Int64, onBytes: @escaping BytesHandler) {
        self.name = name
        self.handle = handle
        self.onBytes = onBytes
        state = Mutex(State(total: max(expectedSize, 0)))
    }

    /// Downloads `url` into `file`, replacing it.
    static func run(
        _ url: URL, to file: URL, name: String, session: URLSession, expectedSize: Int64,
        onBytes: @escaping BytesHandler
    ) async throws {
        try Task.checkCancellation()
        guard FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: nil) else {
            throw FrontportError.fileOperation("Couldn’t create \(file.lastPathComponent).")
        }
        let handle = try FileHandle(forWritingTo: file)
        let delegate = Download(name: name, handle: handle, expectedSize: expectedSize, onBytes: onBytes)

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("Frontport", forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request)
        task.delegate = delegate

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                delegate.state.withLock { $0.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            fail(FrontportError.network("Downloading \(name) failed (HTTP \(http.statusCode))."))
            completionHandler(.cancel)
            return
        }
        if response.expectedContentLength > 0 {
            state.withLock { $0.total = response.expectedContentLength }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle.write(contentsOf: data)
        } catch {
            fail(FrontportError.fileOperation("Couldn’t save \(name): \(error.localizedDescription)"))
            dataTask.cancel()
            return
        }
        let (received, total) = state.withLock { state in
            state.received += Int64(data.count)
            return (state.received, state.total)
        }
        onBytes(received, total)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        try? handle.close()
        let (continuation, failure) = state.withLock { state -> (CheckedContinuation<Void, any Error>?, (any Error)?) in
            guard !state.finished else { return (nil, nil) }
            state.finished = true
            defer { state.continuation = nil }
            return (state.continuation, state.failure)
        }
        guard let continuation else { return }
        if let failure {
            continuation.resume(throwing: failure)
        } else if let error {
            if (error as? URLError)?.code == .cancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                continuation.resume(throwing: FrontportError.network(
                    "Downloading \(name) failed. \(error.localizedDescription)"))
            }
        } else {
            continuation.resume()
        }
    }

    private func fail(_ error: any Error) {
        state.withLock { if $0.failure == nil { $0.failure = error } }
    }
}
