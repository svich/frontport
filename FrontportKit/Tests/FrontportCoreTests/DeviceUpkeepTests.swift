import Foundation
import Testing
@testable import FrontportCore

private let iPhone = DeviceStatusTests.iPhone
private let port: PortID = "ghostship"
private let key = DeviceUpkeepState.Key(port, on: iPhone.id)
private let ready = DeviceReading(device: iPhone, connection: .wired, isLocked: false, developerMode: true)
private let locked = DeviceReading(device: iPhone, connection: .wired, isLocked: true, developerMode: true)
/// Ghostship's one Runtime Requirement, as its iOS version Seeds it.
private let sm64 = IOSVersion(DeviceMatchingTests.entry)!.requirements

/// What Frontport does for Ports on Devices, wired as the App wires it: Ghostship on the iPhone, unless the test
/// installs it, its Super Mario 64 ROM in ROMs and not Seeded there, every change run as the Port's Activity and the
/// Survey read again after it, and a clock the test moves.
@MainActor @Suite struct DeviceUpkeepTests {
    /// The upkeep, its fakes, and what it alerted.
    @MainActor final class Rig {
        let control = ScriptedReadings()
        let library = FakeDeviceLibrary()
        let releases = FakeIOSReleases()
        let activities = Activities()
        let preferences: HeldDevicePreferences
        let survey: Survey
        let upkeep: DeviceUpkeep
        let clock = Clock()
        /// The failures presented, as the user reads them.
        var alerts: [String] = []

        /// `expires` is when Ghostship's app on the iPhone stops launching; the clock starts well before, unless `due`.
        /// Unless `installed`, the iPhone doesn't have it, and an install puts it there.
        init(due: Bool = false, renewsOnItsOwn: Bool = true, installed: Bool = true) async {
            let installation = DeviceMatchingTests.installation(seeded: [:])
            preferences = HeldDevicePreferences(team: DeviceInstallationTests.team, renewsOnItsOwn: renewsOnItsOwn)
            let paths = AppPaths(root: URL(filePath: "/nonexistent/Frontport"), containers: URL(filePath: "/nonexistent/Containers"))
            let activities = activities
            let roms = FakeROMs()
            await roms.set(Matching(roms: DeviceMatchingTests.roms, ports: [port: DeviceMatchingTests.matching("aaa")]))
            await library.set(installed ? [installation] : [], remembered: [iPhone])
            await library.script(install: installation)
            survey = Survey(
                .init(
                    catalog: FakeCatalog(CatalogDocument(issued: .now, platforms: [], games: [], roms: [], ports: [DeviceMatchingTests.entry])),
                    library: FakeLibrary(), roms: roms, releases: releases, devices: library),
                activities: activities, paths: paths)
            await survey.load()
            let survey = survey
            let clock = clock
            clock.now = installation.expires.addingTimeInterval(due ? -86_400 : -100 * 86_400)
            upkeep = DeviceUpkeep(
                services: .init(
                    devices: library, readings: { [control] in try await control.readings() },
                    teams: { [DeviceStatusTests.team] }),
                survey: survey,
                activities: activities, preferences: preferences, now: { clock.now })
            // As the App's `run`, weakly, as the App holds it: work may outlive a test.
            upkeep.perform = { [weak self] kind, port, work, end in
                activities.run(kind, on: port, work) { outcome in
                    await survey.changed(port, by: kind)
                    guard let error = end(outcome) else { return }
                    self?.alerts.append((error as? FrontportError)?.errorDescription ?? "\(error)")
                }
            }
        }

        /// What Seeding on the iPhone waits for, as its row says with the iPhone as `reading` finds it.
        func wait(on reading: DeviceReading) -> DeviceStatus.Seeding.Wait? {
            guard case .waiting(_, let wait) = upkeep.status(of: port, on: reading).seeding else { return nil }
            return wait
        }

        /// Whether the iPhone's row says Ghostship's last Renew there failed.
        var renewFailed: Bool {
            guard case .failed = upkeep.status(of: port, on: ready).renewal else { return false }
            return true
        }

        /// Moves the clock on.
        func wait(_ seconds: TimeInterval) { clock.now = clock.now.addingTimeInterval(seconds) }

        /// Reads the Devices as `reading` finds the iPhone, and waits for whatever that started to end.
        func read(_ reading: DeviceReading) async {
            await control.set(reading)
            await upkeep.refresh()
            await settled()
        }

