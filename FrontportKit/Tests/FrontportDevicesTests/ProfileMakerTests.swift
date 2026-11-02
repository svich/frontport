import Foundation
import FrontportCore
import Testing
@testable import FrontportDevices

/// Making a Provisioning Profile with Xcode: the stub project, `xcodebuild`'s arguments, what its errors mean, and what's
/// left afterwards, over a runner that stands in for `xcodebuild`.
@Suite struct ProfileMakerTests {
    static let team = AppleTeamID("A1B2C3D4E5")!
    static let bundleId = "dev.frontport.port.tiny.a1b2c3d4e5"
    static let device: DeviceID = "00008110-0000000000000000"
    static let developer = URL(filePath: "/Applications/Xcode.app/Contents/Developer", directoryHint: .isDirectory)
    /// An Xcode that's there, with its iOS platform.
    static let locator = Xcode.Locator(selected: { developer }, installed: { [] }, exists: { _ in true })

    // MARK: The stub

    /// A one-target app for iPhone and iPad with the bundle ID and Apple Team, signed automatically, with a scene
    /// delegate, as apps built with the iOS 27 SDK need.
    @Test func theStubIsAnAppForTheBundleIDAndAppleTeam() throws {
        let files = ProfileMaker.files(bundleId: Self.bundleId, team: Self.team)
        #expect(Set(files.keys) == [
            "Stub.xcodeproj/project.pbxproj", "Stub.xcodeproj/xcshareddata/xcschemes/Stub.xcscheme", "Stub/App.swift",
            "Stub/Info.plist",
        ])

        let project = try #require(files["Stub.xcodeproj/project.pbxproj"])
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: Data(project.utf8), format: nil) as? [String: Any])
        let objects = try #require(plist["objects"] as? [String: [String: Any]])
        let settings = objects.values.filter { $0["isa"] as? String == "XCBuildConfiguration" }
            .compactMap { $0["buildSettings"] as? [String: String] }
        let target = try #require(settings.first { $0["PRODUCT_BUNDLE_IDENTIFIER"] != nil })
        #expect(target["PRODUCT_BUNDLE_IDENTIFIER"] == Self.bundleId)
        #expect(target["DEVELOPMENT_TEAM"] == "A1B2C3D4E5")
        #expect(target["CODE_SIGN_STYLE"] == "Automatic")
        #expect(target["TARGETED_DEVICE_FAMILY"] == "1,2")
        #expect(settings.contains { $0["SDKROOT"] == "iphoneos" })
        let sources = objects.values.filter { $0["isa"] as? String == "PBXFileReference" }.compactMap { $0["path"] as? String }
        #expect(Set(sources).isSuperset(of: ["App.swift", "Info.plist", "Stub.app"]))

        // The scheme builds the project's one target.
        let nativeTarget = try #require(objects.first { $0.value["isa"] as? String == "PBXNativeTarget" })
        let scheme = try #require(files["Stub.xcodeproj/xcshareddata/xcschemes/Stub.xcscheme"])
        #expect(scheme.contains("BlueprintIdentifier = \"\(nativeTarget.key)\""))

        let source = try #require(files["Stub/App.swift"])
        #expect(source.contains("@main") && source.contains("UIWindowSceneDelegate") && source.contains("delegateClass"))
        let infoPlist = try #require(files["Stub/Info.plist"])
        let info = try #require(try PropertyListSerialization.propertyList(from: Data(infoPlist.utf8), format: nil) as? [String: Any])
        #expect(info["CFBundleIdentifier"] as? String == "$(PRODUCT_BUNDLE_IDENTIFIER)")
        #expect(info["UIApplicationSceneManifest"] != nil && info["UILaunchScreen"] != nil)
    }

    @Test func argumentsBuildTheStubForTheDevice() {
        let arguments = ProfileMaker.arguments(
            project: URL(filePath: "/p/Stub.xcodeproj", directoryHint: .isDirectory), device: Self.device,
            derivedData: URL(filePath: "/t/dd", directoryHint: .isDirectory), team: Self.team, bundleId: Self.bundleId)
        #expect(arguments == [
            "-project", "/p/Stub.xcodeproj", "-scheme", "Stub", "-configuration", "Debug",
            "-destination", "id=00008110-0000000000000000", "-allowProvisioningUpdates",
            "-allowProvisioningDeviceRegistration", "-derivedDataPath", "/t/dd",
            "DEVELOPMENT_TEAM=A1B2C3D4E5", "PRODUCT_BUNDLE_IDENTIFIER=dev.frontport.port.tiny.a1b2c3d4e5",
            "CODE_SIGN_STYLE=Automatic", "build",
        ])
    }

    // MARK: Making one

    /// The stub goes in `Provisioning/<bundle-id>/` and stays; what Xcode built goes, and what it said is logged under
    /// the Port's iOS folder in Logs.
    @Test func runsXcodeOnTheStubThenCleansUp() async throws {
        let f = try MakerFixture()
        let calls = Box<[(executable: URL, arguments: [String], environment: [String: String])]>([])
        let maker = f.maker { executable, arguments, environment, log in
            calls.update { $0.append((executable, arguments, environment)) }
            try Self.leaveBuildOutput(arguments)
            try Data("** BUILD SUCCEEDED **\n".utf8).write(to: log)
            return ProcessResult(status: 0)
        }

        try await maker.make(for: Self.bundleId, team: Self.team, device: Self.device)

        let call = try #require(calls.get.first)
        #expect(calls.get.count == 1)
        #expect(call.executable.path(percentEncoded: false) == "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild")
        #expect(call.environment["DEVELOPER_DIR"] == "/Applications/Xcode.app/Contents/Developer/")
        let project = f.paths.provisioning.appending(path: Self.bundleId, directoryHint: .isDirectory)
        #expect(call.arguments.prefix(2) == ["-project", project.appending(path: "Stub.xcodeproj").path(percentEncoded: false)])
        #expect(f.exists(project.appending(path: "Stub/App.swift")) && f.exists(project.appending(path: "Stub/Info.plist")))
        #expect(!f.exists(project.appending(path: "build")), "the stub's build output stays")
        #expect(!f.exists(try Self.derivedData(call.arguments)), "DerivedData stays")
        #expect(try f.text(f.paths.logs.appending(path: "tiny.ios/provisioning.log")) == "** BUILD SUCCEEDED **\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.temporary.path(percentEncoded: false)).isEmpty)
    }

    /// A failed build leaves nothing of it either, and says what Xcode said.
    @Test func cleansUpWhenXcodeFails() async throws {
        let f = try MakerFixture()
        let derived = Box<URL?>(nil)
        let maker = f.maker { _, arguments, _, log in
            derived.set(try Self.derivedData(arguments))
            try Self.leaveBuildOutput(arguments)
            try Data(Self.unknownTeamLog.utf8).write(to: log)
            return ProcessResult(status: 65)
        }

        await #expect {
            try await maker.make(for: Self.bundleId, team: Self.team, device: Self.device)
        } throws: { error in
            guard case FrontportError.provisioningFailed(let detail) = error else { return false }
            return detail.contains("Xcode › Settings › Accounts") && detail.contains("A1B2C3D4E5")
        }
        #expect(try !f.exists(#require(derived.get)))
        #expect(!f.exists(f.paths.provisioning.appending(path: "\(Self.bundleId)/build")))
        #expect(try f.text(f.paths.logs.appending(path: "tiny.ios/provisioning.log")) == Self.unknownTeamLog)
    }

    /// Xcode that takes longer than the limit is stopped, and nothing of its build stays.
    @Test func stopsXcodeAfterTheLimit() async throws {
        let f = try MakerFixture()
        let derived = Box<URL?>(nil)
        let maker = f.maker(limit: .milliseconds(200)) { _, arguments, _, _ in
            derived.set(try Self.derivedData(arguments))
            try Self.leaveBuildOutput(arguments)
            try await Task.sleep(for: .seconds(30))
            return ProcessResult(status: 0)
        }
        let started = ContinuousClock.now

        await #expect {
            try await maker.make(for: Self.bundleId, team: Self.team, device: Self.device)
        } throws: { error in
            guard case FrontportError.provisioningFailed(let detail) = error else { return false }
            return detail.contains("within 0 seconds") && detail.contains("provisioning.log")
        }
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(try !f.exists(#require(derived.get)))
    }

    /// Only a Port's bundle ID for the Apple Team names a stub folder, so nothing it writes lands anywhere else.
    @Test(arguments: [
        "../../escape.a1b2c3d4e5", "com.example.app", "dev.frontport.port.Tiny.a1b2c3d4e5", "dev.frontport.port.tiny.zzzzz99999",
        "dev.frontport.port..a1b2c3d4e5", "dev.frontport.port.a/b.a1b2c3d4e5",
    ])
    func refusesWhatIsntAPortsBundleID(_ bundleId: String) async throws {
        let f = try MakerFixture()
        let ran = Box(false)
        let maker = f.maker { _, _, _, _ in
            ran.set(true)
            return ProcessResult(status: 0)
        }
        await #expect {
            try await maker.make(for: bundleId, team: Self.team, device: Self.device)
        } throws: { error in
            if case FrontportError.provisioningFailed = error { true } else { false }
        }
        #expect(!ran.get && !f.exists(f.paths.provisioning) && !f.exists(f.paths.logs))
    }

    @Test func withoutXcodeNothingIsWritten() async throws {
        let f = try MakerFixture()
        let maker = ProfileMaker(
            paths: f.paths, locator: Xcode.Locator(selected: { nil }, installed: { [] }, exists: { _ in false }),
            temporary: f.temporary) { _, _, _, _ in ProcessResult(status: 0) }
        await #expect(throws: FrontportError.xcodeMissing) {
            try await maker.make(for: Self.bundleId, team: Self.team, device: Self.device)
        }
        #expect(!f.exists(f.paths.provisioning))
    }

    // MARK: What Xcode said

    @Test func noAccountForTheAppleTeam() {
        let error = ProfileMaker.failure(fromLog: Self.unknownTeamLog, status: 65, bundleId: Self.bundleId, team: Self.team)
        #expect(error == .provisioningFailed(
            "Xcode isn’t signed in to Apple Team A1B2C3D4E5. Add your Apple Account in Xcode › Settings › Accounts, then try again."))
    }

    @Test(arguments: [
        ("error: Communication with Apple failed. Your maximum App ID limit has been reached. You may create up to 10 App IDs every 7 days.", "10 a week"),
        ("error: The app identifier \"dev.frontport.port.tiny.a1b2c3d4e5\" cannot be registered to your development team because it is not available. Change your bundle identifier to a unique string to try again.", "registered to another Apple Team"),
        ("error: Device \"Test iPhone\" isn't registered in your developer account. The device must be registered in order to be included in a provisioning profile.", "couldn’t register the Device"),
        ("error: Your team has no devices from which to generate a provisioning profile. Connect a device to use or manually add device IDs in Certificates, Identifiers & Profiles.", "couldn’t register the Device"),
        ("error: Unable to register device. You have reached the maximum number of devices.", "couldn’t register the Device"),
    ])
    func whatXcodesErrorsMean(_ line: String, _ meaning: String) {
        let log = "Build description path: /tmp/x\n/tmp/Stub/Stub.xcodeproj: \(line) (in target 'Stub' from project 'Stub')\n** BUILD FAILED **\n"
        guard case .provisioningFailed(let detail) = ProfileMaker.failure(
            fromLog: log, status: 65, bundleId: Self.bundleId, team: Self.team)
        else {
            Issue.record("Not a provisioningFailed")
            return
        }
        #expect(detail.contains(meaning), "\(detail)")
        #expect(!detail.contains("(in target"), "the stub's target is no news")
    }

    @Test func aDeviceXcodeCantReach() {
        let log = "xcodebuild: error: Unable to find a destination matching the provided destination specifier:\n"
        guard case .deviceUnavailable(.away, let detail) = ProfileMaker.failure(
            fromLog: log, status: 70, bundleId: Self.bundleId, team: Self.team)
        else {
            Issue.record("Not away")
            return
        }
        #expect(detail.contains("Unable to find a destination"))
    }

    /// Anything else comes as Xcode said it: its errors, or else the end of the log.
    @Test func anythingElseAsXcodeSaidIt() {
        let errors = "/tmp/Stub.xcodeproj: error: Something new went wrong. (in target 'Stub' from project 'Stub')\n"
            + "/tmp/Stub.xcodeproj: error: Something new went wrong. (in target 'Stub' from project 'Stub')\n"
        #expect(ProfileMaker.failure(fromLog: errors, status: 65, bundleId: Self.bundleId, team: Self.team)
            == .provisioningFailed("Xcode couldn’t make one. Xcode said: Something new went wrong."))
        #expect(ProfileMaker.failure(fromLog: "a\nb\nc\nd\ne\nf\n", status: 1, bundleId: Self.bundleId, team: Self.team)
            == .provisioningFailed("Xcode couldn’t make one. Xcode said: b\nc\nd\ne\nf"))
        #expect(ProfileMaker.failure(fromLog: "", status: 1, bundleId: Self.bundleId, team: Self.team)
            == .provisioningFailed("xcodebuild failed (exit status 1)."))
    }

    // MARK: Xcode

    /// The stub compiles against Xcode's iOS SDK as written, signing nothing and asking Apple nothing. Opt-in with the
    /// Device tests, as it needs Xcode with its iOS platform.
    @Test(.enabled(if: DeviceHost.udid != nil, "Set FRONTPORT_DEVICE_TESTS=<udid>"), .timeLimit(.minutes(3)))
    func theStubBuildsWithXcodesIOSSDK() async throws {
        let f = try MakerFixture()
        let xcode = try await Xcode.find()
        let project = f.folder.appending(path: "stub", directoryHint: .isDirectory)
        for (path, contents) in ProfileMaker.files(bundleId: Self.bundleId, team: Self.team) {
            let file = project.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: file)
        }
        let result = try await ProcessRunner().run(
            xcode.xcodebuild,
            arguments: [
                "-project", project.appending(path: "Stub.xcodeproj").path(percentEncoded: false), "-scheme", "Stub",
                "-configuration", "Debug", "-destination", "generic/platform=iOS",
                "-derivedDataPath", f.temporary.appending(path: "dd").path(percentEncoded: false),
                "CODE_SIGNING_ALLOWED=NO", "build",
            ])
        #expect(result.succeeded, "\(result.output.suffix(2000))")
        let app = f.temporary.appending(path: "dd/Build/Products/Debug-iphoneos/Stub.app")
        #expect(FileOperations.isDirectory(app))
    }

    // MARK: Fixtures

    /// What Xcode 27.2 said for an Apple Team it has no account for (spike S4), its paths shortened.
    static let unknownTeamLog = """
        GatherProvisioningInputs

        /tmp/Stub/Stub.xcodeproj: error: No Account for Team "A1B2C3D4E5". Add a new account in Accounts settings or verify that your accounts have valid credentials. (in target 'Stub' from project 'Stub')
        /tmp/Stub/Stub.xcodeproj: error: No profiles for 'dev.frontport.port.tiny.a1b2c3d4e5' were found: Xcode couldn't find any iOS App Development provisioning profiles matching 'dev.frontport.port.tiny.a1b2c3d4e5'. (in target 'Stub' from project 'Stub')
        ** BUILD FAILED **

        """

    /// The DerivedData folder `-derivedDataPath` names.
    static func derivedData(_ arguments: [String]) throws -> URL {
        let index = try #require(arguments.firstIndex(of: "-derivedDataPath"))
        return URL(filePath: arguments[index + 1], directoryHint: .isDirectory)
    }

    /// Leaves what a build would: DerivedData, and a `build` folder beside the project.
    static func leaveBuildOutput(_ arguments: [String]) throws {
        let derived = try derivedData(arguments)
        try FileManager.default.createDirectory(at: derived.appending(path: "Build/Products"), withIntermediateDirectories: true)
        try Data("app".utf8).write(to: derived.appending(path: "Build/Products/Stub"))
        let index = try #require(arguments.firstIndex(of: "-project"))
        let folder = URL(filePath: arguments[index + 1]).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder.appending(path: "build"), withIntermediateDirectories: true)
    }
}

private final class MakerFixture {
    let folder: URL
    let paths: AppPaths
    let temporary: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "profile-maker-\(UUID().uuidString)", directoryHint: .isDirectory)
        paths = AppPaths(root: folder.appending(path: "Frontport"), containers: folder.appending(path: "Containers"))
        temporary = folder.appending(path: "tmp", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    func maker(limit: Duration = ProfileMaker.limit, _ runner: @escaping ProfileMaker.Runner) -> ProfileMaker {
        ProfileMaker(paths: paths, locator: ProfileMakerTests.locator, limit: limit, temporary: temporary, runner: runner)
    }

    func exists(_ url: URL) -> Bool { FileOperations.exists(url) }

    func text(_ url: URL) throws -> String { try String(decoding: Data(contentsOf: url), as: UTF8.self) }
}

/// A value shared with a runner, from any thread.
final class Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    var get: Value { lock.withLock { value } }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
    func update(_ change: (inout Value) -> Void) { lock.withLock { change(&value) } }
}
