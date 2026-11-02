import Foundation

/// What a Port is doing or has on one Device, and which actions that allows there now, each with why when it doesn't
/// (DESIGN › Devices). Built from the App's state alone, never `devicectl` or the disk: the Device's latest reading,
/// the Port's Installation there, where its ROMs stand there, what Seeding there waits for and why Seeding or Renewing
/// there last failed (`DeviceUpkeepState.Facts`), the Apple Team chosen, the Update its Channel offers, Xcode and the
/// Port's Activity, so the Port page's row and the intent it starts make one decision. Installing goes through the
/// Port's Install on iPhone or iPad… instead (`DeviceInstallStatus`), which asks which Devices to install on.
public struct DeviceStatus: Hashable, Sendable {
    /// The one state the Port shows on the Device, in order of precedence.
    public enum State: Hashable, Sendable {
        /// The Port's Activity is a change on this Device.
        case working(Activity)
        case installed(DeviceInstallation)
        /// Not on the Device.
        case available
    }

    /// Something the user can do with a Port on a Device, in the order its row offers them.
    public enum Action: Hashable, Sendable {
        /// Installs the newer iOS Release its Channel offers over the app there, keeping its Data, then Seeds.
        case update
        /// Signs the app kept for it again with a Provisioning Profile that lasts longer, and installs that over it,
        /// keeping its Data.
        case renew
        /// Copies the ROMs in ROMs that aren't on the Device yet into the app's container there.
        case seed
        /// Removes the app from the Device, and its Data there with it.
        case uninstall

        /// The change to the Installation it makes, as the Port's Activity.
        public var change: DeviceChange {
            switch self {
            case .update: .update
            case .renew: .renew
            case .seed: .seed
            case .uninstall: .uninstall
            }
        }
    }

    /// Why an action the Port has on the Device can't be taken now, in the order the user fixes them: the Device's
    /// readiness first (`DeviceReadiness.Reason`), then the Port's own. Install on iPhone or iPad… gives the same
    /// reasons (`DeviceInstallStatus.Reason`), so each has one wording.
    public enum Reason: Hashable, Sendable {
        /// Xcode with its iOS platform isn't installed.
        case needsXcode
        /// No Apple Team is in the keychain: Xcode has no Apple account to make one from.
        case noAppleTeam
        /// Apple Teams are in the keychain, but none is chosen, or the one chosen has its certificate gone.
        case noAppleTeamChosen
        /// The Apple Team chosen isn't the one the app there is signed with: another one's bundle ID is an app of its
        /// own, so it would be an install of its own, with Data of its own.
        case otherAppleTeam(AppleTeamID)
        /// The Device isn't reachable now.
        case away
        /// The Device is locked with its passcode.
        case locked
        /// Developer Mode is off on the Device.
        case developerModeOff
        /// The Port runs on the Device, as the Device said when Seeding last asked: Seeding waits, and Renewing would
        /// stop it.
        case running
        /// Install on iPhone or iPad… only: Frontport knows no Device, as none was ever connected, or every one was
        /// forgotten.
        case noDevice
        /// One change at a time, on this Mac and every Device: this one is under way.
        case activity(Activity.Kind)
        /// The Catalog no longer lists the Port, so it gets no Updates, nor new Installations.
        case unknownEntry

        /// The Device's readiness reason, as the row gives it; `hasAppleTeams` is whether any Apple Team is in the
        /// keychain, which says what's missing without one chosen.
        public init(_ reason: DeviceReadiness.Reason, hasAppleTeams: Bool) {
            self = switch reason {
            case .needsXcode: .needsXcode
            case .noAppleTeam: hasAppleTeams ? .noAppleTeamChosen : .noAppleTeam
            case .otherAppleTeam(let team): .otherAppleTeam(team)
            case .away: .away
            case .locked: .locked
            case .developerModeOff: .developerModeOff
            }
        }
    }

    /// Whether an action can be taken now.
    public enum Availability: Hashable, Sendable {
        case allowed
        /// The Port has it on the Device, but something stands in the way.
        case disabled(Reason)
        /// The Port has nothing it would act on there, such as no Installation to uninstall, nothing newer to update
        /// to, or nothing to Seed.
        case unavailable
    }

