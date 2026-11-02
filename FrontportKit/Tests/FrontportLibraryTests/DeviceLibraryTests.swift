import Foundation
import FrontportCore
import FrontportPackager
import FrontportROMs
import Testing
@testable import FrontportLibrary

private let noProgress: ProgressHandler = { _ in }

@Suite struct DeviceInstallTests {
    @Test func installsAndRecordsOnceDevicectlHasInstalled() async throws {
        let f = try DeviceFixture()
        let record = f.paths.deviceInstallRecord(for: tiny.id, on: iPhone.id)
        let staging = f.paths.deviceStaging(for: tiny.id, on: iPhone.id)
        f.control.onInstall.set { app in
            // devicectl gets the signed app from staging, before anything is recorded.
            guard !FileManager.default.fileExists(atPath: record.path(percentEncoded: false)),
                app.path(percentEncoded: false).hasPrefix(staging.path(percentEncoded: false))
            else { throw FrontportError.fileOperation("recorded before the install") }
        }
        let phases = Box<[ProgressUpdate.Phase]>([])

        let installation = try await f.library.prepareAndInstall(
            IOSVersion(of: tiny), on: ready(iPhone), team: testTeam, channel: .stable, progress: { update in phases.update { $0.append(update.phase) } })

        let bundleId = "dev.frontport.port.tiny.a1b2c3d4e5"
        #expect(installation.port == tiny.id && installation.device == iPhone.id)
        #expect(installation.release == f.release("1.0") && installation.channel == .stable)
        #expect(installation.appName == "Tiny.app" && installation.bundleId == bundleId && installation.team == testTeam)
        #expect(installation.certificate == testCertificate.sha1 && installation.certificateExpires == testCertificate.expires)
        #expect(installation.profile == DeviceInstallation.Profile(
            uuid: "11111111-2222-3333-4444-555555555555", name: "iOS Team Provisioning Profile: *",
            expires: FakeProvisioning.expires))
        #expect(installation.expires == FakeProvisioning.expires, "the profile expires before the certificate")
        #expect(installation.entry == tiny, "the full entry, not its iOS view")
        #expect(installation.seeded.isEmpty && installation.buildAssets == nil)
        #expect(try JSON.read(DeviceInstallation.self, from: record) == installation)

        #expect(f.control.installs.get.map(\.bundleId) == [bundleId])
        #expect(f.control.installs.get.map(\.signed) == [true])
        #expect(f.control.apps.get[iPhone.id] == [bundleId: "1.0"])
        #expect(f.provisioning.requests.get.map(\.bundleId) == [bundleId])
        #expect(f.provisioning.requests.get.map(\.device) == [iPhone.id])

        // The app is kept as it was signed and installed, for Renew.
        let app = f.paths.deviceApp(for: installation)
        #expect(DeviceFixtures.bundleId(of: app) == bundleId)
        #expect(try f.read(app.appending(path: "embedded.mobileprovision")) == "wildcard profile")
        let signedApp = try #require(f.signer.signed.get.last)
        #expect(signedApp.item.lastPathComponent == "Tiny.app" && signedApp.certificate == testCertificate.sha1)
        #expect(signedApp.entitlements?["application-identifier"] == .string("A1B2C3D4E5.\(bundleId)"))
        #expect(f.signer.signed.get.map(\.item.lastPathComponent) == ["libkit.dylib", "Tiny.app"])

        // Downloaded into the Port's iOS folder, which goes once the Release is prepared; the prepared app stays as it
        // was unpacked, for the next Device.
        #expect(f.fetcher.fetched.get.map(\.downloads) == ["tiny.ios"])
        #expect(!f.exists(f.paths.downloads(for: "tiny.ios")))
        #expect(!f.exists(staging))
        let prepared = try #require(await f.library.prepared(tiny.id))
        #expect(prepared.release == installation.release && prepared.appName == "Tiny.app")
        #expect(f.isUnsigned(f.paths.devicePreparedApp(prepared)))
        #expect(try JSON.read(Device.self, from: f.paths.deviceRecord(iPhone.id)) == iPhone)

        #expect(await f.library.installations() == [installation])
        #expect(await f.library.installation(for: tiny.id, on: iPhone.id) == installation)
        #expect(await f.library.installation(for: tiny.id, on: iPad.id) == nil)
        #expect(phases.get.filter { $0 != .downloading } == [.resolving, .provisioning, .packaging, .transferring])
    }

    @Test func aFailedInstallRecordsNothing() async throws {
        let f = try DeviceFixture()
        f.control.installFailure.set(.deviceUnavailable(.failed, detail: "The app couldn’t be installed."))

        await #expect(throws: FrontportError.deviceUnavailable(.failed, detail: "The app couldn’t be installed.")) {
            try await f.library.prepareAndInstall(IOSVersion(of: tiny), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress)
        }

        #expect(await f.library.installations().isEmpty)
        #expect(!f.exists(f.paths.deviceInstallation(for: tiny.id, on: iPhone.id)), "a first install leaves no folder")
        #expect(f.control.apps.get.isEmpty)
        #expect(await f.library.prepared(tiny.id) != nil, "the prepared app stays for another try")

        f.control.installFailure.set(nil)
        let installed = try await f.library.prepareAndInstall(IOSVersion(of: tiny), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress)
        #expect(await f.library.installations() == [installed])
        #expect(f.fetcher.fetched.get.count == 1, "the other try took the prepared app")
    }

    /// The Provisioning Profile names the Device, so it's taken once the app is prepared, for the Device it goes on;
    /// without one, nothing is installed, and the prepared app stays for when there is one.
    @Test(arguments: [
        FrontportError.provisioningFailed("Xcode has none."), .noAppleTeam,
    ])
    func noProvisioningProfileMeansNoInstall(_ failure: FrontportError) async throws {
        let f = try DeviceFixture()
        f.provisioning.failure.set(failure)

        await #expect(throws: failure) {
            try await f.library.prepareAndInstall(IOSVersion(of: tiny), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress)
        }

        #expect(f.control.installs.get.isEmpty && f.signer.signed.get.isEmpty)
        #expect(!f.exists(f.paths.deviceInstallation(for: tiny.id, on: iPhone.id)))
        #expect(await f.library.prepared(tiny.id) != nil)
    }

    /// The iOS version's own Blocks apply, by its own version; the Mac's don't.
    @Test func refusesABlockedRelease() async throws {
        let f = try DeviceFixture()
        var macBlocked = tiny
        macBlocked.blocked = [Block(release: "1.0", severity: .stop, reason: "The Mac build crashes.")]
        var iosBlocked = tiny
        iosBlocked.ios?.blocked = [Block(release: "1.0", severity: .warn, reason: "Crashes on load.")]

        await #expect(throws: FrontportError.blocked(tiny.id, release: "1.0", reason: "Crashes on load.")) {
            try await f.library.prepareAndInstall(IOSVersion(of: iosBlocked), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress)
        }
        #expect(f.provisioning.requests.get.isEmpty && f.fetcher.fetched.get.isEmpty)

        let installed = try await f.library.prepareAndInstall(
            IOSVersion(of: macBlocked), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress)
        #expect(installed.release.version == "1.0")
    }

    @Test func refusesAnAppNeedingANewerIOS() async throws {
        let f = try DeviceFixture()
        f.fetcher.minimumOS.set(DeviceFixtures.version(28, 0))

        await #expect(throws: FrontportError.cantInstallOnDevice("Tiny needs iOS 28.0 or later, and Test iPhone has iOS 27.0.1.")) {
            try await f.library.prepareAndInstall(IOSVersion(of: tiny), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress)
        }

        #expect(f.control.installs.get.isEmpty)
        #expect(await f.library.installations().isEmpty)
        #expect(!f.exists(f.paths.deviceInstallation(for: tiny.id, on: iPhone.id)))
    }

    /// An iPad-only app can't go on an iPhone; an iPad also runs iPhone apps.
    @Test func refusesAnAppMadeForTheOtherKindOfDevice() async throws {
        let f = try DeviceFixture()
        f.fetcher.families.set([2])

        await #expect(throws: FrontportError.cantInstallOnDevice("Tiny is made for iPad only, and Test iPhone is iPhone 13.")) {
            try await f.library.prepareAndInstall(IOSVersion(of: tiny), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress)
        }
        #expect(f.control.installs.get.isEmpty)

        _ = try await f.library.prepareAndInstall(IOSVersion(of: tiny), on: ready(iPad), team: testTeam, channel: .stable, progress: noProgress)
        f.fetcher.families.set([1])
        try await f.library.uninstall(tiny.id, from: iPad.id)
        _ = try await f.library.prepareAndInstall(IOSVersion(of: tiny), on: ready(iPad), team: testTeam, channel: .stable, progress: noProgress)
        #expect(f.control.installs.get.map(\.device) == [iPad.id, iPad.id])
    }

    /// A Simulator or Mac build is refused by the Packager before anything reaches the Device.
    @Test func refusesAnAppThatIsntForADevice() async throws {
        let f = try DeviceFixture()
        f.fetcher.platform.set(7)

        await #expect(throws: FrontportError.notForDevice("Tiny.app is built for the iOS Simulator.")) {
            try await f.library.prepareAndInstall(IOSVersion(of: tiny), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress)
        }
        #expect(f.control.installs.get.isEmpty && f.signer.signed.get.isEmpty)
    }

    @Test func refusesAnIOSVersionItCantMake() async throws {
        let f = try DeviceFixture()

        await #expect(throws: FrontportError.cantInstallOnDevice(
            "Tiny’s iOS version makes Build Assets from a ROM, which this version of Frontport can’t do for Devices.")) {
            try await f.library.prepareAndInstall(IOSVersion(of: makesAssets), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress)
        }
        #expect(f.provisioning.requests.get.isEmpty && f.fetcher.fetched.get.isEmpty)
        #expect(!f.exists(f.paths.devices))
    }

    @Test func refusesADeviceThatCantTakeAnInstallBeforeAnything() async throws {
        let f = try DeviceFixture()
        let away = DeviceReading(device: iPhone, connection: .away)
        let developerModeOff = DeviceReading(device: iPhone, connection: .wired, isLocked: false, developerMode: false)

        // With nothing prepared, installing would prepare first, but it's refused before then.
        await #expect(throws: FrontportError.deviceUnavailable(.away, detail: "Test iPhone isn’t connected to this Mac or its Wi-Fi network.")) {
            try await f.library.installPrepared(IOSVersion(of: tiny), on: away, team: testTeam, progress: noProgress)
        }
        // The same refusal as Seeding's, which waits for it.
        let off = FrontportError.deviceUnavailable(
            .developerModeOff,
            detail: "Developer Mode is off on Test iPhone. Turn it on in its Settings › Privacy & Security, then try again.")
        await #expect(throws: off) {
            try await f.library.installPrepared(IOSVersion(of: tiny), on: developerModeOff, team: testTeam, progress: noProgress)
        }
        #expect(off.localizedDescription.hasPrefix("Developer Mode is off on Test iPhone."))
        #expect(!f.exists(f.paths.devices))
        #expect(f.provisioning.requests.get.isEmpty && f.fetcher.fetched.get.isEmpty)
        #expect(await f.library.installations().isEmpty)

        // Locked doesn't stop an install.
        let locked = DeviceReading(device: iPhone, connection: .wired, isLocked: true, developerMode: true)
        _ = try await f.library.prepareAndInstall(IOSVersion(of: tiny), on: locked, team: testTeam, channel: .stable, progress: noProgress)
    }

    @Test func refusesASecondInstallOnTheSameDevice() async throws {
        let f = try DeviceFixture()
        _ = try await f.library.prepareAndInstall(IOSVersion(of: tiny), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress)

        await #expect(throws: FrontportError.alreadyInstalled(tiny.id)) {
            try await f.library.prepareAndInstall(IOSVersion(of: tiny), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress)
        }
        _ = try await f.library.prepareAndInstall(IOSVersion(of: tiny), on: ready(iPad), team: testTeam, channel: .stable, progress: noProgress)
        #expect(await f.library.installations().map(\.device) == [iPhone.id, iPad.id])
    }

    @Test func refusesIdsThatCouldNameAnotherFolder() async throws {
        let f = try DeviceFixture()
        var escaping = iPhone
        escaping.id = "../../Library"
        var renamed = tiny
        renamed.id = "../tiny"

        await #expect(throws: FrontportError.self) {
            try await f.library.installPrepared(IOSVersion(of: tiny), on: ready(escaping), team: testTeam, progress: noProgress)
        }
        await #expect(throws: FrontportError.self) {
            try await f.library.installPrepared(IOSVersion(of: renamed), on: ready(iPhone), team: testTeam, progress: noProgress)
        }
        await #expect(throws: FrontportError.self) { try await f.library.remember(escaping) }
        await #expect(throws: FrontportError.self) { try await f.library.uninstall(tiny.id, from: escaping.id) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.paths.root.path(percentEncoded: false)).isEmpty)
    }

    @Test func runsOneOperationPerPortAtATimeOnAnyDevice() async throws {
        let f = try DeviceFixture()
        let library = f.library

        async let first = Result { try await library.prepareAndInstall(IOSVersion(of: tiny), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress) }
        async let second = Result { try await library.prepareAndInstall(IOSVersion(of: tiny), on: ready(iPad), team: testTeam, channel: .stable, progress: noProgress) }
        let results = await [first, second]

        #expect(results.allSatisfy { (try? $0.get()) != nil })
        #expect(f.fetcher.inFlight.get.most == 1, "both share Downloads/tiny.ios")
    }
}

