import XCTest

/// A Port the lifecycle tests take through its whole life in the app.
struct LifecyclePort {
    var id: String
    var name: String
    /// What finds it in the sidebar's search.
    var query: String
    /// Its Game's id: ROMs lists the ROM it needs under it.
    var game: String
    /// About how long installing it takes.
    var installTimeout: TimeInterval = 120
    /// It removes a stored ROM it doesn't recognize, such as a stand-in, so after a run it may need Seeding again.
    var removesStandIn = false
    /// It crashes as it quits.
    var crashesOnQuit = false

    static let testport = LifecyclePort(id: TestportWorld.port, name: TestportWorld.name, query: "Testport", game: TestportWorld.game)

    static let zelda64recomp = LifecyclePort(
        id: "zelda64recomp", name: "Zelda 64: Recompiled", query: "Zelda 64", game: "majoras-mask",
        // About 30 MB from GitHub, unpacked and signed.
        installTimeout: 900, removesStandIn: true, crashesOnQuit: true)
}

/// The steps of a Port's life in the app: install from the store page, the Port page, Permissions, ROMs, play,
/// uninstall and Delete Data. Each test runs them in order over one Session.
@MainActor
struct Lifecycle {
    let port: LifecyclePort
    let session: Session
    var files: PortFiles { PortFiles(port: port.id) }

    /// Install from the store page; the Port shows in the sidebar and the Library, and a relaunch opens on the
    /// Library.
    func install() throws {
        session.waitForCatalog()
        session.openStorePage(port.id, searching: port.query)
        session.click("store.install")
        session.waitForInstall(port.id, timeout: port.installTimeout)
        XCTAssertTrue(
            session.element("store.addROM").exists || session.element("action.play.\(port.id)").exists,
            "The store page offers neither Play nor Add ROM…")
        session.wait(for: "sidebar.port.\(port.id)")

        session.click("sidebar.library")
        session.wait(for: "screen.library")
        session.wait(for: "library.tile.\(port.id)")
        try session.assertGlossaryWording("The Library")

        session.relaunch()
        session.wait(for: "screen.library")
        session.wait(for: "library.tile.\(port.id)")
    }

    /// The toolbar picker switches between Overview, Snapshots and Runs.
    func portPage() throws {
        session.click("sidebar.port.\(port.id)")
        session.wait(for: "screen.port.\(port.id)")
        session.wait(for: "port.overview")
        try session.assertGlossaryWording("The Port page")

        session.selectTab("Snapshots")
        session.wait(for: "port.snapshots")
        session.waitUntilGone("port.overview")
        try session.assertGlossaryWording("Snapshots")

        session.selectTab("Runs")
        session.wait(for: "port.runs")
        session.waitUntilGone("port.snapshots")
        try session.assertGlossaryWording("Runs")

        session.selectTab("Overview")
        session.wait(for: "port.overview")
        session.waitUntilGone("port.runs")
    }

    /// Turning Network on re-signs the app with `network.client`.
    func permissions() throws {
        let network = session.wait(for: "port.permission.network")
        XCTAssertFalse(session.isOn(network), "Network starts on")
        session.click(network)
        XCTAssertTrue(session.waitUntil(120) { session.isOn(network) && network.isEnabled }, "Re-signing didn't finish")

        let app = try XCTUnwrap(files.app(in: session.root), "No app in the Library folder")
        let signed = session.waitUntil(30) {
            PortFiles.entitlements(of: app)["com.apple.security.network.client"] as? Bool == true
        }
        XCTAssertTrue(signed, "No network.client in \(PortFiles.entitlements(of: app))")
        XCTAssertEqual(PortFiles.entitlements(of: app)["com.apple.security.app-sandbox"] as? Bool, true)
    }

    /// Needed lists the Port's ROM; an unknown file is rejected with its hash; the accepted one is added and
    /// Seeded. Both go through Add ROMs… from `file`, which the app adds instead of showing the open panel.
    func roms(rejected: SyntheticROM, accepted: SyntheticROM, file: URL) throws {
        session.click("sidebar.roms")
        session.wait(for: "screen.roms")
        let needed = session.wait(for: "roms.needed.\(port.game)")
        let reasons = try session.strings(in: needed)
        XCTAssertTrue(reasons.contains { $0.contains(port.name) }, "Needed doesn't name the Port: \(reasons)")
        try session.assertGlossaryWording("ROMs")

        try rejected.write(to: file)
        session.click("roms.add")
        session.wait(for: "intake.rejected")
        XCTAssertEqual(session.text(of: session.wait(for: "intake.sha1")), "SHA-1 \(rejected.sha1)")
        try session.assertGlossaryWording("The intake sheet")
        session.click("intake.done")
        session.waitUntilGone("intake.sheet")

        try accepted.write(to: file)
        session.click("roms.add")
        session.wait(for: "intake.added")
        session.click("intake.done")
        session.waitUntilGone("intake.sheet")
        session.waitUntilGone("roms.needed.\(port.game)", timeout: 60)
    }