        /// Waits until no change of Ghostship is under way, nor about to start.
        func settled() async {
            for _ in 0..<50 { await Task.yield() }
            _ = await eventually { activities[port] == nil }
            for _ in 0..<50 { await Task.yield() }
        }

        /// Holds Ghostship's next change until the gate opens, with a change of its own under way meanwhile.
        func hold(_ gate: Gate) {
            activities.run(.applyROMs, on: port, { _ in await gate.wait() }, end: { _ in })
        }

        var seeds: Int { get async { await library.seeds.count } }
        var renews: Int { get async { await library.renews.count } }
    }

    /// Ghostship's iOS version, prepared for the iOS Release the test makes the newest.
    static let app = PreparedDeviceApp(
        port: port, release: Release(port: port, version: "2.0", tag: "v2.0"), channel: .stable, appName: "Ghostship.app",
        minimumOS: "17.0", families: [1, 2])

    // MARK: Installing

    /// Install on iPhone…, with nothing prepared, prepares the iOS version, then hands it to the sheet once its
    /// Activity ends; prepared already for the newest iOS Release, at once.
    @Test func preparingHandsTheAppToTheSheet() async {
        let rig = await Rig(installed: false)
        await rig.read(ready)
        await rig.library.script(prepare: Self.app)
        var asked: [PreparedDeviceApp] = []
        rig.upkeep.prepare(port) { asked.append($0) }
        _ = await eventually { !asked.isEmpty }
        await rig.settled()
        #expect(asked == [Self.app])
        #expect(await rig.library.preparations == [port])

        await rig.releases.set(ios: Self.app.release)
        _ = await rig.survey.refresh()
        rig.upkeep.prepare(port) { asked.append($0) }
        _ = await eventually { asked.count == 2 }
        #expect(asked == [Self.app, Self.app])
        #expect(await rig.library.preparations == [port], "prepared again")
    }

    /// The sheet's Install installs on the iPhone as it's read when its turn comes, then Seeds what ROMs hold for
    /// Ghostship there, as an Activity of its own.
    @Test func installingSeedsWhenTheDeviceIsReadyAtItsTurn() async {
        let rig = await Rig(installed: false)
        await rig.read(locked)
        let gate = Gate()
        rig.hold(gate)
        #expect(rig.upkeep.install(port, prepared: Self.app, on: [iPhone.id]))
        await rig.control.set(ready)
        await rig.upkeep.refresh()
        await gate.open()
        _ = await eventually { await rig.seeds == 1 }
        await rig.settled()
        #expect(await rig.library.installs == [ready])
        #expect(rig.survey.deviceInstallation(port, on: iPhone.id) != nil)
        #expect(await rig.library.seeds == [key])
        #expect(rig.alerts.isEmpty)
    }

    /// Install isn't taken without an Apple Team to sign with, nor on a Device that's away.
    @Test func installingNeedsAnAppleTeamAndTheDevice() async {
        let rig = await Rig(installed: false)
        await rig.read(DeviceReading(device: iPhone, connection: .away))
        #expect(!rig.upkeep.install(port, prepared: Self.app, on: [iPhone.id]), "installed on a Device that's away")
        await rig.read(ready)
        rig.upkeep.chosenTeam = AppleTeamID("Z9Y8X7W6V5")
        #expect(!rig.upkeep.install(port, prepared: Self.app, on: [iPhone.id]), "installed with no Apple Team")
        await rig.settled()
        #expect(await rig.library.installs.isEmpty)
    }

    /// Update installs the newer iOS Release over Ghostship on the iPhone, then Seeds; it isn't taken while the iPhone
    /// is away, nor with another Apple Team chosen than the one it's signed with.
    @Test func updatingSeedsAfterwards() async {
        let rig = await Rig()
        await rig.releases.set(ios: Self.app.release)
        _ = await rig.survey.refresh()
        await rig.read(DeviceReading(device: iPhone, connection: .away))
        rig.upkeep.update(port, on: iPhone.id)
        await rig.read(ready)
        rig.upkeep.chosenTeam = AppleTeamID("Z9Y8X7W6V5")
        rig.upkeep.update(port, on: iPhone.id)
        await rig.settled()
        #expect(await rig.library.updates.isEmpty)

        rig.upkeep.chosenTeam = DeviceInstallationTests.team
        let seeds = await rig.seeds
        rig.upkeep.update(port, on: iPhone.id)
        await rig.settled()
        #expect(await rig.library.updates == [ready])
        #expect(await rig.seeds == seeds + 1)
        #expect(rig.alerts.isEmpty)
    }