/// Preparing fetches and unpacks the iOS version once, for no Device in particular, signing nothing; each Device then
/// gets a signed clone of it.
@Suite struct DevicePrepareTests {
    @Test func preparesWithoutADeviceOrASignature() async throws {
        let f = try DeviceFixture()
        let phases = Box<[ProgressUpdate.Phase]>([])

        let prepared = try await f.library.prepare(
            IOSVersion(of: tiny), channel: .stable, progress: { update in phases.update { $0.append(update.phase) } })

        #expect(prepared == PreparedDeviceApp(
            port: tiny.id, release: f.release("1.0"), channel: .stable, appName: "Tiny.app", minimumOS: "15.0",
            families: [1, 2]))
        #expect(try JSON.read(PreparedDeviceApp.self, from: f.paths.devicePreparedRecord(for: tiny.id)) == prepared)
        #expect(await f.library.prepared(tiny.id) == prepared)
        let app = f.paths.devicePreparedApp(prepared)
        #expect(f.isUnsigned(app) && DeviceFixtures.bundleId(of: app) == "com.upstream.tiny", "as upstream shipped it")
        #expect(try DeviceFixtures.version(of: app) == "1.0")

        #expect(f.provisioning.requests.get.isEmpty && f.signer.signed.get.isEmpty && f.control.installs.get.isEmpty)
        #expect(!f.exists(f.paths.devices), "it's for no Device yet")
        #expect(!f.exists(f.paths.downloads(for: "tiny.ios")), "unpacked, the download goes")
        #expect(!f.exists(f.paths.devicePreparing(for: tiny.id)))
        #expect(!f.exists(f.paths.library) && !f.exists(f.paths.downloads(for: tiny.id)), "nothing of the Mac's")
        #expect(phases.get.filter { $0 != .downloading } == [.resolving])
    }

    /// The prepared app is reused while it's for the newest Release on the Channel; a newer one replaces it.
    @Test func reusesThePreparedAppUntilANewerRelease() async throws {
        let f = try DeviceFixture()
        let first = try await f.library.prepare(IOSVersion(of: tiny), channel: .stable, progress: noProgress)
        #expect(try await f.library.prepare(IOSVersion(of: tiny), channel: .stable, progress: noProgress) == first)
        #expect(f.fetcher.fetched.get.map(\.version) == ["1.0"])

        f.releases.set([.stable: f.release("1.1")])
        let newer = try await f.library.prepare(IOSVersion(of: tiny), channel: .stable, progress: noProgress)

        #expect(newer.release.version == "1.1" && f.fetcher.fetched.get.map(\.version) == ["1.0", "1.1"])
        #expect(try DeviceFixtures.version(of: f.paths.devicePreparedApp(newer)) == "1.1")
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.paths.devicePrepared(for: tiny.id).path(percentEncoded: false))
            .sorted() == ["Tiny.app", "prepared.json"])
    }

    /// One fetch for every Device: each gets its own Provisioning Profile and a signed clone, and the prepared app stays
    /// unsigned for the next.
    @Test func installsOnEachDeviceFromOneFetch() async throws {
        let f = try DeviceFixture()
        let prepared = try await f.library.prepare(IOSVersion(of: tiny), channel: .stable, progress: noProgress)
        let phases = Box<[ProgressUpdate.Phase]>([])

        let onIPhone = try await f.library.installPrepared(
            IOSVersion(of: tiny), on: ready(iPhone), team: testTeam, progress: { update in phases.update { $0.append(update.phase) } })
        let onIPad = try await f.library.installPrepared(IOSVersion(of: tiny), on: ready(iPad), team: testTeam, progress: noProgress)

        #expect(f.fetcher.fetched.get.count == 1)
        #expect(f.provisioning.requests.get.map(\.device) == [iPhone.id, iPad.id])
        #expect(f.control.installs.get.map(\.device) == [iPhone.id, iPad.id])
        #expect(f.control.installs.get.allSatisfy { $0.signed && $0.bundleId == "dev.frontport.port.tiny.a1b2c3d4e5" })
        #expect([onIPhone, onIPad].allSatisfy { $0.release == prepared.release && $0.channel == .stable && $0.entry == tiny })
        #expect(await f.library.installations() == [onIPhone, onIPad])
        #expect(f.isUnsigned(f.paths.devicePreparedApp(prepared)))
        #expect(DeviceFixtures.bundleId(of: f.paths.devicePreparedApp(prepared)) == "com.upstream.tiny")
        #expect(phases.get == [.provisioning, .packaging, .transferring])
    }

    /// What the Device can't run is refused from the prepared app's record, before a Provisioning Profile is taken for
    /// it.
    @Test func checksTheDeviceBeforeTakingAProvisioningProfile() async throws {
        let f = try DeviceFixture()
        f.fetcher.families.set([2])
        _ = try await f.library.prepare(IOSVersion(of: tiny), channel: .stable, progress: noProgress)

        await #expect(throws: FrontportError.cantInstallOnDevice("Tiny is made for iPad only, and Test iPhone is iPhone 13.")) {
            try await f.library.installPrepared(IOSVersion(of: tiny), on: ready(iPhone), team: testTeam, progress: noProgress)
        }
        #expect(f.provisioning.requests.get.isEmpty)
        #expect(!f.exists(f.paths.deviceInstallation(for: tiny.id, on: iPhone.id)))
        _ = try await f.library.installPrepared(IOSVersion(of: tiny), on: ready(iPad), team: testTeam, progress: noProgress)
    }

    /// The entry as it is when installing decides, not as it was when preparing: a Release Blocked since, or a Channel
    /// no longer offered, isn't installed from the prepared app, which stays for when the entry allows it again.
    @Test func refusesAPreparedAppTheEntryNoLongerAllows() async throws {
        let f = try DeviceFixture()
        _ = try await f.library.prepare(IOSVersion(of: tiny), channel: .stable, progress: noProgress)
        var blocked = tiny
        blocked.ios?.blocked = [Block(release: "1.0", severity: .warn, reason: "Crashes on load.")]
        var nightlyOnly = tiny
        nightlyOnly.ios?.releases = .githubRelease(GitHubReleaseSource(repo: "tests/tiny", asset: "Tiny-*.ipa", channels: [.nightly]))

        await #expect(throws: FrontportError.blocked(tiny.id, release: "1.0", reason: "Crashes on load.")) {
            try await f.library.installPrepared(IOSVersion(of: blocked), on: ready(iPhone), team: testTeam, progress: noProgress)
        }
        await #expect(throws: FrontportError.noRelease(tiny.id, .stable)) {
            try await f.library.installPrepared(IOSVersion(of: nightlyOnly), on: ready(iPhone), team: testTeam, progress: noProgress)
        }

        #expect(f.provisioning.requests.get.isEmpty && f.signer.signed.get.isEmpty && f.control.installs.get.isEmpty)
        #expect(!f.exists(f.paths.deviceInstallation(for: tiny.id, on: iPhone.id)))
        #expect(await f.library.prepared(tiny.id) != nil)
        _ = try await f.library.installPrepared(IOSVersion(of: tiny), on: ready(iPhone), team: testTeam, progress: noProgress)
    }

    /// With nothing prepared any more, as when the last Device's uninstall took it while the sheet showed, installing
    /// prepares again on the default Channel rather than failing.
    @Test func installingWithNothingPreparedPreparesAgain() async throws {
        let f = try DeviceFixture()
        _ = try await f.library.prepareAndInstall(IOSVersion(of: tiny), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress)
        try await f.library.uninstall(tiny.id, from: iPhone.id)
        #expect(await f.library.prepared(tiny.id) == nil)

        let installation = try await f.library.installPrepared(IOSVersion(of: tiny), on: ready(iPad), team: testTeam, progress: noProgress)
        #expect(installation.release == f.release("1.0") && installation.device == iPad.id)
        #expect(f.fetcher.fetched.get.map(\.version) == ["1.0", "1.0"], "fetched again")
        #expect(f.control.apps.get[iPad.id] == ["dev.frontport.port.tiny.a1b2c3d4e5": "1.0"])
        #expect(await f.library.prepared(tiny.id)?.release == f.release("1.0"))
        await #expect(throws: FrontportError.alreadyInstalled(tiny.id)) {
            try await f.library.installPrepared(IOSVersion(of: tiny), on: ready(iPad), team: testTeam, progress: noProgress)
        }
    }

    /// Preparing refuses what installing would: a Blocked Release, an iOS version making Build Assets, and an app that
    /// isn't for a Device, keeping nothing of it.
    @Test func refusesWhatInstallingWould() async throws {
        let f = try DeviceFixture()
        var blocked = tiny
        blocked.ios?.blocked = [Block(release: "1.0", severity: .warn, reason: "Crashes on load.")]

        await #expect(throws: FrontportError.blocked(tiny.id, release: "1.0", reason: "Crashes on load.")) {
            try await f.library.prepare(IOSVersion(of: blocked), channel: .stable, progress: noProgress)
        }
        await #expect(throws: FrontportError.cantInstallOnDevice(
            "Tiny’s iOS version makes Build Assets from a ROM, which this version of Frontport can’t do for Devices.")) {
            try await f.library.prepare(IOSVersion(of: makesAssets), channel: .stable, progress: noProgress)
        }
        #expect(f.fetcher.fetched.get.isEmpty)

        f.fetcher.platform.set(7)
        await #expect(throws: FrontportError.notForDevice("Tiny.app is built for the iOS Simulator.")) {
            try await f.library.prepare(IOSVersion(of: tiny), channel: .stable, progress: noProgress)
        }
        #expect(await f.library.prepared(tiny.id) == nil)
        #expect(!f.exists(f.paths.devicePreparing(for: tiny.id)) && !f.exists(f.paths.devicePrepared(for: tiny.id)))
    }

    /// A record that names anything but an app in `prepared/`, or with no app beside it, isn't a prepared app.
    @Test func neverTakesARecordForAnotherApp() async throws {
        let f = try DeviceFixture()
        var prepared = try await f.library.prepare(IOSVersion(of: tiny), channel: .stable, progress: noProgress)
        prepared.appName = "../../tiny/Tiny.app"
        try JSON.write(prepared, to: f.paths.devicePreparedRecord(for: tiny.id))
        #expect(await f.library.prepared(tiny.id) == nil)

        prepared.appName = "Other.app"
        try JSON.write(prepared, to: f.paths.devicePreparedRecord(for: tiny.id))
        #expect(await f.library.prepared(tiny.id) == nil)

        prepared.appName = "Tiny.app"
        prepared.port = "other"
        try JSON.write(prepared, to: f.paths.devicePreparedRecord(for: tiny.id))
        #expect(await f.library.prepared(tiny.id) == nil)
        #expect(await f.library.prepared("../tiny") == nil)
    }

    /// The prepared app is kept while a Device has the Port, for the next one, and goes with the last.
    @Test func thePreparedAppGoesWithTheLastDevice() async throws {
        let f = try DeviceFixture()
        _ = try await f.library.prepareAndInstall(IOSVersion(of: tiny), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress)
        _ = try await f.library.installPrepared(IOSVersion(of: tiny), on: ready(iPad), team: testTeam, progress: noProgress)

        try await f.library.uninstall(tiny.id, from: iPhone.id)
        await f.library.removeLeftovers()
        #expect(await f.library.prepared(tiny.id) != nil)

        try await f.library.uninstall(tiny.id, from: iPad.id)
        #expect(await f.library.prepared(tiny.id) == nil)
        #expect(!f.exists(f.paths.builds(for: "tiny.ios")))
    }

    /// One prepared for no Device goes at the next launch's sweep, and so does one cut short.
    @Test func leftoversTakeAPreparedAppNoDeviceHas() async throws {
        let f = try DeviceFixture()
        _ = try await f.library.prepare(IOSVersion(of: tiny), channel: .stable, progress: noProgress)
        try DeviceFixtures.write(Data("x".utf8), to: f.paths.devicePreparing(for: tiny.id).appending(path: "Tiny.app/Tiny"))

        await f.library.removeLeftovers()

        #expect(await f.library.prepared(tiny.id) == nil)
        #expect(!f.exists(f.paths.builds(for: "tiny.ios")))

        // With a Device that has the Port, only the part cut short goes.
        _ = try await f.library.prepareAndInstall(IOSVersion(of: tiny), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress)
        try DeviceFixtures.write(Data("x".utf8), to: f.paths.devicePreparing(for: tiny.id).appending(path: "Tiny.app/Tiny"))
        await f.library.removeLeftovers()
        #expect(await f.library.prepared(tiny.id) != nil)
        #expect(!f.exists(f.paths.devicePreparing(for: tiny.id)))
    }

    /// Sweeping leftovers waits for preparing under way, so what it's unpacking isn't taken from under it.
    @Test func leftoversWaitForPreparingUnderWay() async throws {
        let f = try DeviceFixture()
        let library = f.library
        let preparing = Task { try await library.prepare(IOSVersion(of: tiny), channel: .stable, progress: noProgress) }
        while f.fetcher.inFlight.get.now == 0 { try await Task.sleep(for: .milliseconds(1)) }

        await library.removeLeftovers()

        let prepared = try await preparing.value
        #expect(f.exists(f.paths.devicePreparedApp(prepared)) == false, "swept once preparing was done, as no Device has it")
        #expect(f.fetcher.fetched.get.count == 1)
    }

    /// A link in place of the iOS build folder goes, never followed.
    @Test func neverFollowsALinkInPlaceOfTheIOSBuildFolder() async throws {
        let f = try DeviceFixture()
        let elsewhere = f.tmp.url.appending(path: "Elsewhere", directoryHint: .isDirectory)
        try DeviceFixtures.write(Data("x".utf8), to: elsewhere.appending(path: "prepared/keep"))
        try FileManager.default.createDirectory(at: f.paths.builds, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.paths.builds(for: "tiny.ios"), withDestinationURL: elsewhere)
        #expect(await f.library.prepared(tiny.id) == nil)

        let prepared = try await f.library.prepare(IOSVersion(of: tiny), channel: .stable, progress: noProgress)

        #expect(FileOperations.isDirectory(f.paths.builds(for: "tiny.ios")) && f.exists(f.paths.devicePreparedApp(prepared)))
        #expect(try f.read(elsewhere.appending(path: "prepared/keep")) == "x")
    }

    /// Nor is one followed by the sweep, whether or not a Device has the Port: the link goes, and what it leads to stays.
    @Test(arguments: [false, true])
    func theSweepNeverFollowsALinkInPlaceOfTheIOSBuildFolder(onADevice: Bool) async throws {
        let f = try DeviceFixture()
        if onADevice {
            _ = try await f.library.prepareAndInstall(IOSVersion(of: tiny), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress)
            try FileManager.default.removeItem(at: f.paths.builds(for: "tiny.ios"))
        }
        let elsewhere = f.tmp.url.appending(path: "Elsewhere", directoryHint: .isDirectory)
        let outside = [elsewhere.appending(path: "preparing/keep"), elsewhere.appending(path: "prepared/keep")]
        for file in outside { try DeviceFixtures.write(Data("x".utf8), to: file) }
        try FileManager.default.createDirectory(at: f.paths.builds, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.paths.builds(for: "tiny.ios"), withDestinationURL: elsewhere)

        await f.library.removeLeftovers()

        for file in outside { #expect(try f.read(file) == "x", "\(file.path(percentEncoded: false))") }
        #expect(!f.exists(f.paths.builds(for: "tiny.ios")))
        #expect(await f.library.installations().count == (onADevice ? 1 : 0))
    }
}

