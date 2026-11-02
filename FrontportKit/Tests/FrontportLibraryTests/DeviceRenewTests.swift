import Foundation
import FrontportCore
import FrontportPackager
import FrontportROMs
import Testing
@testable import FrontportLibrary

private let noProgress: ProgressHandler = { _ in }

/// Renewing an Installation on a Device: the app kept for it signed again with a Provisioning Profile that lasts
/// longer, installed over the one there, then swapped in and recorded, or nothing changed at all.
@Suite struct DeviceRenewTests {
    @Test func signsTheKeptAppAgainAndRecordsTheNewExpiry() async throws {
        let f = try ChangeFixture()
        var installed = try await f.install()
        // What was Seeded there stays, since installing over it keeps its Data.
        installed.seeded = ["Tiny ROM": ["aaa"]]
        try JSON.write(installed, to: f.paths.deviceInstallRecord(for: renewable.id, on: iPhone.id))
        let later = Date(timeIntervalSince1970: 1_870_000_000)
        f.provisioning.profileExpires.set(later)
        f.provisioning.profileUUID.set("99999999-2222-3333-4444-555555555555")
        try DeviceFixtures.write(Data("longer profile".utf8), to: f.provisioning.profile)
        let phases = Box<[ProgressUpdate.Phase]>([])

        let renewed = try await f.library.renew(
            renewable.id, on: ready(iPhone), team: testTeam, progress: { update in phases.update { $0.append(update.phase) } })

        #expect(renewed.profile == DeviceInstallation.Profile(
            uuid: "99999999-2222-3333-4444-555555555555", name: "iOS Team Provisioning Profile: *", expires: later))
        #expect(renewed.certificate == testCertificate.sha1 && renewed.certificateExpires == testCertificate.expires)
        var expected = installed
        expected.profile = renewed.profile
        #expect(renewed == expected, "only the signature changes: Release, Seeded, entry and when it was installed stay")
        #expect(try JSON.read(DeviceInstallation.self, from: f.paths.deviceInstallRecord(for: renewable.id, on: iPhone.id)) == renewed)
        #expect(f.provisioning.outlasting.get.last == installed.expires, "it must outlast the signature the app has")
        #expect(f.provisioning.requests.get.last?.bundleId == installed.bundleId)

        // devicectl installed the app signed again over the one there, with its bundle ID, and it's kept as installed.
        #expect(f.control.installs.get.map(\.bundleId) == [installed.bundleId, installed.bundleId])
        #expect(f.control.installs.get.last?.signed == true && f.control.installs.get.last?.version == "1.0")
        let kept = f.paths.deviceApp(for: renewed)
        #expect(try f.read(kept.appending(path: "embedded.mobileprovision")) == "longer profile")
        #expect(DeviceFixtures.bundleId(of: kept) == installed.bundleId)
        #expect(!f.exists(f.paths.deviceStaging(for: renewable.id, on: iPhone.id)))
        #expect(phases.get == [.provisioning, .packaging, .transferring])
        #expect(f.fetcher.fetched.get.count == 1, "nothing fetched")
    }

    /// A failed install leaves the app kept and the record as they were, and so does finding nothing that lasts longer.
    @Test func whateverFailsLeavesTheAppAndItsRecord() async throws {
        let f = try ChangeFixture()
        let installed = try await f.install()
        let kept = f.paths.deviceApp(for: installed)
        let before = try f.read(kept.appending(path: "embedded.mobileprovision"))

        await #expect(throws: FrontportError.provisioningFailed("Xcode has none for \(installed.bundleId) that lasts long enough.")) {
            try await f.library.renew(renewable.id, on: ready(iPhone), team: testTeam, progress: noProgress)
        }
        f.provisioning.profileExpires.set(Date(timeIntervalSince1970: 1_870_000_000))
        try DeviceFixtures.write(Data("longer profile".utf8), to: f.provisioning.profile)
        f.control.installFailure.set(.deviceUnavailable(.away, detail: "gone"))
        await #expect(throws: FrontportError.deviceUnavailable(.away, detail: "gone")) {
            try await f.library.renew(renewable.id, on: ready(iPhone), team: testTeam, progress: noProgress)
        }

        #expect(await f.library.installation(for: renewable.id, on: iPhone.id) == installed)
        #expect(try f.read(kept.appending(path: "embedded.mobileprovision")) == before)
        #expect(f.control.installs.get.count == 1)
        #expect(!f.exists(f.paths.deviceStaging(for: renewable.id, on: iPhone.id)))

        f.control.installFailure.set(nil)
        let renewed = try await f.library.renew(renewable.id, on: ready(iPhone), team: testTeam, progress: noProgress)
        #expect(renewed.profile.expires == Date(timeIntervalSince1970: 1_870_000_000))
    }

    /// Another Apple Team's bundle ID is an app of its own: that's an install, not a Renew.
    @Test func refusesAnotherAppleTeam() async throws {
        let f = try ChangeFixture()
        _ = try await f.install()
        let other = AppleTeamID("ZZZZZ99999")!
        await #expect(throws: FrontportError.otherAppleTeam(testTeam)) {
            try await f.library.renew(renewable.id, on: ready(iPhone), team: other, progress: noProgress)
        }
        #expect(f.provisioning.requests.get.count == 1 && f.control.installs.get.count == 1)
    }

    /// A Device away, locked or with Developer Mode off is refused before anything is asked of Xcode.
    @Test func refusesADeviceItCantReachNow() async throws {
        let f = try ChangeFixture()
        _ = try await f.install()
        for reading in [
            DeviceReading(device: iPhone, connection: .away),
            DeviceReading(device: iPhone, connection: .wired, isLocked: true, developerMode: true),
            DeviceReading(device: iPhone, connection: .wired, isLocked: false, developerMode: false),
        ] {
            await #expect(throws: FrontportError.self) {
                try await f.library.renew(renewable.id, on: reading, team: testTeam, progress: noProgress)
            }
        }
        #expect(f.provisioning.requests.get.count == 1)
        await #expect(throws: FrontportError.notInstalled(renewable.id)) {
            try await f.library.renew(renewable.id, on: ready(iPad), team: testTeam, progress: noProgress)
        }
    }

    /// An app the user deleted on the Device is never put back, and one running there is never stopped: both are
    /// refused before anything is asked of Xcode, and the record stays.
    @Test func neverPutsBackADeletedAppNorStopsARunningOne() async throws {
        let f = try ChangeFixture()
        let installed = try await f.install()
        f.provisioning.profileExpires.set(Date(timeIntervalSince1970: 1_870_000_000))

        f.control.processes.set([iPhone.id: [
            4242: URL(string: "file:///private/var/containers/Bundle/Application/5EDD/\(installed.appName)/Tiny")!,
        ]])
        await #expect(throws: FrontportError.running(renewable.id)) {
            try await f.library.renew(renewable.id, on: ready(iPhone), team: testTeam, progress: noProgress)
        }
        f.control.processes.set([:])
        f.control.apps.update { $0[iPhone.id]?[installed.bundleId] = nil }
        await #expect {
            try await f.library.renew(renewable.id, on: ready(iPhone), team: testTeam, progress: noProgress)
        } throws: { error in
            guard case FrontportError.deviceUnavailable(.notInstalled, _) = error else { return false }
            return true
        }

        #expect(f.provisioning.requests.get.count == 1 && f.control.installs.get.count == 1)
        #expect(await f.library.installation(for: renewable.id, on: iPhone.id) == installed)
    }

    /// The record is enough: a Device Library that never saw the entry, as after the Catalog dropped the Port, Renews it.
    @Test func needsOnlyTheRecord() async throws {
        let f = try ChangeFixture()
        let installed = try await f.install()
        f.provisioning.profileExpires.set(Date(timeIntervalSince1970: 1_870_000_000))
        f.releases.set([:])

        let renewed = try await f.newLibrary().renew(renewable.id, on: ready(iPhone), team: testTeam, progress: noProgress)
        #expect(renewed.entry == installed.entry && renewed.release == installed.release)
        #expect(renewed.profile.expires == Date(timeIntervalSince1970: 1_870_000_000))
    }
}