    /// Uninstall removes Ghostship from the iPhone, and forgets what Seeding there waited for; with the iPhone away, it
    /// isn't taken.
    @Test func uninstallingForgetsWhatWasKeptThere() async {
        let rig = await Rig()
        await rig.read(DeviceReading(device: iPhone, connection: .away))
        rig.upkeep.uninstall(port, from: iPhone.id)
        await rig.settled()
        #expect(await rig.library.uninstalls.isEmpty)

        rig.upkeep.romsAdded(["aaa"])
        #expect(rig.wait(on: DeviceReading(device: iPhone, connection: .away)) == .away)
        await rig.library.script(seeds: [.failure(FrontportError.running(port))])
        await rig.read(ready)
        #expect(rig.wait(on: ready) == .running)
        rig.upkeep.uninstall(port, from: iPhone.id)
        await rig.settled()
        #expect(await rig.library.uninstalls == [key])
        #expect(rig.survey.deviceInstallation(port, on: iPhone.id) == nil)
        #expect(!rig.upkeep.status(of: port, on: ready).isRunning)
    }

    // MARK: Seeding

    /// ROMs added while the iPhone is locked wait for it; a reading that finds it unlocked Seeds them, once.
    @Test func seedingWaitsForTheDeviceToBeUnlocked() async {
        let rig = await Rig()
        await rig.read(locked)
        rig.upkeep.romsAdded(["aaa"])
        await rig.settled()
        #expect(rig.wait(on: locked) == .locked)
        #expect(await rig.seeds == 0)

        await rig.read(ready)
        #expect(await rig.seeds == 1)
        #expect(rig.wait(on: locked) == nil)

        await rig.read(ready)
        #expect(await rig.seeds == 1, "Seeded again")
        #expect(rig.alerts.isEmpty)
    }

    /// Refused because Ghostship runs on the iPhone: it waits, with no alert, until a reading finds it quit there.
    @Test func seedingRefusedWhileThePortRunsIsTriedAgainOnceItQuits() async {
        let rig = await Rig()
        await rig.library.script(seeds: [.failure(FrontportError.running(port)), .success(nil)])
        await rig.library.run([port])
        await rig.read(ready)
        // Never asked since launch, and the record says it isn't there: requested once a launch.
        #expect(await rig.seeds == 1)
        #expect(rig.wait(on: ready) == .running)
        #expect(rig.upkeep.status(of: port, on: ready).check(.seed) == .disabled(.running))
        #expect(rig.alerts.isEmpty)

        await rig.read(ready)
        _ = await eventually { await rig.library.runningChecks == 1 }
        await rig.settled()
        #expect(await rig.seeds == 1, "Seeded while it runs")

        await rig.library.run([])
        await rig.read(ready)
        let retried = await eventually { await rig.seeds == 2 }
        await rig.settled()
        #expect(retried)
        #expect(rig.wait(on: ready) == nil)
    }

    /// A Seed that fails for another reason alerts and says so on the row; Try Again Seeds again, and clears it once
    /// it succeeds.
    @Test func tryAgainAfterASeedFailed() async {
        let rig = await Rig()
        await rig.read(locked)
        await rig.library.script(seeds: [.failure(FrontportError.fileOperation("The disk is full."))])
        rig.upkeep.romsAdded(["aaa"])
        await rig.read(ready)
        #expect(rig.upkeep.status(of: port, on: ready).seeding == .failed(sm64))
        #expect(rig.alerts.count == 1)
        #expect(rig.wait(on: locked) == nil)

        rig.upkeep.seed(port, on: iPhone.id)
        await rig.settled()
        #expect(await rig.seeds == 2)
        #expect(!rig.upkeep.status(of: port, on: ready).seedFailed)
    }

    /// Forgetting the Device, away, forgets what waited, failed or was held back there for its Ports.
    /// Should it come back with its records, none of that does.
    @Test func forgettingTheDeviceForgetsWhatWasKeptThere() async throws {
        let rig = await Rig(due: true)
        await rig.library.failRenews(with: FrontportError.provisioningFailed("None."))
        await rig.library.script(seeds: [.failure(FrontportError.running(port))])
        await rig.read(ready)
        _ = await eventually { await rig.seeds == 1 }
        await rig.settled()
        #expect(rig.wait(on: ready) == .running && rig.renewFailed)

        await rig.read(DeviceReading(device: iPhone, connection: .away))
        try await rig.upkeep.forget(iPhone.id)
        #expect(await rig.library.forgotten == [iPhone.id])
        await rig.library.set([DeviceMatchingTests.installation(seeded: [:])], remembered: [iPhone])
        await rig.survey.devicesChanged()
        #expect(rig.survey.deviceInstallation(port, on: iPhone.id) != nil)
        #expect(rig.wait(on: ready) == nil && !rig.renewFailed)
    }