    /// Where the Port's ROMs stand on the Device, as its row says, the first that holds of these, in order.
    public enum Seeding: Hashable, Sendable {
        /// What Seeding waits for before it copies what isn't there yet.
        public enum Wait: Hashable, Sendable {
            /// The Port to quit on the Device.
            case running
            /// The Device to be connected.
            case away
            /// The Device to be unlocked.
            case locked
            /// Developer Mode to be turned on there.
            case developerModeOff
        }

        /// These Requirements' folders there hold other ROMs, so Seeding leaves them alone.
        case held([Requirement])
        /// These Requirements' ROMs in ROMs aren't there yet, and Seeding waits to copy them.
        case waiting([Requirement], Wait)
        /// These Requirements' ROMs in ROMs aren't there yet, and Seeding them last failed.
        case failed([Requirement])
        /// These Requirements' ROMs in ROMs aren't there yet.
        case unseeded([Requirement])
        /// No ROM these Requirements accept is in ROMs, and none was Seeded there.
        case missing([Requirement])
        /// These Requirements' ROMs are there; `isLastKnown` while the Device can't be reached, from the record.
        case seeded([Requirement], isLastKnown: Bool)

        /// Where `matching` stands, given what Seeding waits for and whether it last failed; nil for nothing to Seed.
        public init?(_ matching: DeviceMatching?, wait: Wait?, failed: Bool) {
            guard let matching else { return nil }
            let held = matching.requirements(.held)
            let unseeded = matching.requirements(.unseeded)
            let missing = matching.requirements(.missing)
            if !held.isEmpty {
                self = .held(held)
            } else if !unseeded.isEmpty {
                self = wait.map { .waiting(unseeded, $0) } ?? (failed ? .failed(unseeded) : .unseeded(unseeded))
            } else if !missing.isEmpty {
                self = .missing(missing)
            } else {
                self = .seeded(matching.requirements(.seeded), isLastKnown: matching.isLastKnown)
            }
        }
    }

    /// When the Port's app on the Device stops launching, once Renew is due, or why the last Renew failed.
    public enum Renewal: Hashable, Sendable {
        /// It stops launching in this many whole days, rounded down: 0 within the last day.
        case due(daysLeft: Int)
        /// It has stopped launching: its Provisioning Profile or certificate expired.
        case expired
        /// The last Renew failed, for this reason as the user reads it: until one succeeds.
        case failed(String)

        /// Due or expired as of `now`; nil before `renewWindow`.
        public init?(_ installation: DeviceInstallation, now: Date) {
            let left = installation.expires.timeIntervalSince(now)
            guard left <= DeviceStatus.renewWindow else { return nil }
            self = left <= 0 ? .expired : .due(daysLeft: Int(left / 86_400))
        }
    }

    /// How long before its app stops launching Renew is due: 2 days.
    public static let renewWindow: TimeInterval = 2 * 24 * 60 * 60

    public let state: State
    /// The Device as last read: away when the latest reading didn't find it.
    public let reading: DeviceReading

    /// Where the iOS version's Runtime Requirements stand on the Device; nil when it isn't there or Seeds nothing.
    public let matching: DeviceMatching?
    /// Where its ROMs stand there, as the row says; nil when it isn't there or Seeds nothing.
    public let seeding: Seeding?
    /// True once Seeding failed there, until it succeeds: Seed becomes Try Again.
    public let seedFailed: Bool
    /// The newer iOS Release the Installation's Channel offers (`IOSVersion.update`); nil without one.
    public let update: Release?
    /// When its app stops launching once Renew is due, or why the last Renew failed; nil before it's due.
    public let renewal: Renewal?
    /// True once its app has stopped launching: its Provisioning Profile or certificate expired.
    public let isExpired: Bool
    private let facts: Facts

    /// What `check` decides from.
    private struct Facts: Hashable, Sendable {
        var installation: DeviceInstallation?
        var readiness: DeviceReadiness
        var hasAppleTeams: Bool
        var activity: Activity?
        var isRunning: Bool
        var isListed: Bool

