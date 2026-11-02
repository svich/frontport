import Foundation
import Testing
@testable import FrontportCore

private let now = Date(timeIntervalSince1970: 1_850_000_000)
private let day: TimeInterval = 86_400
private let iPhone = DeviceStatusTests.iPhone
private let iPad = DeviceStatusTests.iPad.id
private let tiny = DeviceUpkeepState.Key("tiny", on: iPhone.id)
private let other = DeviceUpkeepState.Key("other", on: iPhone.id)
private let tinyOnIPad = DeviceUpkeepState.Key("tiny", on: iPad)

private func reading(
    _ connection: DeviceReading.Connection = .wired, isLocked: Bool? = false, developerMode: Bool? = true
) -> DeviceReading {
    DeviceReading(device: iPhone, connection: connection, isLocked: isLocked, developerMode: developerMode)
}

private let ready = [iPhone.id: reading()]
private let full = FrontportError.fileOperation("The disk is full.")

/// What Frontport keeps for each Installation on a Device, with no clock, no Devices and no Library: just what happens,
/// in order.
@Suite struct DeviceUpkeepStateTests {
    // MARK: Seeding

    @Test func seedsAtOnceOnAReadyDeviceAndWaitsForOneThatIsnt() {
        var state = DeviceUpkeepState()
        let atOnce = state.requested(tiny, ready: true)
        #expect(atOnce && state.wait(tiny) == nil)
        let later = state.requested(tinyOnIPad, ready: false)
        #expect(!later && state.wait(tinyOnIPad) == .unready)
        let iPadReady = [iPad: DeviceReading(device: DeviceStatusTests.iPad, connection: .wired, isLocked: false)]
        #expect(state.seedsDue(readings: [:], unseeded: []).seed.isEmpty)
        #expect(state.seedsDue(readings: iPadReady, unseeded: []).seed == [tinyOnIPad])
        // Asked again once it's ready, it Seeds and stops waiting.
        let again = state.requested(tinyOnIPad, ready: true)
        #expect(again)
        let due = state.seedsDue(readings: iPadReady, unseeded: [])
        #expect(due.seed.isEmpty && due.check.isEmpty)
    }

    /// Refused because the Device isn't ready or the Port runs there, Seeding waits for that, with no failure; refused
    /// for anything else, it fails and says why until it succeeds. Cancelled, nothing changes.
    @Test func howASeedEnds() {
        var state = DeviceUpkeepState()
        state.ended(.seed, of: tiny, .failed(FrontportError.deviceUnavailable(.locked, detail: "")), at: now)
        #expect(state.wait(tiny) == .unready && state.facts(tiny, on: reading()).seedFailure == nil)
        state.ended(.seed, of: tiny, .failed(FrontportError.running("tiny")), at: now)
        #expect(state.wait(tiny) == .running)

        state.ended(.seed, of: tiny, .failed(full), at: now)
        #expect(state.wait(tiny) == nil && state.facts(tiny, on: reading()).seedFailure == "The disk is full.")
        state.ended(.seed, of: tiny, .cancelled, at: now)
        #expect(state.facts(tiny, on: reading()).seedFailure == "The disk is full.")

        state.ended(.seed, of: tiny, .failed(FrontportError.running("tiny")), at: now)
        state.ended(.seed, of: tiny, .succeeded, at: now)
        #expect(state.wait(tiny) == nil && state.facts(tiny, on: reading()) == .init())
        #expect(state == DeviceUpkeepState(), "kept nothing")
    }

    @Test func refusalsAreTheDevicesAndThePortsRunning() {
        #expect(DeviceUpkeepState.Wait(refusal: FrontportError.running("tiny")) == .running)
        #expect(DeviceUpkeepState.Wait(refusal: FrontportError.deviceUnavailable(.away, detail: "")) == .unready)
        #expect(DeviceUpkeepState.Wait(refusal: FrontportError.deviceUnavailable(.locked, detail: "")) == .unready)
        #expect(DeviceUpkeepState.Wait(refusal: FrontportError.deviceUnavailable(.failed, detail: "")) == nil)
        #expect(DeviceUpkeepState.Wait(refusal: FrontportError.xcodeMissing) == nil)
        #expect(DeviceUpkeepState.Wait(refusal: full) == nil)
        #expect(DeviceUpkeepState.Wait(refusal: CancellationError()) == nil)
    }