/// The iOS version never writes anything of the Mac's, and its view of the entry is refused wherever the Mac's would go.
@Suite struct DeviceIsolationTests {
    @Test func leavesTheMacsFoldersAlone() async throws {
        let f = try DeviceFixture()
        try await f.roms.add("aaa")
        let macDownload = f.paths.downloads(for: tiny.id).appending(path: "Tiny-1.0-mac.zip")
        try DeviceFixtures.write(Data("mac".utf8), to: macDownload)

        _ = try await f.library.prepareAndInstall(IOSVersion(of: tiny), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress)
        await f.library.removeLeftovers()

        #expect(!f.exists(f.paths.library))
        #expect(!f.exists(f.paths.containers), "no container, so nothing is Seeded on the Mac")
        #expect(try f.read(macDownload) == "mac")
        #expect(f.exists(f.paths.rom("aaa", format: "z64")))
    }

    @Test func theIOSViewNeverReachesTheMacsLibraryOrSeeding() async throws {
        let f = try DeviceFixture()
        try await f.roms.add("aaa")
        let view = try IOSVersion(of: tiny).view
        #expect(view.requirements.map(\.seedPath) == ["Documents/"])

        await #expect(throws: FrontportError.self) { try await f.roms.store.seed(view) }
        let mac = Library(
            paths: f.paths, catalog: FakeCatalog(recipe: f.tmp.url), releases: FakeReleases(latest: f.releases),
            fetcher: FakeFetcher(appName: "Tiny"), builder: FakeBuilder(paths: f.paths, appName: "Tiny"), roms: f.roms.store,
            packager: RecordingPackager(paths: f.paths, primer: nil), launcher: FakeLauncher())
        await #expect(throws: FrontportError.self) { try await mac.install(view, channel: .stable, progress: noProgress) }

        #expect(!f.exists(f.paths.containers))
        #expect(!f.exists(f.paths.library))
        #expect(!f.exists(f.paths.devices))
        #expect(f.provisioning.requests.get.isEmpty)
    }
}

