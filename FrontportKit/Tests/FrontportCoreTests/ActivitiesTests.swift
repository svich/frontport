import Foundation
import Testing
@testable import FrontportCore

/// Changes run as Activities with work that waits until a test lets it go: no Library, no clock.
@MainActor @Suite struct ActivitiesTests {
    let port: PortID = "soh"

    /// Holds work until opened.
    actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            for waiter in waiters { waiter.resume() }
            waiters = []
        }
    }

    /// What happened, in order, and a way to wait for the next of it.
    @MainActor final class Log {
        private(set) var events: [String] = []
        private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

        func record(_ event: String) {
            events.append(event)
            let due = waiters.filter { $0.count <= events.count }
            waiters.removeAll { $0.count <= events.count }
            for waiter in due { waiter.continuation.resume() }
        }

        /// Returns once `count` events have happened.
        func until(_ count: Int) async {
            if events.count >= count { return }
            await withCheckedContinuation { waiters.append((count, $0)) }
        }
    }

    static func name(_ outcome: Activities.Outcome) -> String {
        switch outcome {
        case .succeeded: "succeeded"
        case .failed(let error): "failed: \(error)"
        case .cancelled: "cancelled"
        }
    }

    /// Activities whose starts and ends `log` hears of, as "shows <kind>" and "clear".
    static func activities(_ log: Log) -> Activities {
        let activities = Activities()
        activities.onChange = { [weak activities] port in
            log.record(activities?[port].map { "shows \($0.kind)" } ?? "clear")
        }
        return activities
    }

    /// Ends a change into `log`, noting whether its Activity still showed.
    static func end(_ kind: Activity.Kind, _ activities: Activities, _ log: Log, port: PortID) -> Activities.End {
        { outcome in log.record("end \(kind) \(name(outcome))" + (activities[port] == nil ? " unseen" : "")) }
    }

    @Test func aChangeShowsFromItsStartUntilItHasEnded() async {
        let log = Log()
        let activities = Self.activities(log)
        let gate = Gate()
        activities.run(.update, on: port, { progress in
            progress(ProgressUpdate(.downloading, fraction: 0.5))
            await gate.wait()
        }, end: Self.end(.update, activities, log, port: port))
        #expect(activities[port] == Activity(.update))
        #expect(activities[port]?.progress.phase == .resolving)

        await gate.open()
        await log.until(3)
        #expect(log.events == ["shows update", "end update succeeded", "clear"])
        #expect(activities[port] == nil)
    }

    @Test func progressShowsAsTheActivitysAndSeedingMessagesAreKept() async {
        let log = Log()
        let activities = Self.activities(log)
        let gate = Gate()
        activities.run(.update, on: port, { progress in
            progress(ProgressUpdate(.downloading, fraction: 0.2))
            progress(ProgressUpdate(.seeding, message: "Seeding Master Quest failed."))
            await gate.wait()
        }, end: { _ in log.record("end") })
        while activities[port]?.progress.phase != .seeding { await Task.yield() }
        #expect(activities.seedingFailures[port] == "Seeding Master Quest failed.")

        await gate.open()
        await log.until(3)
        #expect(activities.seedingFailures[port] == "Seeding Master Quest failed.", "kept after the change")
        activities.keepSeedingFailures { $0 != "soh" }
        #expect(activities.seedingFailures.isEmpty)
    }

    @Test func failuresAndCancellingEndTheChange() async {
        let log = Log()
        let activities = Self.activities(log)
        activities.run(.applyROMs, on: port, { _ in throw FrontportError.running("soh") },
            end: Self.end(.applyROMs, activities, log, port: port))
        await log.until(3)
        activities.run(.update, on: port, { _ in try await Task.sleep(for: .seconds(600)) },
            end: Self.end(.update, activities, log, port: port))
        activities.cancel(port)
        await log.until(6)
        #expect(log.events == [
            "shows applyROMs", "end applyROMs failed: \(FrontportError.running("soh"))", "clear",
            "shows update", "end update cancelled", "clear",
        ])
    }

    /// Seeding asked for during an update waits for it, then runs and shows as its own Activity.
    @Test func aChangeAskedForDuringAnotherWaitsItsTurn() async {
        let log = Log()
        let activities = Self.activities(log)
        let gate = Gate()
        activities.run(.update, on: port, { _ in await gate.wait() }, end: Self.end(.update, activities, log, port: port))
        activities.run(.applyROMs, on: port, { _ in await log.record("seeding") },
            end: Self.end(.applyROMs, activities, log, port: port))
        #expect(activities[port]?.kind == .update)
        #expect(log.events == ["shows update"], "Seeding doesn't start beside the update")

        await gate.open()
        await log.until(6)
        #expect(log.events == [
            "shows update", "end update succeeded", "shows applyROMs", "seeding", "end applyROMs succeeded", "clear",
        ])
    }

    /// Cancel stops the change under way, and those waiting end cancelled without running or showing.
    @Test func cancellingEndsTheChangesWaitingWithoutRunningThem() async {
        let log = Log()
        let activities = Self.activities(log)
        activities.run(.update, on: port, { _ in try await Task.sleep(for: .seconds(600)) },
            end: Self.end(.update, activities, log, port: port))
        activities.run(.applyROMs, on: port, { _ in await log.record("seeding") },
            end: Self.end(.applyROMs, activities, log, port: port))
        activities.cancel(port)
        await log.until(4)
        #expect(log.events == ["shows update", "end update cancelled", "end applyROMs cancelled unseen", "clear"])

        activities.run(.applyROMs, on: port, { _ in await log.record("seeding") },
            end: Self.end(.applyROMs, activities, log, port: port))
        await log.until(8)
        #expect(log.events.suffix(4) == ["shows applyROMs", "seeding", "end applyROMs succeeded", "clear"],
            "a change asked for after Cancel runs")
    }

    @Test func eachPortHasItsOwnActivity() async {
        let log = Log()
        let activities = Self.activities(log)
        let gate = Gate()
        activities.run(.update, on: port, { _ in await gate.wait() }, end: { _ in log.record("end soh") })
        activities.run(.install, on: "starship", { _ in await gate.wait() }, end: { _ in log.record("end starship") })
        #expect(activities[port]?.kind == .update)
        #expect(activities["starship"]?.kind == .install)

        await gate.open()
        await log.until(6)
        #expect(activities.underWay.isEmpty)
    }
}
