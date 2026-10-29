import Foundation

/// When the ROMs added for a Port are Seeded: never while it runs, so ROMs added then wait for it to quit. (Nor beside
/// another change to it: `Activities` runs Seeding after the Activity under way.) Fed what happens to each Port, it says
/// what to do next; whoever holds it does that, and tells it what came of it.
///
/// macOS may still list a Port for a moment after it quits, and the Library then refuses to Seed. That's tried again a
/// few times, waiting longer each time; after that the ROMs wait for the Port's next quit, or for Try Again.
public struct SeedingWait: Equatable, Sendable {
    /// What to do next for a Port.
    public enum Step: Equatable, Sendable {
        /// Seed now, as the Port's Activity.
        case seed
        /// Wait this long, then ask `due` whether to Seed.
        case retry(after: Duration)
        /// Nothing now: the ROMs wait for the Port to quit, or there's nothing waiting.
        case wait
    }

    /// Tries after a quit that the Library refused, before the ROMs wait for the next quit.
    public static let tries = 4

    /// Ports whose ROMs wait for them to quit.
    private var waiting: Set<PortID> = []
    /// Tries so far since the last quit, by Port.
    private var tried: [PortID: Int] = [:]

    public init() {}

    /// ROMs were added for the Port, or the user asked to try again.
    public mutating func requested(_ port: PortID, running: Bool) -> Step {
        if running {
            waiting.insert(port)
            return .wait
        }
        waiting.remove(port)
        return .seed
    }

    /// The Library refused to Seed, finding the Port running: the ROMs wait for it to quit.
    public mutating func refused(_ port: PortID) {
        waiting.insert(port)
    }

    /// An Activity on the Port ended; `seeded` when it Seeded. ROMs the Library refused
    /// for a Port that no longer runs are tried again.
    public mutating func ended(_ port: PortID, seeded: Bool, running: Bool) -> Step {
        if seeded { tried[port] = nil }
        guard waiting.contains(port), !running else { return .wait }
        let attempt = tried[port, default: 0]
        guard attempt < Self.tries else {
            tried[port] = nil
            return .wait
        }
        tried[port] = attempt + 1
        return .retry(after: .seconds(1 << attempt))
    }

    /// The Port quit, however it was opened: true when ROMs wait for it, to be requested again now, with every try ahead.
    public mutating func quit(_ port: PortID) -> Bool {
        guard waiting.contains(port) else { return false }
        tried[port] = nil
        return true
    }

    /// A retry's wait is over: true when the ROMs still wait and the Port no longer runs, to be requested again now.
    public func due(_ port: PortID, running: Bool) -> Bool {
        waiting.contains(port) && !running
    }

    /// True while Seeding waits for the running Port to quit.
    public func isWaiting(_ port: PortID, running: Bool) -> Bool {
        waiting.contains(port) && running
    }
}