/// Updating an Installation on a Device: the newest iOS Release on its Channel installed over it, forward only, keeping
/// its Data and what was Seeded there.
@Suite struct DeviceUpdateTests {
    @Test func installsTheNewerReleaseOverItKeepingWhatWasSeeded() async throws {
        let f = try ChangeFixture()
        var installed = try await f.install()
        installed.seeded = ["Tiny ROM": ["aaa"]]
        try JSON.write(installed, to: f.paths.deviceInstallRecord(for: renewable.id, on: iPhone.id))
        f.releases.set([.stable: ChangeFixture.release("2.0", day: 2)])

        let updated = try await f.library.update(IOSVersion(of: renewable), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress)

        #expect(updated.release == ChangeFixture.release("2.0", day: 2) && updated.channel == .stable)
        #expect(updated.seeded == ["Tiny ROM": ["aaa"]], "its Data stays on the Device")
        #expect(updated.bundleId == installed.bundleId && updated.appName == installed.appName)
        #expect(try JSON.read(DeviceInstallation.self, from: f.paths.deviceInstallRecord(for: renewable.id, on: iPhone.id)) == updated)
        #expect(f.control.apps.get[iPhone.id] == [installed.bundleId: "2.0"])
        #expect(f.control.installs.get.map(\.signed) == [true, true])
        #expect(try DeviceFixtures.version(of: f.paths.deviceApp(for: updated)) == "2.0")
        #expect(await f.library.prepared(renewable.id)?.release == updated.release, "prepared for the next Device")
    }

