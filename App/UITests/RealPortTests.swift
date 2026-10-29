import FrontportCore
import XCTest

/// Zelda 64: Recompiled, a real Port, through the same life as Testport: installed from GitHub and run in its real
/// container with a stand-in ROM. Opt-in, since it downloads about 30 MB and the Port crashes as it quits:
/// `TEST_RUNNER_FRONTPORT_REAL_PORTS=1 mise run uitest`. It never runs while that container has Data, and deletes
/// the Data it made.
@MainActor
final class RealPortTests: XCTestCase {
    func testZelda64RecompiledLifecycle() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["FRONTPORT_REAL_PORTS"] == "1" else {
            throw XCTSkip("Set FRONTPORT_REAL_PORTS=1 to run real Ports")
        }
        let port = LifecyclePort.zelda64recomp
        let files = PortFiles(port: port.id)
        guard files.running.isEmpty else { throw XCTSkip("\(files.bundleID) is running") }
        guard !files.hasData else {
            throw XCTSkip("\(files.data.path(percentEncoded: false)) exists; this test would delete it")
        }
        // Registered first, so it runs last: after the app has quit.
        addTeardownBlock { @MainActor in
            for app in files.running { _ = app.forceTerminate() }
            try? FileOperations.removeUntrusted(files.data)
        }

        // A file the app is told to accept as the Port's ROM, so the Port can be Seeded and played without a real
        // ROM.
        let accepted = SyntheticROM(marker: "accepted")
        let romFile = Session.base.appending(path: "\(UUID().uuidString) Stand-in.z64")
        try FileManager.default.createDirectory(at: Session.base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: romFile) }
        let session = try Session.launch(self, arguments: [
            "-FrontportImportROMs", romFile.path(percentEncoded: false),
            "-FrontportAcceptROM", "\(port.id)=\(accepted.sha1)",
        ])
        session.attachLogs(of: port.id, to: self)

        let lifecycle = Lifecycle(port: port, session: session)
        try lifecycle.install()
        try lifecycle.portPage()
        try lifecycle.permissions()
        try lifecycle.roms(rejected: SyntheticROM(marker: "rejected"), accepted: accepted, file: romFile)
        try lifecycle.play()
        try lifecycle.uninstall()
        try lifecycle.deleteData()
    }
}
