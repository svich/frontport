import Foundation
import FrontportCore
import FrontportDevices
import FrontportLibrary
import FrontportPackager
import Testing

/// Installs a Port's iOS version on a real Device from the Frontport folder `FRONTPORT_APP_ROOT` names, and Seeds it,
/// leaving both there, so a Debug build of the app can be tried against them with `FRONTPORT_ROOT`. `FRONTPORT_APP_ROMS`
/// adds files to its ROMs first, as the ROMs screen would. Attended, as macOS may ask whether codesign may use the key:
///
///     FRONTPORT_NETWORK_TESTS=1 FRONTPORT_APP_ROOT=/tmp/fp FRONTPORT_APP_PORT=fallout-ce \
///     [FRONTPORT_APP_ROMS=/path/Fallout.iso] FRONTPORT_DEVICE_TESTS=<udid> FRONTPORT_DEVICE_TEAM=<team ID> \
///     swift test --filter installsOnTheDeviceForTheApp
@Suite(
    .enabled(
        if: Integration.requested && Integration.environment["FRONTPORT_APP_ROOT"] != nil && DeviceHost.udid != nil
            && DeviceHost.team != nil),
    .timeLimit(.minutes(60)))
struct DeviceAppRootTests {
    @Test func installsOnTheDeviceForTheApp() async throws {
        let root = try #require(Integration.environment["FRONTPORT_APP_ROOT"])
        let udid = try #require(DeviceHost.udid)
        let team = try #require(DeviceHost.team)
        let world = try await World(root: URL(filePath: root, directoryHint: .isDirectory))
        let entry = try #require(world.catalog.entry(PortID(Integration.environment["FRONTPORT_APP_PORT"] ?? "fallout-ce")))
        let files = (Integration.environment["FRONTPORT_APP_ROMS"] ?? "").split(separator: ",").map { URL(filePath: String($0)) }
        for intake in await world.roms.add(files, catalog: world.catalog) {
            switch intake {
            case .added(let record), .duplicate(let record): print("[roms] \(record.originalFilename): \(record.sha1) \(record.name)")
            case .rejected(let file, let sha1, let reason): Issue.record("\(file.lastPathComponent) (\(sha1 ?? "-")): \(reason)")
            case .unknown(let file, let sha1, _, let reason): Issue.record("\(file.lastPathComponent) (\(sha1)): \(reason)")
            }
        }

        let control = DeviceCtl(xcode: try await Xcode.find())
        let library = DeviceLibrary(
            paths: world.paths, catalog: world.catalogStore, releases: world.releases, fetcher: world.fetcher,
            builder: world.builder, packager: DevicePackager(), control: control,
            provisioning: DeviceProvisioning(maker: ProfileMaker(paths: world.paths)), roms: world.roms)
        let reading = try #require(try await control.readings().first { $0.device.id == udid }, "\(udid) isn’t paired with this Mac")
        try #require(reading.isReachable, "\(reading.device.name) isn’t reachable")

        var installation = await library.installation(for: entry.id, on: udid)
        if installation == nil {
            let started = Date()
            let version = try IOSVersion(of: entry)
            _ = try await library.prepare(version, channel: entry.defaultChannel, progress: world.progress)
            installation = try await library.installPrepared(version, on: reading, team: team, progress: world.progress)
            print("[\(entry.id)] installed on \(reading.device.name) in \(Int(Date().timeIntervalSince(started))) s")
        }
        let installed = try #require(installation)
        print("[\(entry.id)] \(installed.release.version), signed until \(installed.expires), \(installed.bundleId)")

        let current = try #require(try await control.readings().first { $0.device.id == udid })
        let plan = try await library.seed(IOSVersion(of: entry), on: current, progress: world.progress)
        print("[\(entry.id)] Seeded: \(String(describing: plan))")
        print("[\(entry.id)] in \(world.paths.root.path(percentEncoded: false))")
    }
}
