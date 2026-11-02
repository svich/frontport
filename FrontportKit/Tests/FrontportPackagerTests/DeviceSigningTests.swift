import CryptoKit
import Foundation
import FrontportCore
import Testing
@testable import FrontportPackager

/// Signs a clang-built iOS app, with a framework and a loose dylib, through the real codesign, with an Apple
/// Development certificate whose key is in the keychain and a wildcard development Provisioning Profile Xcode has for
/// it. Opt-in, as macOS may ask once whether codesign may use the key, and it needs Xcode's iOS SDK:
///
///     FRONTPORT_DEVICE_TESTS=1 [FRONTPORT_DEVICE_CERTIFICATE=<sha1>] swift test --filter DeviceSigningTests
///
/// It only reads the keychain and the Provisioning Profiles.
@Suite(.enabled(
    if: ProcessInfo.processInfo.environment["FRONTPORT_DEVICE_TESTS"]?.isEmpty == false,
    "Set FRONTPORT_DEVICE_TESTS to sign with your Apple Team"))
struct DeviceSigningTests {
    @Test func signedAppPassesStrictVerificationWithTheThreeEntitlements() async throws {
        let tmp = try TemporaryDirectory()
        let (certificate, profile) = try #require(try await Self.wildcard(), "No wildcard development Provisioning Profile matches a certificate in the keychain")
        let app = try await Self.stub(in: tmp.url)
        let bundleId = PortID("tiny").deviceBundleID(team: profile.team)
        let signing = DeviceSigning(team: profile.team, bundleId: bundleId, certificate: certificate, profile: profile)

        let info = try await DevicePackager().package(app, version: deviceVersion(), signing: signing)

        try await tool("/usr/bin/codesign", ["--verify", "--strict", "--verbose=2", app.path(percentEncoded: false)])
        let team = profile.team.rawValue
        let appEntitlements = try await entitlements(of: app)
        #expect(Set(appEntitlements.keys) == ["application-identifier", "com.apple.developer.team-identifier", "get-task-allow"])
        #expect(appEntitlements["application-identifier"] as? String == "\(team).\(bundleId)")
        #expect(appEntitlements["com.apple.developer.team-identifier"] as? String == team)
        #expect(appEntitlements["get-task-allow"] as? Bool == true)
        let appSignature = try await signatureInfo(of: app)
        #expect(appSignature.contains("TeamIdentifier=\(team)") && appSignature.contains("Identifier=\(bundleId)"))
        #expect(!appSignature.contains("runtime"), "iOS apps aren't signed under the hardened runtime")

        for nested in ["Frameworks/Stub.framework", "Frameworks/libloose.dylib"] {
            let url = app.appending(path: nested)
            #expect(try await signatureInfo(of: url).contains("TeamIdentifier=\(team)"), "\(nested)")
            #expect(try await entitlements(of: url).isEmpty, "\(nested) must not carry the app's entitlements")
        }
        #expect(try Data(contentsOf: app.appending(path: "embedded.mobileprovision")) == Data(contentsOf: profile.file))
        #expect(info.bundleId == bundleId && info.executable == "Tiny" && info.minimumOS == "15.0" && info.sdk != nil)
        #expect(info.families == [1, 2])
    }

    // MARK: Fixtures

