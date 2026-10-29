import Foundation

/// A step of long-running work reported to the UI.
public struct ProgressUpdate: Hashable, Sendable {
    public enum Phase: String, Hashable, Sendable {
        case resolving
        case downloading
        case verifying
        case extracting
        /// Recipe fetch step: cloning the source.
        case fetching
        /// Recipe build step, in the build sandbox.
        case building
        case packaging
        case signing
        case snapshotting
        /// Swapping the new app into the Library.
        case swapping
        case seeding
        case restoring
        case removing
    }

    public var phase: Phase
    /// 0...1, or nil when indeterminate.
    public var fraction: Double?
    public var message: String?

    public init(_ phase: Phase, fraction: Double? = nil, message: String? = nil) {
        self.phase = phase
        self.fraction = fraction
        self.message = message
    }
}

/// Receives progress from a service. Called from any thread.
public typealias ProgressHandler = @Sendable (ProgressUpdate) -> Void

/// A change under way on one Port (GLOSSARY.md). A Port has at most one at a time.
public struct Activity: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case install, update, rollback, switchChannel, permissions, applyROMs, restore, uninstall, deleteData
        case removeBuildFolder
    }

    public var kind: Kind
    public var progress: ProgressUpdate

    public init(kind: Kind, progress: ProgressUpdate) {
        self.kind = kind
        self.progress = progress
    }

    /// A change just started, in its first phase.
    public init(_ kind: Kind) {
        self.init(kind: kind, progress: ProgressUpdate(kind.firstPhase))
    }

    /// Running a Recipe, which the UI calls Building.
    public var isBuilding: Bool { progress.phase == .fetching || progress.phase == .building }
}

extension Activity.Kind {
    /// The phase a change starts in, shown until it reports its own progress.
    public var firstPhase: ProgressUpdate.Phase {
        switch self {
        case .install, .update, .switchChannel: .resolving
        case .rollback: .snapshotting
        case .permissions: .signing
        case .applyROMs: .seeding
        case .restore: .restoring
        case .uninstall, .deleteData, .removeBuildFolder: .removing
        }
    }

    /// A change that may leave the Port on another Release, after which its newest Release is looked up again.
    public var changesRelease: Bool {
        switch self {
        case .install, .update, .rollback, .switchChannel: true
        case .permissions, .applyROMs, .restore, .uninstall, .deleteData, .removeBuildFolder: false
        }
    }
}