    /// One already prepared for that Release is taken as it is.
    @Test func takesWhatsPreparedForTheRelease() async throws {
        let f = try ChangeFixture()
        _ = try await f.install()
        f.releases.set([.stable: ChangeFixture.release("2.0", day: 2)])
        _ = try await f.library.prepare(IOSVersion(of: renewable), channel: .stable, progress: noProgress)

        _ = try await f.library.update(IOSVersion(of: renewable), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress)
        #expect(f.fetcher.fetched.get.map(\.version) == ["1.0", "2.0"])
    }

    /// The Release it has changes nothing, and an older one is refused: a Device keeps no previous Release.
    @Test func movesForwardOnly() async throws {
        let f = try ChangeFixture()
        f.releases.set([.stable: ChangeFixture.release("2.0", day: 2)])
        let installed = try await f.install()

        #expect(try await f.library.update(IOSVersion(of: renewable), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress)
            == installed)
        f.releases.set([.stable: ChangeFixture.release("1.0", day: 1)])
        await #expect(throws: FrontportError.cantInstallOnDevice("1.0 is older than 2.0, which Test iPhone has.")) {
            try await f.library.update(IOSVersion(of: renewable), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress)
        }
        #expect(f.control.installs.get.count == 1)
        #expect(await f.library.installation(for: renewable.id, on: iPhone.id) == installed)
    }

    @Test func refusesABlockedReleaseAnotherAppleTeamAndNoInstallation() async throws {
        let f = try ChangeFixture()
        _ = try await f.install()
        f.releases.set([.stable: ChangeFixture.release("2.0", day: 2)])
        var blocked = renewable
        blocked.ios?.blocked = [Block(release: "2.0", severity: .warn, reason: "Crashes on load.")]

        await #expect(throws: FrontportError.blocked(renewable.id, release: "2.0", reason: "Crashes on load.")) {
            try await f.library.update(IOSVersion(of: blocked), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress)
        }
        await #expect(throws: FrontportError.otherAppleTeam(testTeam)) {
            try await f.library.update(
                IOSVersion(of: renewable), on: ready(iPhone), team: AppleTeamID("ZZZZZ99999")!, channel: .stable, progress: noProgress)
        }
        await #expect(throws: FrontportError.notInstalled(renewable.id)) {
            try await f.library.update(IOSVersion(of: renewable), on: ready(iPad), team: testTeam, channel: .stable, progress: noProgress)
        }
        #expect(f.control.installs.get.count == 1)
    }

    /// A failed install leaves the Installation as it was.
    @Test func aFailedInstallLeavesTheInstallation() async throws {
        let f = try ChangeFixture()
        let installed = try await f.install()
        f.releases.set([.stable: ChangeFixture.release("2.0", day: 2)])
        f.control.installFailure.set(.deviceUnavailable(.away, detail: "gone"))

        await #expect(throws: FrontportError.deviceUnavailable(.away, detail: "gone")) {
            try await f.library.update(IOSVersion(of: renewable), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress)
        }
        #expect(await f.library.installation(for: renewable.id, on: iPhone.id) == installed)
        #expect(try DeviceFixtures.version(of: f.paths.deviceApp(for: installed)) == "1.0")
    }
}

