import Foundation

/// What a Port is doing or needs, as the user sees it, and which actions that allows now, each with why when it
/// doesn't (GLOSSARY.md). Built from the App's state alone, never the disk, so every surface renders one decision.
public struct Status: Hashable, Sendable {
    /// The one state a Port shows, in order of precedence.
    public enum State: Hashable, Sendable {
        /// However it was launched. First, so a running Port can always be stopped.
        case running
        case working(Activity)
        case unsupported(String)
        /// In the Catalog, not installed, and ready to install.
        case available
        /// In the Catalog, not installed, and missing a Build-Stage ROM, without which it can't be installed.
        case needsBuildROM([Requirement])
        /// Installed on a Blocked Release.
        case blocked(Block)
        /// Installed, but Runtime ROMs are missing.
        case needsROM([Requirement])
        /// Installed, with Runtime ROMs in ROMs that aren't Seeded into its Data yet, such as after a Seeding that failed.
        case unseeded([Requirement])
        case updateAvailable(Release)
        case ready
    }

    /// Something the user can do with a Port.
    public enum Action: Hashable, Sendable {
        case install
        /// Add ROM…: a Build Requirement's ROM before installing, a Runtime Requirement's once installed.
        case addROM(Stage)
        case play
        case stop
        /// Cancels the Activity.
        case cancel
        /// To `update`.
        case update
        /// To `fallback`, the way off a Blocked Release when there's nothing newer.
        case installFallback
        /// To `previous`, with the Snapshot taken before leaving it.
        case rollBack
        /// One of its Snapshots, over its Data.
        case restore
        case switchChannel
        case setPermissions
        /// Seeds its Runtime ROMs and rebuilds its Build Assets for a new Build ROM. It waits for the Port to quit, and
        /// for an Activity to finish, rather than being refused.
        case seed
        case uninstall
        case deleteData
        case removeBuildFolder
    }

    /// Why an action the Port has can't be taken now.
    public enum Reason: Hashable, Sendable {
        /// It changes the app or its Data, so the Port has to quit first.
        case running
        /// One change at a time: this one is under way.
        case activity(Activity.Kind)
        /// Rolling back would land on a Blocked Release.
        case previousBlocked
        /// It re-signs the app, which needs the Catalog entry, and neither the Catalog nor the Installation has it.
        case unknownEntry
    }

    /// Whether an action can be taken now.
    public enum Availability: Hashable, Sendable {
        case allowed
        /// The Port has it, but something stands in the way.
        case disabled(Reason)
        /// The Port has nothing it would act on, such as no Installation to uninstall or no previous Release.
        case unavailable
    }

    public let state: State
    /// The action the state calls for; nil for an Unsupported Port, or one Blocked with no way off.
    public let main: Action?
    /// The others to offer beside it: Play while an update waits, or the other ways off a Blocked Release.
    public let others: [Action]
    /// Installed on a Blocked Release: Update, the older Release, or Rollback, best first, whatever else the Port is
    /// doing. Empty otherwise.
    public let waysOff: [Action]
    /// What `Move.offer` offers the Installation: where `update` or `installFallback` leads.
    public let offer: Move.Offer?
    /// Where `rollBack` leads.
    public let previous: Release?
    private let facts: Facts

    /// What `check` decides from.
    private struct Facts: Hashable, Sendable {
        var isKnown = false
        var isInstallable = false
        var isInstalled = false
        var activity: Activity?
        var isRunning = false
        /// The Catalog lists it, or its Installation kept the entry.
        var knowsEntry = false
        /// Its Release is Blocked, and the block stops it from launching.
        var isStopped = false
        var isPreviousBlocked = false
        var isMissingBuildROMs = false
        var isMissingRuntimeROMs = false
        var hasChannels = false
    }

