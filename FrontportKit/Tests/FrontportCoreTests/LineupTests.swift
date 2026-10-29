import Foundation
import Testing
@testable import FrontportCore

@Suite struct LineupTests {
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func date(_ text: String) -> Date { try! Date(text + "T12:00:00Z", strategy: .iso8601) }

    static func entry(
        _ id: PortID, _ name: String, game: GameID, repo: String, developer: String = "HarbourMasters",
        unsupported: String? = nil, firstRelease: String? = nil
    ) -> CatalogEntry {
        CatalogEntry(
            id: id, name: name, kind: .decomp, game: game, developer: developer, summary: "", description: "",
            source: URL(string: "https://github.com/\(repo)")!, bundleId: id.conventionalBundleID,
            releases: .githubRelease(GitHubReleaseSource(repo: repo, asset: "*.zip")), unsupported: unsupported,
            firstRelease: firstRelease.map(date))
    }

    /// Two Platforms; Ocarina of Time with one Port, Majora's Mask with two, Mario Kart 64 with an Unsupported one, and
    /// two Switch Games from one Project.
    static let catalog = CatalogDocument(
        issued: .now,
        platforms: [
            Platform(id: "n64", name: "Nintendo 64", shortName: "N64", medium: .cartridge),
            Platform(id: "switch", name: "Nintendo Switch", shortName: "Switch", medium: .cartridge),
        ],
        genres: [Genre(id: "adventure", name: "Adventure"), Genre(id: "racing", name: "Racing"),
                 Genre(id: "platformer", name: "Platformer")],
        games: [
            Game(id: "oot", name: "The Legend of Zelda: Ocarina of Time", shortName: "Ocarina of Time", platform: "n64",
                 genres: ["adventure"]),
            Game(id: "mm", name: "The Legend of Zelda: Majora’s Mask", shortName: "Majora’s Mask", platform: "n64",
                 genres: ["adventure"]),
            Game(id: "kart", name: "Mario Kart 64", platform: "n64", genres: ["racing"]),
            Game(id: "wonder", name: "Super Mario Bros. Wonder", platform: "switch", genres: ["platformer"]),
            Game(id: "totk", name: "The Legend of Zelda: Tears of the Kingdom", shortName: "Tears of the Kingdom",
                 platform: "switch", genres: ["adventure"]),
        ],
        roms: [],
        ports: [
            entry("soh", "Ship of Harkinian", game: "oot", repo: "HarbourMasters/Shipwright", firstRelease: "2022-03-01"),
            entry("2ship", "2 Ship 2 Harkinian", game: "mm", repo: "HarbourMasters/2ship2harkinian",
                  firstRelease: "2024-05-01"),
            entry("zelda64recomp", "Zelda 64: Recompiled", game: "mm", repo: "Zelda64Recomp/Zelda64Recomp",
                  developer: "Wiseguy", firstRelease: "2024-05-20"),
            entry("spaghettikart", "SpaghettiKart", game: "kart", repo: "HarbourMasters/SpaghettiKart",
                  unsupported: "It needs a GPU driver the sandbox denies.", firstRelease: "2025-01-10"),
            entry("nxnative-wonder", "nxnative", game: "wonder", repo: "nxnative/nxnative", developer: "nxnative"),
            entry("nxnative-totk", "nxnative", game: "totk", repo: "nxnative/nxnative", developer: "nxnative",
                  firstRelease: "2023-07-01"),
        ])

    static func release(_ port: PortID, _ version: String, published: String?) -> Release {
        Release(port: port, version: version, published: published.map(date))
    }

    // MARK: Ports to install

    @Test func portsToInstallLeaveOutTheLibraryAndUnsupportedPorts() {
        let lineup = Lineup(catalog: Self.catalog, library: ["soh"], calendar: Self.utc)
        #expect(Set(lineup.toInstall.map(\.id)) == ["2ship", "zelda64recomp", "nxnative-wonder", "nxnative-totk"])
        #expect(lineup.toInstall.first?.id == "2ship")
        #expect(lineup.toInstall.last?.id == "zelda64recomp")
        #expect(lineup.unsupported.map(\.id) == ["spaghettikart"])
        #expect(Lineup(catalog: nil).toInstall.isEmpty)
    }