// MARK: Fixtures

private let renewable = CatalogEntry(
    id: "tiny", name: "Tiny", kind: .decomp, game: "tiny-game", developer: "Tests", summary: "", description: "",
    source: URL(string: "https://github.com/tests/tiny")!, bundleId: "dev.frontport.port.tiny",
    releases: .githubRelease(GitHubReleaseSource(repo: "tests/tiny", asset: "Tiny-*-mac.zip")),
    requirements: [Requirement(label: "Tiny ROM", stage: .runtime, oneOf: ["aaa"], seedPath: "roms/")],
    ios: IOSSpec(releases: .githubRelease(GitHubReleaseSource(repo: "tests/tiny", asset: "Tiny-*.ipa")), seedPaths: ["Documents/"]))

private struct ChangeFixture {
    let tmp: TemporaryDirectory
    let paths: AppPaths
    let releases = Box<[Channel: Release]>([:])
    let fetcher: FakeDeviceFetcher
    let signer = RecordingDeviceSigner()
    let control = FakeDeviceControl()
    let provisioning: FakeProvisioning
    let library: DeviceLibrary

    init() throws {
        tmp = try TemporaryDirectory()
        paths = AppPaths(root: tmp.url.appending(path: "root"), containers: tmp.url.appending(path: "Containers"))
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        fetcher = FakeDeviceFetcher(paths: paths)
        provisioning = try FakeProvisioning(profile: tmp.url.appending(path: "Profiles/wildcard.mobileprovision"))
        releases.set([.stable: Self.release("1.0", day: 1)])
        library = DeviceLibrary(
            paths: paths, catalog: FakeCatalog(recipe: tmp.url), releases: FakeReleases(latest: releases), fetcher: fetcher,
            builder: FakeBuilder(paths: paths, appName: "Tiny"), packager: DevicePackager(signer: signer), control: control,
            provisioning: provisioning, roms: ROMStore(paths: paths))
    }

    func newLibrary() -> DeviceLibrary {
        DeviceLibrary(
            paths: paths, catalog: FakeCatalog(recipe: tmp.url), releases: FakeReleases(latest: releases), fetcher: fetcher,
            builder: FakeBuilder(paths: paths, appName: "Tiny"), packager: DevicePackager(signer: signer), control: control,
            provisioning: provisioning, roms: ROMStore(paths: paths))
    }

    /// Tiny installed on the iPhone from the newest Release.
    func install() async throws -> DeviceInstallation {
        try await library.prepareAndInstall(IOSVersion(of: renewable), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress)
    }

    /// A Release published on its day, so a later day's is newer.
    static func release(_ version: String, day: Int) -> Release {
        Release(
            port: renewable.id, version: version, tag: "v\(version)",
            published: Date(timeIntervalSince1970: 1_800_000_000 + Double(day) * 86_400),
            asset: ReleaseAsset(
                name: "Tiny-\(version).ipa", url: URL(string: "https://example.com/Tiny-\(version).ipa")!, size: 3, sha256: "0\(version)"))
    }

    func read(_ url: URL) throws -> String {
        try String(decoding: Data(contentsOf: url), as: UTF8.self)
    }

    func exists(_ url: URL) -> Bool { FileOperations.exists(url) }
}