@Suite struct DeviceUninstallTests {
    @Test func removesTheAppItsRecordAndItsIOSFolders() async throws {
        let f = try DeviceFixture()
        let installed = try await f.library.prepareAndInstall(IOSVersion(of: tiny), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress)
        for folder in [f.paths.builds(for: "tiny.ios"), f.paths.logs(for: "tiny.ios")] {
            try DeviceFixtures.write(Data(), to: folder.appending(path: "kept"))
        }

        try await f.library.uninstall(tiny.id, from: iPhone.id)

        #expect(f.control.uninstalls.get.map(\.bundleId) == [installed.bundleId])
        #expect(f.control.apps.get[iPhone.id]?.isEmpty == true)
        #expect(await f.library.installations().isEmpty)
        #expect(!f.exists(f.paths.deviceInstallation(for: tiny.id, on: iPhone.id)))
        #expect(!f.exists(f.paths.builds(for: "tiny.ios")) && !f.exists(f.paths.logs(for: "tiny.ios")))
        #expect(await f.library.devices() == [iPhone], "the Device is still remembered")
        await #expect(throws: FrontportError.notInstalled(tiny.id)) { try await f.library.uninstall(tiny.id, from: iPhone.id) }
    }

    @Test func keepsTheIOSFoldersWhileAnotherDeviceHasThePort() async throws {
        let f = try DeviceFixture()
        _ = try await f.library.prepareAndInstall(IOSVersion(of: tiny), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress)
        _ = try await f.library.prepareAndInstall(IOSVersion(of: tiny), on: ready(iPad), team: testTeam, channel: .stable, progress: noProgress)
        try DeviceFixtures.write(Data(), to: f.paths.logs(for: "tiny.ios").appending(path: "kept"))

        try await f.library.uninstall(tiny.id, from: iPhone.id)

        #expect(f.exists(f.paths.logs(for: "tiny.ios")))
        #expect(await f.library.installations().map(\.device) == [iPad.id])
    }