    /// Platforms and Genres count Games with Ports to install, not Ports, and count Unsupported Ports apart.
    @Test func platformsAndGenresCountGamesToInstall() {
        let lineup = Lineup(catalog: Self.catalog, library: ["soh"], calendar: Self.utc)
        #expect(lineup.platforms.map { "\($0.platform.id) \($0.count) \($0.unsupported)" } == ["n64 1 1", "switch 2 0"])
        #expect(lineup.genres.map { "\($0.genre.id) \($0.count) \($0.unsupported)" }
            == ["adventure 2 0", "racing 0 1", "platformer 1 0"])
        #expect(lineup.toInstall(on: "n64").map(\.id) == ["2ship", "zelda64recomp"])
        #expect(lineup.unsupported(on: "n64").map(\.id) == ["spaghettikart"])
        #expect(lineup.toInstall(in: "racing").isEmpty)
        #expect(lineup.unsupported(in: "racing").map(\.id) == ["spaghettikart"])
        #expect(lineup.unsupported(on: "switch").isEmpty)
    }

    /// Games are by name, each with its Ports to install in Catalog order; a Game with none is left out.
    @Test func gamesListTheirPortsToInstall() {
        let lineup = Lineup(catalog: Self.catalog, library: ["soh"], calendar: Self.utc)
        #expect(lineup.games.map(\.game.id) == ["mm", "wonder", "totk"])
        #expect(lineup.games(on: "n64").map(\.game.id) == ["mm"])
        #expect(lineup.games(on: "n64").first?.ports.map(\.id) == ["2ship", "zelda64recomp"])
        #expect(lineup.games(in: "adventure").map(\.game.id) == ["mm", "totk"])
        #expect(lineup.games(in: "racing").isEmpty)
        // A Game's Ports, installed and Unsupported ones too, for its Game page.
        #expect(lineup.ports(of: "oot").map(\.id) == ["soh"])
        #expect(lineup.ports(of: "kart").map(\.id) == ["spaghettikart"])
        #expect(lineup.ports(of: "mm").map(\.id) == ["2ship", "zelda64recomp"])
    }

    // MARK: Port of the Day and New Ports

    @Test func portOfTheDayStaysAllDayAndIgnoresOtherInstalls() throws {
        let morning = try Date("2026-10-29T00:30:00Z", strategy: .iso8601)
        let night = try Date("2026-10-29T23:30:00Z", strategy: .iso8601)
        let lineup = Lineup(catalog: Self.catalog, calendar: Self.utc)
        let pick = try #require(lineup.portOfTheDay(on: morning))
        #expect(lineup.portOfTheDay(on: night) == pick)
        #expect(lineup.toInstall.contains(pick))

        let other = try #require(lineup.toInstall.first { $0.id != pick.id })
        #expect(Lineup(catalog: Self.catalog, library: [other.id], calendar: Self.utc).portOfTheDay(on: night) == pick)
        let installed = Lineup(catalog: Self.catalog, library: [pick.id], calendar: Self.utc).portOfTheDay(on: night)
        #expect(installed != nil && installed != pick)
    }

    /// The 3 Ports to install first released most recently, undated last, without the Port of the Day.
    @Test func newPortsLeaveOutThePortOfTheDay() throws {
        let now = Self.date("2026-10-29")
        let lineup = Lineup(catalog: Self.catalog, calendar: Self.utc)
        let hero = try #require(lineup.portOfTheDay(on: now)).id
        let newest: [PortID] = ["zelda64recomp", "2ship", "nxnative-totk", "soh", "nxnative-wonder"]
        #expect(lineup.newPorts(now: now).map(\.id) == Array(newest.filter { $0 != hero }.prefix(3)))
    }

    /// Every Catalog Port, Unsupported ones too, by the year of its first Release; undated ones last.
    @Test func yearsGroupEveryPortByFirstRelease() {
        let lineup = Lineup(catalog: Self.catalog, library: ["soh"], calendar: Self.utc)
        #expect(lineup.years.map(\.year) == [2025, 2024, 2023, 2022, nil])
        #expect(lineup.years.map { $0.ports.map(\.id) }
            == [["spaghettikart"], ["zelda64recomp", "2ship"], ["nxnative-totk"], ["soh"], ["nxnative-wonder"]])
    }

    // MARK: Search

    @Test func searchMatchesPortGamePlatformOrDeveloper() {
        let lineup = Lineup(catalog: Self.catalog, library: ["soh"], calendar: Self.utc)
        let rows: [(String, [PortID])] = [
            ("harbour", ["2ship", "soh", "spaghettikart"]),
            ("Majora", ["2ship", "zelda64recomp"]),
            ("Switch", ["nxnative-wonder", "nxnative-totk"]),
            ("  zelda 64 ", ["zelda64recomp"]),
            ("Wiseguy", ["zelda64recomp"]),
            ("", []),
            ("   ", []),
        ]
        for (query, expected) in rows {
            #expect(Set(lineup.search(query).map(\.id)) == Set(expected), "“\(query)”")
        }
        #expect(lineup.search("harbour").map(\.id) == ["2ship", "soh", "spaghettikart"])
    }

    // MARK: Projects

    /// Ports sharing a repository are one Project, named after its first Port, and its Releases update them together.
    @Test func projectsGroupPortsByRepository() throws {
        let updates: [PortID: Release] = [
            "nxnative-wonder": Self.release("nxnative-wonder", "1.1", published: "2026-10-20"),
            "nxnative-totk": Self.release("nxnative-totk", "1.1", published: "2026-10-20"),
            "soh": Self.release("soh", "9.3.1", published: "2026-10-01"),
        ]
        let lineup = Lineup(catalog: Self.catalog, library: ["soh", "nxnative-wonder", "nxnative-totk"],
                            updates: updates, calendar: Self.utc)
        #expect(lineup.projects.map(\.name)
            == ["2 Ship 2 Harkinian", "nxnative", "Ship of Harkinian", "SpaghettiKart", "Zelda 64: Recompiled"])
        let nxnative = try #require(lineup.project("nxnative/nxnative"))
        #expect(nxnative.ports.map(\.id) == ["nxnative-wonder", "nxnative-totk"])
        #expect(lineup.project(for: nxnative.ports[1]) == nxnative)
        #expect(lineup.project("nobody/nothing") == nil)
        #expect(lineup.projectUpdates.map(\.project.id) == ["nxnative/nxnative", "HarbourMasters/Shipwright"])
        #expect(lineup.projectUpdates.first?.ports.map(\.id) == ["nxnative-wonder", "nxnative-totk"])
        #expect(lineup.projectUpdates.first?.release.version == "1.1")
    }

    /// A Project's Releases: the newest, its updates and the installed ones, newest first, each version once.
    @Test func aProjectsReleasesIncludeInstalledOnes() throws {
        let lineup = Lineup(
            catalog: Self.catalog,
            releases: [Self.release("nxnative-wonder", "1.1", published: "2026-10-20"),
                       Self.release("nxnative-totk", "1.1", published: "2026-10-20")],
            installed: [Self.release("nxnative-wonder", "1.0", published: "2026-09-01"),
                        Self.release("soh", "9.3.0", published: "2026-09-02")],
            calendar: Self.utc)
        let nxnative = try #require(lineup.project("nxnative/nxnative"))
        #expect(lineup.releases(of: nxnative).map(\.version) == ["1.1", "1.0"])
    }

    // MARK: Releases

    /// One per Project and version, leaving out updates for installed Ports, newest first.
    @Test func otherReleasesLeaveOutUpdates() {
        let lineup = Lineup(
            catalog: Self.catalog,
            releases: [
                Self.release("zelda64recomp", "1.2", published: "2026-10-01"),
                Self.release("nxnative-wonder", "1.1", published: "2026-10-20"),
                Self.release("nxnative-totk", "1.1", published: "2026-10-20"),
                Self.release("soh", "9.3.1", published: "2026-10-15"),
                Self.release("2ship", "2.0", published: "2026-10-10"),
            ],
            updates: ["soh": Self.release("soh", "9.3.1", published: "2026-10-15")],
            calendar: Self.utc)
        #expect(lineup.otherReleases.map(\.version) == ["1.1", "2.0", "1.2"])
        #expect(lineup.otherReleases.dropFirst().map(\.port) == ["2ship", "zelda64recomp"])
    }

    /// The last 12 months by month, newest first, then everything older or undated as "Earlier".
    @Test func monthsGroupTheLastYearThenEarlier() {
        let lineup = Lineup(
            catalog: Self.catalog,
            releases: [
                Self.release("2ship", "2.0", published: "2026-10-03"),
                Self.release("soh", "9.3.1", published: "2026-10-20"),
                Self.release("zelda64recomp", "1.2", published: "2026-08-15"),
                Self.release("spaghettikart", "0.9", published: "2025-09-01"),
                Self.release("nxnative-wonder", "1.0", published: nil),
            ],
            calendar: Self.utc)
        let months = lineup.months(now: Self.date("2026-10-29"))
        #expect(months.map(\.start) == [
            Self.utc.dateInterval(of: .month, for: Self.date("2026-10-01"))?.start,
            Self.utc.dateInterval(of: .month, for: Self.date("2026-08-01"))?.start,
            nil,
        ])
        #expect(months.map { $0.releases.map(\.port) }
            == [["soh", "2ship"], ["zelda64recomp"], ["spaghettikart", "nxnative-wonder"]])
    }
}
