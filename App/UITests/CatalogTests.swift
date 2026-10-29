import FrontportCore
import XCTest

/// The launch rule, the Catalog's counts, Platform and Genre pages, store pages and search, on an empty root. Reads
/// the bundled Catalog only.
@MainActor
final class CatalogTests: XCTestCase {
    private let catalog = BundledCatalog.document
    private let lineup = BundledCatalog.lineup

    /// An empty root opens on the Catalog. Each Platform and Genre counts only Games with Ports that can be installed,
    /// and its page lists the Unsupported Ports apart.
    func testEmptyRootOpensOnCatalogWithHonestCounts() throws {
        continueAfterFailure = false
        let session = try Session.launch(self)
        session.wait(for: "screen.catalog")
        session.waitForCatalog()
        XCTAssertFalse(session.element("screen.library").exists)
        XCTAssertFalse(catalog.genres.isEmpty)
        let groups =
            lineup.platforms.map { platform, games, _ in
                (kind: "platform", id: platform.id.rawValue, name: platform.name, games: games,
                 toInstall: lineup.toInstall(on: platform.id).count, unsupported: lineup.unsupported(on: platform.id))
            }
            + lineup.genres.map { genre, games, _ in
                (kind: "genre", id: genre.id.rawValue, name: genre.name, games: games,
                 toInstall: lineup.toInstall(in: genre.id).count, unsupported: lineup.unsupported(in: genre.id))
            }
        for group in groups {
            let counted =
                group.games == 0 && !group.unsupported.isEmpty
                ? "\(group.unsupported.count) Unsupported" : "\(group.games) Game\(group.games == 1 ? "" : "s")"
            XCTAssertEqual(session.scrollTo("catalog.\(group.kind).\(group.id)", in: "screen.catalog").label, "\(group.name), \(counted)")
        }
        try session.assertGlossaryWording("The Catalog")

        for group in groups {
            let installable = group.toInstall
            let unsupported = group.unsupported
            session.click("sidebar.catalog")
            session.click(session.scrollTo("catalog.\(group.kind).\(group.id)", in: "screen.catalog"))
            session.wait(for: "screen.\(group.kind).\(group.id)")
            XCTAssertEqual(
                session.text(of: session.wait(for: "\(group.kind).available")),
                "\(installable) Port\(installable == 1 ? "" : "s") to install")
            if !unsupported.isEmpty {
                XCTAssertEqual(session.text(of: session.wait(for: "catalog.unsupported.count")), "\(unsupported.count)")
            }
            for port in unsupported {
                XCTAssertTrue(session.element("catalog.unsupported.\(port.id)").exists, "\(port.id) isn't listed as Unsupported")
                XCTAssertFalse(session.element("catalog.port.\(port.id)").exists, "\(port.id) is listed as available")
            }
            try session.assertGlossaryWording("The \(group.name) page")
        }
    }

    /// New Ports shows 3 Ports to install, and All opens every Port by the year of its first Release.
    func testNewPortsAllOpensEveryPortByFirstRelease() throws {
        continueAfterFailure = false
        let session = try Session.launch(self)
        session.waitForCatalog()
        let all = session.scrollTo("catalog.new.all", in: "screen.catalog")
        XCTAssertEqual(session.elements(prefix: "catalog.card.", in: session.element("screen.catalog")).count, 3)

        session.click(all)
        let screen = session.wait(for: "screen.releases")
        XCTAssertTrue(session.waitUntil(10) { !session.elements(prefix: "releases.year", in: screen).isEmpty })
        try session.assertGlossaryWording("New Ports on the Releases screen")
    }

    /// A Game with more than one Port opens a page of its Ports. Each opens its store page, which leads back to all of
    /// them and on to its Project's page.
    func testGameWithSeveralPortsListsThemAndLeadsToProjects() throws {
        continueAfterFailure = false
        let session = try Session.launch(self)
        session.waitForCatalog()
        let (game, entries) = try XCTUnwrap(lineup.games.first { $0.ports.count > 1 })
        let ports = entries.map(\.id.rawValue)

        session.click(session.scrollTo("catalog.game.\(game.id.rawValue)", in: "screen.catalog"))
        session.wait(for: "screen.game.\(game.id.rawValue)")
        for port in ports {
            XCTAssertTrue(session.element("game.port.\(port)").exists, "\(port) isn't on its Game's page")
        }
        try session.assertGlossaryWording("The \(game.name) Game page")

        session.click("game.port.\(ports[1])")
        session.wait(for: "screen.store.\(ports[1])")
        session.click("store.allPorts")
        session.wait(for: "screen.game.\(game.id.rawValue)")

        session.click("game.port.\(ports[0])")
        session.wait(for: "screen.store.\(ports[0])")
        session.click("store.project")
        session.wait(for: "screen.project")
        XCTAssertTrue(session.element("catalog.card.\(ports[0])").exists, "The Project's page doesn't list \(ports[0])")
        try session.assertGlossaryWording("The Project page")
    }

    /// Zelda 64: Recompiled offers Install and no donate button; an Unsupported Port, when the Catalog has one, offers
    /// no Install.
    func testStorePagesOfferInstallOnlyWhenSupported() throws {
        continueAfterFailure = false
        let session = try Session.launch(self)
        session.waitForCatalog()

        session.openStorePage("zelda64recomp", searching: "Zelda 64")
        XCTAssertTrue(session.wait(for: "store.install").isEnabled)
        let shown = try session.strings(in: session.app.windows.firstMatch).joined(separator: "\n").lowercased()
        for word in ["donate", "donation", "sponsor", "patreon", "ko-fi", "tip jar"] {
            XCTAssertFalse(shown.contains(word), "The store page mentions “\(word)”")
        }
        try session.assertGlossaryWording("The Zelda 64: Recompiled store page")

        guard let unsupported = lineup.unsupported.first else { return }
        let id = unsupported.id.rawValue
        let platform = try XCTUnwrap(catalog.platform(for: unsupported)).id.rawValue
        session.click("sidebar.catalog")
        session.click(session.scrollTo("catalog.platform.\(platform)", in: "screen.catalog"))
        session.click("catalog.unsupported.\(id)")
        session.wait(for: "screen.store.\(id)")
        session.wait(for: "store.status")
        XCTAssertFalse(session.element("store.install").exists)
        XCTAssertFalse(session.element("action.install.\(id)").exists)
        let installs = session.app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Install'"))
        XCTAssertEqual(installs.count, 0, "An Unsupported Port's store page offers Install")
        try session.assertGlossaryWording("The \(unsupported.name) store page")
    }

    /// Typing filters Ports; picking a result opens its store page and ends the search.
    func testSearchFiltersAndOpensStorePage() throws {
        continueAfterFailure = false
        let session = try Session.launch(self)
        session.waitForCatalog()

        for query in ["Mario", "Zelda 64"] {
            session.search(query)
            let results = session.wait(for: "screen.search")
            let expected = Set(lineup.search(query).map(\.id.rawValue))
            XCTAssertFalse(expected.isEmpty)
            let matched = session.waitUntil(10) {
                Set(session.elements(prefix: "catalog.card.", in: results).map { $0.identifier }) == Set(expected.map { "catalog.card.\($0)" })
            }
            XCTAssertTrue(matched, "“\(query)” should show exactly \(expected.sorted())")
        }
        try session.assertGlossaryWording("Search results")

        session.click("catalog.card.zelda64recomp")
        session.wait(for: "screen.store.zelda64recomp")
        session.waitUntilGone("screen.search")
        XCTAssertEqual(session.searchText, "")
    }
}