    /// A flat iOS app built with clang against Xcode's iOS SDK: its program links `Frameworks/Stub.framework` and
    /// `Frameworks/libloose.dylib`.
    static func stub(in directory: URL) async throws -> URL {
        let app = directory.appending(path: "Tiny.app", directoryHint: .isDirectory)
        let frameworks = app.appending(path: "Frameworks", directoryHint: .isDirectory)
        let framework = frameworks.appending(path: "Stub.framework", directoryHint: .isDirectory)
        let sources = directory.appending(path: "src", directoryHint: .isDirectory)
        try write(
            DeviceApp.dictionary("""
                <key>CFBundleIdentifier</key><string>com.upstream.tiny</string>
                <key>CFBundleExecutable</key><string>Tiny</string>
                <key>CFBundleName</key><string>Tiny</string>
                <key>CFBundlePackageType</key><string>APPL</string>
                <key>CFBundleShortVersionString</key><string>1.0</string>
                <key>CFBundleVersion</key><string>1</string>
                <key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
                <key>MinimumOSVersion</key><string>15.0</string>
                <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
                <key>UILaunchScreen</key><dict/>
                """), to: app.appending(path: "Info.plist"))
        try write(
            DeviceApp.dictionary("""
                <key>CFBundleIdentifier</key><string>com.upstream.tiny.stub</string>
                <key>CFBundleExecutable</key><string>Stub</string>
                <key>CFBundleName</key><string>Stub</string>
                <key>CFBundlePackageType</key><string>FMWK</string>
                <key>CFBundleShortVersionString</key><string>1.0</string>
                <key>CFBundleVersion</key><string>1</string>
                <key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
                <key>MinimumOSVersion</key><string>15.0</string>
                """), to: framework.appending(path: "Info.plist"))
        try write("const char *stub_hello(void) { return \"hello\"; }\n", to: sources.appending(path: "stub.c"))
        try write("int loose_value(void) { return 42; }\n", to: sources.appending(path: "loose.c"))
        try write(
            "const char *stub_hello(void); int loose_value(void);\nint main(void) { return stub_hello()[0] == 'h' && loose_value() == 42 ? 0 : 1; }\n",
            to: sources.appending(path: "main.c"))

        func iosClang(_ arguments: [String]) async throws {
            try await tool("/usr/bin/xcrun", ["--sdk", "iphoneos", "clang", "-target", "arm64-apple-ios15.0"] + arguments)
        }
        let path = { (url: URL) in url.path(percentEncoded: false) }
        try await iosClang([
            "-dynamiclib", "-install_name", "@rpath/Stub.framework/Stub", "-o", path(framework.appending(path: "Stub")),
            path(sources.appending(path: "stub.c")),
        ])
        try await iosClang([
            "-dynamiclib", "-install_name", "@rpath/libloose.dylib", "-o", path(frameworks.appending(path: "libloose.dylib")),
            path(sources.appending(path: "loose.c")),
        ])
        try await iosClang([
            "-F", path(frameworks), "-framework", "Stub", "-L", path(frameworks), "-lloose",
            "-Wl,-rpath,@executable_path/Frameworks", "-o", path(app.appending(path: "Tiny")), path(sources.appending(path: "main.c")),
        ])
        try FileManager.default.removeItem(at: sources)
        return app
    }

    /// The first unexpired wildcard development Provisioning Profile in Xcode's folder whose certificate has its key
    /// in the keychain, and that certificate: FRONTPORT_DEVICE_CERTIFICATE's when it's set.
    static func wildcard() async throws -> (SigningCertificate, ProvisioningProfile)? {
        let identities = String(decoding: try await output("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"]), as: UTF8.self)
        var keychain = Set(identities.matches(of: #/\) ([0-9A-F]{40}) "Apple Development: /#).map { String($0.1) })
        if let wanted = ProcessInfo.processInfo.environment["FRONTPORT_DEVICE_CERTIFICATE"]?.uppercased() {
            keychain = keychain.intersection([wanted])
        }
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Developer/Xcode/UserData/Provisioning Profiles", directoryHint: .isDirectory)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "mobileprovision" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            let decoded = try await output("/usr/bin/security", ["cms", "-D", "-i", file.path(percentEncoded: false)])
            guard let plist = try? PropertyListSerialization.propertyList(from: decoded, format: nil) as? [String: Any],
                let team = (plist["TeamIdentifier"] as? [String])?.first.flatMap({ AppleTeamID(rawValue: $0) }),
                let entitlements = plist["Entitlements"] as? [String: Any],
                let applicationIdentifier = entitlements["application-identifier"] as? String,
                entitlements["get-task-allow"] as? Bool == true, applicationIdentifier == "\(team.rawValue).*",
                let expires = plist["ExpirationDate"] as? Date, expires > Date().addingTimeInterval(86_400),
                let certificates = plist["DeveloperCertificates"] as? [Data]
            else { continue }
            let sha1s = certificates.map { Insecure.SHA1.hash(data: $0).map { String(format: "%02X", $0) }.joined() }
            guard let sha1 = sha1s.first(where: keychain.contains) else { continue }
            let profile = ProvisioningProfile(
                uuid: plist["UUID"] as? String ?? "", name: plist["Name"] as? String ?? "", team: team,
                applicationIdentifier: applicationIdentifier, isDevelopment: true,
                devices: (plist["ProvisionedDevices"] as? [String] ?? []).map { DeviceID($0) }, certificates: sha1s,
                created: plist["CreationDate"] as? Date ?? .distantPast, expires: expires, file: file)
            return (SigningCertificate(sha1: sha1, name: "Apple Development", team: team, expires: expires), profile)
        }
        return nil
    }

    /// A tool's stdout alone, failing on a non-zero exit.
    static func output(_ path: String, _ arguments: [String]) async throws -> Data {
        let log = FileManager.default.temporaryDirectory.appending(path: "out-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: log) }
        let result = try await ProcessRunner().run(URL(filePath: path), arguments: arguments, stdout: .file(log), stderr: .discard)
        guard result.succeeded else {
            throw FrontportError.processFailed(command: path, status: result.status, output: "")
        }
        return try Data(contentsOf: log)
    }
}
