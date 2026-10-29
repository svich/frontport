import Darwin
import Foundation

/// How a process exited, with whatever output was captured.
public struct ProcessResult: Hashable, Sendable {
    /// Exit status, or the signal number when `signaled`.
    public var status: Int32
    /// True when the process died from an uncaught signal.
    public var signaled: Bool
    /// Captured stdout; empty unless `.capture` was used.
    public var stdout: Data
    /// Captured stderr; empty unless `.capture` was used.
    public var stderr: Data

    public init(status: Int32, signaled: Bool = false, stdout: Data = Data(), stderr: Data = Data()) {
        self.status = status
        self.signaled = signaled
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { !signaled && status == 0 }
    public var output: String { String(decoding: stdout, as: UTF8.self) }
    public var errorOutput: String { String(decoding: stderr, as: UTF8.self) }

    /// Throws `FrontportError.processFailed` unless the process succeeded.
    @discardableResult
    public func check(_ command: String) throws -> ProcessResult {
        guard succeeded else {
            let detail = errorOutput.isEmpty ? output : errorOutput
            throw FrontportError.processFailed(
                command: command, status: status, output: detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return self
    }
}

/// Runs a process asynchronously. Cancelling the calling Task sends SIGTERM to the process's group and then
/// throws `CancellationError` once it has exited.
///
/// `Process` starts each child as the leader of a new process group, which its own children join unless they
/// leave it (`setsid`, or a shell's job control).
public struct ProcessRunner: Sendable {
    /// Where a stream goes.
    public enum Output: Sendable {
        /// Into `ProcessResult.stdout` / `.stderr`.
        case capture
        case discard
        /// Into a file, replacing it.
        case file(URL)
        /// Onto the end of a file, creating it if needed.
        case append(URL)
        /// To a handler, one line at a time without the newline, on a background thread.
        case lines(@Sendable (String) -> Void)
    }

    public init() {}

    /// Runs `executable` to completion. A nil `environment` inherits Frontport's. Stdin is /dev/null.
    /// When stdout and stderr name the same file, they share one handle, interleaved.
    ///
    /// - Parameter killsGroupOnExit: once the process exits, however it ends, SIGKILL whatever is left in its
    ///   process group before waiting for its output to close, so nothing it started in the group outlives it or
    ///   holds the output open.
    /// - Parameter killAfter: once cancelled, SIGKILL the process (its group, when it leads one) if it's still running
    ///   this long after the SIGTERM, so one that ignores SIGTERM can't keep the caller waiting.
    public func run(
        _ executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        stdout: Output = .capture,
        stderr: Output = .capture,
        killsGroupOnExit: Bool = false,
        killAfter: Duration? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardInput = FileHandle.nullDevice

        let out = try Sink(stdout)
        let err: Sink
        if let a = out.fileURL, let b = Sink.fileURL(of: stderr), a.standardizedFileURL == b.standardizedFileURL {
            err = out
        } else {
            err = try Sink(stderr)
        }
        process.standardOutput = out.target
        process.standardError = err.target

        let control = Control(process, killAfter: killAfter)
        let command = executable.lastPathComponent

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, any Error>) in
                let group = DispatchGroup()
                group.enter()
                process.terminationHandler = { _ in
                    if killsGroupOnExit { control.killGroup() }
                    group.leave()
                }
                do {
                    try control.launch()
                } catch {
                    out.close()
                    err.close()
                    if error is CancellationError {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(throwing: FrontportError.processFailed(
                            command: command, status: -1, output: error.localizedDescription))
                    }
                    return
                }
                out.startReading(group)
                if err !== out { err.startReading(group) }
                group.notify(queue: .global()) {
                    out.close()
                    err.close()
                    if control.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    continuation.resume(returning: ProcessResult(
                        status: process.terminationStatus,
                        signaled: process.terminationReason == .uncaughtSignal,
                        stdout: out.data,
                        stderr: err.data))
                }
            }
        } onCancel: {
            control.cancel()
        }
    }
}

/// Serializes launch against cancellation, so a cancelled Task never starts a process and a running one is
/// signalled exactly once.
private final class Control: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private let killAfter: Duration?
    private var launched = false
    private var cancelled = false

    init(_ process: Process, killAfter: Duration?) {
        self.process = process
        self.killAfter = killAfter
    }

    var isCancelled: Bool { lock.withLock { cancelled } }

    func launch() throws {
        try lock.withLock {
            if cancelled { throw CancellationError() }
            try process.run()
            launched = true
        }
    }

    /// SIGKILLs what's left in the group the process led. A group outlives its leader while any member is left, and
    /// no process can take its id until then, so this reaches only the process's own group.
    func killGroup() {
        lock.withLock {
            guard launched else { return }
            killpg(process.processIdentifier, SIGKILL)
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            guard launched, process.isRunning else { return }
            send(SIGTERM)
            guard let killAfter else { return }
            let (seconds, attoseconds) = killAfter.components
            let delay = Double(seconds) + Double(attoseconds) / 1e18
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
                lock.withLock {
                    // Still running, so its id is still its own.
                    if process.isRunning { send(SIGKILL) }
                }
            }
        }
    }

    /// Signals the whole group when the child leads one, so build tools it spawned stop too. Called holding the lock.
    private func send(_ signal: Int32) {
        let pid = process.processIdentifier
        if getpgid(pid) == pid {
            kill(-pid, signal)
        } else {
            kill(pid, signal)
        }
    }
}

/// One output stream: a pipe being drained, a file, or /dev/null.
private final class Sink: @unchecked Sendable {
    let output: ProcessRunner.Output
    let target: Any
    let fileURL: URL?
    private let pipe: Pipe?
    private let handle: FileHandle?
    /// Written by the reader thread before it leaves the group; read after the group completes.
    private(set) var data = Data()

    static func fileURL(of output: ProcessRunner.Output) -> URL? {
        switch output {
        case .file(let url), .append(let url): url
        default: nil
        }
    }

    init(_ output: ProcessRunner.Output) throws {
        self.output = output
        fileURL = Self.fileURL(of: output)
        switch output {
        case .capture, .lines:
            let pipe = Pipe()
            self.pipe = pipe
            handle = nil
            target = pipe
        case .discard:
            pipe = nil
            handle = nil
            target = FileHandle.nullDevice
        case .file(let url), .append(let url):
            let append: Bool
            if case .append = output { append = true } else { append = false }
            if !append || !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                guard FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil) else {
                    throw FrontportError.fileOperation("Couldn’t create \(url.lastPathComponent)")
                }
            }
            let handle = try FileHandle(forWritingTo: url)
            if append { try handle.seekToEnd() }
            pipe = nil
            self.handle = handle
            target = handle
        }
    }

    func startReading(_ group: DispatchGroup) {
        guard let reader = pipe?.fileHandleForReading else { return }
        group.enter()
        let output = output
        DispatchQueue.global(qos: .utility).async {
            switch output {
            case .lines(let handler):
                var buffer = Data()
                while true {
                    let chunk = reader.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        handler(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                        buffer.removeSubrange(buffer.startIndex...newline)
                    }
                }
                if !buffer.isEmpty { handler(String(decoding: buffer, as: UTF8.self)) }
            default:
                self.data = (try? reader.readToEnd()) ?? Data()
            }
            try? reader.close()
            group.leave()
        }
    }

    func close() {
        try? handle?.close()
    }
}
