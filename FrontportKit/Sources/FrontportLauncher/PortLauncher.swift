import AppKit
import Darwin
import FrontportCore
import Foundation

/// Launches Ports by running their main executable directly, so stdout and stderr land in a run log. The
/// sandbox still applies because it lives in the signature.
public actor PortLauncher: PortLaunching {
    /// Run logs kept per Port.
    public static let keptRuns = 5

    private struct Active {
        var run: Run
        let process: Process
    }

    private let paths: AppPaths
    /// The Port's Data, made again with the Redirects' folders before each launch.
    private let data: PortData
    /// Brings forward the Port when it runs started some other way, from the Dock or Finder, and says whether it does.
    private let bringForward: @Sendable (String) -> Bool
    private var active: [String: Active] = [:]
    /// The preparation of each Port's Redirects under way, so a second launch waits for it rather than prime again.
    private var preparing: [PortID: Task<Void, any Error>] = [:]
    private var subscribers: [UUID: AsyncStream<LaunchEvent>.Continuation] = [:]

    /// Inherited variables that describe Frontport itself rather than the Port.
    private static let excludedEnvironment: Set<String> = ["__CFBundleIdentifier", "XPC_SERVICE_NAME", "XPC_FLAGS"]

    public init(paths: AppPaths, primer: (any ContainerPriming)? = nil) {
        self.init(paths: paths, primer: primer) { bundleId in
            guard let other = Self.runningApplications(bundleId).first else { return false }
            other.activate()
            return true
        }
    }

    init(paths: AppPaths, primer: (any ContainerPriming)?, bringForward: @escaping @Sendable (String) -> Bool) {
        self.paths = paths
        data = PortData(paths: paths, primer: primer)
        self.bringForward = bringForward
    }

    public func launch(_ entry: CatalogEntry, installation: Installation) async throws -> Run {
        guard !installation.disabled else {
            throw FrontportError.disabled(entry.id, reason: entry.block(for: installation.release)?.reason ?? "")
        }
        if let run = activate(entry.id) { return run }
        if bringForward(entry.bundleId) { throw FrontportError.running(entry.id) }

        let app = paths.app(for: installation)
        let executable = try Self.mainExecutable(of: app, port: entry.id)
        try await prepareRedirects(in: app, for: entry)
        // The Port may have started while the primer ran: through another launch, or from the Dock.
        if let run = activate(entry.id) { return run }
        if bringForward(entry.bundleId) { throw FrontportError.running(entry.id) }
        try FileOperations.createDirectory(paths.logs(for: entry.id))

        let now = Date()
        let id = Self.runID(now)
        let started = now.wholeSeconds
        let log = paths.runLog(id, for: entry.id)
        guard FileManager.default.createFile(atPath: log.path(percentEncoded: false), contents: nil) else {
            throw FrontportError.fileOperation("Couldn’t create the run log for \(entry.name).")
        }
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }

        let process = Process()
        process.executableURL = executable
        process.arguments = entry.launch.arguments
        var environment = ProcessInfo.processInfo.environment.filter { !Self.excludedEnvironment.contains($0.key) }
        environment.merge(entry.launch.environment) { _, port in port }
        process.environment = environment
        // Where the Dock and Finder start apps.
        process.currentDirectoryURL = URL(filePath: "/", directoryHint: .isDirectory)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            let signaled = process.terminationReason == .uncaughtSignal
            Task { await self?.ended(id, status: status, signaled: signaled) }
        }

        let run = Run(id: id, port: entry.id, release: installation.release.version, started: started, log: log)
        try save(run)
        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: log)
            try? FileManager.default.removeItem(at: paths.runRecord(id, for: entry.id))
            throw FrontportError.processFailed(command: executable.lastPathComponent, status: -1, output: error.localizedDescription)
        }
        active[id] = Active(run: run, process: process)
        publish(.started(run))
        prune(entry.id)
        return run
    }

    public func isRunning(_ entry: CatalogEntry) async -> Bool {
        active.values.contains { $0.run.port == entry.id } || !Self.runningApplications(entry.bundleId).isEmpty
    }

    public func running() async -> Set<PortID> {
        Set(active.values.map(\.run.port))
    }

    public func stop(_ entry: CatalogEntry) async {
        for item in active.values where item.run.port == entry.id {
            let pid = item.process.processIdentifier
            // A quit event lets the Port save; a process that never became an app gets SIGTERM.
            if NSRunningApplication(processIdentifier: pid)?.terminate() != true {
                kill(pid, SIGTERM)
            }
        }
        for app in Self.runningApplications(entry.bundleId)
        where !active.values.contains(where: { $0.process.processIdentifier == app.processIdentifier }) {
            app.terminate()
        }
    }

    public func runs(for port: PortID) async -> [Run] {
        records(for: port).map { run in
            guard run.isRunning, active[run.id] == nil else { return run }
            // Started by an earlier Frontport session, which can't know how it ended.
            var closed = run
            let modified = try? run.log.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            closed.ended = max(modified ?? run.started, run.started).wholeSeconds
            try? save(closed)
            return closed
        }
    }

    public func events() async -> AsyncStream<LaunchEvent> {
        let (stream, continuation) = AsyncStream<LaunchEvent>.makeStream()
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        return stream
    }

    // MARK: Internals

    /// Brings the Port forward when this launcher already runs it, and returns that run.
    private func activate(_ port: PortID) -> Run? {
        guard let existing = active.values.first(where: { $0.run.port == port }) else { return nil }
        NSRunningApplication(processIdentifier: existing.process.processIdentifier)?.activate()
        return existing.run
    }

    private func ended(_ id: String, status: Int32, signaled: Bool) {
        guard var item = active.removeValue(forKey: id) else { return }
        item.run.ended = Date().wholeSeconds
        item.run.exitStatus = status
        item.run.signaled = signaled
        try? save(item.run)
        publish(.ended(item.run))
    }

    private func publish(_ event: LaunchEvent) {
        for subscriber in subscribers.values { subscriber.yield(event) }
    }

    private func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
    }

    private func save(_ run: Run) throws {
        try JSON.write(run, to: paths.runRecord(run.id, for: run.port))
    }

    /// Run records on disk, newest first.
    private func records(for port: PortID) -> [Run] {
        let folder = paths.logs(for: port)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSON.read(Run.self, from: $0) }
            .sorted { $0.started != $1.started ? $0.started > $1.started : $0.id > $1.id }
    }

    /// Keeps the newest `keptRuns` runs, and every run still going.
    private func prune(_ port: PortID) {
        for run in records(for: port).dropFirst(Self.keptRuns) where active[run.id] == nil {
            try? FileManager.default.removeItem(at: paths.runLog(run.id, for: port))
            try? FileManager.default.removeItem(at: paths.runRecord(run.id, for: port))
        }
    }

    /// LaunchServices forgets an app a moment after it exits (and `isTerminated` only updates on the main run
    /// loop), so a process that's gone doesn't count.
    private static func runningApplications(_ bundleId: String) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).filter {
            !$0.isTerminated && (kill($0.processIdentifier, 0) == 0 || errno == EPERM)
        }
    }

    /// Sortable and unique: "20261024-153012-123-a1b2".
    private static func runID(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        let suffix = UUID().uuidString.prefix(4).lowercased()
        return String(
            format: "%04d%02d%02d-%02d%02d%02d-%03d-%@", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!,
            c.nanosecond! / 1_000_000, String(suffix))
    }

    /// The Port may have removed a folder its Redirects lead to, and a cleaner app or Finder its whole Data, so they
    /// come back before each launch, never following a link, with Data first as the Library makes it: otherwise a
    /// Port like `gk` finds its folder's link leading nowhere and tries to make the folder inside its bundle. One
    /// preparation runs per Port at a time, so the primer never runs twice at once for it.
    private func prepareRedirects(in app: URL, for entry: CatalogEntry) async throws {
        if let underway = preparing[entry.id] { return try await underway.value }
        let data = data
        let preparation = Task { try await data.prepareRedirects(of: app, for: entry) }
        preparing[entry.id] = preparation
        defer { preparing[entry.id] = nil }
        try await preparation.value
    }

    /// Read from Info.plist each time: `Bundle` caches by path, and an update swaps a new app in at the same path.
    private static func mainExecutable(of app: URL, port: PortID) throws -> URL {
        let plist = app.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let name = info["CFBundleExecutable"] as? String
        else { throw FrontportError.notInstalled(port) }
        let executable = app.appending(path: "Contents/MacOS/\(name)")
        guard FileManager.default.isExecutableFile(atPath: executable.path(percentEncoded: false)) else {
            throw FrontportError.notInstalled(port)
        }
        return executable
    }
}

extension Date {
    /// Run records store whole seconds; the in-memory Run matches what's on disk.
    fileprivate var wholeSeconds: Date { Date(timeIntervalSinceReferenceDate: timeIntervalSinceReferenceDate.rounded(.down)) }
}
