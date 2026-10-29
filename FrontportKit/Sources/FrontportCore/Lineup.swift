import Foundation

/// An upstream Project: the Catalog's Ports built from one repository, which all follow its Releases.
public struct Project: Identifiable, Hashable, Sendable {
    /// The repository, "owner/name".
    public var id: String
    public var name: String
    public var developer: String
    public var kind: Kind
    public var source: URL
    public var website: URL?
    /// In Catalog order.
    public var ports: [CatalogEntry]

    /// A Project named after its first Port.
    init(_ entry: CatalogEntry) {
        id = entry.releases.repo
        name = entry.name
        developer = entry.developer
        kind = entry.kind
        source = entry.source
        website = entry.website
        ports = [entry]
    }

    /// What the Project is, from its first Port's description.
    public var about: String { ports.first.map { $0.description.isEmpty ? $0.summary : $0.description } ?? "" }

    public var isSourceBuilt: Bool { ports.first?.isSourceBuilt ?? false }
}

/// One Project's Release that updates Library Ports.
public struct ProjectUpdate: Identifiable, Hashable, Sendable {
    public var project: Project
    public var release: Release
    /// The Library Ports it updates.
    public var ports: [CatalogEntry]
    public var id: String { project.id }
}

/// The Catalog's Ports as the Library sees them: which are to install and which Unsupported, by Platform, Genre and
/// Game; New Ports and the Port of the Day; search; Projects; and the Releases worth showing. Every Catalog screen reads
/// its answers here, worked out once when the Catalog, the Library or the known Releases change.
public struct Lineup: Sendable {
    public typealias GameGroup = (game: Game, ports: [CatalogEntry])

    /// The Ports first released in one year, for New Ports.
    public struct Year: Hashable, Sendable, Identifiable {
        /// Nil for Ports without a first Release: "Earlier", last.
        public var year: Int?
        public var ports: [CatalogEntry]
        public var id: Int { year ?? 0 }
    }

    /// The Releases published in one month of the last 12, or earlier.
    public struct Month: Hashable, Sendable, Identifiable {
        /// The month's first day; nil for every Release before the last 12 months: "Earlier", last.
        public var start: Date?
        public var releases: [Release]
        public var id: Date { start ?? .distantPast }
    }

    /// Installed Ports and first installs under way.
    public let library: Set<PortID>
    /// Installable Catalog entries not in the Library, by name: the Ports to install.
    public let toInstall: [CatalogEntry]
    /// Catalog entries that can't work in the sandbox, by name: listed apart, never installable.
    public let unsupported: [CatalogEntry]
    /// Every Platform with how many Games on it have Ports to install, and how many Ports are Unsupported.
    public let platforms: [(platform: Platform, count: Int, unsupported: Int)]
    /// Every Genre with how many Games in it have Ports to install, and how many Ports are Unsupported.
    public let genres: [(genre: Genre, count: Int, unsupported: Int)]
    /// Every Game with Ports to install, by name, each with them in Catalog order: All Games.
    public let games: [GameGroup]
    /// Every Project, by name.
    public let projects: [Project]
    /// Updates for Library Ports, one per Project, by Project name.
    public let projectUpdates: [ProjectUpdate]
    /// Catalog Releases other than updates for installed Ports, newest first, one per Project and version: the Ports
    /// of one Project share its Releases.
    public let otherReleases: [Release]
    /// Every Catalog Port by the year of its first Release, newest first; undated ones last.
    public let years: [Year]

    private let catalog: CatalogDocument?
    private let calendar: Calendar
    private let byPlatform: [PlatformID: [CatalogEntry]]
    private let byGenre: [GenreID: [CatalogEntry]]
    private let gamesByPlatform: [PlatformID: [GameGroup]]
    private let gamesByGenre: [GenreID: [GameGroup]]
    private let portsByGame: [GameID: [CatalogEntry]]
    private let projectsByID: [String: Project]
    /// Every known Release of a Catalog Port: the newest on its Channel, its update, and the installed one.
    private let known: [Release]

