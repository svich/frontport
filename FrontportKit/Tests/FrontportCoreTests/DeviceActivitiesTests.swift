import Foundation
import Testing
@testable import FrontportCore

/// Changes on a Device are Activities of the Port like any other: one at a time, on this Mac and every Device alike.
@MainActor @Suite struct DeviceActivitiesTests {
    let port: PortID = "soh"
    let iPhone: DeviceID = "00008110-0000000000000000"

    /// A change on a Device asked for during one on this Mac waits its turn, and the other way round.
    @Test func changesOnThisMacAndADeviceRunOneAfterAnother() async {
        let log = ActivitiesTests.Log()
        let activities = ActivitiesTests.activities(log)
        let (first, second, third) = (ActivitiesTests.Gate(), ActivitiesTests.Gate(), ActivitiesTests.Gate())
        let onDevice = Activity.Kind.device(.install, iPhone)
        let deviceUninstall = Activity.Kind.device(.uninstall, iPhone)

        activities.run(.update, on: port, { _ in await first.wait() }, end: ActivitiesTests.end(.update, activities, log, port: port))
        activities.run(onDevice, on: port, { _ in await second.wait() }, end: ActivitiesTests.end(onDevice, activities, log, port: port))
        activities.run(.uninstall, on: port, { _ in await third.wait() }, end: ActivitiesTests.end(.uninstall, activities, log, port: port))
        #expect(activities[port]?.kind == .update, "the Device's install waits")

        await first.open()
        await log.until(3)
        #expect(activities[port]?.kind == onDevice)
        await second.open()
        await log.until(5)
        #expect(activities[port]?.kind == .uninstall, "this Mac's uninstall waited for the Device's install")
        await third.open()
        await log.until(7)
        #expect(log.events == [
            "shows update", "end update succeeded", "shows \(onDevice)", "end \(onDevice) succeeded",
            "shows uninstall", "end uninstall succeeded", "clear",
        ])

        // Another Port's change on the same Device doesn't wait.
        let other: PortID = "2ship"
        let gate = ActivitiesTests.Gate()
        activities.run(onDevice, on: port, { _ in await gate.wait() }, end: { _ in })
        activities.run(deviceUninstall, on: other, { _ in }, end: { _ in })
        #expect(activities[other]?.kind == deviceUninstall)
        await gate.open()
    }

    /// Seeding progress on a Device isn't a failure to Seed this Mac's Data.
    @Test func seedingOnADeviceLeavesThisMacsSeedingFailuresAlone() async {
        let log = ActivitiesTests.Log()
        let activities = ActivitiesTests.activities(log)
        let seed = Activity.Kind.device(.seed, iPhone)
        activities.run(seed, on: port, { progress in
            progress(ProgressUpdate(.seeding, message: "Copying to the iPhone failed."))
        }, end: ActivitiesTests.end(seed, activities, log, port: port))
        await log.until(3)
        #expect(activities.seedingFailures.isEmpty)
    }

    /// A Device change starts in its own first phase, counts as a first install only when it installs, and looks up
    /// its iOS Release again only when it may have changed it. Installing starts from the app already prepared.
    @Test func deviceChangesAreNotTakenForTheMacs() {
        let install = Activity.Kind.device(.install, iPhone)
        #expect(install.firstPhase == .provisioning)
        #expect(Activity.Kind.device(.update, iPhone).firstPhase == .resolving)
        #expect(Activity.Kind.device(.renew, iPhone).firstPhase == .provisioning)
        #expect(Activity.Kind.device(.uninstall, iPhone).firstPhase == .removing)
        #expect(install.isFirstInstall && Activity.Kind.install.isFirstInstall)
        #expect(!Activity.Kind.device(.update, iPhone).isFirstInstall && !Activity.Kind.update.isFirstInstall)
        #expect(install.changesRelease && Activity.Kind.device(.update, iPhone).changesRelease)
        #expect(!Activity.Kind.device(.renew, iPhone).changesRelease && !Activity.Kind.device(.uninstall, iPhone).changesRelease)
        #expect(install.device == iPhone && Activity.Kind.install.device == nil)
        #expect(Activity.Kind.device(.uninstall, iPhone) != .uninstall)
        #expect(install.isForDevices && !Activity.Kind.install.isForDevices && !Activity.Kind.uninstall.isForDevices)
    }

    /// Preparing the iOS version is for Devices, though on none: it starts by resolving, counts as a first install, so
    /// the Port is in the Library while it runs, and changes no Release of an Installation.
    @Test func preparingIsForDevicesButOnNone() {
        let prepare = Activity.Kind.prepareForDevices
        #expect(prepare.firstPhase == .resolving)
        #expect(prepare.isFirstInstall && prepare.isForDevices)
        #expect(prepare.device == nil && !prepare.changesRelease)
        #expect(prepare != .install)
    }

    /// Preparing is one of the Port's changes like any other: a change on this Mac or a Device asked for meanwhile waits
    /// for it, and it waits for theirs.
    @Test func preparingRunsOneAfterAnotherWithTheOthers() async {
        let log = ActivitiesTests.Log()
        let activities = ActivitiesTests.activities(log)
        let (first, second, third) = (ActivitiesTests.Gate(), ActivitiesTests.Gate(), ActivitiesTests.Gate())
        let prepare = Activity.Kind.prepareForDevices
        let onDevice = Activity.Kind.device(.install, iPhone)

        activities.run(prepare, on: port, { _ in await first.wait() }, end: ActivitiesTests.end(prepare, activities, log, port: port))
        activities.run(onDevice, on: port, { _ in await second.wait() }, end: ActivitiesTests.end(onDevice, activities, log, port: port))
        activities.run(.applyROMs, on: port, { _ in await third.wait() }, end: ActivitiesTests.end(.applyROMs, activities, log, port: port))
        #expect(activities[port]?.kind == prepare)

        await first.open()
        await log.until(3)
        #expect(activities[port]?.kind == onDevice, "the Device's install waited for preparing")
        await second.open()
        await log.until(5)
        #expect(activities[port]?.kind == .applyROMs)
        await third.open()
        await log.until(7)
        #expect(log.events == [
            "shows \(prepare)", "end \(prepare) succeeded", "shows \(onDevice)", "end \(onDevice) succeeded",
            "shows applyROMs", "end applyROMs succeeded", "clear",
        ])
    }

    /// Seeding progress while preparing isn't this Mac's either.
    @Test func preparingLeavesThisMacsSeedingFailuresAlone() async {
        let log = ActivitiesTests.Log()
        let activities = ActivitiesTests.activities(log)
        let prepare = Activity.Kind.prepareForDevices
        activities.run(prepare, on: port, { progress in
            progress(ProgressUpdate(.seeding, message: "Not this Mac's."))
        }, end: ActivitiesTests.end(prepare, activities, log, port: port))
        await log.until(3)
        #expect(activities.seedingFailures.isEmpty)
    }
}
