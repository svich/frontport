import Foundation
import Testing
@testable import FrontportCore

/// What a Port can do on one Device: the actions its row offers, and why one is disabled, first reason first.
@Suite struct DeviceStatusTests {
    static let iPhone = Device(
        id: DeviceInstallationTests.device, name: "Test iPhone", model: "iPhone 13", osVersion: "27.0.1", families: [1])
    static let iPad = Device(id: "00008112-0000000000000000", name: "Test iPad", model: "iPad Air", osVersion: "27.0", families: [1, 2])
    static let certificate = SigningCertificate(
        sha1: String(repeating: "AB", count: 20), name: "Apple Development: Tests", team: DeviceInstallationTests.team,
        expires: Date(timeIntervalSince1970: 1_900_000_000))
    static let team = AppleTeam(id: DeviceInstallationTests.team, name: "Tests", certificates: [certificate])
    static let installed = DeviceInstallationTests.installation(
        profileExpires: Date(timeIntervalSince1970: 1_900_000_000), certificateExpires: Date(timeIntervalSince1970: 1_900_000_000))

    /// Tiny on the iPhone as the App sees it: installed, everything ready, unless a test says otherwise.
    struct Scenario {
        var isInstalled = true
        var hasXcode = true
        var connection = DeviceReading.Connection.wired
        var isLocked: Bool? = false
        var developerMode: Bool? = true
        var activity: Activity.Kind?

        var status: DeviceStatus {
            DeviceStatus(
                reading: DeviceReading(
                    device: DeviceStatusTests.iPhone, connection: connection, isLocked: isLocked, developerMode: developerMode),
                installation: isInstalled ? DeviceStatusTests.installed : nil, hasXcode: hasXcode,
                activity: activity.map { Activity($0) })
        }
    }

    // MARK: Uninstall

    /// Uninstalling needs Xcode and the Device, and waits for the change under way, but no Apple Team, Developer Mode or
    /// Catalog entry: the record names the app.
    @Test func uninstallNeedsOnlyXcodeAndTheDevice() {
        var scenario = Scenario(hasXcode: false, connection: .away, developerMode: false, activity: .update)
        #expect(scenario.status.actions == [.uninstall])
        #expect(scenario.status.check(.uninstall) == .disabled(.needsXcode))
        scenario.hasXcode = true
        #expect(scenario.status.check(.uninstall) == .disabled(.away))
        scenario.connection = .network
        #expect(scenario.status.check(.uninstall) == .disabled(.activity(.update)))
        scenario.activity = nil
        #expect(scenario.status.check(.uninstall) == .allowed)
        #expect(Scenario(isInstalled: false).status.check(.uninstall) == .unavailable)
    }

    /// Installing goes through the Port's Install on iPhone or iPad…, so a Device without the Port offers nothing.
    @Test func aDeviceWithoutThePortOffersNothing() {
        #expect(Scenario(isInstalled: false).status.actions.isEmpty)
        #expect(Scenario().status.actions == [.uninstall])
    }

    /// Preparing the iOS version for Devices, or a change on another Device, holds an uninstall back too.
    @Test func anyChangeOfThePortHoldsAnUninstallBack() {
        #expect(Scenario(activity: .prepareForDevices).status.check(.uninstall) == .disabled(.activity(.prepareForDevices)))
        let elsewhere = Activity.Kind.device(.install, DeviceStatusTests.iPad.id)
        let status = Scenario(activity: elsewhere).status
        #expect(status.check(.uninstall) == .disabled(.activity(elsewhere)))
        #expect(status.state == .installed(Self.installed), "a change on the iPad isn't one on the iPhone")
    }

    // MARK: State

    @Test func aChangeOnTheDeviceShowsAsWorkingThere() {
        let change = Activity.Kind.device(.uninstall, DeviceInstallationTests.device)
        #expect(Scenario(activity: change).status.state == .working(Activity(change)))
        #expect(Scenario(isInstalled: false, activity: .device(.install, DeviceInstallationTests.device)).status.state
            == .working(Activity(.device(.install, DeviceInstallationTests.device))))
        #expect(Scenario().status.state == .installed(Self.installed))
        #expect(Scenario(activity: .update).status.state == .installed(Self.installed))
        #expect(Scenario(activity: .prepareForDevices).status.state == .installed(Self.installed))
        #expect(Scenario(isInstalled: false).status.state == .available)
    }
}