    // MARK: Renewing

    /// Due, it Renews on its own once; failing, it doesn't alert and holds back an hour, or until Frontport comes to the
    /// front or the user chooses an Apple Team.
    @Test func aFailedRenewOnItsOwnHoldsBack() async {
        let rig = await Rig(due: true)
        await rig.library.failRenews(with: FrontportError.provisioningFailed("No Provisioning Profile lasts longer."))
        await rig.read(ready)
        #expect(await rig.renews == 1)
        #expect(rig.alerts.isEmpty, "A Renew on its own alerted")
        #expect(rig.renewFailed)

        rig.wait(30 * 60)
        await rig.read(ready)
        #expect(await rig.renews == 1, "Tried again within the hour")
        rig.wait(31 * 60)
        await rig.read(ready)
        #expect(await rig.renews == 2)

        rig.upkeep.activated()
        let afterActivation = await eventually { await rig.renews == 3 }
        await rig.settled()
        #expect(afterActivation)

        rig.upkeep.chosenTeam = nil
        await rig.settled()
        #expect(await rig.renews == 4, "Choosing an Apple Team didn't try again")
        #expect(rig.preferences.team == nil)
        #expect(rig.alerts.isEmpty)
    }

    /// The user's own Renew that fails alerts.
    @Test func aFailedRenewTheUserAskedForAlerts() async {
        let rig = await Rig(due: true, renewsOnItsOwn: false)
        await rig.library.failRenews(with: FrontportError.provisioningFailed("No Provisioning Profile lasts longer."))
        await rig.read(ready)
        rig.upkeep.renew(port, on: iPhone.id)
        await rig.settled()
        #expect(await rig.renews == 1)
        #expect(rig.alerts.count == 1)
    }

    /// Turned off, nothing is Renewed on its own; turned back on, what's due is, and the store keeps it. The Renew fails,
    /// as the fake Renew writes no new record, so one that succeeded would stay due.
    @Test func turningRenewingOnItsOwnOffStopsIt() async {
        let rig = await Rig(due: true, renewsOnItsOwn: false)
        await rig.library.failRenews(with: FrontportError.provisioningFailed("No Provisioning Profile lasts longer."))
        await rig.read(ready)
        #expect(await rig.renews == 0)

        rig.upkeep.renewsOnItsOwn = true
        await rig.settled()
        #expect(await rig.renews == 1)
        #expect(rig.preferences.renewsOnItsOwn)
    }

    // MARK: Reading

    /// While its row shows, what Seeding would copy is read from the iPhone, locked or not, but not while Ghostship has
    /// a change under way: the row says its ROM is there, as the plan found it.
    @Test func readingWhatSeedingWouldCopy() async {
        let rig = await Rig()
        await rig.read(locked)
        await rig.library.script(plan: DeviceMatchingTests.plan(.seeded))
        let gate = Gate()
        rig.hold(gate)
        await rig.upkeep.readSeeding(of: port)
        #expect(await rig.library.plans.isEmpty, "Read during a change")
        await gate.open()
        await rig.settled()

        #expect(rig.upkeep.status(of: port, on: locked).seeding == .unseeded(sm64))
        await rig.upkeep.readSeeding(of: port)
        #expect(await rig.library.plans == [key])
        #expect(rig.upkeep.status(of: port, on: locked).seeding == .seeded(sm64, isLastKnown: false))
    }

    /// A reading that reaches the iPhone remembers it as it says it is now, once; one that finds it away doesn't.
    @Test func aReadingRemembersTheDeviceAsItSaysItIs() async {
        let rig = await Rig()
        var renamed = iPhone
        renamed.name = "Renamed iPhone"
        renamed.osVersion = "27.1"
        await rig.read(DeviceReading(device: renamed, connection: .away))
        #expect(await rig.library.rememberings.isEmpty, "Remembered as away")

        let reading = DeviceReading(device: renamed, connection: .wired, isLocked: false, developerMode: true)
        await rig.read(reading)
        #expect(await rig.library.rememberings == [renamed])
        #expect(rig.survey.devices == [renamed])
        await rig.read(reading)
        #expect(await rig.library.rememberings.count == 1, "Remembered again unchanged")
    }