    /// The waits on Devices the reading found ready come due, those for the Port to quit to check first; due isn't done,
    /// so they hold until requested again or ended.
    @Test func aWaitComesDueOnAReadingThatFindsTheDeviceReady() {
        var state = DeviceUpkeepState()
        state.ended(.seed, of: tiny, .failed(FrontportError.running("tiny")), at: now)
        state.ended(.seed, of: other, .failed(FrontportError.deviceUnavailable(.away, detail: "")), at: now)
        for found in [[:], [iPhone.id: reading(.away)], [iPhone.id: reading(isLocked: true)]] {
            let due = state.seedsDue(readings: found, unseeded: [])
            #expect(due.seed.isEmpty && due.check.isEmpty)
        }
        let due = state.seedsDue(readings: ready, unseeded: [])
        #expect(due.seed == [other] && due.check == [tiny])
        #expect(state.seedsDue(readings: ready, unseeded: []) == due)
        state.ended(.seed, of: tiny, .failed(full), at: now)
        #expect(state.seedsDue(readings: ready, unseeded: []).check.isEmpty)
    }

    /// After a relaunch, what a record says isn't on a ready Device yet is requested once, after the waits, whatever came
    /// of it; one that waits is left to its wait.
    @Test func whatWasntRequestedSinceLaunchIsRequestedOnce() {
        var state = DeviceUpkeepState()
        #expect(state.seedsDue(readings: ready, unseeded: [tiny, other, tiny]).seed == [other, tiny])
        #expect(state.seedsDue(readings: [:], unseeded: [tiny]).seed.isEmpty, "on a Device that isn't ready")
        _ = state.requested(tiny, ready: true)
        _ = state.requested(other, ready: true)
        state.forget(other)
        #expect(state.seedsDue(readings: ready, unseeded: [tiny, other]).seed.isEmpty, "not again, nor once forgotten")

        state.ended(.seed, of: tinyOnIPad, .failed(FrontportError.running("tiny")), at: now)
        let iPadReady = [iPad: DeviceReading(device: DeviceStatusTests.iPad, connection: .wired, isLocked: false)]
        #expect(state.seedsDue(readings: iPadReady, unseeded: [tinyOnIPad]) == ([], [tinyOnIPad]))
        let waiting = DeviceUpkeepState.Key("waiting", on: iPad)
        _ = state.requested(waiting, ready: false)
        let due = state.seedsDue(readings: iPadReady, unseeded: [DeviceUpkeepState.Key("behind", on: iPad), waiting])
        #expect(due.seed == [waiting, DeviceUpkeepState.Key("behind", on: iPad)], "waits first")
    }