    /// - Parameters:
    ///   - library: installed Ports and first installs under way.
    ///   - releases: the newest Release of each Catalog Port on its Channel.
    ///   - updates: newer non-Blocked Releases for installed Ports.
    ///   - installed: the Releases installed now.
    ///   - calendar: the user's, for the Port of the Day and the year and month groups.
    public init(
        catalog: CatalogDocument?, library: Set<PortID> = [], releases: [Release] = [], updates: [PortID: Release] = [:],
        installed: [Release] = [], calendar: Calendar = .current
    ) {
        self.catalog = catalog
        self.library = library
        self.calendar = calendar
        let ports = catalog?.ports ?? []
        let game = { (entry: CatalogEntry) in catalog?.game(for: entry) }

        let toInstall = ports.filter { $0.isInstallable && !library.contains($0.id) }.sorted(by: Self.byName)
        let unsupported = ports.filter { !$0.isInstallable }.sorted(by: Self.byName)
        let portsByGame = Dictionary(grouping: ports) { $0.game }

        var byPlatform: [PlatformID: [CatalogEntry]] = [:]
        var byGenre: [GenreID: [CatalogEntry]] = [:]
        var unsupportedByPlatform: [PlatformID: Int] = [:]
        var unsupportedByGenre: [GenreID: Int] = [:]
        for entry in toInstall {
            guard let game = game(entry) else { continue }
            byPlatform[game.platform, default: []].append(entry)
            for genre in game.genres { byGenre[genre, default: []].append(entry) }
        }
        for entry in unsupported {
            guard let game = game(entry) else { continue }
            unsupportedByPlatform[game.platform, default: 0] += 1
            for genre in game.genres { unsupportedByGenre[genre, default: 0] += 1 }
        }

        let available = Set(toInstall.map(\.id))
        let games = (catalog?.games ?? [])
            .map { game -> GameGroup in (game: game, ports: (portsByGame[game.id] ?? []).filter { available.contains($0.id) }) }
            .filter { !$0.ports.isEmpty }
            .sorted { $0.game.displayName.localizedStandardCompare($1.game.displayName) == .orderedAscending }
        let gamesByPlatform = Dictionary(grouping: games) { $0.game.platform }
        var gamesByGenre: [GenreID: [GameGroup]] = [:]
        for group in games {
            for genre in group.game.genres { gamesByGenre[genre, default: []].append(group) }
        }

        var projects: [Project] = []
        var index: [String: Int] = [:]
        for entry in ports {
            if let i = index[entry.releases.repo] {
                projects[i].ports.append(entry)
            } else {
                index[entry.releases.repo] = projects.count
                projects.append(Project(entry))
            }
        }
        projects.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let repo = { (release: Release) in catalog?.entry(release.port)?.releases.repo ?? release.port.rawValue }
        let key = { (release: Release) in "\(repo(release))@\(release.version)" }
        var seen = Set(updates.values.map(key))

        var years: [Year] = []
        for port in Self.byFirstRelease(ports) {
            let year = port.firstRelease.map { calendar.component(.year, from: $0) }
            if let i = years.firstIndex(where: { $0.year == year }) {
                years[i].ports.append(port)
            } else {
                years.append(Year(year: year, ports: [port]))
            }
        }

        self.toInstall = toInstall
        self.unsupported = unsupported
        self.portsByGame = portsByGame
        self.byPlatform = byPlatform
        self.byGenre = byGenre
        self.games = games
        self.gamesByPlatform = gamesByPlatform
        self.gamesByGenre = gamesByGenre
        platforms = (catalog?.platforms ?? []).map { platform in
            (platform: platform, count: gamesByPlatform[platform.id]?.count ?? 0,
             unsupported: unsupportedByPlatform[platform.id] ?? 0)
        }
        genres = (catalog?.genres ?? []).map { genre in
            (genre: genre, count: gamesByGenre[genre.id]?.count ?? 0, unsupported: unsupportedByGenre[genre.id] ?? 0)
        }
        self.projects = projects
        projectsByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        projectUpdates = projects.compactMap { project in
            let ports = project.ports.filter { updates[$0.id] != nil }
            guard let first = ports.first, let release = updates[first.id] else { return nil }
            return ProjectUpdate(project: project, release: release, ports: ports)
        }
        otherReleases = releases.sorted(by: Self.newestFirst).filter { seen.insert(key($0)).inserted }
        known = Array(updates.values) + releases + installed
        self.years = years
    }

    // MARK: Ports to install

    public func toInstall(on platform: PlatformID) -> [CatalogEntry] { byPlatform[platform] ?? [] }

    public func toInstall(in genre: GenreID) -> [CatalogEntry] { byGenre[genre] ?? [] }

