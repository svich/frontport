import Foundation
import FrontportCore
import FrontportDevices
import Testing

/// Xcode making a Provisioning Profile for a real Apple Team and Device, through the real ProfileMaker and Xcode's own
/// `xcodebuild`, then Frontport taking one that covers the bundle ID. Opt-in and attended, as Xcode may register the
/// Device or an App ID on the Apple Team:
///
///     FRONTPORT_DEVICE_TESTS=<udid> FRONTPORT_DEVICE_TEAM=<team ID> swift test --filter ProfileMakerDeviceTests
///
/// It only ever uses the throwaway bundle ID `dev.frontport.port.spike.<team>`, the one App ID this test may register.
/// Its Frontport folder is a temporary one, and it installs nothing on the Device.
@Suite(
    .enabled(if: DeviceHost.udid != nil && DeviceHost.team != nil, "Set FRONTPORT_DEVICE_TESTS=<udid> and FRONTPORT_DEVICE_TEAM=<team ID>"),
    .serialized, .timeLimit(.minutes(10)))
struct ProfileMakerDeviceTests {
    static let port: PortID = "spike"

    @Test func xcodeMakesOneForTheSpikesBundleIDThenFrontportTakesIt() async throws {
        let udid = try #require(DeviceHost.udid)
        let team = try #require(DeviceHost.team)
        let bundleId = Self.port.deviceBundleID(team: team)
        try #require(bundleId == "dev.frontport.port.spike.\(team.rawValue.lowercased())", "only the throwaway App ID")
        let folder = try Scratch()
        let paths = AppPaths(
            root: folder.url.appending(path: "Frontport", directoryHint: .isDirectory),
            containers: folder.url.appending(path: "Containers", directoryHint: .isDirectory))
        let temporary = folder.url.appending(path: "tmp", directoryHint: .isDirectory)
        try FileOperations.createDirectory(temporary)
        let maker = ProfileMaker(paths: paths, temporary: temporary)

        let started = Date()
        do {
            try await maker.make(for: bundleId, team: team, device: udid)
        } catch {
            let log = (try? String(contentsOf: paths.provisioningLog(for: Self.port), encoding: .utf8)) ?? ""
            print("[\(Self.port)] xcodebuild said:\n\(log.suffix(4000))")
            throw error
        }
        print("[\(Self.port)] Xcode finished in \(Int(Date().timeIntervalSince(started))) s")

        let project = paths.provisioningProject(for: Self.port, team: team)
        #expect(FileOperations.exists(project.appending(path: "Stub.xcodeproj/project.pbxproj")), "the stub stays")
        #expect(!FileOperations.exists(project.appending(path: "build")))
        #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path(percentEncoded: false)).isEmpty, "DerivedData goes")
        #expect(FileOperations.exists(paths.provisioningLog(for: Self.port)))

        // Xcode's folder now has one that covers the bundle ID and lists the Device, whether it made it or had it.
        let signing = try await DeviceProvisioning().signing(for: bundleId, team: team, device: udid, outlasting: nil)
        print("[\(Self.port)] takes “\(signing.profile.name)”, expiring \(signing.profile.expires)")
        #expect(signing.bundleId == bundleId && signing.team == team)
        #expect(signing.profile.covers(bundleId) && signing.profile.devices.contains(udid) && signing.profile.isDevelopment)
        #expect(signing.profile.expires > Date().addingTimeInterval(ProvisioningProfiles.margin))

        // Through take, make, take, it's taken at once.
        let again = try await DeviceProvisioning(maker: maker).signing(for: bundleId, team: team, device: udid, outlasting: nil)
        #expect(again.profile.uuid == signing.profile.uuid)
    }
}
