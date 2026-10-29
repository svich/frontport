import Foundation
import Observation

/// The Activity under way on each Port, for the App to show and Status to read. A Port has one at a time, shown from
/// when its change starts until the change has ended, its state reloaded. A change asked for while another runs, such
/// as Seeding ROMs added during an update, waits its turn and then runs as an Activity of its own: the Library takes one
/// change per Port at a time anyway, and this way none runs unseen.
@MainActor @Observable
public final class Activities {
    /// What came of a change.
    public enum Outcome: Sendable {
        case succeeded
        case failed(any Error)
        /// Cancelled, under way or waiting its turn: never a failure to present.
        case cancelled
    }

    /// A change's work, reporting progress from any thread.
    public typealias Work = @Sendable (@escaping ProgressHandler) async throws -> Void
    /// Ends a change while its Activity still shows: reloads what the change may have touched, and acts on what came
    /// of it.
    public typealias End = @MainActor (Outcome) async -> Void

    /// Under way, by Port.
    public private(set) var underWay: [PortID: Activity]
    /// Why Seeding last failed during a change, by Port: a change of Release reports that as progress rather than
    /// failing.
    public private(set) var seedingFailures: [PortID: String] = [:]
    /// Told when a Port's Activity starts or ends, not as it progresses.
    @ObservationIgnored public var onChange: @MainActor (PortID) -> Void = { _ in }

    private struct Change {
        var kind: Activity.Kind
        var work: Work
        var end: End
        var isCancelled = false
    }

    /// Changes waiting for the Activity under way, by Port, in the order asked.
    @ObservationIgnored private var waiting: [PortID: [Change]] = [:]
    @ObservationIgnored private var tasks: [PortID: Task<Void, Never>] = [:]

    /// `underWay` is what previews show; it never ends.
    public init(_ underWay: [PortID: Activity] = [:]) {
        self.underWay = underWay
    }

    public subscript(port: PortID) -> Activity? { underWay[port] }

    /// Runs a change as the Port's Activity, now or once the one under way and those asked before have ended. Its
    /// progress shows as the Activity's, newest only, so a burst never floods the main actor; a Seeding message is kept
    /// in `seedingFailures`. `end` runs once, whatever came of it, before the Activity clears.
    public func run(_ kind: Activity.Kind, on port: PortID, _ work: @escaping Work, end: @escaping End) {
        let change = Change(kind: kind, work: work, end: end)
        if underWay[port] != nil || tasks[port] != nil {
            waiting[port, default: []].append(change)
        } else {
            start(change, on: port)
        }
    }

    /// Cancels the Port's change under way and every one waiting its turn, which end as cancelled without running.
    public func cancel(_ port: PortID) {
        waiting[port] = waiting[port]?.map { change in
            var change = change
            change.isCancelled = true
            return change
        }
        tasks[port]?.cancel()
    }

    /// Drops the Seeding failures of Ports for which `stands` is false, such as those whose ROMs are now Seeded.
    public func keepSeedingFailures(where stands: (PortID) -> Bool) {
        seedingFailures = seedingFailures.filter { stands($0.key) }
    }

    private func start(_ change: Change, on port: PortID) {
        underWay[port] = Activity(change.kind)
        onChange(port)
        let (updates, continuation) = AsyncStream.makeStream(of: ProgressUpdate.self, bufferingPolicy: .bufferingNewest(1))
        let progress = Task { [weak self] in
            for await update in updates {
                self?.underWay[port]?.progress = update
                if update.phase == .seeding, let message = update.message { self?.seedingFailures[port] = message }
            }
        }
        tasks[port] = Task { [weak self] in
            let outcome: Outcome
            do {
                try await change.work { continuation.yield($0) }
                outcome = .succeeded
            } catch is CancellationError {
                outcome = .cancelled
            } catch {
                outcome = .failed(error)
            }
            continuation.finish()
            await progress.value
            await change.end(outcome)
            await self?.next(after: port)
        }
    }

    /// Clears the Port's Activity and starts the next change waiting, ending cancelled ones on the way.
    private func next(after port: PortID) async {
        underWay[port] = nil
        while let change = waiting[port]?.first {
            waiting[port]?.removeFirst()
            if waiting[port]?.isEmpty == true { waiting[port] = nil }
            guard change.isCancelled else {
                start(change, on: port)
                return
            }
            await change.end(.cancelled)
        }
        tasks[port] = nil
        onChange(port)
    }
}
