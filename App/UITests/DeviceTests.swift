import FrontportCore
import XCTest

/// Testport installed on an iPhone through Install on iPhone…, its ROM Seeded there once it's added, and uninstalled
/// from it, offline and without a real Device: `FRONTPORT_FAKE_DEVICE` has the app give Testport an iOS version from its
/// own Releases, Seeding into `Documents/`, and stand in for `devicectl`, the keychain and the Device Packager, with one
/// iPhone (App/Sources/Views/Debug/FakeDevices.swift). The Device Library, the Fetcher, ROMs and the records are the
/// app's own. Nothing is installed on this Mac, so Testport's container isn't touched.
@MainActor
final class DeviceTests: XCTestCase {
    static let udid = "00008110-0000000000000000"
    static let team = "A1B2C3D4E5"

    func testInstallOnAndUninstallFromADevice() async throws {
        continueAfterFailure = false
        let world = try await TestportWorld()
        let romFile = Session.base.appending(path: "\(UUID().uuidString) Synthetic.z64")
        try FileManager.default.createDirectory(at: Session.base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: romFile) }
        let session = try Session.launch(self, arguments: ["-FrontportImportROMs", romFile.path(percentEncoded: false)], world: world)
        // Session.launch sets no environment of its own before it launches, so the stand-ins take over at a relaunch.
        // The Apple Team is named, so one the user chose for real Devices doesn't stand in the way.
        session.app.launchEnvironment["FRONTPORT_FAKE_DEVICE"] = TestportWorld.port
        session.app.launchArguments += ["-appleTeam", Self.team]
        session.relaunch()
        let port = TestportWorld.port
        let folder = session.root.appending(path: "Devices/\(Self.udid)/\(port)", directoryHint: .isDirectory)
        let record = folder.appending(path: "install.json")

        // The store page lists iPhone and iPad, and offers to install there beside the Mac's Install.
        session.waitForCatalog()
        session.openStorePage(port, searching: "Testport")
        session.wait(for: "store.requirements.devices")
        let button = session.wait(for: "store.installOnDevices")
        XCTAssertEqual(session.text(of: button), "Install on iPhone…", "The one Device known is an iPhone")

