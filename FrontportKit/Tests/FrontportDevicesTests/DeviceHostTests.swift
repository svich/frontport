import Foundation
import FrontportCore
import Testing
@testable import FrontportDevices

/// This Mac's real Xcode, keychain, Provisioning Profiles and paired Device, read only. Opt-in, with the UDID of a
/// Device paired with it and the ID of an Apple Team whose certificate is in the keychain:
///
///     FRONTPORT_DEVICE_TESTS=<udid> FRONTPORT_DEVICE_TEAM=<team ID> swift test --filter FrontportDevicesTests
enum DeviceHost {
    static let environment = ProcessInfo.processInfo.environment
    static var udid: DeviceID? { environment["FRONTPORT_DEVICE_TESTS"].map { DeviceID($0) } }
    static var team: AppleTeamID! { environment["FRONTPORT_DEVICE_TEAM"].flatMap { AppleTeamID($0) } }
}

@Suite(.enabled(if: DeviceHost.udid != nil && DeviceHost.team != nil), .timeLimit(.minutes(2)))
struct DeviceHostTests {
    @Test func readingFindsTheDevice() async throws {
        let udid = try #require(DeviceHost.udid)
        let devicectl = DeviceCtl(xcode: try await Xcode.find())
        let reading = try #require(try await devicectl.readings().first { $0.device.id == udid })
        #expect(!reading.device.name.isEmpty)
        #expect(reading.device.families.contains(1))
        #expect(reading.developerMode == true)
        if reading.isReachable { #expect(reading.isLocked != nil) }
    }

    @Test func theApplesTeamIsInTheKeychain() throws {
        let team = try #require(KeychainAppleTeams().teams().first { $0.id == DeviceHost.team })
        #expect(!team.name.isEmpty)
        #expect(team.certificates.allSatisfy { $0.team == DeviceHost.team && $0.sha1.count == 40 && $0.expires > .now })
    }

    @Test func choosesTheWildcardForAPort() async throws {
        let udid = try #require(DeviceHost.udid)
        let bundleId = PortID("x").deviceBundleID(team: DeviceHost.team)
        let signing = try await DeviceProvisioning().signing(for: bundleId, team: DeviceHost.team, device: udid, outlasting: nil)
        #expect(signing.bundleId == "dev.frontport.port.x.\(DeviceHost.team.rawValue.lowercased())")
        #expect(signing.profile.isWildcard)
        #expect(signing.profile.isDevelopment)
        #expect(signing.profile.devices.contains(udid))
        #expect(signing.profile.certificates.contains(signing.certificate.sha1))
        #expect(FileManager.default.fileExists(atPath: signing.profile.file.path(percentEncoded: false)))
    }
}
