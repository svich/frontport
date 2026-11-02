import Foundation
import FrontportCore
import Testing
@testable import FrontportLibrary

/// An Installation's folder on a Device on its own, over a temporary folder: apps made in `staging/` as the Device
/// Packager leaves them, and an install that does what each test says.
@Suite struct DeviceFolderTests {
    @Test func theRecordFollowsTheInstall() async throws {
        let f = try Folder()
        let first = try await f.replace(nil, with: "1.0")
        #expect(f.folder.record == first && first.appName == "Tiny.app")
        #expect(try DeviceFixtures.version(of: f.paths.deviceApp(for: first)) == "1.0")

        let app = try f.staged("1.1")
        let record = f.paths.deviceInstallRecord(for: port, on: device)
        let installed = Box<[String]>([])
        let second = try await f.folder.replace(first, with: app, recording: f.record("1.1")) { app in
            // While devicectl installs, the folder still holds the current app and its record.
            let recorded = try JSON.read(DeviceInstallation.self, from: record).release.version
            let kept = try DeviceFixtures.version(of: f.paths.deviceApp(for: first))
            let installing = try DeviceFixtures.version(of: app)
            installed.update { $0.append("installing \(installing) over \(kept), recorded \(recorded)") }
        }

        #expect(installed.get == ["installing 1.1 over 1.0, recorded 1.0"])
        #expect(f.folder.record == second && second.release.version == "1.1")
        #expect(try DeviceFixtures.version(of: f.paths.deviceApp(for: second)) == "1.1")
    }

    @Test func aFailedInstallLeavesTheCurrentAppAndRecord() async throws {
        let f = try Folder()
        let current = try await f.replace(nil, with: "1.0")
        let app = try f.staged("1.1")

        await #expect(throws: FrontportError.deviceUnavailable(.away, detail: "gone")) {
            try await f.folder.replace(current, with: app, recording: f.record("1.1")) { _ in
                throw FrontportError.deviceUnavailable(.away, detail: "gone")
            }
        }

        #expect(f.folder.record == current)
        #expect(try DeviceFixtures.version(of: f.paths.deviceApp(for: current)) == "1.0")
        #expect(try DeviceFixtures.version(of: app) == "1.1", "the new app stays in staging")
    }

    /// Should the record fail after the install, the current app goes back, and is installed again so the Device runs
    /// what the record says.
    @Test func aFailedRecordPutsTheCurrentAppBackOnTheDevice() async throws {
        let f = try Folder()
        let current = try await f.replace(nil, with: "1.0")
        let app = try f.staged("1.1", named: "Renamed")
        // install.json can't be written: a folder stands in its way.
        let record = f.paths.deviceInstallRecord(for: port, on: device)
        try FileManager.default.removeItem(at: record)
        try FileManager.default.createDirectory(at: record, withIntermediateDirectories: false)
        let installed = Box<[String]>([])

        await #expect(throws: FrontportError.self) {
            try await f.folder.replace(current, with: app, recording: f.record("1.1")) { app in
                installed.update { $0.append(try! DeviceFixtures.version(of: app)) }
            }
        }

        #expect(installed.get == ["1.1", "1.0"])
        #expect(try DeviceFixtures.version(of: f.paths.deviceApp(for: current)) == "1.0")
        #expect(!FileOperations.exists(f.paths.deviceApp(for: port, on: device, named: "Renamed.app")))
        #expect(try DeviceFixtures.version(of: app) == "1.1")
    }

    @Test func anAppWithAnotherNameReplacesTheCurrentOne() async throws {
        let f = try Folder()
        let current = try await f.replace(nil, with: "1.0")
        let renamed = try await f.folder.replace(
            current, with: try f.staged("1.1", named: "Renamed"), recording: f.record("1.1")) { _ in }

        #expect(renamed.appName == "Renamed.app" && f.folder.record == renamed)
        #expect(try DeviceFixtures.version(of: f.paths.deviceApp(for: renamed)) == "1.1")
        #expect(!FileOperations.exists(f.paths.deviceApp(for: current)))
    }

    @Test func leftoversAreStagingAndSeedsOrTheWholeUnrecordedFolder() async throws {
        let f = try Folder()
        #expect(f.folder.leftovers == [f.paths.deviceInstallation(for: port, on: device)])
        _ = try await f.replace(nil, with: "1.0")
        #expect(f.folder.leftovers == [f.paths.deviceStaging(for: port, on: device), f.paths.deviceSeeds(for: port, on: device)])
    }
}

private let port: PortID = "tiny"
private let device: DeviceID = "00008110-0000000000000000"
private let entry = CatalogEntry(
    id: port, name: "Tiny", kind: .decomp, game: "tiny-game", developer: "Tests", summary: "", description: "",
    source: URL(string: "https://github.com/tests/tiny")!, bundleId: "dev.frontport.port.tiny",
    releases: .githubRelease(GitHubReleaseSource(repo: "tests/tiny", asset: "Tiny-*-mac.zip")),
    ios: IOSSpec(releases: .githubRelease(GitHubReleaseSource(repo: "tests/tiny", asset: "Tiny-*.ipa"))))

private struct Folder {
    let tmp: TemporaryDirectory
    let paths: AppPaths
    let folder: DeviceFolder

    init() throws {
        tmp = try TemporaryDirectory()
        paths = AppPaths(root: tmp.url.appending(path: "root"), containers: tmp.url.appending(path: "Containers"))
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        folder = DeviceFolder(paths: paths, port: port, device: device)
    }

    /// An app at `version` in a fresh `staging/`, as the Device Packager leaves it.
    func staged(_ version: String, named name: String = "Tiny") throws -> URL {
        try DeviceFixtures.app(named: name, version: version, in: try folder.freshStaging())
    }

    func record(_ version: String) -> DeviceInstallation {
        DeviceInstallation(
            port: port, device: device, release: Release(port: port, version: version), channel: .stable,
            installedAt: Date(timeIntervalSince1970: 1_800_000_000), appName: "Tiny.app",
            bundleId: port.deviceBundleID(team: testTeam), team: testTeam, certificate: testCertificate.sha1,
            certificateExpires: testCertificate.expires,
            profile: DeviceInstallation.Profile(uuid: "uuid", name: "profile", expires: FakeProvisioning.expires), entry: entry)
    }

    /// Replaces the current Installation with one at `version`, installing it on a Device that takes it.
    func replace(_ current: DeviceInstallation?, with version: String) async throws -> DeviceInstallation {
        try await folder.replace(current, with: try staged(version), recording: record(version)) { _ in }
    }
}