    /// What the row shows of a wait: for the Port to quit, however the Device is; for the Device, only while it still
    /// isn't ready, and for what it said.
    @Test func theRowsWaitIsTheDevicesAsLastRead() {
        var state = DeviceUpkeepState()
        #expect(state.facts(tiny, on: reading(.away)).wait == nil)
        _ = state.requested(tiny, ready: false)
        let cases: [(DeviceReading, DeviceStatus.Seeding.Wait?)] = [
            (reading(.away), .away), (reading(isLocked: true), .locked), (reading(developerMode: false), .developerModeOff),
            (reading(), nil), (reading(isLocked: nil, developerMode: nil), nil),
        ]
        for (found, wait) in cases { #expect(state.facts(tiny, on: found).wait == wait, "\(found)") }
        state.ended(.seed, of: tiny, .failed(FrontportError.running("tiny")), at: now)
        #expect(state.facts(tiny, on: reading(.away)).wait == .running && state.facts(tiny, on: reading()).wait == .running)
    }

    /// A plan read is kept until the app there is installed or updated over, which leaves it out of date.
    @Test func aPlanIsKeptUntilTheAppIsReplaced() {
        var state = DeviceUpkeepState()
        let plan = DeviceSeedingPlan(items: [])
        state.read(plan, for: tiny)
        #expect(state.plan(tiny) == plan && state.plan(other) == nil)
        state.ended(.seed, of: tiny, .failed(full), at: now)
        #expect(state.plan(tiny) == plan)
        state.ended(.update, of: tiny, .succeeded, at: now)
        #expect(state.plan(tiny) == nil)
        state.read(plan, for: tiny)
        state.ended(.install, of: tiny, .failed(full), at: now)
        #expect(state.plan(tiny) == nil)
    }

    /// Uninstalled from the Device, or the Device forgotten: nothing waits, failed or is held back there any more, and
    /// nothing else is touched.
    @Test func anUninstallOrForgettingDropsEverythingKept() {
        for forget: (inout DeviceUpkeepState) -> Void in [
            { $0.ended(.uninstall, of: tiny, .succeeded, at: now) }, { $0.forget(tiny) },
        ] {
            var state = DeviceUpkeepState()
            state.read(DeviceSeedingPlan(items: []), for: tiny)
            state.ended(.seed, of: tiny, .failed(full), at: now)
            state.renewStarted(tiny)
            state.ended(.renew, of: tiny, .failed(full), at: now)
            state.renewStarted(tiny)
            state.ended(.seed, of: tiny, .failed(FrontportError.running("tiny")), at: now)
            state.ended(.seed, of: other, .failed(full), at: now)
            forget(&state)
            #expect(state.plan(tiny) == nil && state.wait(tiny) == nil && !state.isRenewing(tiny))
            #expect(state.facts(tiny, on: reading()) == .init())
            #expect(state.facts(other, on: reading()).seedFailure != nil)
            #expect(Self.renews(state) == [tiny], "its Renew held back")
        }
    }

    /// An uninstall that failed or was cancelled leaves the Installation on its Device, and everything kept for it.
    @Test(arguments: [Activities.Outcome.failed(full), .cancelled])
    func anUninstallThatDidntSucceedKeepsEverything(_ outcome: Activities.Outcome) {
        var state = DeviceUpkeepState()
        state.read(DeviceSeedingPlan(items: []), for: tiny)
        state.ended(.seed, of: tiny, .failed(full), at: now)
        state.renewStarted(tiny)
        state.ended(.renew, of: tiny, .failed(full), at: now)
        state.ended(.seed, of: tiny, .failed(FrontportError.running("tiny")), at: now)
        let before = state

        state.ended(.uninstall, of: tiny, outcome, at: now)

        #expect(state == before)
        #expect(state.wait(tiny) != nil && state.facts(tiny, on: reading()).seedFailure != nil)
        #expect(Self.renews(state).isEmpty, "its Renew still held back")
    }

    @Test func previewsSayWhySeedingFailed() {
        let state = DeviceUpkeepState(seedFailures: [tiny: "It failed."])
        #expect(state.facts(tiny, on: reading()) == .init(seedFailure: "It failed."))
    }

    // MARK: Renewing

    static let due = DeviceInstallationTests.installation(
        profileExpires: now.addingTimeInterval(day), certificateExpires: now.addingTimeInterval(365 * day))

    static func renews(
        _ state: DeviceUpkeepState = DeviceUpkeepState(), installations: [DeviceInstallation] = [due],
        readings: [DeviceID: DeviceReading] = ready, busy: Set<PortID> = [], team: AppleTeamID? = DeviceInstallationTests.team,
        hasXcode: Bool = true, enabled: Bool = true, at time: Date = now
    ) -> [DeviceUpkeepState.Key] {
        state.renewsDue(installations, readings: readings, busy: busy, team: team, hasXcode: hasXcode, enabled: enabled, now: time)
    }

    @Test func renewDueWhenEverythingIsReady() {
        #expect(Self.renews() == [tiny])
        let expired = DeviceInstallationTests.installation(
            profileExpires: now.addingTimeInterval(-day), certificateExpires: now.addingTimeInterval(365 * day))
        #expect(Self.renews(installations: [expired]) == [tiny], "expired too")
        let far = DeviceInstallationTests.installation(
            profileExpires: now.addingTimeInterval(3 * day), certificateExpires: now.addingTimeInterval(365 * day))
        #expect(Self.renews(installations: [far]).isEmpty, "not before it's due")
    }

    /// The Device reachable, unlocked and in Developer Mode, no change of the Port under way, the Apple Team it's signed
    /// with, Xcode, and the user not having turned it off.
    @Test func eachConditionHoldsARenewBack() {
        for found in [reading(.away), reading(isLocked: true), reading(developerMode: false)] {
            #expect(Self.renews(readings: [iPhone.id: found]).isEmpty, "\(found)")
        }
        #expect(Self.renews(readings: [:]).isEmpty, "a Device the reading didn't find")
        #expect(Self.renews(readings: [iPhone.id: DeviceReading(device: iPhone, connection: .network)]) == [tiny],
            "what the Device didn't say doesn't hold it back")
        #expect(Self.renews(busy: ["tiny"]).isEmpty)
        #expect(Self.renews(team: AppleTeamID("ZZZZZ99999")).isEmpty && Self.renews(team: nil).isEmpty)
        #expect(Self.renews(hasXcode: false).isEmpty)
        #expect(Self.renews(enabled: false).isEmpty)
    }

