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
        XCTAssertTrue(session.waitUntil(180) { !session.elements(prefix: "releases.row.", in: screen).isEmpty })
        // The months are a lazy stack, made only near the visible area: gather them while scrolling down.
        var groups: [String] = []
        var notes: [String] = []
        for _ in 0..<15 {
            let shown = session.elements(prefix: "releases.group", in: screen).map { session.text(of: $0) }
            XCTAssertEqual(Set(shown).count, shown.count, "A month shows twice: \(shown)")
            groups += shown.filter { !groups.contains($0) }
            let shownNotes = session.elements(prefix: "content.notes.", in: screen).map { session.text(of: $0) }
            notes += shownNotes.filter { !notes.contains($0) }
            if groups.count >= 2, notes.filter({ $0.hasSuffix("Release Notes") }).count >= 3 { break }
            screen.scroll(byDeltaX: 0, deltaY: -300)
        }
        XCTAssertGreaterThanOrEqual(groups.count, 2, "Releases aren't grouped by month: \(groups)")
        for label in groups {
            XCTAssertNotNil(label.wholeMatch(of: /[A-Z]+ \d{4}|EARLIER/), "“\(label)” isn't a month")
        }

        let linked = notes.filter { $0.hasSuffix("Release Notes") }
        XCTAssertGreaterThanOrEqual(linked.count, 3, "Too few Release Notes links: \(notes)")
        XCTAssertTrue(linked.contains { $0.count > "Release Notes".count + 10 }, "No Release shows a summary: \(notes)")
        try session.assertGlossaryWording("Releases")
    }
}
