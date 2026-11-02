import Foundation
import FrontportCore
import os

/// Xcode's `devicectl`, which reads Devices and installs on them. Each call runs it once with `--timeout` and its JSON
/// written to a file in a private temporary folder, never `-j -`, which `--console` makes unusable. Only what Frontport
/// uses is decoded, every field optional, so fields `devicectl` adds or drops don't break it; its errors pass through in
/// its own words, mapped to a `DeviceProblem`.
public struct DeviceCtl: DeviceControlling {
    /// Runs `devicectl` with `arguments` and returns how it exited; `timeout` is what `--timeout` says. The JSON goes to
    /// the file after `-j`. Tests inject one that writes a fixture there.
    public typealias Runner = @Sendable (_ arguments: [String], _ timeout: Duration) async throws -> ProcessResult

    private let runner: Runner

    public init(runner: @escaping Runner) {
        self.runner = runner
    }

    /// Runs the `devicectl` of `xcode`, stopping it should it outlive its own `--timeout` by `grace`.
    public init(xcode: Xcode, grace: Duration = .seconds(30)) {
        self.init { arguments, timeout in try await Self.run(xcode, arguments, timeout: timeout, grace: grace) }
    }

    /// Runs the `devicectl` of the Xcode that `Xcode.find` finds when it's first needed, not at launch, so Frontport
    /// opens without Xcode, and finds one installed while it's open: a lookup that failed is tried again on the next
    /// call. Every call throws `xcodeMissing` or `noIOSPlatform` while there's none.
    public init(locator: Xcode.Locator = .system, grace: Duration = .seconds(30)) {
        let found = OSAllocatedUnfairLock<Xcode?>(initialState: nil)
        self.init { arguments, timeout in
            let xcode: Xcode
            if let known = found.withLock({ $0 }) {
                xcode = known
            } else {
                xcode = try await Xcode.find(locator)
                found.withLock { $0 = xcode }
            }
            return try await Self.run(xcode, arguments, timeout: timeout, grace: grace)
        }
    }

    private static func run(_ xcode: Xcode, _ arguments: [String], timeout: Duration, grace: Duration) async throws -> ProcessResult {
        try await withDeadline(timeout + grace) {
            try await ProcessRunner().run(xcode.devicectl, arguments: arguments, killAfter: .seconds(5))
        }
    }

    // MARK: DeviceControlling

    public func readings() async throws -> [DeviceReading] {
        let listed = try await call(["list", "devices"], timeout: 30, as: Output.Devices.self)
        let readings = (listed.devices ?? []).compactMap(Self.reading(of:))
        return await withTaskGroup(of: (Int, DeviceReading).self) { group in
            for (index, reading) in readings.enumerated() {
                group.addTask { (index, await lockState(of: reading)) }
            }
            var read = readings
            for await (index, reading) in group { read[index] = reading }
            return read
        }
    }

    public func apps(on device: DeviceID) async throws -> Set<String> {
        let listed = try await call(["device", "info", "apps"], device: device, timeout: 60, as: Output.Apps.self)
        return Set((listed.apps ?? []).filter { $0.builtByDeveloper != false }.compactMap(\.bundleIdentifier))
    }

    public func install(_ app: URL, on device: DeviceID) async throws {
        _ = try await call(
            ["device", "install", "app"], device: device, timeout: 600, positional: [Self.argument(app)],
            as: Output.Installed.self)
    }

    public func uninstall(_ bundleId: String, from device: DeviceID) async throws {
        do {
            _ = try await call(
                ["device", "uninstall", "app"], device: device, timeout: 120, positional: [bundleId],
                as: Output.Uninstalled.self)
        } catch FrontportError.deviceUnavailable(.notInstalled, _) {}
    }

    // MARK: Containers