    @Test func anAppAlreadyGoneFromTheDeviceCountsAsRemoved() async throws {
        let f = try DeviceFixture()
        _ = try await f.library.prepareAndInstall(IOSVersion(of: tiny), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress)
        // Deleted there: `devicectl` counts that as removed.
        f.control.apps.update { $0[iPhone.id] = [:] }

        try await f.library.uninstall(tiny.id, from: iPhone.id)

        #expect(await f.library.installations().isEmpty)
    }

    /// `devicectl` removes the app a record names with its Data, so a record that names any app but its Port's own
    /// (another Port's, copied into this folder, or not Frontport's at all) counts as one that can't be read.
    @Test func neverUninstallsAnAppTheRecordDoesntBelongTo() async throws {
        let f = try DeviceFixture()
        let installed = try await f.library.prepareAndInstall(IOSVersion(of: tiny), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress)
        let copied = f.paths.deviceInstallRecord(for: "other", on: iPhone.id)
        try FileManager.default.createDirectory(at: copied.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: f.paths.deviceInstallRecord(for: tiny.id, on: iPhone.id), to: copied)
        var foreign = installed
        foreign.port = "foreign"
        foreign.bundleId = "com.example.mail"
        try JSON.write(foreign, to: f.paths.deviceInstallRecord(for: "foreign", on: iPhone.id).creatingFolder())
        var escaping = installed
        escaping.port = "escaping"
        escaping.bundleId = PortID("escaping").deviceBundleID(team: testTeam)
        escaping.appName = "../tiny/Tiny.app"
        try JSON.write(escaping, to: f.paths.deviceInstallRecord(for: "escaping", on: iPhone.id).creatingFolder())

        for port: PortID in ["other", "foreign", "escaping"] {
            #expect(await f.library.installation(for: port, on: iPhone.id) == nil)
            await #expect(throws: FrontportError.notInstalled(port)) { try await f.library.uninstall(port, from: iPhone.id) }
            await #expect(throws: FrontportError.alreadyInstalled(port), "still an Installation's folder") {
                var entry = tiny
                entry.id = port
                entry.bundleId = port.conventionalBundleID
                try await f.library.installPrepared(IOSVersion(of: entry), on: ready(iPhone), team: testTeam, progress: noProgress)
            }
        }

