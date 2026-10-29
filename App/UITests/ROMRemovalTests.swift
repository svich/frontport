import XCTest

/// Removing ROMs from the ROMs table, offline against Testport's Catalog.
@MainActor
final class ROMRemovalTests: XCTestCase {
    /// Remove… asks first; a removed row leaves the table while the app keeps running, and removing the last
    /// ROM leaves the empty state.
    func testRemoveAsksThenRemoves() async throws {
        continueAfterFailure = false
        let world = try await TestportWorld()
        let file = Session.base.appending(path: "\(UUID().uuidString) Synthetic.z64")
        try FileManager.default.createDirectory(at: Session.base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let session = try Session.launch(
            self, arguments: ["-FrontportImportROMs", file.path(percentEncoded: false)], world: world)

        session.click("sidebar.roms")
        session.wait(for: "screen.roms")
        // Add ROMs… adds whatever the file holds when clicked.
        for rom in [world.rom, world.spare] {
            try rom.write(to: file)
            session.click("roms.add")
            session.wait(for: "intake.added")
            session.click("intake.done")
            session.waitUntilGone("intake.sheet")
        }

        let spare = "roms.more.\(world.spare.sha1)"
        session.click(spare)
        session.click(session.app.menuItems["Remove…"])
        session.answerDialog("Cancel")
        XCTAssertTrue(session.element(spare).exists, "Cancel removed it")

        for rom in [world.spare, world.rom] {
            let more = "roms.more.\(rom.sha1)"
            session.click(more)
            session.click(session.app.menuItems["Remove…"])
            session.answerDialog("Remove")
            session.waitUntilGone(more)
            session.waitUntil(2) { false }
            XCTAssertEqual(session.app.state, .runningForeground, "The app quit after removing a ROM")
        }
        XCTAssertTrue(session.app.staticTexts["No ROMs Yet"].waitForExistence(timeout: 10), "No empty state")
    }
}