    /// `offer` is what `Move.offer` gives for the Installation. `isListed` is whether the Catalog lists the entry,
    /// rather than only the Installation keeping it.
    public init(
        entry: CatalogEntry, installation: Installation?, matching: PortMatching, offer: Move.Offer? = nil,
        activity: Activity? = nil, isRunning: Bool = false, isListed: Bool = true
    ) {
        var update: Release?
        var fallback: Release?
        switch offer {
        case .update(let release): update = release
        case .fallback(let release): fallback = release
        case nil: break
        }
        let block = installation.flatMap { entry.block(for: $0.release) }
        let missingBuild = matching.missing(.build)
        let missingRuntime = matching.missing(.runtime)
        let facts = Facts(
            isKnown: true, isInstallable: entry.isInstallable, isInstalled: installation != nil, activity: activity,
            isRunning: isRunning, knowsEntry: isListed || installation?.entry != nil, isStopped: block?.severity == .stop,
            isPreviousBlocked: installation?.previous.map { entry.block(for: $0) != nil } ?? false,
            isMissingBuildROMs: !missingBuild.isEmpty, isMissingRuntimeROMs: !missingRuntime.isEmpty,
            hasChannels: entry.channels.count > 1)

        let state: State
        if isRunning {
            state = .running
        } else if let activity {
            state = .working(activity)
        } else if let reason = entry.unsupported {
            state = .unsupported(reason)
        } else if installation == nil {
            state = missingBuild.isEmpty ? .available : .needsBuildROM(missingBuild)
        } else if let block {
            state = .blocked(block)
        } else if !missingRuntime.isEmpty {
            state = .needsROM(missingRuntime)
        } else if !matching.unseeded.isEmpty {
            state = .unseeded(matching.unseeded)
        } else if let update {
            state = .updateAvailable(update)
        } else {
            state = .ready
        }

        let previous = installation?.previous
        let waysOff: [Action] = block == nil ? [] : [
            update.map { _ in .update }, fallback.map { _ in .installFallback },
            previous != nil && !facts.isPreviousBlocked ? .rollBack : nil,
        ].compactMap { $0 }
        var main: Action?
        var others: [Action] = []
        switch state {
        case .running: main = .stop
        case .working: main = .cancel
        case .unsupported: main = nil
        case .available: main = .install
        case .needsBuildROM: main = .addROM(.build)
        case .blocked(let block):
            // An update first, then Play past a warning, then the other ways off; the rest besides.
            main = update != nil || block.severity == .stop ? waysOff.first : .play
            others = waysOff.filter { $0 != main }
        case .needsROM: main = .addROM(.runtime)
        case .unseeded: main = .seed
        case .updateAvailable:
            main = .update
            others = [.play]
        case .ready: main = .play
        }
        self.init(
            state: state, main: main, others: others, waysOff: waysOff, offer: offer, previous: previous, facts: facts)
    }

    private init(
        state: State, main: Action?, others: [Action], waysOff: [Action], offer: Move.Offer?, previous: Release?,
        facts: Facts
    ) {
        self.state = state
        self.main = main
        self.others = others
        self.waysOff = waysOff
        self.offer = offer
        self.previous = previous
        self.facts = facts
    }

    /// For a Port without a Catalog entry: there's nothing to do with it.
    public static let unknown = Status(
        state: .available, main: nil, others: [], waysOff: [], offer: nil, previous: nil, facts: Facts())

    /// Where `update` leads.
    public var update: Release? {
        if case .update(let release) = offer { release } else { nil }
    }

    /// Where `installFallback` leads.
    public var fallback: Release? {
        if case .fallback(let release) = offer { release } else { nil }
    }

    /// Installed, or being installed for the first time.
    public var isInLibrary: Bool { facts.isInstalled || facts.activity?.kind == .install }

    /// Whether the user can take `action` now. Two rules hold every change back: one change at a time, and those that
    /// change the app or its Data wait for the Port to quit. A reason that waiting won't fix comes first.
    public func check(_ action: Action) -> Availability {
        guard facts.isKnown else { return .unavailable }
        switch action {
        case .install:
            guard !facts.isInstalled, facts.isInstallable, !facts.isMissingBuildROMs else { return .unavailable }
            return waiting(quit: false)
        case .addROM(.build):
            return !facts.isInstalled && facts.isMissingBuildROMs ? .allowed : .unavailable
        case .addROM(.runtime):
            return facts.isInstalled && facts.isMissingRuntimeROMs ? .allowed : .unavailable
        case .play:
            guard facts.isInstalled, !facts.isRunning, !facts.isStopped else { return .unavailable }
            return waiting(quit: false)
        case .stop:
            return facts.isRunning ? .allowed : .unavailable
        case .cancel:
            return facts.activity != nil ? .allowed : .unavailable
        case .update:
            guard facts.isInstalled, update != nil else { return .unavailable }
            return waiting(quit: true)
        case .installFallback:
            guard facts.isInstalled, fallback != nil else { return .unavailable }
            return waiting(quit: true)
        case .rollBack:
            guard facts.isInstalled, previous != nil else { return .unavailable }
            if facts.isPreviousBlocked { return .disabled(.previousBlocked) }
            if !facts.knowsEntry { return .disabled(.unknownEntry) }
            return waiting(quit: true)
        case .restore, .deleteData:
            return waiting(quit: true)
        case .switchChannel:
            guard facts.isInstalled, facts.hasChannels else { return .unavailable }
            return waiting(quit: true)
        case .setPermissions:
            guard facts.isInstalled else { return .unavailable }
            if !facts.knowsEntry { return .disabled(.unknownEntry) }
            return waiting(quit: true)
        case .seed:
            guard facts.isInstalled else { return .unavailable }
            return facts.knowsEntry ? .allowed : .disabled(.unknownEntry)
        case .uninstall:
            guard facts.isInstalled else { return .unavailable }
            return waiting(quit: true)
        case .removeBuildFolder:
            return waiting(quit: false)
        }
    }

    /// True when `check` allows it.
    public func allows(_ action: Action) -> Bool { check(action) == .allowed }

    private func waiting(quit: Bool) -> Availability {
        if let activity = facts.activity { return .disabled(.activity(activity.kind)) }
        if quit, facts.isRunning { return .disabled(.running) }
        return .allowed
    }
}
