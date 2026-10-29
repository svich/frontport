import Foundation

/// Where one of a Requirement's ROMs stands for a Port.
public enum ROMState: String, Hashable, Sendable {
    /// Not in ROMs, nor what the Port's Build Assets were made from.
    case missing
    /// In ROMs, and not used yet: the Port isn't installed, or a rebuild of its Build Assets would take it.
    case inROMs
    /// The Port's Build Assets were made from it, whether or not it's still in ROMs.
    case builtIn
    /// In the Port's Data.
    case seeded
    /// In ROMs, but not in the Port's Data yet.
    case unseeded
}

/// Where one of a Port's Requirements stands: its accepted ROM, and each extra.
public struct RequirementState: Hashable, Sendable, Identifiable {
    public var requirement: Requirement
    /// The accepted ROM: the Match's, or else the one the Port's Build Assets were made from. Nil when missing.
    public var rom: String?
    /// Where `rom` stands: `.missing` without one.
    public var accepted: ROMState
    /// Where each extra the Requirement lists stands, by SHA-1. A `.missing` extra is one the Port does without.
    public var extras: [String: ROMState]

    public var id: String { requirement.id }

    public init(requirement: Requirement, rom: String?, accepted: ROMState, extras: [String: ROMState] = [:]) {
        self.requirement = requirement
        self.rom = rom
        self.accepted = accepted
        self.extras = extras
    }

    /// The Requirement's own state: missing without an accepted ROM; unseeded, then in ROMs, when any of its ROMs
    /// there is; otherwise its accepted ROM's.
    public var state: ROMState {
        guard accepted != .missing else { return .missing }
        let present = [accepted] + extras.values.filter { $0 != .missing }
        if present.contains(.unseeded) { return .unseeded }
        if present.contains(.inROMs) { return .inROMs }
        return accepted
    }
}

/// The ROMs a Recipe builds from: every Build Match's accepted ROM and extras. Only the Builder opens their files.
public struct BuildROMs: Hashable, Sendable {
    package var files: [ROMFile]

    package init(_ files: [ROMFile]) {
        self.files = files
    }

    public static let none = BuildROMs([])

    public var isEmpty: Bool { files.isEmpty }

    /// Their SHA-1s, sorted: what `BuildAssetsRecord.roms` keeps.
    public var sha1s: [String] { Array(Set(files.map(\.record.sha1))).sorted() }
}

/// Where a Port's Requirements stand, as one reading of ROMs and its Data found them.
public struct PortMatching: Hashable, Sendable {
    public var port: PortID
    /// The reading had its Installation, and read its Data.
    public var isInstalled: Bool
    /// In the entry's order.
    public var requirements: [RequirementState]
    /// An update can carry the Installation's Build Assets forward instead of rebuilding them: they're in the
    /// Catalog's format, and were made from every Build Match's ROMs.
    public var carriesBuildAssets: Bool
    /// Build Requirements without a Match, built in or not.
    var unmatched: [Requirement]
    var build: BuildROMs

    /// For previews: no ROM to build from.
    public init(port: PortID, isInstalled: Bool, requirements: [RequirementState], carriesBuildAssets: Bool = false) {
        self.init(
            port: port, isInstalled: isInstalled, requirements: requirements, carriesBuildAssets: carriesBuildAssets,
            unmatched: requirements.filter { $0.requirement.stage == .build && $0.state == .missing }.map(\.requirement),
            build: .none)
    }

    package init(
        port: PortID, isInstalled: Bool, requirements: [RequirementState], carriesBuildAssets: Bool,
        unmatched: [Requirement], build: BuildROMs
    ) {
        self.port = port
        self.isInstalled = isInstalled
        self.requirements = requirements
        self.carriesBuildAssets = carriesBuildAssets
        self.unmatched = unmatched
        self.build = build
    }

    /// Requirements that are missing, of one Stage or of both. One the Build Assets were made from isn't, as the
    /// Port runs without it; only a rebuild needs it again (`buildROMs`).
    public func missing(_ stage: Stage? = nil) -> [Requirement] {
        requirements.filter { $0.state == .missing && (stage == nil || $0.requirement.stage == stage) }.map(\.requirement)
    }

    /// Runtime Requirements whose Match isn't all in the Port's Data.
    public var unseeded: [Requirement] {
        requirements.filter { $0.state == .unseeded }.map(\.requirement)
    }

    /// The Build Matches' ROMs, for a Recipe to build from. Throws `romMissing` for the first Build Requirement without
    /// a Match, even one the Build Assets were made from: a rebuild needs its ROM in ROMs.
    public func buildROMs() throws -> BuildROMs {
        if let requirement = unmatched.first { throw FrontportError.romMissing(port, requirement: requirement.label) }
        return build
    }
}

/// One reading of ROMs and the installed Ports' Data (`ROMStoring.matching`). FrontportROMs works out every state;
/// this only keeps them.
public struct Matching: Hashable, Sendable {
    /// Every ROM in ROMs, newest first.
    public var roms: [ROMRecord]
    /// Per Port, for the entries the reading was given.
    public var ports: [PortID: PortMatching]
    /// Per ROM, the installed Ports that would ask for it again, were it removed: a Build Requirement of theirs would be
    /// left without a Match, which an update that rebuilds their Build Assets needs.
    var askingAgain: [String: [PortID]]

    public init(roms: [ROMRecord] = [], ports: [PortID: PortMatching] = [:], askingAgain: [String: [PortID]] = [:]) {
        self.roms = roms
        self.ports = ports
        self.askingAgain = askingAgain
    }

    public static let empty = Matching()

    public subscript(port: PortID) -> PortMatching? { ports[port] }

    /// True when the ROM is in ROMs.
    public func contains(_ sha1: String) -> Bool {
        roms.contains { $0.sha1 == sha1 }
    }

    /// The installed Ports that would ask for the ROM again, were it removed, on an update that rebuilds their Build
    /// Assets.
    public func askingAgain(for sha1: String) -> [PortID] {
        askingAgain[sha1] ?? []
    }
}