    public func unsupported(on platform: PlatformID) -> [CatalogEntry] {
        unsupported.filter { catalog?.platform(for: $0)?.id == platform }
    }

    public func unsupported(in genre: GenreID) -> [CatalogEntry] {
        unsupported.filter { catalog?.game(for: $0)?.genres.contains(genre) == true }
    }

    /// A Platform's Games with their Ports to install, by name; Games with none are left out.
    public func games(on platform: PlatformID) -> [GameGroup] { gamesByPlatform[platform] ?? [] }

    /// A Genre's Games with their Ports to install, by name; Games with none are left out.
    public func games(in genre: GenreID) -> [GameGroup] { gamesByGenre[genre] ?? [] }

    /// The Catalog's Ports of a Game, in Catalog order, so the first is the one the Catalog recommends: installed and
    /// Unsupported ones too.
    public func ports(of game: GameID) -> [CatalogEntry] { portsByGame[game] ?? [] }

    /// Changes once a day; drawn from the Ports to install. Each gets a score from a hash of the local date and its id,
    /// and the highest wins: the same Port all day on every Mac, and installing a different Port doesn't change the
    /// pick.
    public func portOfTheDay(on date: Date = .now) -> CatalogEntry? {
        let local = calendar.dateComponents([.year, .month, .day], from: date)
        let stamp = [local.year, local.month, local.day].map { String($0 ?? 0) }.joined(separator: "-")
        return toInstall
            .max { Hashing.sha256(Data("\(stamp)/\($0.id)".utf8)) < Hashing.sha256(Data("\(stamp)/\($1.id)".utf8)) }
    }

    /// The 3 Ports to install whose first Release is newest, leaving out the Port of the Day, which the Catalog's hero
    /// already shows.
    public func newPorts(now: Date = .now) -> [CatalogEntry] {
        let hero = portOfTheDay(on: now)?.id
        return Array(Self.byFirstRelease(toInstall.filter { $0.id != hero }).prefix(3))
    }

    /// Every Catalog entry matching the text by Port, Game, Platform or developer, by name.
    public func search(_ text: String) -> [CatalogEntry] {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, let catalog else { return [] }
        return catalog.ports.filter { entry in
            let fields = [entry.name, entry.developer, catalog.game(for: entry)?.name, catalog.platform(for: entry)?.name]
            return fields.contains { $0?.localizedStandardContains(query) == true }
        }
        .sorted(by: Self.byName)
    }

    // MARK: Projects

    /// The Project with this repository.
    public func project(_ id: String) -> Project? { projectsByID[id] }

    public func project(for entry: CatalogEntry) -> Project? { projectsByID[entry.releases.repo] }

    /// The Project's known Releases, newest first, each version once: installed ones too.
    public func releases(of project: Project) -> [Release] {
        let ids = Set(project.ports.map(\.id))
        var seen = Set<String>()
        return known.filter { ids.contains($0.port) }.sorted(by: Self.newestFirst).filter { seen.insert($0.version).inserted }
    }

    // MARK: Releases

    /// `otherReleases` of the last 12 months by month, newest first, then the rest as "Earlier".
    public func months(now: Date = .now) -> [Month] {
        let cutoff = calendar.date(byAdding: .month, value: -12, to: now) ?? .distantPast
        var months: [Month] = []
        for release in otherReleases {
            let date = release.published ?? .distantPast
            let start = date < cutoff ? nil : calendar.dateInterval(of: .month, for: date)?.start
            if let i = months.firstIndex(where: { $0.start == start }) {
                months[i].releases.append(release)
            } else {
                months.append(Month(start: start, releases: [release]))
            }
        }
        return months
    }

    // MARK: Order

    private static func byName(_ a: CatalogEntry, _ b: CatalogEntry) -> Bool {
        a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    private static func newestFirst(_ a: Release, _ b: Release) -> Bool {
        (a.published ?? .distantPast) > (b.published ?? .distantPast)
    }

    /// Newest first Release first, undated last, then by name.
    private static func byFirstRelease(_ ports: [CatalogEntry]) -> [CatalogEntry] {
        ports.sorted { a, b in
            a.firstRelease != b.firstRelease
                ? (a.firstRelease ?? .distantPast) > (b.firstRelease ?? .distantPast)
                : byName(a, b)
        }
    }
}
