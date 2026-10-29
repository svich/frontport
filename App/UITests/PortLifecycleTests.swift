import FrontportCore
import XCTest

/// Testport through its whole life in the app, offline: install from the local server, Permissions, ROMs, play,
/// uninstall and delete its Data. Uses Testport's real container, so it never runs while that container has Data,
/// and deletes the Data it made.
@MainActor
final class PortLifecycleTests: XCTestCase {
    func testInstallPlayUninstallAndDeleteData() async throws {
        continueAfterFailure = false
        let files = PortFiles(port: TestportWorld.port)
        guard files.running.isEmpty else { throw XCTSkip("\(files.bundleID) is running") }
        guard !files.hasData else {
            throw XCTSkip("\(files.data.path(percentEncoded: false)) exists; this test would delete it")
        }
        // Registered first, so it runs last: after the app has quit.
        addTeardownBlock { @MainActor in
            for app in files.running { _ = app.forceTerminate() }
            try? FileOperations.removeUntrusted(files.data)
        }

        let world = try await TestportWorld()
        let romFile = Session.base.appending(path: "\(UUID().uuidString) Synthetic.z64")
        try FileManager.default.createDirectory(at: Session.base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: romFile) }
        let session = try Session.launch(
            self, arguments: ["-FrontportImportROMs", romFile.path(percentEncoded: false)], world: world)
        session.attachLogs(of: TestportWorld.port, to: self)

        let lifecycle = Lifecycle(port: .testport, session: session)
        try lifecycle.install()
        try lifecycle.portPage()
        try lifecycle.permissions()
        try lifecycle.roms(rejected: SyntheticROM(marker: "rejected"), accepted: world.rom, file: romFile)
        try lifecycle.play {
            // Testport found the Seeded ROM from inside its sandbox.
            var report: TestportReport?
            session.waitUntil(30) {
                report = TestportReport.read(from: files.data)
                return report != nil
            }
            let read = try XCTUnwrap(report, "Testport wrote no report")
            XCTAssertTrue(read.sandboxed, "Testport doesn't see its sandbox")
            XCTAssertEqual(read.rom?.sha1, world.rom.sha1, "Testport didn't read the Seeded ROM")
        }
        try lifecycle.uninstall()
        try lifecycle.deleteData()
    }
}
