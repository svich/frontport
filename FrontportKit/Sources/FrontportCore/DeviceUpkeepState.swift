import Foundation

/// What Frontport keeps for each Installation on a Device while it's open, beside its record (DESIGN › Devices): the
/// plan Seeding last read there, what Seeding waits for or why it last failed, and why a Renew last failed. Fed what
/// happens, keyed by Port and Device, it says which Seeds and Renews on their own are due, and what each Installation's
/// row shows of it (`Facts`). It keeps no clock, as the time is given, and nothing between launches. `DeviceUpkeep`
/// keeps one and tells it what happened.
///
/// Seeding never runs while `DeviceReadiness` finds a reason on the Device against it (away, locked or Developer Mode
/// off), nor while the Port runs there: once a reading finds the Device ready again, the waits it ends come due, and
/// those for the Port to quit are checked by asking the Device what runs. What's missing on this Mac, such as Xcode,
/// fails Seeding instead. Apart from the Mac's `SeedingWait`, which it leaves alone.
///
/// A Renew is due on its own once it's due at all (`DeviceStatus.renewWindow`), while `DeviceReadiness` lets it Renew on
/// its Device as the latest reading found it (Xcode there, the Apple Team chosen the one it's signed with, the Device
/// reachable, unlocked and in Developer Mode, as far as it said), no change of the Port is under way and the user hasn't
/// turned Renewing on its own off (DESIGN › Renew). One that failed, the user's own included, holds that Installation
/// back until Frontport next comes to the front, the user chooses an Apple Team, or a reading at least `backOff` later:
/// never in a loop.
public struct DeviceUpkeepState: Equatable, Sendable {
    /// An Installation on a Device: the Port, and the Device.
    public struct Key: Hashable, Sendable {
        public var port: PortID
        public var device: DeviceID

        public init(_ port: PortID, on device: DeviceID) {
            self.port = port
            self.device = device
        }
    }

    /// What Seeding waits for.
    public enum Wait: Equatable, Sendable {
        /// The Device to be ready to Seed on (`isReady`).
        case unready
        /// The Port to quit on the Device.
        case running

        /// The wait a refusal from the Device Library means, or nil for a failure that's no reason to wait.
        public init?(refusal error: any Error) {
            if case FrontportError.running = error {
                self = .running
            } else if DeviceReadiness.Reason(refusal: error)?.isOnDevice == true {
                self = .unready
            } else {
                return nil
            }
        }
    }

    /// What an Installation's row shows of what's kept for it (`DeviceStatus`).
    public struct Facts: Hashable, Sendable {
        /// What Seeding there waits for, as the Device was last read: a wait for the Device counts only while it still
        /// isn't ready.
        public var wait: DeviceStatus.Seeding.Wait?
        /// Why Seeding there last failed, until it succeeds.
        public var seedFailure: String?
        /// Why the last Renew there failed, until one succeeds.
        public var renewFailure: String?

        public init(wait: DeviceStatus.Seeding.Wait? = nil, seedFailure: String? = nil, renewFailure: String? = nil) {
            self.wait = wait
            self.seedFailure = seedFailure
            self.renewFailure = renewFailure
        }
    }

    /// How long a failed Renew holds its Installation back, unless Frontport comes to the front first: an hour.
    public static let backOff: TimeInterval = 60 * 60

    /// What's kept for one Installation; none of it once there's nothing to keep.
    private struct Kept: Equatable, Sendable {
        var plan: DeviceSeedingPlan?
        var wait: Wait?
        var seedFailure: String?
        var renewFailure: RenewFailure?
        /// True from when a Renew started on its own until it ends.
        var isRenewing = false
    }

    /// A Renew that failed.
    private struct RenewFailure: Equatable, Sendable {
        var date: Date
        /// Why, as the user reads it.
        var message: String
        /// True until Frontport next comes to the front or the user chooses an Apple Team.
        var holdsBack: Bool
    }

    private var kept: [Key: Kept] = [:]
    /// Every Installation Seeding was requested for since launch: forgetting one leaves it here.
    private var asked: Set<Key> = []

    /// `seedFailures` is why Seeding failed on each, for previews.
    public init(seedFailures: [Key: String] = [:]) {
        for (key, message) in seedFailures { self[key].seedFailure = message }
    }

    /// What's kept for the Installation, dropped once it's nothing.
    private subscript(key: Key) -> Kept {
        get { kept[key] ?? Kept() }
        set { kept[key] = newValue == Kept() ? nil : newValue }
    }

    // MARK: Events

    /// ROMs were added for the Port, it was just installed on the Device, or the user asked to Seed: true to Seed now,
    /// when the Device is `ready`; otherwise it waits for a reading that finds it ready.
    public mutating func requested(_ key: Key, ready: Bool) -> Bool {
        asked.insert(key)
        self[key].wait = ready ? nil : .unready
        return ready
    }

    /// Seeding read what it would copy to the Device, or Seeded it.
    public mutating func read(_ plan: DeviceSeedingPlan?, for key: Key) {
        self[key].plan = plan
    }

    /// A Renew of the Installation started on its own, so it isn't started again while it waits its turn or runs, and
    /// its failure isn't presented.
    public mutating func renewStarted(_ key: Key) {
        self[key].isRenewing = true
    }

