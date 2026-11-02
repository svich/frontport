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
        /// Taking the Provisioning Profile a Device install signs with.
        case provisioning
        /// `devicectl` sending the app or ROMs to a Device.
        case transferring
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

/// A change to a Port's Installation on a Device (DESIGN › Devices).
public enum DeviceChange: String, Hashable, Sendable {
    case install, update, renew, seed, uninstall
}

/// A change under way on one Port (GLOSSARY.md). A Port has at most one at a time, on this Mac and its Devices alike.
public struct Activity: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case install, update, rollback, switchChannel, permissions, applyROMs, restore, uninstall, deleteData
        case removeBuildFolder
        /// A change to the Port's Installation on one Device. A case of its own, so nothing that reads a change on this
        /// Mac, such as its first install or its uninstall, takes it for one.
        case device(DeviceChange, DeviceID)
        /// Readies the Port's iOS version for Devices, none in particular: resolved, then fetched and unpacked or built
        /// on this Mac, and not signed, until the user picks the Devices to install it on. Neither a change on this Mac nor on a
        /// Device, though the Library counts the Port in while it runs, as for a first install.
        case prepareForDevices
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
        case .device(let change, _):
            switch change {
            // Installing takes the app already prepared.
            case .install, .renew: .provisioning
            case .update: .resolving
            case .seed: .transferring
            case .uninstall: .removing
            }
        case .prepareForDevices: .resolving
        }
    }

    /// A change that may leave the Port on another Release, after which its newest Release is looked up again: on a
    /// Device, its newest iOS Release.
    public var changesRelease: Bool {
        switch self {
        case .install, .update, .rollback, .switchChannel: true
        case .permissions, .applyROMs, .restore, .uninstall, .deleteData, .removeBuildFolder: false
        case .device(let change, _): change == .install || change == .update
        // It installs nothing.
        case .prepareForDevices: false
        }
    }

    /// A first install, on this Mac or a Device, or preparing one for Devices, during which the Port counts as in the
    /// Library.
    public var isFirstInstall: Bool {
        switch self {
        case .install, .prepareForDevices: true
        case .device(let change, _): change == .install
        default: false
        }
    }

    /// The Device a change is on; nil for one on this Mac, and for preparing one for Devices.
    public var device: DeviceID? {
        if case .device(_, let device) = self { device } else { nil }
    }

    /// True for a change on a Device, and for preparing one: nothing of this Mac's Installation changes.
    public var isForDevices: Bool {
        switch self {
        case .device, .prepareForDevices: true
        default: false
        }
    }
}
