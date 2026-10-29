import Foundation
import FrontportCore

/// Turns Recipe output into progress: ninja's `[n/m]` lines, CMake's `[ nn%]` lines, and `==> ` lines a
/// Recipe prints to name the step it's on.
struct BuildProgressParser: Sendable {
    var phase: ProgressUpdate.Phase
    /// The latest `==> ` step, shown instead of individual compile lines.
    private(set) var stage: String?

    init(phase: ProgressUpdate.Phase) { self.phase = phase }

    mutating func parse(_ line: String) -> ProgressUpdate? {
        if line.hasPrefix("==> ") {
            let stage = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
            self.stage = stage.isEmpty ? nil : stage
            return ProgressUpdate(phase, fraction: nil, message: self.stage)
        }
        if let match = line.wholeMatch(of: /\[(\d+)\/(\d+)\]\s*(.*)/), let done = Double(match.1), let total = Double(match.2),
            total > 0
        {
            return ProgressUpdate(phase, fraction: min(done / total, 1), message: stage ?? String(match.3))
        }
        if let match = line.wholeMatch(of: /\[\s*(\d{1,3})%\]\s*(.*)/), let percent = Double(match.1) {
            return ProgressUpdate(phase, fraction: min(percent / 100, 1), message: stage ?? String(match.2))
        }
        return nil
    }
}

/// Appends a step's output to the build log, one line at a time, and reports progress parsed from it.
/// Called from the process's reader threads.
final class BuildOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private var parser: BuildProgressParser
    private let progress: ProgressHandler
    private var lastReport = ContinuousClock.now
    private var lastFraction: Double?

    /// Opens `log` for appending, creating it and its folder if needed. Refuses a link.
    init(log: URL, phase: ProgressUpdate.Phase, progress: @escaping ProgressHandler) throws {
        try FileOperations.createDirectory(log.deletingLastPathComponent())
        handle = try FileOperations.openForAppending(log)
        parser = BuildProgressParser(phase: phase)
        self.progress = progress
    }

    /// Starts `log` afresh, so it holds only the run about to begin, both of its steps, rather than every run before
    /// it. A link there is removed, never followed.
    static func restart(_ log: URL) throws {
        guard unlink(log.path(percentEncoded: false)) != 0, errno != ENOENT else { return }
        let code = errno
        throw FrontportError.fileOperation("Couldn’t start \(log.lastPathComponent) afresh: \(String(cString: strerror(code)))")
    }

    func close() {
        lock.withLock { try? handle.close() }
    }

    /// A timestamped line from Frontport itself rather than the Recipe.
    func note(_ text: String) {
        write("[frontport \(Date().formatted(.iso8601))] \(text)")
    }

    func consume(_ line: String) {
        write(line)
        let update: ProgressUpdate? = lock.withLock {
            guard let update = parser.parse(line) else { return nil }
            // A build prints thousands of lines; report steps, completion and at most ten updates a second.
            let now = ContinuousClock.now
            let isStage = update.fraction == nil
            guard isStage || update.fraction == 1 || lastFraction == nil || now - lastReport >= .milliseconds(100) else {
                return nil
            }
            lastReport = now
            lastFraction = update.fraction
            return update
        }
        if let update { progress(update) }
    }

    private func write(_ line: String) {
        lock.withLock { try? handle.write(contentsOf: Data((line + "\n").utf8)) }
    }
}