        // It downloads the iOS version first, then asks which Devices: the only one that can take it is chosen.
        session.click("store.installOnDevices", timeout: 60)
        session.wait(for: "devicePicker.sheet", timeout: 120)
        let choice = session.wait(for: "devicePicker.device.\(Self.udid)")
        XCTAssertTrue(choice.isEnabled && session.isOn(choice), "The iPhone isn't chosen")
        let prepared = session.root.appending(path: "Builds/\(port).ios/prepared/prepared.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.path(percentEncoded: false)), "Nothing was prepared")
        XCTAssertTrue(
            session.text(of: session.wait(for: "devicePicker.footer")).hasPrefix("Frontport signs it"),
            "The sheet says why Install can't be taken, though it can")
        let sheetWording = Glossary.violations(in: try session.strings(in: session.element("devicePicker.sheet")))
        XCTAssertTrue(sheetWording.isEmpty, "The sheet uses words GLOSSARY.md avoids: \(sheetWording)")

        // Install on it: the Port is in the Library, though not on this Mac, so the store page opens its Port page and
        // offers the Mac's Install alone.
        session.click("devicePicker.install")
        session.waitUntilGone("devicePicker.sheet")
        session.wait(for: "store.open", timeout: 120)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path(percentEncoded: false)), "No record on the Device")
        let installed = try JSON.decode(DeviceInstallation.self, from: Data(contentsOf: record))
        XCTAssertEqual(installed.bundleId, "dev.frontport.port.\(port).\(Self.team.lowercased())")
        XCTAssertEqual(installed.release.version, "1.0")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: session.root.appending(path: "Library/\(port)").path(percentEncoded: false)),
            "It was installed on this Mac too")
        XCTAssertEqual(session.text(of: session.wait(for: "store.detail")), "On Test iPhone, not on this Mac")
        XCTAssertTrue(session.element("store.install").exists, "The Mac's Install is gone")
        XCTAssertFalse(session.element("store.installOnDevices").exists, "The store page still installs on Devices")
        XCTAssertFalse(session.element("device.uninstall.\(Self.udid)").exists, "The store page manages the iPhone")
        session.wait(for: "sidebar.device.\(Self.udid).port.\(port)")

        // Open leads to its page on the iPhone, with installing anywhere only in its More menu.
        session.click("store.open")
        let page = "screen.device.\(Self.udid).port.\(port)"
        session.wait(for: page)
        XCTAssertEqual(session.text(of: session.wait(for: "device.release.\(Self.udid)")), "1.0")
        XCTAssertFalse(session.element("action.install.\(port)").exists, "The iPhone's page offers the Mac's Install")

        // Asked again, it takes what was prepared, and the iPhone has it already.
        session.click("port.more")
        session.wait(for: "port.more.install")
        session.click("port.more.installOnDevices")
        session.wait(for: "devicePicker.sheet", timeout: 30)
        let again = session.wait(for: "devicePicker.device.\(Self.udid)")
        XCTAssertFalse(again.isEnabled, "The iPhone has it, and can be chosen")
        XCTAssertTrue(session.text(of: session.wait(for: "devicePicker.detail.\(Self.udid)")).hasPrefix("Installed"))
        XCTAssertFalse(session.element("devicePicker.install").isEnabled, "Install with nothing chosen")
        session.click("devicePicker.cancel")
        session.waitUntilGone("devicePicker.sheet")

        let wording = Glossary.violations(in: try session.strings(in: session.element(page)))
        XCTAssertTrue(wording.isEmpty, "The iPhone's page uses words GLOSSARY.md avoids: \(wording)")

        // No ROM to Seed yet: the row says so, and the ROMs screen counts the Port, though it's only on the iPhone.
        XCTAssertTrue(session.text(of: session.wait(for: "device.seeding.\(Self.udid)")).hasPrefix("Add a ROM for Synthetic 64"))
        XCTAssertFalse(session.element("device.seed.\(Self.udid)").exists, "Seed with nothing to Seed")
        session.click("sidebar.roms")
        session.wait(for: "screen.roms")
        let needed = session.wait(for: "roms.needed.\(TestportWorld.game)")
        XCTAssertTrue(try session.strings(in: needed).contains { $0.contains(TestportWorld.name) }, "Needed doesn't name the Port")

        // Adding it Seeds it on the iPhone, as an Activity of its own, and records it there.
        try world.rom.write(to: romFile)
        session.click("roms.add")
        session.wait(for: "intake.added")
        session.click("intake.done")
        session.waitUntilGone("intake.sheet")
        session.waitUntilGone("roms.needed.\(TestportWorld.game)", timeout: 60)
        session.click("sidebar.device.\(Self.udid).port.\(port)")
        session.wait(for: page)
        session.wait(for: "device.seeded.\(Self.udid)", timeout: 60)
        let seeded = try JSON.decode(DeviceInstallation.self, from: Data(contentsOf: record))
        XCTAssertEqual(seeded.seeded, ["Synthetic 64": [world.rom.sha1]])
        XCTAssertFalse(session.element("device.seed.\(Self.udid)").exists, "Seed once it's Seeded")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: folder.appending(path: "seeds").path(percentEncoded: false)),
            "What was laid out for the iPhone is still there")

        // Uninstall asks first, saying its Data there goes too; once it's gone from the Library, the page closes.
        session.click("port.more")
        session.click("device.uninstall.\(Self.udid)")
        let dialog = try XCTUnwrap(session.dialog(), "No confirmation appeared")
        XCTAssertTrue(
            try session.strings(in: dialog).contains { $0.contains("Data on Test iPhone goes too") },
            "The confirmation doesn't say its Data goes")
        session.answerDialog("Cancel")
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path(percentEncoded: false)), "Cancel uninstalled it")

        session.click("port.more")
        session.click("device.uninstall.\(Self.udid)")
        session.answerDialog("Uninstall")
        session.waitUntilGone("sidebar.device.\(Self.udid).port.\(port)", timeout: 60)
        session.wait(for: "screen.catalog")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)), "Its folder is still there")
        for folder in ["Downloads/\(port).ios", "Builds/\(port).ios"] {
            let url = session.root.appending(path: folder)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)), "\(folder) is still there")
        }
    }

    /// Testport installed on the iPhone with a Provisioning Profile that has a day and a half left: the row says how
    /// long, the sidebar marks the Port, and Renew installs it there again with one that lasts as long as the
    /// certificate, the same Release and bundle ID, so its Data stays. Renewing on its own is off, so the test Renews it.
    func testRenewOnADevice() async throws {
        continueAfterFailure = false
        let world = try await TestportWorld()
        let session = try Session.launch(self, world: world)
        session.app.launchEnvironment["FRONTPORT_FAKE_DEVICE"] = TestportWorld.port
        session.app.launchEnvironment["FRONTPORT_FAKE_DEVICE_RENEW"] = "1"
        session.app.launchArguments += ["-appleTeam", Self.team, "-renewOnItsOwn", "NO"]
        session.relaunch()
        let port = TestportWorld.port
        let record = session.root.appending(path: "Devices/\(Self.udid)/\(port)/install.json")

        session.waitForCatalog()
        session.openStorePage(port, searching: "Testport")
        session.click("store.installOnDevices", timeout: 60)
        session.wait(for: "devicePicker.sheet", timeout: 120)
        session.click("devicePicker.install")
        session.waitUntilGone("devicePicker.sheet")

        // Due at once: its page says how long it has, and leads with Renew.
        session.click("sidebar.device.\(Self.udid).port.\(port)", timeout: 120)
        let page = "screen.device.\(Self.udid).port.\(port)"
        session.wait(for: page)
        session.wait(for: "device.renew.\(Self.udid)", timeout: 120)
        let installed = try JSON.decode(DeviceInstallation.self, from: Data(contentsOf: record))
        XCTAssertLessThan(installed.expires, Date().addingTimeInterval(2 * 86_400), "Renew isn't due")
        XCTAssertEqual(session.text(of: session.wait(for: "device.renewal.\(Self.udid)")), "1 day left to Renew")
        XCTAssertEqual(session.wait(for: "status.\(Self.udid).\(port)").label, "Renew due", "The sidebar doesn't mark it")
        let wording = Glossary.violations(in: try session.strings(in: session.element(page)))
        XCTAssertTrue(wording.isEmpty, "The iPhone's page uses words GLOSSARY.md avoids: \(wording)")

        // Renew: nothing is asked, and once it's done, nothing's due.
        session.click("device.renew.\(Self.udid)")
        session.waitUntilGone("device.renew.\(Self.udid)", timeout: 60)
        XCTAssertFalse(session.element("device.renewal.\(Self.udid)").exists, "Still due once Renewed")
        let renewed = try JSON.decode(DeviceInstallation.self, from: Data(contentsOf: record))
        XCTAssertGreaterThan(renewed.expires, Date().addingTimeInterval(300 * 86_400), "Renewed for no longer")
        XCTAssertEqual(renewed.release, installed.release)
        XCTAssertEqual(renewed.bundleId, installed.bundleId)
        XCTAssertEqual(renewed.installedAt, installed.installedAt)
        session.wait(for: "device.signed.\(Self.udid)")
        let mark = session.element("status.\(Self.udid).\(port)")
        XCTAssertFalse(mark.exists && mark.label == "Renew due", "The sidebar still marks it")

        session.click("port.more")
        session.click("device.uninstall.\(Self.udid)")
        session.answerDialog("Uninstall")
        session.waitUntilGone("sidebar.device.\(Self.udid).port.\(port)", timeout: 60)
    }
}