    /// Lists each folder at the top of the container a seed goes into, at every depth, or the whole container for a
    /// file at its top, then reads each marker with `copy from`. `files --subdirectory` fails for a folder the container
    /// doesn't have yet, so then the container's own listing says what's in it: nothing.
    public func list(
        _ seeds: [StagedSeed], markers: [String], of bundleId: String, on device: DeviceID
    ) async throws -> DeviceListing {
        var tops: [String?] = []
        for seed in seeds {
            let components = seed.path.split(separator: "/").map(String.init)
            let top = seed.isFolder || components.count > 1 ? components.first : nil
            if !tops.contains(top) { tops.append(top) }
        }
        var files: [DeviceFile] = []
        for top in tops {
            do {
                files += try await self.files(of: bundleId, on: device, in: top)
            } catch let error as FrontportError {
                guard case .deviceUnavailable(.failed, _) = error, let top else { throw error }
                files += try await self.files(of: bundleId, on: device, in: nil).filter { $0.path.hasPrefix(top + "/") }
            }
        }
        var listing = DeviceListing(files: files)
        for marker in markers where listing.isFile(marker) {
            listing.markers[marker] = DeviceListing.named(by: try await read(marker, of: bundleId, on: device))
        }
        return listing
    }

    /// Copies `root`'s files into the container, top entry by top entry, then the markers, set aside in a private
    /// temporary folder meanwhile. `copy to` merges a folder into the one there, keeps what's only on the Device, and
    /// skips a file of the same size and modification time, so each file but the markers is dated now, or a little
    /// earlier should the file it replaces in `listing` have that time.
    public func put(
        _ root: URL, markers: [String], over listing: DeviceListing, of bundleId: String, on device: DeviceID
    ) async throws {
        let aside = FileManager.default.temporaryDirectory
            .appending(path: "frontport-devicectl-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileOperations.createDirectory(aside)
        defer { try? FileManager.default.removeItem(at: aside) }
        for marker in markers {
            let destination = aside.appending(path: marker)
            try FileOperations.createDirectory(destination.deletingLastPathComponent())
            try FileManager.default.moveItem(at: root.appending(path: marker), to: destination)
            Self.removeEmpty((marker as NSString).deletingLastPathComponent, in: root)
        }
        let now = Date()
        let names = FileManager.default.enumerator(atPath: root.path(percentEncoded: false))?.allObjects as? [String] ?? []
        for path in names where !FileOperations.isDirectory(root.appending(path: path)) {
            let replaced = listing.files[path]?.modified
            let date = replaced.map { abs($0.timeIntervalSince(now)) < 2 } == true ? now.addingTimeInterval(-2) : now
            try FileManager.default.setAttributes(
                [.modificationDate: date], ofItemAtPath: root.appending(path: path).path(percentEncoded: false))
        }
        for folder in [root, aside] {
            let tops = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
            for top in tops.sorted() {
                try Task.checkCancellation()
                try await copy(folder.appending(path: top), to: top, of: bundleId, on: device)
            }
        }
    }

    /// Removes the folder at `path` in `root` while it's empty, then each folder above it left empty in turn, so a
    /// folder that held only markers isn't copied.
    private static func removeEmpty(_ path: String, in root: URL) {
        var path = path
        while !path.isEmpty {
            let url = root.appending(path: path)
            guard (try? FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false)))?.isEmpty == true,
                (try? FileManager.default.removeItem(at: url)) != nil
            else { return }
            path = (path as NSString).deletingLastPathComponent
        }
    }

    /// What's in the app's container on the Device, or in `subdirectory` of it, with paths relative to the container.
    /// Links are listed as links, so whatever the Port put at a name counts as there.
    public func files(of bundleId: String, on device: DeviceID, in subdirectory: String? = nil) async throws -> [DeviceFile] {
        let listed = try await call(
            ["device", "info", "files"], device: device, timeout: 120,
            options: Self.container(bundleId) + (subdirectory.map { ["--subdirectory", $0] } ?? []), as: Output.Files.self)
        let prefix = subdirectory.map { $0.trimmingCharacters(in: ["/"]) + "/" } ?? ""
        return (listed.files ?? []).compactMap { file in
            guard let path = file.relativePath ?? file.name else { return nil }
            let isLink = file.resources?.isSymbolicLink == true
            return DeviceFile(
                path: prefix + path, isDirectory: !isLink && file.resources?.isDirectory == true,
                size: file.metadata?.size ?? 0, modified: file.metadata?.lastModDate.flatMap(Self.date), isLink: isLink)
        }
    }

    /// Copies a file or folder into the app's container on the Device at `destination`, relative to the container. A
    /// folder merges into one already there; a local file overwrites the Device's unless both have the same size and
    /// modification time.
    public func copy(_ source: URL, to destination: String, of bundleId: String, on device: DeviceID) async throws {
        _ = try await call(
            ["device", "copy", "to"], device: device, timeout: 1800,
            options: Self.container(bundleId) + ["--source", Self.argument(source), "--destination", destination],
            as: Output.Copied.self)
    }

    /// The contents of a small file in the app's container on the Device, copied from it into a private temporary
    /// folder that goes afterwards. Anything over 64 KB is refused.
    public func read(_ path: String, of bundleId: String, on device: DeviceID) async throws -> Data {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "frontport-devicectl-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileOperations.createDirectory(folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appending(path: "file")
        _ = try await call(
            ["device", "copy", "from"], device: device, timeout: 120,
            options: Self.container(bundleId) + ["--source", path, "--destination", Self.argument(destination)],
            as: Output.Copied.self)
        guard (try? FileOperations.size(of: destination)) ?? 0 <= 65_536 else {
            throw FrontportError.deviceUnavailable(.failed, detail: "\(path) is too large to read.")
        }
        do {
            return try FileOperations.readRegularFile(destination)
        } catch {
            throw FrontportError.deviceUnavailable(.failed, detail: "devicectl copied nothing from \(path).")
        }
    }

    // MARK: Processes

    /// The executables running on the Device, by process ID.
    public func processes(on device: DeviceID) async throws -> [Int32: URL] {
        let listed = try await call(["device", "info", "processes"], device: device, timeout: 30, as: Output.Processes.self)
        var processes: [Int32: URL] = [:]
        for process in listed.runningProcesses ?? [] {
            guard let pid = process.processIdentifier, let executable = process.executable.flatMap(URL.init(string:)) else {
                continue
            }
            processes[pid] = executable
        }
        return processes
    }

    // MARK: Running devicectl

    /// Runs one `devicectl` command and decodes its result. `command` is its subcommand words, `options` go after
    /// `--device`, and `positional` arguments come last.
    func call<Result: Decodable>(
        _ command: [String], device: DeviceID? = nil, timeout seconds: Int, options: [String] = [],
        positional: [String] = [], as type: Result.Type
    ) async throws -> Result {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "frontport-devicectl-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileOperations.createDirectory(folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let json = folder.appending(path: "output.json")

        let arguments = command + (device.map { ["--device", $0.rawValue] } ?? []) + options
            + ["--timeout", String(seconds), "-j", json.path(percentEncoded: false)] + positional
        let result: ProcessResult
        do {
            result = try await runner(arguments, .seconds(seconds))
        } catch is CancellationError where !Task.isCancelled {
            throw FrontportError.deviceUnavailable(.away, detail: "devicectl didn’t finish in time.")
        }
        return try Self.decode(Result.self, from: try? Data(contentsOf: json), result: result)
    }

    /// The result in `devicectl`'s JSON, or the error it reports, mapped to a `DeviceProblem`.
    static func decode<Result: Decodable>(_ type: Result.Type, from data: Data?, result: ProcessResult) throws -> Result {
        let envelope = data.flatMap { try? JSONDecoder().decode(Output.Envelope<Result>.self, from: $0) }
        // A timeout comes with an error that only says how devicectl exited.
        if envelope?.info?.outcome == "timeout" {
            let detail = envelope?.info?.details.map { "devicectl: \($0)." } ?? "devicectl gave up waiting for the Device."
            throw FrontportError.deviceUnavailable(.away, detail: detail)
        }
        if let failure = envelope?.error {
            throw FrontportError.deviceUnavailable(problem(of: failure, command: envelope?.info?.commandType), detail: failure.text)
        }
        guard result.succeeded, (envelope?.info?.outcome ?? "success") == "success", let value = envelope?.result else {
            let output = (result.errorOutput.isEmpty ? result.output : result.errorOutput)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = result.succeeded || output.isEmpty ? "devicectl’s output couldn’t be read." : output
            throw FrontportError.deviceUnavailable(.failed, detail: detail)
        }
        return value
    }

    /// What a `devicectl` error means for the user. Its codes are CoreDevice's own, checked on 2026-10-31 with
    /// devicectl 651.32.
    static func problem(of failure: Output.Failure, command: String?) -> DeviceProblem {
        let chain = failure.chain
        if chain.contains(where: { $0.domain == "FBSOpenApplicationErrorDomain" && $0.code == 7 }) { return .locked }
        if failure.domain == "com.apple.dt.CoreDeviceError" && failure.code == 1000 { return .away }
        // A launch of a bundle ID LaunchServices doesn't know, or a copy into a container that doesn't exist.
        if chain.contains(where: {
            ($0.domain == "NSOSStatusErrorDomain" && $0.code == -10814) || $0.domain == "ContainerLookupErrorDomain"
        }) {
            return .notInstalled
        }
        // Listing the files of an app that isn't installed fails with nothing more specific.
        if command == "devicectl.device.info.files", failure.domain == "CoreDevice.ActionError", failure.code == 3 {
            return .notInstalled
        }
        return .failed
    }

    /// The reading a listed Device gives before its lock state is read, or nil for anything but a paired iPhone or iPad.
    static func reading(of listed: Output.ListedDevice) -> DeviceReading? {
        let hardware = listed.properties?.hardware
        let legacy = listed.hardwareProperties
        let connection = listed.properties?.connection
        guard let udid = hardware?.udid ?? legacy?.udid, let type = hardware?.deviceType ?? legacy?.deviceType,
            ["iPhone", "iPad"].contains(type),
            (hardware?.reality ?? legacy?.reality) != "virtual",
            (connection?.pairingState ?? listed.connectionProperties?.pairingState) == "paired"
        else { return nil }

        let device = Device(
            id: DeviceID(udid),
            name: listed.properties?.state?.name ?? listed.deviceProperties?.name ?? udid,
            model: hardware?.marketingName ?? legacy?.marketingName ?? type,
            osVersion: listed.properties?.software?.osVersionNumber?.stringValue
                ?? listed.deviceProperties?.osVersionNumber ?? "",
            families: hardware?.supportedDeviceFamilies ?? legacy?.supportedDeviceFamilies ?? [])
        // Listed while reachable with its tunnel down, since devicectl opens it on demand; away, without a transport.
        let transport = connection?.transportType ?? listed.connectionProperties?.transportType
        let tunnel = connection?.state ?? listed.connectionProperties?.tunnelState
        let reach: DeviceReading.Connection =
            switch transport {
            case _ where tunnel == "unavailable": .away
            case "wired": .wired
            case "localNetwork": .network
            default: .away
            }
        let mode = listed.properties?.state?.developerModeStatus?.state ?? listed.deviceProperties?.developerModeStatus
        return DeviceReading(
            device: device, connection: reach, developerMode: mode == "enabled" ? true : mode == "disabled" ? false : nil)
    }

    /// The reading with its lock state, or away when the Device doesn't answer.
    private func lockState(of reading: DeviceReading) async -> DeviceReading {
        guard reading.isReachable else { return reading }
        var reading = reading
        do {
            let state = try await call(["device", "info", "lockState"], device: reading.device.id, timeout: 15, as: Output.LockState.self)
            reading.isLocked = state.passcodeRequired
        } catch FrontportError.deviceUnavailable(.away, _) {
            reading.connection = .away
        } catch {}
        return reading
    }

    private static func container(_ bundleId: String) -> [String] {
        ["--domain-type", "appDataContainer", "--domain-identifier", bundleId]
    }

    /// A local file or folder as `devicectl` was seen to take it: its path without a trailing slash, which a folder's URL
    /// has.
    static func argument(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// A date as `devicectl` writes it, with or without fractional seconds.
    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

/// Runs `body`, cancelling it after `limit`; then throws `CancellationError`.
func withDeadline<T: Sendable>(_ limit: Duration, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw CancellationError()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
