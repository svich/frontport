import Foundation

// Seeding on a Device (DESIGN › Seeding on a Device): the Port's ROMs laid out for its container there, what the Device
// holds of them, what to copy, and where each Requirement stands. Pure: the Device Library's `DeviceSeeder` lists the
// Device, puts and records, and the App shows what comes of it. ADR 0010's tag doesn't survive `devicectl`'s copy, so the record and
// the Device's listing say what's there, never the tag.

/// One ROM laid out for a Device by `ROMStoring.stage`: an APFS clone in a folder of Frontport's own under `Devices/`, at
/// the path its iOS seedPath gives it in the app's container.
public struct StagedSeed: Hashable, Sendable {
    /// The Requirement's label, which the record's `seeded` goes by.
    public var label: String
    /// The ROM's SHA-1, as the Requirement lists it.
    public var sha1: String
    /// The SHA-1 of the file's own standard form, an Unverified ROM's own (`ROMRecord.fileSHA1`): what the record keeps
    /// and a folder's marker names.
    public var fileSHA1: String
    /// Relative to the container: the file, such as "Documents/sm64.z64", or the folder a folder ROM fills, such as
    /// "Documents".
    public var path: String
    /// Its files, relative to the container, with their sizes: the file itself, or each of a folder ROM's files but its
    /// marker.
    public var files: [DeviceFile]
    /// For a folder ROM, what its marker says: its `fileSHA1` and a newline. Nil for a file.
    public var marker: String?

    public init(label: String, sha1: String, fileSHA1: String, path: String, files: [DeviceFile], marker: String? = nil) {
        self.label = label
        self.sha1 = sha1
        self.fileSHA1 = fileSHA1
        self.path = path
        self.files = files
        self.marker = marker
    }

    public var isFolder: Bool { marker != nil }

    /// Where a folder ROM's marker goes, relative to the container, such as "Documents/.frontport-rom"; nil for a file.
    public var markerPath: String? { marker == nil ? nil : "\(path)/\(ROMRecord.folderMarker)" }
}

/// What a Port's container on a Device holds where its ROMs go, as one listing found it.
public struct DeviceListing: Hashable, Sendable {
    /// Every file and folder listed, by its path relative to the container.
    public var files: [String: DeviceFile]
    /// What each folder ROM's marker found there names, a SHA-1, by the marker's path.
    public var markers: [String: String]

    public init(files: [DeviceFile] = [], markers: [String: String] = [:]) {
        self.files = Dictionary(files.map { ($0.path, $0) }) { first, _ in first }
        self.markers = markers
    }

    /// True when a file, not a folder or link, is listed at `path`: one a marker can be read from.
    public func isFile(_ path: String) -> Bool {
        files[path].map { !$0.isDirectory && !$0.isLink } ?? false
    }