    /// Once started on its own, it isn't started again while it waits its turn or runs.
    @Test func notTwiceAtOnce() {
        var state = DeviceUpkeepState()
        state.renewStarted(tiny)
        #expect(state.isRenewing(tiny) && Self.renews(state).isEmpty)
        state.ended(.renew, of: tiny, .succeeded, at: now)
        #expect(!state.isRenewing(tiny) && state.facts(tiny, on: reading()).renewFailure == nil)
        #expect(Self.renews(state) == [tiny])
    }

    /// A failure, on its own or the user's, holds it back for an hour of readings, or until Frontport next comes to the
    /// front or the user chooses an Apple Team, never in a loop; why it failed shows until one succeeds.
    @Test func aFailedRenewBacksOff() {
        var state = DeviceUpkeepState()
        state.renewStarted(tiny)
        state.ended(.renew, of: tiny, .failed(FrontportError.provisioningFailed("None lasts longer.")), at: now)
        let message = state.facts(tiny, on: reading()).renewFailure
        #expect(message != nil && !state.isRenewing(tiny))
        #expect(Self.renews(state, at: now.addingTimeInterval(10)).isEmpty)
        #expect(Self.renews(state, at: now.addingTimeInterval(DeviceUpkeepState.backOff - 1)).isEmpty)
        #expect(Self.renews(state, at: now.addingTimeInterval(DeviceUpkeepState.backOff)) == [tiny])

        state.activated()
        #expect(Self.renews(state, at: now.addingTimeInterval(10)) == [tiny], "coming to the front tries again")
        #expect(state.facts(tiny, on: reading()).renewFailure == message)

        // The user's own, cancelled, holds back too, until they choose an Apple Team.
        state.ended(.renew, of: tiny, .cancelled, at: now.addingTimeInterval(20))
        #expect(state.facts(tiny, on: reading()).renewFailure == "It was cancelled.")
        #expect(Self.renews(state, at: now.addingTimeInterval(30)).isEmpty, "and holds back again")
        state.teamChanged()
        #expect(Self.renews(state, at: now.addingTimeInterval(30)) == [tiny])

        state.ended(.renew, of: tiny, .succeeded, at: now.addingTimeInterval(40))
        #expect(state == DeviceUpkeepState(), "kept nothing")
    }

    /// A Renew's failure is the Installation's alone.
    @Test func aFailureHoldsBackOnlyItsInstallation() {
        var state = DeviceUpkeepState()
        state.ended(.renew, of: tiny, .failed(full), at: now)
        var onIPad = Self.due
        onIPad.device = iPad
        let iPadReady = [iPad: DeviceReading(device: DeviceStatusTests.iPad, connection: .wired, isLocked: false)]
        #expect(Self.renews(state, installations: [Self.due, onIPad], readings: ready.merging(iPadReady) { a, _ in a })
            == [tinyOnIPad])
    }
}