    /// Play launches the Port sandboxed; while it runs its Permissions are locked; `running` checks it further.
    /// Stop ends it, and Runs lists the run with its log.
    func play(running: () throws -> Void = {}) throws {
        session.click("sidebar.port.\(port.id)")
        session.wait(for: "port.overview")
        // Play shows once the ROM is Seeded.
        session.click("action.play.\(port.id)", timeout: 120)
        session.wait(for: "action.stop.\(port.id)", timeout: 60)
        // The Port's window comes to the front.
        session.app.activate()
        XCTAssertEqual(session.wait(for: "status.\(port.id)").label, "Running")
        // macOS lists the process as an app only once it has set itself up, a moment after Frontport started it.
        session.waitUntil(30) { !files.running.isEmpty }
        let process = try XCTUnwrap(files.running.first, "\(files.bundleID) isn't running")
        XCTAssertTrue(PortFiles.isSandboxed(process.processIdentifier), "The Port runs outside the sandbox")
        XCTAssertFalse(session.wait(for: "port.permission.network").isEnabled, "Permissions can change while it runs")
        try running()

        if port.crashesOnQuit {
            // XCTest reports a crash of a process Frontport started.
            let crash = XCTExpectedFailure.Options()
            crash.isStrict = false
            crash.issueMatcher = { [bundleID = files.bundleID] in $0.compactDescription.contains("\(bundleID) crashed") }
            XCTExpectFailure("\(port.name) crashes as it quits", options: crash)
        }
        session.click("action.stop.\(port.id)")
        session.waitUntilGone("action.stop.\(port.id)", timeout: 90)
        if port.removesStandIn {
            session.waitForAny("action.play.\(port.id)", "action.seed.\(port.id)", timeout: 30)
        } else {
            // The ROM stays Seeded.
            session.wait(for: "action.play.\(port.id)")
        }
        XCTAssertTrue(session.waitUntil(30) { files.running.isEmpty }, "The Port is still running")

        session.selectTab("Runs")
        session.wait(for: "port.runs")
        XCTAssertTrue(session.wait(for: "run.openLog").isEnabled)
        let logs = session.root.appending(path: "Logs/\(port.id)", directoryHint: .isDirectory)
        let kept = (try? FileManager.default.contentsOfDirectory(atPath: logs.path(percentEncoded: false))) ?? []
        XCTAssertFalse(kept.isEmpty, "No run log in \(logs.path(percentEncoded: false))")
        session.selectTab("Overview")
        session.wait(for: "port.overview")
    }

    /// Uninstall asks first; once the Library is empty the app goes back to the Catalog.
    func uninstall() throws {
        session.click("data.uninstall")
        session.answerDialog("Cancel")
        XCTAssertTrue(session.element("sidebar.port.\(port.id)").exists, "Cancel uninstalled it")

        session.click("data.uninstall")
        session.answerDialog("Uninstall")
        session.waitUntilGone("sidebar.port.\(port.id)", timeout: 60)
        session.wait(for: "screen.catalog")
    }

    /// Delete Data asks first, then removes the container's Data, leaving only what macOS protects.
    func deleteData() throws {
        XCTAssertTrue(files.hasData, "Seeding and playing left no Data")
        session.openStorePage(port.id, searching: port.query)
        session.click("data.delete")
        session.answerDialog("Cancel")
        XCTAssertTrue(files.hasData, "Cancel deleted the Data")

        session.click("data.delete")
        session.answerDialog("Delete Data")
        session.waitUntilGone("data.delete", timeout: 60)
        XCTAssertTrue(session.waitUntil(30) { !files.hasData }, "Data is still there")
        let left = files.containerContents.filter { $0 != ".com.apple.containermanagerd.metadata.plist" }
        XCTAssertEqual(left, [], "The container still holds \(left)")
    }
}
