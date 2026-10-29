import FrontportCore
import FrontportROMs
import Foundation

// Derived values and wording the screens share.

extension Kind {
    var name: String {
        switch self {
        case .decomp: "Decomp"
        case .recomp: "Recomp"
        case .recreation: "Recreation"
        case .sourceport: "Sourceport"
        }
    }
}

extension ROMType {
    var name: String {
        switch self {
        case .cartridge: "Cartridge"
        case .iso: "ISO"
        case .folder: "Folder"
        case .file: "File"
        case .key: "Key"
        case .firmware: "Firmware"
        case .update: "Update"
        case .dlc: "DLC"
        }
    }

    /// Shown in place of artwork, for a ROM of no Game.
    var symbol: String {
        switch self {
        case .cartridge: "memorychip"
        case .iso: "opticaldisc"
        case .folder: "folder"
        case .file: "doc"
        case .key: "key"
        case .firmware: "cpu"
        case .update: "arrow.up.circle"
        case .dlc: "puzzlepiece"
        }
    }
}

extension Permission {
    var name: String {
        switch self {
        case .controllers: "Controllers"
        case .network: "Network"
        case .files: "Files you pick"
        }
    }
}

extension Permissions {
    /// "Controllers, Network", or "None".
    var summary: String {
        let names = Permission.allCases.filter { self[$0] }.map { $0 == .files ? "Files" : $0.name }
        return names.isEmpty ? "None" : names.formatted(.list(type: .and, width: .narrow))
    }
}

extension Channel {
    var name: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

extension Release {
    /// "Dewey Bravo 9.3.1", or the version alone.
    var displayName: String { title.map { "\($0) \(version)" } ?? version }
}

extension URL {
    /// "HarbourMasters/Shipwright" for a GitHub URL, else the host without "www.".
    var shortDisplay: String {
        let host = (host() ?? absoluteString).replacingOccurrences(of: "www.", with: "")
        if host == "github.com" {
            let path = path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return path.isEmpty ? host : path
        }
        return host
    }
}

enum Format {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// "Oct 18, 2026".
    static func date(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    /// "Oct 18" this year, "Oct 18, 2025" otherwise; "Today" for today.
    static func shortDate(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return Self.date(date)
    }

    /// "last week", "yesterday", "3 days ago".
    static func relative(_ date: Date, now: Date = .now) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        if Calendar.current.isDateInToday(date) { return "today" }
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// "1 h 12 min", "48 min", "under a minute".
    static func duration(_ interval: TimeInterval) -> String {
        guard interval >= 60 else { return "under a minute" }
        let minutes = Int(interval / 60)
        let hours = minutes / 60
        if hours == 0 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(hours) h" : "\(hours) h \(minutes % 60) min"
    }

    /// "1 Port", "3 Ports".
    static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n) \(n == 1 ? singular : plural ?? singular + "s")"
    }
}

extension Lineup.Month {
    /// "October 2026", or "Earlier".
    var label: String { start?.formatted(.dateTime.month(.wide).year()) ?? "Earlier" }
    /// Dates in an older group include the year.
    var isEarlier: Bool { start == nil }
}

extension Lineup.Year {
    /// "2025", or "Earlier".
    var label: String {
        year.flatMap { Calendar.current.date(from: DateComponents(year: $0)) }?.formatted(.dateTime.year()) ?? "Earlier"
    }
}

/// What installed Ports still need of one Game, for the ROMs screen: a ROM to add, or one to Seed.
struct NeededGame: Identifiable {
    var game: GameID?
    var label: String
    /// The Requirement's label when it's more than the Game's name, such as a Switch game's "Update 1.2.1".
    var detail: String?
    var ports: [CatalogEntry]
    var stages: Set<Stage>
    /// In ROMs, but not yet Seeded into these Ports' Data.
    var isUnseeded = false
    var id: String { (game?.rawValue ?? label) + (detail.map { "/\($0)" } ?? "") + (isUnseeded ? "/unseeded" : "") }
}

extension AppModel {
    /// The Game's name; for an Installation the Catalog doesn't list, which has no known Game, says so.
    func gameName(for entry: CatalogEntry) -> String {
        guard survey.isListed(entry.id) else { return Self.unlistedText }
        return survey.game(for: entry)?.displayName ?? entry.game.rawValue
    }

    static let unlistedText = "Not in the Catalog"

    /// "Ocarina of Time · Nintendo 64 · Decomp".
    func detailLine(for entry: CatalogEntry) -> String {
        guard survey.isListed(entry.id) else { return Self.unlistedText }
        return [gameName(for: entry), survey.platform(for: entry)?.name, entry.kind.name].compactMap { $0 }
            .joined(separator: " · ")
    }

