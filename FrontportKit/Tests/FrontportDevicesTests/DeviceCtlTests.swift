import Foundation
import FrontportCore
import Synchronization
import Testing
@testable import FrontportDevices

/// `devicectl`'s JSON, as the Device spikes saved it (sanitized), read through a runner that writes it where `-j` says.
enum Fixtures {
    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static var names: [String] {
        let folder = Bundle.module.resourceURL!.appending(path: "Fixtures", directoryHint: .isDirectory)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    /// The UDID the fixtures name.
    static let udid: DeviceID = "00000000-0000000000000000"
}

/// Answers each `devicectl` run with the next fixture, written to the file after `-j`, and keeps the arguments.
final class FakeDeviceCtl: Sendable {
    struct Answer: Sendable {
        var json: Data?
        var status: Int32 = 0
        var stderr = ""
        /// Written where `--destination` says, as `copy from` does.
        var contents: Data?

        /// A fixture's JSON, failing as `devicectl` does when it holds an error.
        static func fixture(_ name: String, contents: Data? = nil) throws -> Answer {
            let data = try Fixtures.data(name)
            let failed = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] != nil
            return Answer(json: data, status: failed ? 1 : 0, contents: contents)
        }
    }

    private let state: Mutex<(answers: [Answer], calls: [[String]])>

    init(_ answers: [Answer]) {
        state = Mutex((answers, []))
    }

    convenience init(fixtures: [String], editing edit: (String) -> String = { $0 }) throws {
        try self.init(fixtures.map { name in
            let data = Data(edit(String(decoding: try Fixtures.data(name), as: UTF8.self)).utf8)
            let failed = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] != nil
            return Answer(json: data, status: failed ? 1 : 0)
        })
    }

    var calls: [[String]] { state.withLock { $0.calls } }

    var devicectl: DeviceCtl {
        DeviceCtl { arguments, _ in
            let answer = self.state.withLock { state -> Answer in
                state.calls.append(arguments)
                return state.answers.isEmpty ? Answer(json: nil, status: 1, stderr: "no answer") : state.answers.removeFirst()
            }
            if let json = answer.json, let index = arguments.firstIndex(of: "-j") {
                try json.write(to: URL(filePath: arguments[index + 1]))
            }
            if let contents = answer.contents, let index = arguments.firstIndex(of: "--destination") {
                try contents.write(to: URL(filePath: arguments[index + 1]))
            }
            return ProcessResult(status: answer.status, stderr: Data(answer.stderr.utf8))
        }
    }
}

/// Keeps each `copy to`'s arguments, destination, and the files its source held as it ran, with their modification
/// dates, by path within the source.
final class Sources: Sendable {
    struct Call: Sendable {
        var arguments: [String]
        var destination: String
        var files: [String: Date]
    }

    private let state = Mutex<[Call]>([])

    var calls: [Call] { state.withLock { $0 } }

    func record(_ arguments: [String]) {
        let value = { (option: String) in arguments.firstIndex(of: option).map { arguments[$0 + 1] } ?? "" }
        let source = URL(filePath: value("--source"))
        var files: [String: Date] = [:]
        let names = FileManager.default.enumerator(atPath: source.path(percentEncoded: false))?.allObjects as? [String] ?? []
        for name in names.isEmpty ? [""] : names {
            let url = name.isEmpty ? source : source.appending(path: name)
            guard !FileOperations.isDirectory(url),
                let date = (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.modificationDate] as? Date
            else { continue }
            files[name.isEmpty ? source.lastPathComponent : name] = date
        }
        state.withLock { $0.append(Call(arguments: arguments, destination: value("--destination"), files: files)) }
    }
}

/// Answers `devicectl device copy from` with a fixture and, unless it's an error, writes `contents` where
/// `--destination` says, as `devicectl` does.
final class CopyingFrom: Sendable {
    private let json: Data
    private let contents: Data
    private let failed: Bool
    private let state = Mutex<[[String]]>([])

    init(_ fixture: String, contents: Data) throws {
        json = try Fixtures.data(fixture)
        self.contents = contents
        failed = (try JSONSerialization.jsonObject(with: json) as? [String: Any])?["error"] != nil
    }

    var calls: [[String]] { state.withLock { $0 } }

