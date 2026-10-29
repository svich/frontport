import XCTest

/// The Releases screen, from Releases discovered on GitHub at launch.
@MainActor
final class ReleasesTests: XCTestCase {
    /// Releases are grouped by month, each with a summary of its notes and a Release Notes link.
    func testReleasesGroupedByMonthWithNotes() throws {
        continueAfterFailure = false
        let session = try Session.launch(self)
        session.click("sidebar.releases")
        let screen = session.wait(for: "screen.releases")

        // Discovery asks GitHub about every Port in the Catalog.
        XCTAssertTrue(session.waitUntil(180) { session.elements(prefix: "releases.row.", in: screen).count >= 5 })
        let groups = session.elements(prefix: "releases.group", in: screen).map { session.text(of: $0) }
        XCTAssertGreaterThanOrEqual(groups.count, 2, "Releases aren't grouped by month: \(groups)")
        for label in groups {
            XCTAssertNotNil(label.wholeMatch(of: /[A-Z]+ \d{4}|EARLIER/), "“\(label)” isn't a month")
        }
        XCTAssertEqual(Set(groups).count, groups.count, "A month shows twice: \(groups)")

        let notes = session.elements(prefix: "content.notes.", in: screen).map { session.text(of: $0) }
        let linked = notes.filter { $0.hasSuffix("Release Notes") }
        XCTAssertGreaterThanOrEqual(linked.count, 3, "Too few Release Notes links: \(notes)")
        XCTAssertTrue(linked.contains { $0.count > "Release Notes".count + 10 }, "No Release shows a summary: \(notes)")
        try session.assertGlossaryWording("Releases")
    }
}
