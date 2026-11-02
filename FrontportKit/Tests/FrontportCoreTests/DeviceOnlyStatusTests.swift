import Foundation
import Testing
@testable import FrontportCore

/// This Mac's Status of a Port that's only on a Device: one the Catalog lists can be installed here too; one it no
/// longer lists, known only from the Device's record, can't.
@Suite struct DeviceOnlyStatusTests {
    static func status(isListed: Bool, activity: Activity.Kind? = nil) -> Status {
        let entry = DeviceInstallationTests.installation(profileExpires: .distantFuture, certificateExpires: .distantFuture).entry
        return Status(
            entry: entry, installation: nil, matching: PortMatching(port: entry.id, isInstalled: false, requirements: []),
            activity: activity.map { Activity($0) }, isListed: isListed)
    }

    @Test func anUnlistedPortOnlyADeviceHasCantBeInstalledHere() {
        let status = Self.status(isListed: false)
        #expect(status.state == .available)
        #expect(status.main == nil)
        #expect(status.check(.install) == .unavailable)
        #expect(status.check(.uninstall) == .unavailable)
        #expect(!status.isInLibrary)
    }

    /// Nor is a Build ROM asked for to install it here, though one is missing.
    @Test func anUnlistedPortOnlyADeviceHasAsksForNoBuildROM() {
        var scenario = StatusTests.Scenario(isInstalled: false, build: .missing, isListed: false)
        #expect(scenario.status.state == .needsBuildROM([StatusTests.buildROM]))
        #expect(scenario.status.main == nil)
        #expect(scenario.status.check(.addROM(.build)) == .unavailable)

        scenario.isListed = true
        #expect(scenario.status.main == .addROM(.build))
        #expect(scenario.status.check(.addROM(.build)) == .allowed)
    }

    @Test func aListedPortOnADeviceCanBeInstalledHereToo() {
        let status = Self.status(isListed: true)
        #expect(status.main == .install)
        #expect(status.check(.install) == .allowed)
    }

    /// Its change on the Device holds a change here back, and shows as the Port's Activity.
    @Test func aChangeOnTheDeviceIsThePortsActivity() {
        let change = Activity.Kind.device(.install, DeviceInstallationTests.device)
        let status = Self.status(isListed: true, activity: change)
        #expect(status.state == .working(Activity(change)))
        #expect(status.main == .cancel)
        #expect(status.check(.install) == .disabled(.activity(change)))
        #expect(!status.isInLibrary, "a first install on a Device isn't one on this Mac")
    }

    /// Nor is preparing one for Devices, though the Lineup counts the Port in the Library meanwhile: its cards keep
    /// this Mac's action, Cancel while it runs.
    @Test func preparingForDevicesIsntInThisMacsLibrary() {
        let status = Self.status(isListed: true, activity: .prepareForDevices)
        #expect(status.state == .working(Activity(.prepareForDevices)))
        #expect(status.main == .cancel)
        #expect(!status.isInLibrary)
    }
}