    /// A reading started within 5 s of another doesn't start; one started after another wins.
    @Test func theLatestReadingWinsAndOneJustStartedHoldsOthersOff() async {
        let rig = await Rig()
        await rig.control.set(ready)
        await rig.upkeep.refresh(unlessReadWithin: .seconds(5))
        await rig.upkeep.refresh(unlessReadWithin: .seconds(5))
        #expect(await rig.control.reads == 1)
        rig.wait(6)
        await rig.upkeep.refresh(unlessReadWithin: .seconds(5))
        #expect(await rig.control.reads == 2)

        let gate = Gate()
        await rig.control.set(locked)
        await rig.control.hold(gate)
        let first = Task { await rig.upkeep.refresh() }
        _ = await eventually { await gate.isWaiting }
        await rig.control.set(ready)
        await rig.upkeep.refresh()
        #expect(rig.upkeep.readings[iPhone.id] == ready)
        await gate.open()
        await first.value
        #expect(rig.upkeep.readings[iPhone.id] == ready, "The earlier reading landed last")
    }

    /// Without Xcode there's nothing to read; a reading that fails otherwise has every Device away.
    @Test func whatAFailedReadingSays() async {
        let rig = await Rig()
        await rig.control.fail(with: FrontportError.xcodeMissing)
        await rig.upkeep.refresh()
        #expect(rig.upkeep.hasXcode == false)

        await rig.read(ready)
        #expect(rig.upkeep.hasXcode == true && rig.upkeep.readings[iPhone.id] == ready)

        await rig.control.fail(with: FrontportError.fileOperation("devicectl crashed."))
        await rig.upkeep.refresh()
        #expect(rig.upkeep.hasXcode == true)
        #expect(rig.upkeep.readings.isEmpty)
        #expect(rig.upkeep.knownDevices.map(\.connection) == [.away])
        #expect(rig.upkeep.team?.id == DeviceInstallationTests.team)
    }

    /// However many screens watch, one loop reads, and it stops once none does.
    @Test func oneLoopReadsWhileAnyScreenWatches() async {
        let rig = await Rig()
        await rig.control.set(ready)
        let first = Task { await rig.upkeep.watch() }
        let second = Task { await rig.upkeep.watch() }
        let watching = await eventually { rig.upkeep.watchers == 2 }
        #expect(watching)
        _ = await eventually { await rig.control.reads == 1 }
        #expect(await rig.control.reads == 1, "Each screen read")

        first.cancel()
        second.cancel()
        let stopped = await eventually { rig.upkeep.watchers == 0 }
        #expect(stopped)
    }

    // MARK: Alerts

    /// Seeding refused at its turn because the Device isn't ready waits there instead, with no alert; one that fails
    /// for another reason alerts.
    @Test func whichSeedingFailuresAlert() async {
        let rig = await Rig()
        await rig.read(locked)
        await rig.library.script(seeds: [
            .failure(FrontportError.deviceUnavailable(.locked, detail: "")), .failure(FrontportError.xcodeMissing),
        ])
        rig.upkeep.romsAdded(["aaa"])
        await rig.read(ready)
        #expect(await rig.seeds == 1)
        #expect(rig.alerts.isEmpty)
        #expect(rig.wait(on: locked) == .locked)

        await rig.read(ready)
        #expect(await rig.seeds == 2)
        #expect(rig.alerts.count == 1)
        #expect(rig.upkeep.status(of: port, on: ready).seedFailed)
    }
}

// MARK: Fakes

/// The time, as the test sets it.
@MainActor final class Clock {
    var now = Date(timeIntervalSince1970: 0)
}

/// The iPhone as the test says it reads.
actor ScriptedReadings {
    private var result: Result<[DeviceReading], any Error> = .success([])
    private var gate: Gate?
    /// How many times the Devices were read.
    private(set) var reads = 0

    func set(_ reading: DeviceReading) { result = .success([reading]) }
    func fail(with error: any Error) { result = .failure(error) }
    /// Holds the next reading, as it was when it started, until the gate opens.
    func hold(_ gate: Gate) { self.gate = gate }

    func readings() async throws -> [DeviceReading] {
        reads += 1
        let result = result
        if let gate {
            self.gate = nil
            await gate.wait()
        }
        return try result.get()
    }
}