    /// What a marker's contents name: the SHA-1 on its line.
    public static func named(by contents: Data) -> String {
        String(decoding: contents, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// What Seeding a Port's staged ROMs on a Device copies, from a listing of the Device and the record (`DeviceSeeding`).
public struct DeviceSeedingPlan: Hashable, Sendable {
    /// What comes of one staged ROM.
    public enum Step: Hashable, Sendable {
        /// On the Device already: nothing to copy.
        case seeded
        /// Copy these files, relative to the container, then for a folder ROM its marker.
        case copy(files: [String], marker: String?)
        /// A folder ROM whose folder on the Device is marked as another ROM's, by that one's SHA-1: left alone.
        case heldBy(String)
    }

    public struct Item: Hashable, Sendable {
        public var seed: StagedSeed
        public var step: Step

        public init(seed: StagedSeed, step: Step) {
            self.seed = seed
            self.step = step
        }
    }

    /// One per staged ROM, in their order.
    public var items: [Item]

    public init(items: [Item]) {
        self.items = items
    }

    /// Every file to copy, relative to the container, markers left out.
    public var files: [String] {
        items.flatMap { item -> [String] in
            if case .copy(let files, _) = item.step { files } else { [] }
        }
    }

    /// The folder ROMs' files to copy, which a copy that stops part way may leave cut short.
    public var folderFiles: [String] {
        items.flatMap { item -> [String] in
            if case .copy(let files, _) = item.step, item.seed.isFolder { files } else { [] }
        }
    }

    /// The folder ROMs' markers to copy once every file is there.
    public var markers: [String] {
        items.compactMap { item -> String? in
            if case .copy(_, let marker) = item.step { marker } else { nil }
        }
    }

    public var copiesNothing: Bool { files.isEmpty && markers.isEmpty }

    /// The folder ROMs left alone, their folder on the Device held by another ROM.
    public var held: [StagedSeed] {
        items.compactMap { item in
            if case .heldBy = item.step { item.seed } else { nil }
        }
    }

    /// The record's `seeded` once the plan is carried out: `old`, with each Requirement it staged ROMs for holding those
    /// it copies or found Seeded. A folder held by another ROM gets nothing.
    public func carriedOut(over old: [String: [String]]) -> [String: [String]] {
        record(over: old) { if case .heldBy = $0 { false } else { true } }
    }

    /// The record's `seeded` as the plan found the Device: `old`, with each Requirement it staged ROMs for holding only
    /// those already Seeded there.
    public func found(over old: [String: [String]]) -> [String: [String]] {
        record(over: old) { $0 == .seeded }
    }

    private func record(over old: [String: [String]], keeping kept: (Step) -> Bool) -> [String: [String]] {
        var result = old
        for label in Set(items.map(\.seed.label)) { result[label] = nil }
        for item in items where kept(item.step) {
            result[item.seed.label, default: []].append(item.seed.fileSHA1)
        }
        return result.mapValues { Array(Set($0)).sorted() }
    }
}

/// Plans Seeding on a Device: which staged files to copy, given what the Device holds.
public enum DeviceSeeding {
    /// `devicectl device copy to` overwrites a Device's file that differs from the local one, and skips one with the
    /// same size and modification time even when its contents differ, so the plan alone decides what's copied: the
    /// staging folder is pruned to it first.
    ///
    /// A file ROM is Seeded when the Device has a file of its size at its path and the record says it was Seeded there
    /// for its Requirement; otherwise it's copied, over whatever is there. A folder ROM is filled in: only its files
    /// missing on the Device, in any form, a link included, then its marker, so nothing the Port wrote among them is
    /// overwritten. The one exception is a file of the record's `filling` shorter than the ROM's while the folder has no
    /// marker: a copy that stopped part way cut it short, so it's copied again. A folder marked as another ROM's is left
    /// alone.
    public static func plan(
        _ staged: [StagedSeed], on listing: DeviceListing, seeded: [String: [String]], filling: [String] = []
    ) -> DeviceSeedingPlan {
        let filling = Set(filling)
        return DeviceSeedingPlan(items: staged.map { seed in
            DeviceSeedingPlan.Item(seed: seed, step: step(for: seed, on: listing, seeded: seeded, filling: filling))
        })
    }

    private static func step(
        for seed: StagedSeed, on listing: DeviceListing, seeded: [String: [String]], filling: Set<String>
    ) -> DeviceSeedingPlan.Step {
        if let markerPath = seed.markerPath {
            let named = listing.markers[markerPath]
            if let named, named != seed.fileSHA1 { return .heldBy(named) }
            let marked = named != nil
            let missing = seed.files.filter { file in
                guard let there = listing.files[file.path] else { return true }
                return !marked && filling.contains(file.path) && !there.isDirectory && !there.isLink && there.size < file.size
            }
            if missing.isEmpty, marked { return .seeded }
            return .copy(files: missing.map(\.path), marker: marked ? nil : markerPath)
        }
        let size = seed.files.first?.size
        if let file = listing.files[seed.path], !file.isDirectory, !file.isLink, file.size == size,
            seeded[seed.label]?.contains(seed.fileSHA1) == true
        {
            return .seeded
        }
        return .copy(files: [seed.path], marker: nil)
    }
}

/// Where each of a Port's Runtime Requirements on iOS stands on one Device: from the Mac's Matching, which says which
/// ROMs in ROMs match it, the record of what was last Seeded there, and while the Device is reachable, the latest plan
/// read from its listing.
public struct DeviceMatching: Hashable, Sendable {
    public enum State: Hashable, Sendable {
        /// Its ROMs are on the Device.
        case seeded
        /// No ROM it accepts is in ROMs, and none was Seeded there.
        case missing
        /// A ROM it accepts is in ROMs but not on the Device yet.
        case unseeded
        /// Its folder ROM's folder on the Device holds another ROM, so Seeding leaves it alone.
        case held
    }

    public struct Item: Hashable, Sendable, Identifiable {
        public var requirement: Requirement
        public var state: State

        public init(requirement: Requirement, state: State) {
            self.requirement = requirement
            self.state = state
        }

        public var id: String { requirement.id }
    }

    /// The Runtime Requirements the iOS version Seeds, in the entry's order.
    public var requirements: [Item]
    /// True while the Device can't be reached: what the record says was last Seeded there.
    public var isLastKnown: Bool

    public init(requirements: [Item], isLastKnown: Bool = false) {
        self.requirements = requirements
        self.isLastKnown = isLastKnown
    }

    /// `version` is the one Seeding goes by, `matching` the Mac's reading of the Port and `roms` every ROM in ROMs;
    /// `plan` is the latest read from the Device, used only while `isReachable`.
    public init(
        version: IOSVersion, matching: PortMatching, roms: [ROMRecord], installation: DeviceInstallation,
        plan: DeviceSeedingPlan?, isReachable: Bool
    ) {
        let plan = isReachable ? plan : nil
        requirements = version.requirements.map { requirement in
            let state = matching.requirements.first { $0.id == requirement.id }
            let recorded = Set(installation.seeded[requirement.label] ?? [])
            let wanted = Self.inROMs(state).map { sha1 in roms.first { $0.sha1 == sha1 }?.fileSHA1 ?? sha1 }
            // With nothing to Seed, what was Seeded there stays.
            guard !wanted.isEmpty else { return Item(requirement: requirement, state: recorded.isEmpty ? .missing : .seeded) }
            let states = wanted.map { fileSHA1 -> State in
                let step = plan?.items.first { $0.seed.label == requirement.label && $0.seed.fileSHA1 == fileSHA1 }?.step
                switch step {
                case .seeded?: return .seeded
                case .heldBy?: return .held
                case .copy?: return .unseeded
                case nil: return recorded.contains(fileSHA1) ? .seeded : .unseeded
                }
            }
            let combined: State = states.contains(.held) ? .held : states.contains(.unseeded) ? .unseeded : .seeded
            return Item(requirement: requirement, state: combined)
        }
        isLastKnown = !isReachable
    }

    /// The SHA-1s of the Match's ROMs in ROMs: the accepted ROM and the extras there.
    private static func inROMs(_ state: RequirementState?) -> [String] {
        guard let state, let rom = state.rom, state.accepted != .missing else { return [] }
        let extras = state.extras.filter { $0.value != .missing && $0.value != .builtIn }.keys.sorted()
        return [rom] + extras
    }

    /// The Requirements in that state.
    public func requirements(_ state: State) -> [Requirement] {
        requirements.filter { $0.state == state }.map(\.requirement)
    }

    /// True when a ROM in ROMs isn't on the Device yet, so Seeding would copy it.
    public var hasUnseeded: Bool { requirements.contains { $0.state == .unseeded } }
}

extension DeviceInstallation {
    /// True when `processes`, the Device's as `devicectl` lists them, run an executable inside the installed app: its
    /// bundle keeps its name on the Device.
    public func isRunning(in processes: [Int32: URL]) -> Bool {
        processes.values.contains { $0.deletingLastPathComponent().lastPathComponent == appName }
    }
}