        var isInstalled: Bool { installation != nil }
    }

    /// `team` is the Apple Team chosen in Settings › Devices while its certificate is in the keychain, `hasAppleTeams`
    /// whether any is there; `matching` where its ROMs stand there; `update` what `IOSVersion.update` offers the
    /// Installation; `upkeep` what Seeding there waits for, and why Seeding and Renewing there last failed; `isListed`
    /// whether the Catalog lists the Port.
    public init(
        reading: DeviceReading, installation: DeviceInstallation?, hasXcode: Bool, team: AppleTeamID? = nil,
        hasAppleTeams: Bool = false, activity: Activity? = nil, matching: DeviceMatching? = nil, update: Release? = nil,
        upkeep: DeviceUpkeepState.Facts = .init(), isListed: Bool = true, now: Date = .now
    ) {
        self.reading = reading
        self.matching = installation == nil ? nil : matching
        seedFailed = installation != nil && upkeep.seedFailure != nil
        seeding = Seeding(self.matching, wait: upkeep.wait, failed: seedFailed)
        self.update = installation == nil ? nil : update
        let due = installation.flatMap { Renewal($0, now: now) }
        renewal = due.map { due in upkeep.renewFailure.map(Renewal.failed) ?? due }
        isExpired = due == .expired
        facts = Facts(
            installation: installation, readiness: DeviceReadiness(hasXcode: hasXcode, team: team),
            hasAppleTeams: hasAppleTeams, activity: activity, isRunning: upkeep.wait == .running, isListed: isListed)
        if let activity, activity.kind.device == reading.device.id {
            state = .working(activity)
        } else if let installation {
            state = .installed(installation)
        } else {
            state = .available
        }
    }

    /// True once its app stops launching within `renewWindow`, or has stopped: until it's Renewed.
    public var isRenewDue: Bool { renewal != nil }

    /// True while the Port runs on the Device, as the Device said when Seeding last asked.
    public var isRunning: Bool { facts.isRunning }

    /// What the Port's row for the Device offers once it's there: Update while its Channel has a newer iOS Release,
    /// Renew once it's due, Seed while a ROM in ROMs isn't there yet, and Uninstall.
    public var actions: [Action] {
        guard facts.isInstalled else { return [] }
        return [Action.update, .renew, .seed].filter { check($0) != .unavailable } + [.uninstall]
    }

    /// Whether the user can take `action` now. The Device's readiness comes first, then the Port running there, then
    /// the one change at a time.
    public func check(_ action: Action) -> Availability {
        guard let installation = facts.installation else { return .unavailable }
        switch action {
        case .update:
            // The app goes over the one there, so it's signed as that one was; it's unlocked only to be Seeded after.
            guard update != nil else { return .unavailable }
            return disabled(.install, signed: installation.team) ?? (facts.isListed ? .allowed : .disabled(.unknownEntry))
        case .renew:
            guard isRenewDue else { return .unavailable }
            return disabled(.renew, signed: installation.team, unlessRunning: true) ?? .allowed
        case .seed:
            guard matching?.hasUnseeded == true else { return .unavailable }
            return disabled(.seed, unlessRunning: true) ?? .allowed
        case .uninstall:
            // Its record names the app.
            return disabled(.uninstall) ?? .allowed
        }
    }

    /// True when `check` allows it.
    public func allows(_ action: Action) -> Bool { check(action) == .allowed }

    /// The first reason `operation` can't run on the Device now, then the Port running there when `unlessRunning`, then
    /// a change under way; nil when none holds.
    private func disabled(
        _ operation: DeviceReadiness.Operation, signed: AppleTeamID? = nil, unlessRunning: Bool = false
    ) -> Availability? {
        if let reason = facts.readiness.reason(operation, on: reading, signed: signed) {
            return .disabled(Reason(reason, hasAppleTeams: facts.hasAppleTeams))
        }
        if unlessRunning, facts.isRunning { return .disabled(.running) }
        return facts.activity.map { .disabled(.activity($0.kind)) }
    }
}
