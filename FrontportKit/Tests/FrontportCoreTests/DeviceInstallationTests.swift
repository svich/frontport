import Foundation
import Testing
@testable import FrontportCore

/// The record of an Installation on a Device, and where its folders are.
@Suite struct DeviceInstallationTests {
    static let team = AppleTeamID("A1B2C3D4E5")!
    static let device: DeviceID = "00008110-0000000000000000"

    static func installation(profileExpires: Date, certificateExpires: Date) -> DeviceInstallation {
        let entry = CatalogEntry(
            id: "tiny", name: "Tiny", kind: .decomp, game: "tiny-game", developer: "Tests", summary: "", description: "",
            source: URL(string: "https://github.com/tests/tiny")!, bundleId: "dev.frontport.port.tiny",
            releases: .githubRelease(GitHubReleaseSource(repo: "tests/tiny", asset: "Tiny-*-mac.zip")),
            ios: IOSSpec(releases: .githubRelease(GitHubReleaseSource(repo: "tests/tiny", asset: "Tiny-*.ipa"))))
        return DeviceInstallation(
            port: "tiny", device: device,
            release: Release(
                port: "tiny", version: "1.0", tag: "v1.0",
                asset: ReleaseAsset(name: "Tiny.ipa", url: URL(string: "https://example.com/Tiny.ipa")!, size: 3, sha256: "abc")),
            channel: .stable, installedAt: Date(timeIntervalSince1970: 1_800_000_000), appName: "Tiny.app",
            bundleId: "dev.frontport.port.tiny.a1b2c3d4e5", team: team, certificate: String(repeating: "AB", count: 20),
            certificateExpires: certificateExpires,
            profile: DeviceInstallation.Profile(uuid: "uuid", name: "iOS Team Provisioning Profile: *", expires: profileExpires),
            seeded: ["Tiny ROM": ["aaa"]], entry: entry)
    }

    @Test func expiresWithItsProvisioningProfileOrCertificateWhicheverIsFirst() {
        let (early, late) = (Date(timeIntervalSince1970: 1_800_000_000), Date(timeIntervalSince1970: 1_900_000_000))
        #expect(Self.installation(profileExpires: early, certificateExpires: late).expires == early)
        #expect(Self.installation(profileExpires: late, certificateExpires: early).expires == early)
    }

    @Test func roundTripsThroughItsRecord() throws {
        let installation = Self.installation(
            profileExpires: Date(timeIntervalSince1970: 1_800_000_000), certificateExpires: Date(timeIntervalSince1970: 1_900_000_000))
        let data = try JSON.encode(installation)
        #expect(try JSON.decode(DeviceInstallation.self, from: data) == installation)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["team"] as? String == "A1B2C3D4E5" && object["device"] as? String == Self.device.rawValue)
        #expect((object["release"] as? [String: Any])?["asset"].flatMap { ($0 as? [String: Any])?["sha256"] as? String } == "abc")
        #expect((object["entry"] as? [String: Any])?["ios"] != nil, "the full entry, with its iOS version")

        // A record naming something that isn't an Apple Team's ID can't be read.
        var malformed = object
        malformed["team"] = "../x"
        #expect(throws: (any Error).self) {
            try JSON.decode(DeviceInstallation.self, from: try JSONSerialization.data(withJSONObject: malformed))
        }
    }

    @Test func devicesHaveFoldersOfTheirOwn() {
        let paths = AppPaths(root: URL(filePath: "/F", directoryHint: .isDirectory), containers: URL(filePath: "/C", directoryHint: .isDirectory))
        let path = { (url: URL) in url.path(percentEncoded: false) }
        let udid = Self.device.rawValue
        #expect(path(paths.devices) == "/F/Devices/")
        #expect(path(paths.deviceRecord(Self.device)) == "/F/Devices/\(udid)/device.json")
        #expect(path(paths.deviceInstallRecord(for: "tiny", on: Self.device)) == "/F/Devices/\(udid)/tiny/install.json")
        #expect(path(paths.deviceApp(for: "tiny", on: Self.device, named: "Tiny.app")) == "/F/Devices/\(udid)/tiny/Tiny.app/")
        #expect(path(paths.deviceStaging(for: "tiny", on: Self.device)) == "/F/Devices/\(udid)/tiny/staging/")
        #expect(path(paths.deviceSeeds(for: "tiny", on: Self.device)) == "/F/Devices/\(udid)/tiny/seeds/")
        #expect(path(paths.downloads(for: PortID("tiny").deviceWorkspace)) == "/F/Downloads/tiny.ios/")
    }
}