    /// "Ocarina of Time · Decomp · by HarbourMasters".
    func bylineLine(for entry: CatalogEntry) -> String {
        guard survey.isListed(entry.id) else { return Self.unlistedText }
        return "\(gameName(for: entry)) · \(entry.kind.name) · by \(entry.developer)"
    }

    /// What an activity is doing, by kind, naming the Project with its version: "Installing Ship of Harkinian 9.3.1…",
    /// "Updating to Ship of Harkinian 9.3.1…", "Building Starship 2.0.0 from source…".
    func activityText(_ activity: Activity, for port: PortID) -> String {
        let name = survey.entry(port)?.name
        let version = survey.latestRelease(for: port).map { [name, $0.version].compactMap { $0 }.joined(separator: " ") }
        if activity.isBuilding {
            return ["Building", version, "from source…"].compactMap { $0 }.joined(separator: " ")
        }
        switch activity.kind {
        case .install: return ["Installing", version].compactMap { $0 }.joined(separator: " ") + "…"
        case .update:
            let offer = survey.offers[port]
            let target = offer.map { [name, $0.release.version].compactMap { $0 }.joined(separator: " ") } ?? version ?? ""
            if case .fallback = offer { return "Installing \(target)…" }
            return "Updating to \(target)…"
        case .rollback: return "Rolling back…"
        case .switchChannel: return "Switching Channel…"
        case .permissions: return "Applying Permissions…"
        case .applyROMs: return "Applying ROMs…"
        case .restore: return "Restoring Snapshot…"
        case .uninstall: return "Uninstalling…"
        case .deleteData: return "Deleting Data…"
        case .removeBuildFolder: return "Removing build folder…"
        }
    }

    /// Why `action` is disabled for the Port, as help: "Quit Ship of Harkinian to update it". Nil when it isn't.
    func help(_ action: Status.Action, for port: PortID) -> String? {
        let status = status(of: port)
        guard case .disabled(let reason) = status.check(action) else { return nil }
        let name = survey.entry(port)?.name ?? port.rawValue
        switch reason {
        case .running:
            return "Quit \(name) to \(Self.purpose(of: action))"
        case .activity(let kind):
            return Self.waiting(for: kind)
        case .previousBlocked:
            return "\(status.previous?.version ?? "The previous Release") is Blocked too"
        case .unknownEntry:
            return "It was installed before Frontport kept its Catalog entry, which re-signing needs"
        }
    }

    private static func purpose(of action: Status.Action) -> String {
        switch action {
        case .update: "update it"
        case .installFallback: "install an older Release"
        case .rollBack: "roll it back"
        case .restore: "restore a Snapshot"
        case .switchChannel: "switch Channel"
        case .setPermissions: "change its Permissions"
        case .uninstall: "uninstall it"
        case .deleteData: "delete its Data"
        default: "change it"
        }
    }

    private static func waiting(for kind: Activity.Kind) -> String {
        switch kind {
        case .install: "Wait until it’s installed"
        case .update: "Wait until it’s updated"
        case .rollback: "Wait until it’s rolled back"
        case .switchChannel: "Wait until it’s switched Channel"
        case .permissions: "Wait until its Permissions are applied"
        case .applyROMs: "Wait until its ROMs are applied"
        case .restore: "Wait until the Snapshot is restored"
        case .uninstall: "Wait until it’s uninstalled"
        case .deleteData: "Wait until its Data is deleted"
        case .removeBuildFolder: "Wait until its build folder is removed"
        }
    }

    // MARK: Catalog

    /// Where a Game opens: its Game page when the Catalog has more than one Port of it, else its one Port.
    func screen(for game: GameID) -> Screen? {
        let ports = survey.lineup.ports(of: game)
        if ports.count > 1 { return .game(game) }
        return ports.first.map { .store($0.id) }
    }

    // MARK: ROMs

    func knownROMs(_ sha1s: [String]) -> [KnownROM] {
        sha1s.compactMap { survey.catalog?.knownROM($0) }
    }

    /// The Game a Requirement's ROMs are dumps of; nil for a Platform's own files, such as console keys.
    func game(for requirement: Requirement) -> Game? { survey.catalog?.game(for: requirement) }

    func type(of rom: ROMRecord) -> ROMType { ROMType(rom, in: survey.catalog) }

    func type(of rom: KnownROM) -> ROMType { ROMType(rom, in: survey.catalog) }

    /// The installers the Catalog knows that hold a ROM, such as a Game's GOG setup program.
    func installers(holding sha1: String) -> [KnownROM] { survey.catalog?.installers(holding: sha1) ?? [] }

