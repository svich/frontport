import Foundation
import Testing
@testable import FrontportCore

/// Finding Xcode for Devices, and the pure parts of the Device types.
@Suite struct XcodeTests {
    static let xcode = URL(filePath: "/Applications/Xcode.app/Contents/Developer", directoryHint: .isDirectory)
    static let beta = URL(filePath: "/Applications/Xcode-beta.app/Contents/Developer", directoryHint: .isDirectory)
    static let tools = URL(filePath: "/Library/Developer/CommandLineTools", directoryHint: .isDirectory)

    /// A locator over folders that exist only as `existing` says.
    static func locator(selected: URL?, installed: [URL], existing: [URL]) -> Xcode.Locator {
        let paths = Set(existing.map { $0.standardizedFileURL.path(percentEncoded: false) })
        return Xcode.Locator(
            selected: { selected }, installed: { installed },
            exists: { paths.contains($0.standardizedFileURL.path(percentEncoded: false)) })
    }

    static func withPlatform(_ developer: URL) -> [URL] {
        [developer, Xcode(developer: developer).iosPlatform]
    }

    @Test func theSelectedXcode() async throws {
        let found = try await Xcode.find(Self.locator(
            selected: Self.beta, installed: [URL(filePath: "/Applications/Xcode.app")],
            existing: Self.withPlatform(Self.xcode) + Self.withPlatform(Self.beta)))
        #expect(found.developer == Self.beta)
        #expect(found.devicectl.path(percentEncoded: false) == "/Applications/Xcode-beta.app/Contents/Developer/usr/bin/devicectl")
        #expect(found.xcodebuild.path(percentEncoded: false) == "/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild")
        #expect(found.iosSDK.path(percentEncoded: false)
            == "/Applications/Xcode-beta.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/")
    }

    @Test func launchServicesWhenTheCommandLineToolsAreSelected() async throws {
        let found = try await Xcode.find(Self.locator(
            selected: Self.tools, installed: [URL(filePath: "/Applications/Xcode.app", directoryHint: .isDirectory)],
            existing: [Self.tools] + Self.withPlatform(Self.xcode)))
        #expect(found.developer.standardizedFileURL == Self.xcode.standardizedFileURL)
    }

    @Test func anotherXcodeWhenTheSelectedOneLacksTheIOSPlatform() async throws {
        let found = try await Xcode.find(Self.locator(
            selected: Self.beta, installed: [URL(filePath: "/Applications/Xcode.app")],
            existing: [Self.beta] + Self.withPlatform(Self.xcode)))
        #expect(found.developer.standardizedFileURL == Self.xcode.standardizedFileURL)
    }

    @Test func noXcode() async {
        await #expect(throws: FrontportError.xcodeMissing) {
            try await Xcode.find(Self.locator(selected: Self.tools, installed: [], existing: [Self.tools]))
        }
        await #expect(throws: FrontportError.xcodeMissing) {
            try await Xcode.find(Self.locator(selected: nil, installed: [URL(filePath: "/Applications/Xcode.app")], existing: []))
        }
    }

    @Test func noIOSPlatform() async {
        await #expect(throws: FrontportError.noIOSPlatform) {
            try await Xcode.find(Self.locator(
                selected: Self.xcode, installed: [URL(filePath: "/Applications/Xcode.app")], existing: [Self.xcode]))
        }
    }
}

@Suite struct DeviceTypesTests {
    static let team = AppleTeamID("ABCDE12345")!

    static func profile(_ appID: String, team: AppleTeamID = team) -> ProvisioningProfile {
        ProvisioningProfile(
            uuid: "u", name: "n", team: team, applicationIdentifier: appID, isDevelopment: true, devices: [], certificates: [],
            created: .distantPast, expires: .distantFuture, file: URL(filePath: "/tmp/u.mobileprovision"))
    }

    @Test func aWildcardCoversEveryBundleID() {
        let profile = Self.profile("ABCDE12345.*")
        #expect(profile.isWildcard)
        #expect(profile.appID == "*")
        #expect(profile.covers("dev.frontport.port.x.abcde12345"))
        #expect(!profile.covers(""))
    }

    @Test func aWildcardCoversWhatExtendsItsStem() {
        let profile = Self.profile("ABCDE12345.com.example.*")
        #expect(profile.covers("com.example.game"))
        #expect(!profile.covers("com.example."))
        #expect(!profile.covers("com.example"))
        #expect(!profile.covers("com.examples.game"))
    }

    @Test func anExplicitAppIDCoversOnlyItself() {
        let profile = Self.profile("ABCDE12345.com.example.game")
        #expect(!profile.isWildcard)
        #expect(profile.covers("com.example.game"))
        #expect(!profile.covers("com.example.game2"))
        #expect(!profile.covers("com.example"))
    }

    @Test func anAppIDWithAnotherPrefixCoversNothing() {
        let profile = Self.profile("ZZZZZ99999.*")
        #expect(profile.appID == nil)
        #expect(!profile.covers("com.example.game"))
    }

    @Test func errorsSayWhatToDo() {
        #expect(FrontportError.xcodeMissing.localizedDescription.contains("Xcode"))
        #expect(FrontportError.deviceUnavailable(.locked, detail: "x").localizedDescription == "Unlock the Device, then try again.")
        #expect(FrontportError.deviceUnavailable(.failed, detail: "It broke.").localizedDescription == "The Device couldn’t do that. It broke.")
    }
}