        #expect(f.control.uninstalls.get.isEmpty)
        #expect(f.control.apps.get[iPhone.id] == [installed.bundleId: "1.0"])
        #expect(await f.library.installations() == [installed])
        #expect(f.exists(f.paths.deviceApp(for: installed)))
    }

    @Test func aDeviceThatCantBeReachedKeepsTheInstallation() async throws {
        let f = try DeviceFixture()
        let installed = try await f.library.prepareAndInstall(IOSVersion(of: tiny), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress)
        f.control.uninstallFailure.set(.deviceUnavailable(.away, detail: "Timed out."))

        await #expect(throws: FrontportError.deviceUnavailable(.away, detail: "Timed out.")) {
            try await f.library.uninstall(tiny.id, from: iPhone.id)
        }

        #expect(await f.library.installations() == [installed])
        #expect(f.exists(f.paths.deviceApp(for: installed)))
    }
}

@Suite struct DeviceRecordTests {
    @Test func remembersAndForgetsDevices() async throws {
        let f = try DeviceFixture()
        try await f.library.remember(iPhone)
        _ = try await f.library.prepareAndInstall(IOSVersion(of: tiny), on: ready(iPad), team: testTeam, channel: .stable, progress: noProgress)
        #expect(await f.library.devices() == [iPad, iPhone])

        var updated = iPhone
        updated.osVersion = "27.1"
        try await f.library.remember(updated)
        #expect(await f.library.devices() == [iPad, updated])

        // Forgetting a Device forgets its Installations; their apps stay on it.
        try await f.library.forget(iPad.id)
        #expect(await f.library.devices() == [updated])
        #expect(await f.library.installations().isEmpty)
        #expect(!f.exists(f.paths.device(iPad.id)))
        #expect(f.control.uninstalls.get.isEmpty)
    }

