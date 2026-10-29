import FrontportCore
import XCTest

/// Adding a file the Catalog doesn't list, through Add ROMs…, and keeping it Unverified.
@MainActor
final class ROMIntakeTests: XCTestCase {
    /// The intake sheet shows the file with its SHA-1 and the ROMs it can be kept as; kept as one, it's added
    /// Unverified, and the ROMs screen says so.
    func testUnknownFileIsKeptUnverifiedAsTheChosenROM() throws {
        continueAfterFailure = false
        let rom = SyntheticROM(marker: "unknown")
        // Written once the session has its scratch folder; the app adds it instead of showing the open panel.
        let file = Session.base.appending(path: "\(UUID().uuidString) Not a ROM.z64")
        try FileManager.default.createDirectory(at: Session.base, withIntermediateDirectories: true)
        try rom.write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let catalog = BundledCatalog.document
        let chosen = try XCTUnwrap(catalog.assignable(format: "z64").first)
        let game = try XCTUnwrap(chosen.game.flatMap(catalog.game))
        let session = try Session.launch(self, arguments: ["-FrontportImportROMs", file.path(percentEncoded: false)])

        session.click("sidebar.roms")
        session.wait(for: "screen.roms")
        session.click("roms.add")
        session.wait(for: "intake.sheet")
        session.wait(for: "intake.unknown")
        XCTAssertFalse(session.element("intake.added").exists)
        XCTAssertEqual(session.text(of: session.wait(for: "intake.sha1")), "SHA-1 \(rom.sha1)")
        XCTAssertEqual(session.text(of: session.wait(for: "intake.title")), "Not in the Catalog")
        XCTAssertFalse(session.wait(for: "intake.keep").isEnabled)
        try session.assertGlossaryWording("The intake sheet")

        session.click("intake.choice")
        session.click(session.app.menuItems["\(game.displayName) · \(chosen.name)"])
        session.click("intake.keep")
        session.wait(for: "intake.added")
        XCTAssertEqual(session.text(of: session.wait(for: "intake.title")), "Added 1 ROM")
        try session.assertGlossaryWording("The intake sheet, once a file is kept")

        session.click("intake.done")
        session.waitUntilGone("intake.sheet")
        session.wait(for: "roms.unverified.\(chosen.sha1)")
        try session.assertGlossaryWording("The ROMs screen with an Unverified ROM")
    }
}