    /// A change of the Installation ended, at `now`. Seeding refused because the Device isn't ready or the Port runs
    /// there waits for that; done, it waits no more; failed otherwise, it says why until it succeeds; cancelled, nothing
    /// changes. A Renew, on its own or the user's, that failed or was cancelled holds the next one on its own back. An
    /// uninstall that succeeded forgets everything kept for it, and an install or update leaves its plan out of date.
    public mutating func ended(_ change: DeviceChange, of key: Key, _ outcome: Activities.Outcome, at now: Date) {
        switch change {
        case .renew:
            let failure: String? = switch outcome {
            case .succeeded: nil
            case .failed(let error): Self.message(error)
            // Not tried again at once either.
            case .cancelled: "It was cancelled."
            }
            self[key].isRenewing = false
            self[key].renewFailure = failure.map { RenewFailure(date: now, message: $0, holdsBack: true) }
        case .seed:
            switch outcome {
            case .succeeded:
                self[key].wait = nil
                self[key].seedFailure = nil
            case .failed(let error):
                if let wait = Wait(refusal: error) {
                    self[key].wait = wait
                } else {
                    self[key].wait = nil
                    self[key].seedFailure = Self.message(error)
                }
            case .cancelled:
                break
            }
        case .uninstall:
            // Still on its Device otherwise, it keeps what waits, failed or is held back there.
            if case .succeeded = outcome { forget(key) }
        case .install, .update:
            self[key].plan = nil
        }
    }

    /// The Installation left its Device, or its Device was forgotten: nothing waits, failed or is held back there any
    /// more.
    public mutating func forget(_ key: Key) {
        kept[key] = nil
    }

    /// Frontport came to the front: a failed Renew holds nothing back any more, though why it failed still shows.
    public mutating func activated() {
        for key in kept.keys { kept[key]?.renewFailure?.holdsBack = false }
    }

    /// The user chose another Apple Team: as when Frontport comes to the front, a failed Renew holds nothing back any
    /// more.
    public mutating func teamChanged() {
        activated()
    }

    // MARK: Answers

    /// True when the Device as `reading` found it is ready to Seed on: `DeviceReadiness` finds no reason there.
    public static func isReady(_ reading: DeviceReading) -> Bool {
        DeviceReadiness.reason(.seed, on: reading) == nil
    }

    /// What the Installation's row shows, its Device as `reading` found it.
    public func facts(_ key: Key, on reading: DeviceReading) -> Facts {
        let kept = self[key]
        let wait: DeviceStatus.Seeding.Wait? = switch (kept.wait, DeviceReadiness.reason(.seed, on: reading)) {
        case (.running?, _): .running
        case (.unready?, .away?): .away
        case (.unready?, .locked?): .locked
        case (.unready?, .developerModeOff?): .developerModeOff
        default: nil
        }
        return Facts(wait: wait, seedFailure: kept.seedFailure, renewFailure: kept.renewFailure?.message)
    }

    /// What Seeding last read from the Device: what it would copy there.
    public func plan(_ key: Key) -> DeviceSeedingPlan? { self[key].plan }

    /// What Seeding on the Device waits for, if anything.
    public func wait(_ key: Key) -> Wait? { self[key].wait }

    /// True while a Renew of the Installation started on its own hasn't ended: its failure isn't presented.
    public func isRenewing(_ key: Key) -> Bool { self[key].isRenewing }

    /// After a reading, the Seeds on Devices it found ready: those to request again now, and those that wait for the
    /// Port to quit, to request again once the Device says it doesn't run. Those to request are the waits for the
    /// Device, then of `unseeded`, the Installations whose record says ROMs in ROMs aren't there yet, those Seeding
    /// wasn't requested for since launch and doesn't wait for: a wait ends when Frontport quits, so after a relaunch each
    /// is requested once.
    public func seedsDue(readings: [DeviceID: DeviceReading], unseeded: [Key]) -> (seed: [Key], check: [Key]) {
        let ready = { (key: Key) in readings[key.device].map(Self.isReady) ?? false }
        let waiting = kept.filter { $0.value.wait != nil && ready($0.key) }.keys.sorted(by: Self.order)
        let unasked = Set(unseeded).filter { ready($0) && !asked.contains($0) && self[$0].wait == nil }.sorted(by: Self.order)
        return (waiting.filter { self[$0].wait == .unready } + unasked, waiting.filter { self[$0].wait == .running })
    }

    /// The Installations to Renew on their own now, by Port then Device, leaving out those started and not ended.
    /// `team` is the Apple Team chosen, while its certificate is in the keychain; `busy` the Ports with a change under
    /// way.
    public func renewsDue(
        _ installations: [DeviceInstallation], readings: [DeviceID: DeviceReading], busy: Set<PortID>,
        team: AppleTeamID?, hasXcode: Bool, enabled: Bool, now: Date
    ) -> [Key] {
        guard enabled else { return [] }
        let readiness = DeviceReadiness(hasXcode: hasXcode, team: team)
        return installations
            .filter { installation in
                let key = Key(installation.port, on: installation.device)
                guard let reading = readings[installation.device], !busy.contains(installation.port),
                    !self[key].isRenewing, installation.expires.timeIntervalSince(now) <= DeviceStatus.renewWindow,
                    readiness.reason(.renew, on: reading, signed: installation.team) == nil
                else { return false }
                guard let failure = self[key].renewFailure, failure.holdsBack else { return true }
                return now.timeIntervalSince(failure.date) >= Self.backOff
            }
            .map { Key($0.port, on: $0.device) }
            .sorted(by: Self.order)
    }

    /// By Port, then Device.
    private static func order(_ a: Key, _ b: Key) -> Bool { (a.port, a.device) < (b.port, b.device) }

    /// An error as the user reads it.
    static func message(_ error: any Error) -> String {
        (error as? FrontportError)?.errorDescription ?? error.localizedDescription
    }
}