    /// The files these ROMs are added from, such as ".z64, .v64 or .n64", or "folder or .exe" for a folder an
    /// installer holds; nil for a Folder no installer holds, whose Type already says so.
    func filesText(for roms: [KnownROM]) -> String? {
        var files: [String] = []
        for rom in roms {
            let names = rom.isFolder ? ["folder"] : ROMStore.extensions(of: rom.format).map { ".\($0)" }
            let installerFiles = installers(holding: rom.sha1).map { ".\($0.format)" }
            files += (names + installerFiles).filter { !files.contains($0) }
        }
        guard !files.isEmpty, files != ["folder"] || roms.first.map(type(of:)) != .folder else { return nil }
        return files.formatted(.list(type: .or))
    }

    /// What a ROM is a dump of: its Game, or the Platform whose own files it is.
    func owner(of rom: ROMRecord) -> String {
        if let game = rom.game { return survey.catalog?.game(game)?.displayName ?? game.rawValue }
        if let platform = rom.platform { return survey.catalog?.platform(platform)?.name ?? platform.rawValue }
        return rom.originalFilename
    }

    func owner(of rom: KnownROM) -> String {
        if let game = rom.game { return survey.catalog?.game(game)?.displayName ?? game.rawValue }
        if let platform = rom.platform { return survey.catalog?.platform(platform)?.name ?? platform.rawValue }
        return rom.name
    }

    /// The ROMs in the Catalog a file of this format can be kept as, Unverified, by Game then name.
    func assignable(format: String) -> [KnownROM] {
        (survey.catalog?.assignable(format: format) ?? []).sorted { (owner(of: $0), $0.name) < (owner(of: $1), $1.name) }
    }

    /// Needed ROMs grouped by Game, so one ROM needed by two Ports shows once; ROMs to Seed apart from ROMs to add.
    var neededGames: [NeededGame] {
        var groups: [NeededGame] = []
        for needed in neededROMs {
            guard let entry = survey.entry(needed.port) else { continue }
            let game = game(for: needed.requirement)
            let label = needed.requirement.label
            let detail = game.map { [$0.name, $0.displayName].contains(label) } == false ? label : nil
            let group = NeededGame(
                game: game?.id, label: [game?.displayName ?? label, detail].compactMap { $0 }.joined(separator: " · "),
                detail: detail, ports: [entry], stages: [needed.requirement.stage], isUnseeded: needed.isUnseeded)
            if let index = groups.firstIndex(where: { $0.id == group.id }) {
                groups[index].ports.append(entry)
                groups[index].stages.insert(needed.requirement.stage)
            } else {
                groups.append(group)
            }
        }
        return groups
    }

    /// True while Seeding waits for the running Port to quit.
    func isWaitingToSeed(_ port: PortID) -> Bool { seedingWait.isWaiting(port, running: isRunning(port)) }

    /// Distinct Library Ports that use any added ROM.
    var portsUsingROMs: Int {
        Set(survey.roms.flatMap { ports(using: $0.sha1).map(\.id) }).count
    }

    // MARK: Releases

    /// "checked today", or "not checked yet".
    var lastCheckedText: String {
        guard let lastChecked = survey.lastChecked else { return "not checked yet" }
        return "checked \(Format.relative(lastChecked))"
    }

    // MARK: Port page

    func lastRun(for port: PortID) -> Run? { runs[port]?.first }

    /// "Played last week", or nil before the first launch.
    func playedText(for port: PortID) -> String? {
        if isRunning(port) { return "Playing now" }
        return lastRun(for: port).map { "Played \(Format.relative($0.started))" }
    }

    /// The Snapshot a Rollback would restore. Nil when there's none, and the Rollback keeps the current Data.
    func rollbackSnapshot(for port: PortID) -> Snapshot? {
        survey.installation(port).flatMap(Move.rollback(from:))?.restores(from: snapshots[port] ?? [])
    }
}

extension Status {
    /// An action's title, the same on every surface.
    func title(_ action: Action) -> String {
        switch action {
        case .install: "Install"
        case .addROM: "Add ROM…"
        case .play: "Play"
        case .stop: "Stop"
        case .cancel: "Cancel"
        case .update: "Update"
        case .installFallback: fallback.map { "Install \($0.version)…" } ?? "Install…"
        case .rollBack: previous.map { "Roll Back to \($0.version)…" } ?? "Roll Back…"
        case .restore: "Restore…"
        case .switchChannel: "Switch Channel…"
        case .setPermissions: "Change Permissions"
        case .seed: "Seed ROMs"
        case .uninstall: "Uninstall…"
        case .deleteData: "Delete Data…"
        case .removeBuildFolder: "Remove…"
        }
    }
}