    var devicectl: DeviceCtl {
        DeviceCtl { arguments, _ in
            self.state.withLock { $0.append(arguments) }
            if let index = arguments.firstIndex(of: "-j") { try self.json.write(to: URL(filePath: arguments[index + 1])) }
            if !self.failed, let index = arguments.firstIndex(of: "--destination") {
                try self.contents.write(to: URL(filePath: arguments[index + 1]))
            }
            return ProcessResult(status: self.failed ? 1 : 0, stderr: Data())
        }
    }
}

@Suite struct DeviceCtlTests {
    /// The `DeviceProblem` and detail a call throws, or nil when it doesn't throw `deviceUnavailable`.
    func problem(_ body: () async throws -> Void) async -> (DeviceProblem, String)? {
        do {
            try await body()
        } catch FrontportError.deviceUnavailable(let problem, let detail) {
            return (problem, detail)
        } catch {
            Issue.record("unexpected \(error)")
        }
        return nil
    }

    // MARK: Readings

    @Test func readsAPairedIPhoneOverTheNetworkAndItsLockState() async throws {
        let fake = try FakeDeviceCtl(fixtures: ["devices-network-connected", "lockstate-locked"])
        let readings = try await fake.devicectl.readings()
        #expect(readings == [
            DeviceReading(
                device: Device(id: Fixtures.udid, name: "Test User’s iPhone", model: "iPhone 13", osVersion: "27.0.1", families: [1]),
                connection: .network, isLocked: true, developerMode: true)
        ])
        #expect(fake.calls.count == 2)
        #expect(fake.calls[0].starts(with: ["list", "devices"]))
        #expect(fake.calls[1].starts(with: ["device", "info", "lockState", "--device", Fixtures.udid.rawValue]))
    }

    @Test func unlocked() async throws {
        let fake = try FakeDeviceCtl(fixtures: ["devices-network-disconnected", "lockstate-unlocked"])
        #expect(try await fake.devicectl.readings().map(\.isLocked) == [false])
    }

    @Test func overUSB() async throws {
        let fake = try FakeDeviceCtl(fixtures: ["devices-network-connected", "lockstate-unlocked"]) {
            $0.replacingOccurrences(of: "\"localNetwork\"", with: "\"wired\"")
        }
        #expect(try await fake.devicectl.readings().map(\.connection) == [.wired])
    }

    @Test func awayWithoutATransportAndNotAskedForItsLockState() async throws {
        let fake = try FakeDeviceCtl(fixtures: ["devices-network-connected"]) {
            $0.replacingOccurrences(of: "\"transportType\": \"localNetwork\",", with: "")
                .replacingOccurrences(of: "\"tunnelState\": \"disconnected\"", with: "\"tunnelState\": \"unavailable\"")
        }
        let readings = try await fake.devicectl.readings()
        #expect(readings.map(\.connection) == [.away])
        #expect(readings.map(\.isLocked) == [nil])
        #expect(fake.calls.count == 1)
    }

    @Test func awayWhenItDoesntAnswerForItsLockState() async throws {
        let fake = try FakeDeviceCtl(fixtures: ["devices-network-connected", "error-install-unknown-device"])
        let readings = try await fake.devicectl.readings()
        #expect(readings.map(\.connection) == [.away])
        #expect(readings.map(\.isLocked) == [nil])
    }

    @Test func developerModeOff() async throws {
        let fake = try FakeDeviceCtl(fixtures: ["devices-network-connected", "lockstate-unlocked"]) {
            $0.replacingOccurrences(of: "\"enabled\": {", with: "\"disabled\": {")
                .replacingOccurrences(of: "\"developerModeStatus\": \"enabled\"", with: "\"developerModeStatus\": \"disabled\"")
        }
        #expect(try await fake.devicectl.readings().map(\.developerMode) == [false])
    }

    @Test(arguments: [
        ("\"deviceType\": \"iPhone\"", "\"deviceType\": \"appleWatch\""),
        ("\"pairingState\": \"paired\"", "\"pairingState\": \"unpaired\""),
        ("\"reality\": \"physical\"", "\"reality\": \"virtual\""),
    ])
    func listsOnlyPairedIPhonesAndIPads(_ field: String, _ edited: String) async throws {
        let fake = try FakeDeviceCtl(fixtures: ["devices-network-connected"]) {
            $0.replacingOccurrences(of: field, with: edited)
        }
        #expect(try await fake.devicectl.readings().isEmpty)
    }

    // MARK: Apps

    @Test func appsByBundleID() async throws {
        let fake = try FakeDeviceCtl(fixtures: ["apps", "apps-after-uninstall"])
        #expect(try await fake.devicectl.apps(on: Fixtures.udid) == ["dev.frontport.port.spikeapp.a1b2c3d4e5"])
        #expect(try await fake.devicectl.apps(on: Fixtures.udid).isEmpty)
    }

    @Test func installsWithTheAppLast() async throws {
        let fake = try FakeDeviceCtl(fixtures: ["install-app"])
        try await fake.devicectl.install(URL(filePath: "/tmp/Spike.app", directoryHint: .isDirectory), on: Fixtures.udid)
        let arguments = try #require(fake.calls.first)
        #expect(Array(arguments.prefix(7)) == ["device", "install", "app", "--device", Fixtures.udid.rawValue, "--timeout", "600"])
        // Without the folder URL's trailing slash, as the spikes ran it.
        #expect(arguments.last == "/tmp/Spike.app")
    }

    @Test func installOnADeviceThatIsntThere() async throws {
        let fake = try FakeDeviceCtl(fixtures: ["error-install-unknown-device"])
        let failure = await problem { try await fake.devicectl.install(URL(filePath: "/tmp/Spike.app"), on: Fixtures.udid) }
        #expect(failure?.0 == .away)
        #expect(failure?.1 == "The specified device was not found. (Name: 00000000-0000000000000000)")
    }

    @Test func uninstallingAnAppThatIsntInstalledSucceeds() async throws {
        let fake = try FakeDeviceCtl(fixtures: ["uninstall", "uninstall-not-installed-succeeds", "error-launch-not-installed"])
        for _ in 0..<3 {
            try await fake.devicectl.uninstall("dev.frontport.port.spikeapp.a1b2c3d4e5", from: Fixtures.udid)
        }
        #expect(fake.calls.allSatisfy { $0.last == "dev.frontport.port.spikeapp.a1b2c3d4e5" })
    }

    // MARK: Containers and processes

    @Test func filesRelativeToTheContainer() async throws {
        let fake = try FakeDeviceCtl(fixtures: ["files-documents-merged"])
        let files = try await fake.devicectl.files(of: "dev.frontport.port.spikeapp.a1b2c3d4e5", on: Fixtures.udid, in: "Documents")
        let arguments = try #require(fake.calls.first)
        #expect(arguments.contains("--subdirectory"))
        #expect(files.first == DeviceFile(
            path: "Documents/single.txt", isDirectory: false, size: 12, modified: DeviceCtl.date("2026-10-31T17:27:00Z")))
        #expect(files.contains { $0.path == "Documents/x" && $0.isDirectory })
        #expect(files.contains { $0.path == "Documents/x/.frontport-rom" })
        #expect(files.first?.modified != nil)
    }

    @Test func filesKeepsSymbolicLinks() async throws {
        // single.txt as a link the Port made in its place: Seeding counts it as there.
        let fake = try FakeDeviceCtl(fixtures: ["files-documents-merged"]) { json in
            guard let range = json.range(of: "\"isSymbolicLink\": false") else { return json }
            return json.replacingCharacters(in: range, with: "\"isSymbolicLink\": true")
        }
        let files = try await fake.devicectl.files(of: "dev.frontport.port.spikeapp.a1b2c3d4e5", on: Fixtures.udid, in: "Documents")
        #expect(files.contains { $0.path == "Documents/single.txt" && $0.isLink && !$0.isDirectory && $0.size == 12 })
        #expect(files.filter(\.isLink).count == 1)
    }

    @Test func filesOfTheWholeContainerAndABigFolder() async throws {
        let fake = try FakeDeviceCtl(fixtures: ["files-container-root", "files-subdirectory", "files-empty"])
        let root = try await fake.devicectl.files(of: "b", on: Fixtures.udid)
        #expect(root.map(\.path).contains("Library/Preferences"))
        let big = try await fake.devicectl.files(of: "b", on: Fixtures.udid, in: "Documents/big")
        #expect(big.count == 204)
        #expect(big.first?.path == "Documents/big/big1.dat")
        #expect(big.first?.size == 62_914_560)
        #expect(try await fake.devicectl.files(of: "b", on: Fixtures.udid, in: "Documents").isEmpty)
    }

    @Test func filesOfAnAppThatIsntInstalled() async throws {
        let fake = try FakeDeviceCtl(fixtures: ["error-files-app-not-installed"])
        let failure = await problem { _ = try await fake.devicectl.files(of: "b", on: Fixtures.udid) }
        #expect(failure?.0 == .notInstalled)
        #expect(failure?.1.contains("failed to get a list of files") == true)
    }

    @Test func copiesIntoTheContainer() async throws {
        let fake = try FakeDeviceCtl(fixtures: ["copy-to-file", "copy-to-folder", "copy-to-folder-200mb", "error-copy-to-app-not-installed"])
        let devicectl = fake.devicectl
        try await devicectl.copy(URL(filePath: "/tmp/a"), to: "Documents/a", of: "b", on: Fixtures.udid)
        try await devicectl.copy(URL(filePath: "/tmp/x"), to: "Documents/x", of: "b", on: Fixtures.udid)
        try await devicectl.copy(URL(filePath: "/tmp/big"), to: "Documents/big", of: "b", on: Fixtures.udid)
        let failure = await problem { try await devicectl.copy(URL(filePath: "/tmp/a"), to: "Documents/a", of: "b", on: Fixtures.udid) }
        #expect(failure?.0 == .notInstalled)
        let arguments = try #require(fake.calls.first)
        let pairs = Dictionary(uniqueKeysWithValues: stride(from: 3, to: arguments.count - 1, by: 2).map { (arguments[$0], arguments[$0 + 1]) })
        #expect(pairs["--domain-type"] == "appDataContainer")
        #expect(pairs["--domain-identifier"] == "b")
        #expect(pairs["--source"] == "/tmp/a")
        #expect(pairs["--destination"] == "Documents/a")
    }

    @Test func readsASmallFileFromTheContainer() async throws {
        let fake = try CopyingFrom("copy-from-file", contents: Data("fff\n".utf8))

        #expect(try await fake.devicectl.read("Documents/.frontport-rom", of: "b", on: Fixtures.udid) == Data("fff\n".utf8))

        let arguments = try #require(fake.calls.first)
        #expect(Array(arguments.prefix(3)) == ["device", "copy", "from"])
        let pairs = Dictionary(uniqueKeysWithValues: stride(from: 3, to: arguments.count - 1, by: 2).map { (arguments[$0], arguments[$0 + 1]) })
        #expect(pairs["--domain-type"] == "appDataContainer" && pairs["--domain-identifier"] == "b")
        #expect(pairs["--source"] == "Documents/.frontport-rom")
        let destination = try #require(pairs["--destination"])
        #expect(!FileManager.default.fileExists(atPath: destination), "its private folder goes")
    }

    @Test func readingAMissingOrLargeFileFails() async throws {
        let missing = try CopyingFrom("error-copy-from-missing-file", contents: Data())
        let failure = await problem { _ = try await missing.devicectl.read("Documents/nope.txt", of: "b", on: Fixtures.udid) }
        #expect(failure?.0 == .failed && failure?.1.contains("Documents/nope.txt") == true)

        let large = try CopyingFrom("copy-from-file", contents: Data(count: 70_000))
        let tooLarge = await problem { _ = try await large.devicectl.read("Documents/big", of: "b", on: Fixtures.udid) }
        #expect(tooLarge?.0 == .failed)
    }

    // MARK: Listing and putting for Seeding

    static let fileSeed = StagedSeed(
        label: "ROM", sha1: "aaa", fileSHA1: "aaa", path: "Documents/single.txt",
        files: [DeviceFile(path: "Documents/single.txt", isDirectory: false, size: 12)])
    static let folderSeed = StagedSeed(
        label: "Game", sha1: "fff", fileSHA1: "fff", path: "Documents/x",
        files: [DeviceFile(path: "Documents/x/a.txt", isDirectory: false, size: 19)], marker: "fff\n")

    @Test func listsEachTopFolderOnceThenReadsTheMarkersListedAsFiles() async throws {
        let fake = try FakeDeviceCtl([
            .fixture("files-documents-merged"), .fixture("copy-from-file", contents: Data("fff\n".utf8)),
        ])

        let listing = try await fake.devicectl.list(
            [Self.fileSeed, Self.folderSeed], markers: ["Documents/x/.frontport-rom", "Documents/y/.frontport-rom"],
            of: "b", on: Fixtures.udid)

        #expect(listing.files["Documents/single.txt"]?.size == 12)
        #expect(listing.markers == ["Documents/x/.frontport-rom": "fff"], "a marker not listed isn't read")
        #expect(fake.calls.count == 2)
        #expect(fake.calls[0].starts(with: ["device", "info", "files"]))
        #expect(fake.calls[0].firstIndex(of: "--subdirectory").map { fake.calls[0][$0 + 1] } == "Documents")
        #expect(fake.calls[1].starts(with: ["device", "copy", "from"]))
        #expect(fake.calls[1].firstIndex(of: "--source").map { fake.calls[1][$0 + 1] } == "Documents/x/.frontport-rom")
    }

    @Test func aFolderTheContainerDoesntHaveYetIsListedFromTheContainer() async throws {
        // A file at the container's top lists the container; a folder there fails to list, so the container says.
        let fake = try FakeDeviceCtl([
            .fixture("files-container-root"), .init(json: nil, status: 1, stderr: "No such folder"),
            .fixture("files-container-root"),
        ])
        let seeds = [
            StagedSeed(
                label: "ROM", sha1: "aaa", fileSHA1: "aaa", path: "rom.bin",
                files: [DeviceFile(path: "rom.bin", isDirectory: false, size: 1)]),
            StagedSeed(label: "Game", sha1: "fff", fileSHA1: "fff", path: "Game", files: [], marker: "fff\n"),
        ]

        let listing = try await fake.devicectl.list(seeds, markers: ["Game/.frontport-rom"], of: "b", on: Fixtures.udid)

        #expect(fake.calls.map { $0.contains("--subdirectory") } == [false, true, false])
        #expect(fake.calls[1].firstIndex(of: "--subdirectory").map { fake.calls[1][$0 + 1] } == "Game")
        #expect(listing.files["Library/Preferences"]?.isDirectory == true)
        #expect(listing.markers.isEmpty)
    }

    @Test func listingForAnAppThatIsntInstalledFails() async throws {
        let fake = try FakeDeviceCtl([.fixture("error-files-app-not-installed")])
        let failure = await problem { _ = try await fake.devicectl.list([Self.folderSeed], markers: [], of: "b", on: Fixtures.udid) }
        #expect(failure?.0 == .notInstalled)
        #expect(fake.calls.count == 1, "not taken for a missing folder")
    }

    @Test func putsTopByTopThenTheMarkersDatedSoNoneIsSkipped() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "put-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["Documents/single.txt", "Documents/x/a.txt", "Documents/x/.frontport-rom", "top.bin"] {
            try FileOperations.createDirectory(root.appending(path: path).deletingLastPathComponent())
            try Data(path.utf8).write(to: root.appending(path: path))
        }
        // a.txt replaces a file dated just now, single.txt one dated long ago.
        let now = Date()
        let listing = DeviceListing(files: [
            DeviceFile(path: "Documents/x/a.txt", isDirectory: false, size: 17, modified: now),
            DeviceFile(path: "Documents/single.txt", isDirectory: false, size: 20, modified: Date(timeIntervalSince1970: 0)),
        ])
        let sent = Sources()
        let devicectl = DeviceCtl { arguments, _ in
            sent.record(arguments)
            let json = try Fixtures.data("copy-to-folder")
            try json.write(to: URL(filePath: arguments[arguments.firstIndex(of: "-j")! + 1]))
            return ProcessResult(status: 0)
        }

        try await devicectl.put(root, markers: ["Documents/x/.frontport-rom"], over: listing, of: "b", on: Fixtures.udid)

        let calls = sent.calls
        #expect(calls.map(\.destination) == ["Documents", "top.bin", "Documents"])
        #expect(calls.allSatisfy { $0.arguments.starts(with: ["device", "copy", "to"]) })
        #expect(Set(calls[0].files.keys) == ["single.txt", "x/a.txt"], "the marker set aside")
        #expect(Array(calls[2].files.keys) == ["x/.frontport-rom"], "the marker last")
        let a = try #require(calls[0].files["x/a.txt"])
        let single = try #require(calls[0].files["single.txt"])
        #expect(abs(a.timeIntervalSince(now)) >= 1, "not the date of the file it replaces")
        #expect(abs(single.timeIntervalSince(now)) < 2, "dated now")
    }

    @Test func aPutOfMarkersAloneCopiesNoEmptyFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "put-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileOperations.createDirectory(root.appending(path: "Documents/x"))
        try Data("fff\n".utf8).write(to: root.appending(path: "Documents/x/.frontport-rom"))
        let sent = Sources()
        let devicectl = DeviceCtl { arguments, _ in
            sent.record(arguments)
            try Fixtures.data("copy-to-folder").write(to: URL(filePath: arguments[arguments.firstIndex(of: "-j")! + 1]))
            return ProcessResult(status: 0)
        }

        try await devicectl.put(root, markers: ["Documents/x/.frontport-rom"], over: DeviceListing(), of: "b", on: Fixtures.udid)

        #expect(sent.calls.map(\.destination) == ["Documents"])
        #expect(Array(sent.calls[0].files.keys) == ["x/.frontport-rom"])
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Documents").path(percentEncoded: false)))
    }

    @Test func processes() async throws {
        let fake = try FakeDeviceCtl(fixtures: ["processes-app-running", "processes"])
        let running = try await fake.devicectl.processes(on: Fixtures.udid)
        #expect(running.count == 4)
        #expect(running[30785]?.lastPathComponent == "Spike")
        #expect(try await fake.devicectl.processes(on: Fixtures.udid)[30785] == nil)
    }

    // MARK: Every call

    @Test func everyCallNamesTheDeviceATimeoutAndAPrivateJSONFile() async throws {
        let fake = try FakeDeviceCtl(fixtures: [
            "apps", "install-app", "uninstall", "files-empty", "copy-to-file", "processes", "devices-network-connected",
            "lockstate-locked",
        ])
        let devicectl = fake.devicectl
        _ = try await devicectl.apps(on: Fixtures.udid)
        try await devicectl.install(URL(filePath: "/tmp/Spike.app"), on: Fixtures.udid)
        try await devicectl.uninstall("b", from: Fixtures.udid)
        _ = try await devicectl.files(of: "b", on: Fixtures.udid)
        try await devicectl.copy(URL(filePath: "/tmp/a"), to: "Documents/a", of: "b", on: Fixtures.udid)
        _ = try await devicectl.processes(on: Fixtures.udid)
        _ = try await devicectl.readings()
        #expect(fake.calls.count == 8)
        for arguments in fake.calls {
            if arguments.first == "device" {
                #expect(arguments.firstIndex(of: "--device").map { arguments[$0 + 1] } == Fixtures.udid.rawValue)
            }
            let timeout = try #require(arguments.firstIndex(of: "--timeout"))
            #expect(Int(arguments[timeout + 1]).map { $0 > 0 } == true)
            let json = try #require(arguments.firstIndex(of: "-j").map { arguments[$0 + 1] })
            #expect(json != "-")
            #expect(json.hasPrefix(FileManager.default.temporaryDirectory.path(percentEncoded: false)))
            // The private folder is gone once the call returns.
            #expect(!FileManager.default.fileExists(atPath: URL(filePath: json).deletingLastPathComponent().path(percentEncoded: false)))
        }
    }

    @Test func withoutJSONItsOwnOutputIsTheDetail() async throws {
        let fake = FakeDeviceCtl([.init(json: nil, status: 1, stderr: "ERROR: something odd\n")])
        let failure = await problem { _ = try await fake.devicectl.apps(on: Fixtures.udid) }
        #expect(failure?.0 == .failed)
        #expect(failure?.1 == "ERROR: something odd")
    }

    @Test func unreadableOutput() async throws {
        let fake = FakeDeviceCtl([.init(json: Data("{\"info\": {\"outcome\": \"success\"}}".utf8))])
        let failure = await problem { _ = try await fake.devicectl.apps(on: Fixtures.udid) }
        #expect(failure?.0 == .failed)
        #expect(failure?.1 == "devicectl’s output couldn’t be read.")
    }

    // MARK: Errors

    @Test(arguments: [
        ("launch-error-locked", DeviceProblem.locked, "The application failed to launch. The request was denied by service delegate"),
        ("error-launch-not-installed", .notInstalled, "The application failed to launch. The requested application"),
        ("error-install-unknown-device", .away, "The specified device was not found."),
        ("error-copy-to-app-not-installed", .notInstalled, "The specified file could not be transferred."),
        ("error-files-app-not-installed", .notInstalled, "This operation could not be performed"),
        ("error-copy-from-missing-file", .failed, "Failed to retrieve the file node for Documents/nope.txt"),
        ("error-terminate-no-such-process", .failed, "Failed to send signal 15 to process 30,785. No such process"),
        ("launch-console-timeout", .away, "devicectl: Exceeded command timeout."),
    ])
    func errorsMapToProblemsInDevicectlsOwnWords(_ fixture: String, _ expected: DeviceProblem, _ detail: String) throws {
        let data = try Fixtures.data(fixture)
        #expect(throws: FrontportError.self) {
            _ = try DeviceCtl.decode(DeviceCtl.Output.Launched.self, from: data, result: ProcessResult(status: 1))
        }
        do {
            _ = try DeviceCtl.decode(DeviceCtl.Output.Launched.self, from: data, result: ProcessResult(status: 1))
        } catch FrontportError.deviceUnavailable(let problem, let text) {
            #expect(problem == expected)
            #expect(text.hasPrefix(detail))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    /// Each fixture decodes into the mirror of its command, or into an error.
    @Test func everyFixtureDecodes() throws {
        #expect(Fixtures.names.count == 33)
        for name in Fixtures.names {
            let data = try Fixtures.data(name)
            let envelope = try JSONDecoder().decode(DeviceCtl.Output.Envelope<Empty>.self, from: data)
            let command = try #require(envelope.info?.commandType, "\(name)")
            if envelope.error != nil || envelope.info?.outcome != "success" {
                #expect(throws: FrontportError.self, "\(name)") {
                    _ = try DeviceCtl.decode(Empty.self, from: data, result: ProcessResult(status: 1))
                }
                continue
            }
            let success = ProcessResult(status: 0)
            switch command {
            case "devicectl.list.devices":
                let devices = try DeviceCtl.decode(DeviceCtl.Output.Devices.self, from: data, result: success)
                #expect(devices.devices?.compactMap(DeviceCtl.reading(of:)).count == 1, "\(name)")
            case "devicectl.device.info.lockState":
                #expect(try DeviceCtl.decode(DeviceCtl.Output.LockState.self, from: data, result: success).passcodeRequired != nil)
            case "devicectl.device.info.apps":
                #expect(try DeviceCtl.decode(DeviceCtl.Output.Apps.self, from: data, result: success).apps != nil)
            case "devicectl.device.info.files":
                let files = try DeviceCtl.decode(DeviceCtl.Output.Files.self, from: data, result: success).files ?? []
                #expect(files.allSatisfy { $0.relativePath != nil && $0.metadata?.lastModDate.flatMap(DeviceCtl.date) != nil })
            case "devicectl.device.info.processes":
                let processes = try DeviceCtl.decode(DeviceCtl.Output.Processes.self, from: data, result: success)
                #expect(processes.runningProcesses?.allSatisfy { $0.processIdentifier != nil } == true)
            case "devicectl.device.install.app":
                let installed = try DeviceCtl.decode(DeviceCtl.Output.Installed.self, from: data, result: success)
                #expect(installed.installedApplications?.first?.bundleID != nil)
            case "devicectl.device.uninstall.app":
                let removed = try DeviceCtl.decode(DeviceCtl.Output.Uninstalled.self, from: data, result: success)
                #expect(removed.uninstalledApplications?.first?.bundleID != nil)
            case "devicectl.device.copy.to", "devicectl.device.copy.from":
                #expect(try DeviceCtl.decode(DeviceCtl.Output.Copied.self, from: data, result: success).destination != nil)
            case "devicectl.device.process.launch":
                let launched = try DeviceCtl.decode(DeviceCtl.Output.Launched.self, from: data, result: success)
                #expect(launched.process?.processIdentifier != nil)
            case "devicectl.device.process.terminate", "devicectl.device.process.signal":
                let signalled = try DeviceCtl.decode(DeviceCtl.Output.Signalled.self, from: data, result: success)
                #expect(signalled.signal?.value != nil)
            default:
                Issue.record("\(name): no mirror for \(command)")
            }
        }
    }

    @Test func aConsoleLaunchThatEndsReportsTheExitCode() throws {
        let data = try Fixtures.data("launch-console-exited-uiscene-required")
        let launched = try DeviceCtl.decode(DeviceCtl.Output.Launched.self, from: data, result: ProcessResult(status: 0))
        #expect(launched.terminationResult?.exitCode == 0)
    }

    struct Empty: Decodable {}
}
