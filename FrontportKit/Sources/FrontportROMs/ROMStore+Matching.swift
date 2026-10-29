import Foundation
import FrontportCore

/// Where each Port's Requirements stand: what ROMs holds for them, what an installed Port's Build Assets were made
/// from, and what its Data holds.
extension ROMStore {
    /// One reading: `records` newest first, `files` the same by SHA-1, and the Data of each entry with an Installation.
    @concurrent
    static func read(
        _ records: [ROMRecord], _ files: [String: ROMFile], entries: [CatalogEntry], installations: [PortID: Installation],
        paths: AppPaths
    ) async -> Matching {
        var ports: [PortID: PortMatching] = [:]
        var askingAgain: [String: [PortID]] = [:]
        for entry in entries {
            // An entry whose id or bundle ID could name another Port's folders gets nothing read from them.
            let installation = (try? entry.checkIdentity()) == nil ? nil : installations[entry.id]
            let data = installation.map { _ in paths.data(for: entry.bundleId) }
            var states: [RequirementState] = []
            var unmatched: [Requirement] = []
            var build: [ROMFile] = []
            for requirement in entry.requirements {
                let match = match(requirement, in: files)
                switch requirement.stage {
                case .build:
                    states.append(built(requirement, match, files, from: installation?.buildAssets))
                    if let match { build += [match.rom] + match.extras } else { unmatched.append(requirement) }
                    // Without the one accepted ROM in ROMs, an update that rebuilds would ask for it again.
                    let present = requirement.oneOf.filter { files[$0] != nil }
                    if installation != nil, present.count == 1 { askingAgain[present[0], default: []].append(entry.id) }
                case .runtime:
                    states.append(seeded(requirement, match, files, in: data))
                }
            }
            let roms = BuildROMs(build)
            ports[entry.id] = PortMatching(
                port: entry.id, isInstalled: installation != nil, requirements: states,
                carriesBuildAssets: carries(entry, installation, roms), unmatched: unmatched, build: roms)
        }
        return Matching(roms: records, ports: ports, askingAgain: askingAgain)
    }

    /// A Build Requirement: built in when the Build Assets were made from a ROM, otherwise in ROMs or missing.
    private static func built(
        _ requirement: Requirement, _ match: Match?, _ files: [String: ROMFile], from record: BuildAssetsRecord?
    ) -> RequirementState {
        let made = Set(record?.roms ?? [])
        func state(_ sha1: String) -> ROMState {
            if made.contains(sha1) { return .builtIn }
            return files[sha1] != nil ? .inROMs : .missing
        }
        let extras = Dictionary(requirement.extras.map { ($0, state($0)) }, uniquingKeysWith: { a, _ in a })
        let rom = match?.rom.record.sha1 ?? requirement.oneOf.first(where: made.contains)
        return RequirementState(requirement: requirement, rom: rom, accepted: rom.map(state) ?? .missing, extras: extras)
    }

    /// A Runtime Requirement: in ROMs or missing, and once installed, Seeded or not.
    private static func seeded(
        _ requirement: Requirement, _ match: Match?, _ files: [String: ROMFile], in data: URL?
    ) -> RequirementState {
        guard let match else {
            let extras = requirement.extras.map { ($0, files[$0] != nil ? ROMState.inROMs : .missing) }
            return RequirementState(
                requirement: requirement, rom: nil, accepted: .missing,
                extras: Dictionary(extras, uniquingKeysWith: { a, _ in a }))
        }
        let seeded = data.map { requirement.seedPath == nil ? [] : Seeding.seeded(match, in: $0) } ?? []
        func state(_ sha1: String) -> ROMState {
            guard files[sha1] != nil else { return .missing }
            // Not installed, there's nothing to Seed into; without a seedPath, nothing to Seed.
            guard data != nil else { return .inROMs }
            guard requirement.seedPath != nil else { return .seeded }
            return seeded.contains(sha1) ? .seeded : .unseeded
        }
        let extras = Dictionary(requirement.extras.map { ($0, state($0)) }, uniquingKeysWith: { a, _ in a })
        let rom = match.rom.record.sha1
        return RequirementState(requirement: requirement, rom: rom, accepted: state(rom), extras: extras)
    }

    /// An update can carry the Installation's Build Assets forward: they're in the Catalog's format, and were made from
    /// every Build Match's ROMs.
    private static func carries(_ entry: CatalogEntry, _ installation: Installation?, _ roms: BuildROMs) -> Bool {
        guard entry.isSourceBuilt, let spec = entry.buildAssets, let record = installation?.buildAssets,
            record.format == spec.format
        else { return false }
        return Set(roms.sha1s).isSubset(of: Set(record.roms))
    }
}