    /// An install under way when its Device is forgotten finishes first, and is forgotten with the rest: it makes its
    /// Port's folder before it awaits anything.
    @Test func forgettingADeviceWaitsForAnInstallUnderWay() async throws {
        let f = try DeviceFixture()
        let library = f.library
        f.provisioning.delay.set(.milliseconds(200))
        let install = Task {
            try await library.prepareAndInstall(IOSVersion(of: tiny), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress)
        }
        while f.provisioning.requests.get.isEmpty { try await Task.sleep(for: .milliseconds(5)) }

        try await library.forget(iPhone.id)

        _ = try await install.value
        #expect(f.control.installs.get.map(\.device) == [iPhone.id], "installed before the Device was forgotten")
        #expect(!f.exists(f.paths.device(iPhone.id)))
        #expect(await library.installations().isEmpty)
        #expect(await library.devices().isEmpty)
    }

    @Test func aNewDeviceLibraryReadsTheRecords() async throws {
        let f = try DeviceFixture()
        let installed = try await f.library.prepareAndInstall(IOSVersion(of: tiny), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress)

        #expect(await f.newLibrary().installations() == [installed])
        #expect(await f.newLibrary().devices() == [iPhone])
    }
}

@Suite struct DeviceLeftoverTests {
    @Test func removesWhatFailedOperationsLeft() async throws {
        let f = try DeviceFixture()
        let installed = try await f.library.prepareAndInstall(IOSVersion(of: tiny), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress)
        let stray = Device(id: "00008120-0000000000000000", name: "Stray", model: "iPhone 15", osVersion: "27.0", families: [1])
        let leftovers = [
            f.paths.deviceStaging(for: tiny.id, on: iPhone.id).appending(path: "Tiny.app/Tiny"),
            f.paths.deviceSeeds(for: tiny.id, on: iPhone.id).appending(path: "Documents/aaa.z64"),
            f.paths.deviceInstallation(for: "other", on: iPhone.id).appending(path: "staging/Other.app/Other"),
            f.paths.downloads(for: "tiny.ios").appending(path: "Tiny-1.1.ipa"),
            f.paths.downloads(for: "other.ios").appending(path: "Other-1.0.ipa"),
            f.paths.builds(for: "other.ios").appending(path: "src/main.c"),
            f.paths.logs(for: "other.ios").appending(path: "build.log"),
            f.paths.device(stray.id).appending(path: "notes"),
        ]
        let kept = [
            f.paths.builds(for: "tiny.ios").appending(path: "src/main.c"),
            f.paths.logs(for: "tiny.ios").appending(path: "build.log"),
            // The Mac's, and what isn't a Port's iOS folder.
            f.paths.downloads(for: "tiny").appending(path: "Tiny-1.0-mac.zip"),
            f.paths.builds(for: "tiny").appending(path: "src/main.c"),
            f.paths.downloads(for: "Not.A.Port.ios").appending(path: "x"),
        ]
        for file in leftovers + kept { try DeviceFixtures.write(Data("x".utf8), to: file) }

        await f.library.removeLeftovers()

        for file in leftovers { #expect(!f.exists(file), "\(file.path(percentEncoded: false))") }
        for file in kept { #expect(f.exists(file), "\(file.path(percentEncoded: false))") }
        #expect(!f.exists(f.paths.deviceInstallation(for: "other", on: iPhone.id)))
        #expect(!f.exists(f.paths.device(stray.id)), "a Device folder with no record and no Installation")
        #expect(f.exists(f.paths.deviceApp(for: installed)))
        #expect(await f.library.installations() == [installed])
        #expect(await f.library.devices() == [iPhone])
    }

    /// A link in place of a Port's folder on a Device goes, and what it leads to stays, whether it's swept or
    /// installed over.
    @Test func neverFollowsALinkInPlaceOfAPortsFolder() async throws {
        let f = try DeviceFixture()
        let elsewhere = f.tmp.url.appending(path: "Elsewhere", directoryHint: .isDirectory)
        let outside = [elsewhere.appending(path: "install.json"), elsewhere.appending(path: "staging/keep")]
        for file in outside { try DeviceFixtures.write(Data("x".utf8), to: file) }
        let folder = f.paths.deviceInstallation(for: tiny.id, on: iPhone.id)
        // A remembered Device, and an iOS download that has the sweep look at the Port's folder on each Device.
        try await f.library.remember(iPhone)
        try DeviceFixtures.write(Data("x".utf8), to: f.paths.downloads(for: "tiny.ios").appending(path: "Tiny-1.0.ipa"))
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: elsewhere)

        #expect(await f.library.installation(for: tiny.id, on: iPhone.id) == nil)
        await f.library.removeLeftovers()
        #expect(!f.exists(folder) && f.exists(f.paths.deviceRecord(iPhone.id)))
        for file in outside { #expect(try f.read(file) == "x") }

        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: elsewhere)
        let installed = try await f.library.prepareAndInstall(IOSVersion(of: tiny), on: ready(iPhone), team: testTeam, channel: .stable, progress: noProgress)
        #expect(FileOperations.isDirectory(folder) && f.exists(f.paths.deviceApp(for: installed)))
        for file in outside { #expect(try f.read(file) == "x") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path(percentEncoded: false)).sorted() == ["install.json", "staging"])
    }

    /// The Mac's sweep takes only Ports' own folders: a `.ios` name is no Port's id.
    @Test func theMacsLibraryLeavesIOSFoldersAlone() async throws {
        let f = try DeviceFixture()
        let iosFolders = [f.paths.downloads(for: "tiny.ios"), f.paths.builds(for: "tiny.ios"), f.paths.logs(for: "tiny.ios")]
        for folder in iosFolders { try DeviceFixtures.write(Data("x".utf8), to: folder.appending(path: "file")) }
        try await f.library.remember(iPhone)
        let mac = Library(
            paths: f.paths, catalog: FakeCatalog(recipe: f.tmp.url), releases: FakeReleases(latest: f.releases),
            fetcher: FakeFetcher(appName: "Tiny"), builder: FakeBuilder(paths: f.paths, appName: "Tiny"), roms: f.roms.store,
            packager: RecordingPackager(paths: f.paths, primer: nil), launcher: FakeLauncher())

        await mac.removeLeftovers()

        for folder in iosFolders { #expect(f.exists(folder.appending(path: "file"))) }
        #expect(f.exists(f.paths.deviceRecord(iPhone.id)))
    }
}

// MARK: Fixture

/// A Port with an iOS version whose Runtime ROM goes in `Documents/` on a Device and `roms/` on the Mac.
private let tiny = CatalogEntry(
    id: "tiny", name: "Tiny", kind: .decomp, game: "tiny-game", developer: "Tests", summary: "", description: "",
    source: URL(string: "https://github.com/tests/tiny")!, bundleId: "dev.frontport.port.tiny",
    releases: .githubRelease(GitHubReleaseSource(repo: "tests/tiny", asset: "Tiny-*-mac.zip")),
    requirements: [Requirement(label: "Tiny ROM", stage: .runtime, oneOf: ["aaa"], seedPath: "roms/")],
    ios: IOSSpec(releases: .githubRelease(GitHubReleaseSource(repo: "tests/tiny", asset: "Tiny-*.ipa")), seedPaths: ["Documents/"]))

/// Tiny with an iOS Recipe that makes Build Assets from a Build-Stage ROM.
private let makesAssets: CatalogEntry = {
    var entry = tiny
    entry.requirements.append(Requirement(label: "Tiny Assets", stage: .build, oneOf: ["bbb"]))
    entry.ios = IOSSpec(
        releases: .git(GitSource(
            repo: "tests/tiny", refs: [.stable: "v1.0"], recipe: "recipes/tiny-ios.sh", recipeSHA256: String(repeating: "0", count: 64))),
        seedPaths: ["Documents/", nil], buildAssets: BuildAssetsSpec(path: "assets.dat", format: "1"))
    return entry
}()

private struct DeviceFixture {
    let tmp: TemporaryDirectory
    let paths: AppPaths
    let releases = Box<[Channel: Release]>([:])
    let fetcher: FakeDeviceFetcher
    let signer = RecordingDeviceSigner()
    let control = FakeDeviceControl()
    let provisioning: FakeProvisioning
    let roms: StoredROMs
    let library: DeviceLibrary

    init() throws {
        tmp = try TemporaryDirectory()
        paths = AppPaths(root: tmp.url.appending(path: "root"), containers: tmp.url.appending(path: "Containers"))
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        fetcher = FakeDeviceFetcher(paths: paths)
        provisioning = try FakeProvisioning(profile: tmp.url.appending(path: "Profiles/wildcard.mobileprovision"))
        roms = StoredROMs(store: ROMStore(paths: paths))
        releases.set([.stable: Self.release("1.0")])
        library = DeviceLibrary(
            paths: paths, catalog: FakeCatalog(recipe: tmp.url), releases: FakeReleases(latest: releases), fetcher: fetcher,
            builder: FakeBuilder(paths: paths, appName: "Tiny"), packager: DevicePackager(signer: signer), control: control,
            provisioning: provisioning, roms: roms.store)
    }

    func newLibrary() -> DeviceLibrary {
        DeviceLibrary(
            paths: paths, catalog: FakeCatalog(recipe: tmp.url), releases: FakeReleases(latest: releases), fetcher: fetcher,
            builder: FakeBuilder(paths: paths, appName: "Tiny"), packager: DevicePackager(signer: signer), control: control,
            provisioning: provisioning, roms: roms.store)
    }

    func release(_ version: String) -> Release { Self.release(version) }

    static func release(_ version: String) -> Release {
        Release(
            port: tiny.id, version: version, tag: "v\(version)", published: Date(timeIntervalSince1970: 1_800_000_000),
            asset: ReleaseAsset(
                name: "Tiny-\(version).ipa", url: URL(string: "https://example.com/Tiny-\(version).ipa")!, size: 3, sha256: "00"))
    }

    func read(_ url: URL) throws -> String {
        try String(decoding: Data(contentsOf: url), as: UTF8.self)
    }

    func exists(_ url: URL) -> Bool { FileOperations.exists(url) }

    /// True when the app holds upstream's signature and no Provisioning Profile, as it was unpacked.
    func isUnsigned(_ app: URL) -> Bool {
        (try? read(app.appending(path: "_CodeSignature/CodeResources"))) == "upstream"
            && !exists(app.appending(path: "embedded.mobileprovision"))
    }
}

extension URL {
    /// The URL, once its folder exists.
    fileprivate func creatingFolder() throws -> URL {
        try FileManager.default.createDirectory(at: deletingLastPathComponent(), withIntermediateDirectories: true)
        return self
    }
}

extension Result where Failure == any Error {
    fileprivate init(_ body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
