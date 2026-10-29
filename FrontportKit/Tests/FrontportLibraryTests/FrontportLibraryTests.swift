import Foundation
import FrontportCore
import FrontportPackager
import FrontportROMs
import Testing
@testable import FrontportLibrary

private let noProgress: ProgressHandler = { _ in }

@Suite struct InstallTests {
    @Test func installsPrebuiltPortAndSeedsItsROM() async throws {
        let f = try Fixture()
        try await f.roms.add("aaa")
        f.releases.set([.stable: f.release("1.0", day: 1)])

        let installation = try await f.library.install(soh, channel: .stable, progress: noProgress)

        #expect(installation.release.version == "1.0")
        #expect(installation.appName == "SoH.app")
        #expect(installation.permissions == soh.permissions)
        #expect(installation.previous == nil)
        #expect(installation.entry == soh, "kept so the Port still works if the Catalog drops it")
        #expect(try version(of: f.paths.app(for: installation)) == "1.0")
        #expect(try JSON.read(Installation.self, from: f.paths.installRecord(for: soh.id)) == installation)
        #expect(f.packager.packaged.get.map(\.permissions) == [soh.permissions])
        #expect(try f.readData(soh, "roms/aaa.z64") == "rom aaa")
        #expect(!f.exists(f.paths.staging(for: soh.id)))
        #expect(await f.library.installation(for: soh.id) == installation)
        #expect(await f.library.installations() == [installation])
        #expect(await f.library.snapshots(for: soh.id).isEmpty, "a first install takes no Snapshot")
    }

    @Test func missingRuntimeROMStillInstallsAndIsSeededOnceAdded() async throws {
        let f = try Fixture()
        f.releases.set([.stable: f.release("1.0", day: 1)])

        _ = try await f.library.install(soh, channel: .stable, progress: noProgress)
        #expect(!f.exists(f.data(soh).appending(path: "roms/aaa.z64")))

        try await f.roms.add("aaa")
        try await f.library.applyROMs(to: soh, progress: noProgress)
        let seeded = try f.inode(f.data(soh).appending(path: "roms/aaa.z64"))
        try await f.library.applyROMs(to: soh, progress: noProgress)

        #expect(try f.readData(soh, "roms/aaa.z64") == "rom aaa")
        #expect(try f.inode(f.data(soh).appending(path: "roms/aaa.z64")) == seeded, "an already Seeded ROM isn't Seeded again")
    }

    @Test func missingBuildStageROMStopsTheInstall() async throws {
        let f = try Fixture()
        f.releases.set([.stable: Release(port: starship.id, version: "2.0.0", tag: "v2.0.0")])

        await #expect(throws: FrontportError.romMissing(starship.id, requirement: "Star Fox 64")) {
            try await f.library.install(starship, channel: .stable, progress: noProgress)
        }
        #expect(f.builder.builds.get.isEmpty)
        #expect(await f.library.installation(for: starship.id) == nil)
    }

    @Test func refusesUnsupportedAndSecondInstalls() async throws {
        let f = try Fixture()
        f.releases.set([.stable: f.release("1.0", day: 1)])
        var unsupported = soh
        unsupported.unsupported = "Needs to write next to its executable."

        await #expect(throws: FrontportError.unsupported(soh.id, reason: "Needs to write next to its executable.")) {
            try await f.library.install(unsupported, channel: .stable, progress: noProgress)
        }
        _ = try await f.library.install(soh, channel: .stable, progress: noProgress)
        await #expect(throws: FrontportError.alreadyInstalled(soh.id)) {
            try await f.library.install(soh, channel: .stable, progress: noProgress)
        }
    }

    @Test func refusesBlockedRelease() async throws {
        let f = try Fixture()
        f.releases.set([.stable: f.release("1.0", day: 1)])
        var blocked = soh
        blocked.blocked = [Block(release: "1.0", severity: .warn, reason: "Crashes on load.")]

        await #expect(throws: FrontportError.blocked(soh.id, release: "1.0", reason: "Crashes on load.")) {
            try await f.library.install(blocked, channel: .stable, progress: noProgress)
        }
    }

    @Test func runsOneOperationPerPortAtATime() async throws {
        let f = try Fixture()
        f.releases.set([.stable: f.release("1.0", day: 1)])
        let library = f.library

        async let first = Result { try await library.install(soh, channel: .stable, progress: noProgress) }
        async let second = Result { try await library.install(soh, channel: .stable, progress: noProgress) }
        let results = await [first, second]

        #expect(results.filter { (try? $0.get()) != nil }.count == 1)
        #expect(results.contains {
            guard case .failure(let error) = $0 else { return false }
            return error as? FrontportError == .alreadyInstalled(soh.id)
        })
        #expect(f.fetcher.inFlight.get.most == 1)
    }
}

@Suite struct UpdateAndRollbackTests {
    @Test func updateSnapshotsDataAndKeepsThePreviousRelease() async throws {
        let f = try Fixture()
        f.releases.set([.stable: f.release("1.0", day: 1)])
        _ = try await f.library.install(soh, channel: .stable, progress: noProgress)
        try f.writeData(soh, "save.dat", "1.0 progress")
        f.releases.set([.stable: f.release("1.1", day: 2)])

        let updated = try await f.library.update(soh, to: nil, progress: noProgress)

        #expect(updated.release.version == "1.1")
        #expect(updated.previous?.version == "1.0")
        #expect(try version(of: f.paths.app(for: updated)) == "1.1")
        #expect(try version(of: f.paths.previous(for: soh.id).appending(path: "SoH.app")) == "1.0")
        let snapshots = await f.library.snapshots(for: soh.id)
        #expect(snapshots.count == 1)
        let snapshot = try #require(snapshots.first)
        #expect(snapshot.reason == .update && snapshot.release == "1.0" && snapshot.target == "1.1")
        #expect(try JSON.read(Snapshot.self, from: f.paths.snapshotRecord(snapshot.id, for: soh.id)) == snapshot)
        #expect(try f.read(f.paths.snapshotData(snapshot.id, for: soh.id).appending(path: "save.dat")) == "1.0 progress")
        #expect(f.metadataSurvives(soh))
    }

    @Test func updateToTheCurrentReleaseChangesNothing() async throws {
        let f = try Fixture()
        f.releases.set([.stable: f.release("1.0", day: 1)])
        let installed = try await f.library.install(soh, channel: .stable, progress: noProgress)

        #expect(try await f.library.update(soh, to: nil, progress: noProgress) == installed)
        #expect(f.fetcher.fetched.get == ["1.0"])
    }

    @Test func rollbackRestoresTheSnapshotFromBeforeTheUpdate() async throws {
        let f = try Fixture()
        f.releases.set([.stable: f.release("1.0", day: 1)])
        _ = try await f.library.install(soh, channel: .stable, progress: noProgress)
        try f.writeData(soh, "save.dat", "1.0 progress")
        f.releases.set([.stable: f.release("1.1", day: 2)])
        _ = try await f.library.update(soh, to: nil, progress: noProgress)
        try f.writeData(soh, "save.dat", "1.1 progress")
        try f.writeData(soh, "new-in-1.1.dat", "x")
        try await f.roms.add("aaa")

        let rolledBack = try await f.library.rollback(soh, progress: noProgress)

        #expect(rolledBack.release.version == "1.0")
        #expect(rolledBack.previous == nil)
        #expect(try version(of: f.paths.app(for: rolledBack)) == "1.0")
        #expect(!f.exists(f.paths.previous(for: soh.id)))
        #expect(try f.readData(soh, "save.dat") == "1.0 progress")
        #expect(!f.exists(f.data(soh).appending(path: "new-in-1.1.dat")))
        let newest = try #require(await f.library.snapshots(for: soh.id).first)
        #expect(newest.reason == .rollback && newest.release == "1.1" && newest.target == "1.0")
        #expect(try f.read(f.paths.snapshotData(newest.id, for: soh.id).appending(path: "save.dat")) == "1.1 progress")
        #expect(try f.readData(soh, "roms/aaa.z64") == "rom aaa", "the restored Data gets its ROM back")
        #expect(f.metadataSurvives(soh))

        await #expect(throws: FrontportError.noPreviousRelease(soh.id)) {
            try await f.library.rollback(soh, progress: noProgress)
        }
    }

    @Test func rollbackResignsWhenPermissionsChangedSinceTheUpdate() async throws {
        let f = try Fixture()
        f.releases.set([.stable: f.release("1.0", day: 1)])
        _ = try await f.library.install(soh, channel: .stable, progress: noProgress)
        f.releases.set([.stable: f.release("1.1", day: 2)])
        _ = try await f.library.update(soh, to: nil, progress: noProgress)
        let permissions = Permissions(network: false, controllers: false, files: true)
        _ = try await f.library.setPermissions(permissions, for: soh)

        let rolledBack = try await f.library.rollback(soh, progress: noProgress)

        #expect(rolledBack.permissions == permissions)
        // Re-signed in previous/ before it takes the app's place.
        let kept = f.paths.previous(for: soh.id).appending(path: "SoH.app", directoryHint: .isDirectory)
        #expect(f.packager.signed(kept, with: permissions))
    }

    @Test func refusesChangesWhileRunning() async throws {
        let f = try Fixture()
        f.releases.set([.stable: f.release("1.0", day: 1)])
        _ = try await f.library.install(soh, channel: .stable, progress: noProgress)
        f.releases.set([.stable: f.release("1.1", day: 2)])
        f.launcher.runningPorts.set([soh.id])

        await #expect(throws: FrontportError.running(soh.id)) { try await f.library.update(soh, to: nil, progress: noProgress) }
        await #expect(throws: FrontportError.running(soh.id)) { try await f.library.rollback(soh, progress: noProgress) }
        await #expect(throws: FrontportError.running(soh.id)) {
            try await f.library.switchChannel(soh, to: .nightly, progress: noProgress)
        }
        await #expect(throws: FrontportError.running(soh.id)) { try await f.library.setPermissions(.default, for: soh) }
        await #expect(throws: FrontportError.running(soh.id)) { try await f.library.uninstall(soh) }
        await #expect(throws: FrontportError.running(soh.id)) { try await f.library.deleteData(soh) }
        #expect(f.fetcher.fetched.get == ["1.0"])
    }

    @Test func switchingToANewerChannelReleaseUpdates() async throws {
        let f = try Fixture()
        f.releases.set([.stable: f.release("1.0", day: 1), .nightly: f.release("1.1-dev", channel: .nightly, day: 5)])
        _ = try await f.library.install(soh, channel: .stable, progress: noProgress)
        try f.writeData(soh, "save.dat", "stable progress")

        let switched = try await f.library.switchChannel(soh, to: .nightly, progress: noProgress)

        #expect(switched.channel == .nightly && switched.release.version == "1.1-dev")
        #expect(switched.previous?.version == "1.0")
        let snapshot = try #require(await f.library.snapshots(for: soh.id).first)
        #expect(snapshot.reason == .channelSwitch && snapshot.release == "1.0" && snapshot.target == "1.1-dev")
    }

    @Test func switchingToAnOlderReleaseIsARollback() async throws {
        let f = try Fixture()
        f.releases.set([.stable: f.release("1.0", day: 1), .nightly: f.release("1.1-dev", channel: .nightly, day: 5)])
        _ = try await f.library.install(soh, channel: .stable, progress: noProgress)
        try f.writeData(soh, "save.dat", "stable progress")
        _ = try await f.library.switchChannel(soh, to: .nightly, progress: noProgress)
        try f.writeData(soh, "save.dat", "nightly progress")

        let back = try await f.library.switchChannel(soh, to: .stable, progress: noProgress)

        #expect(back.channel == .stable && back.release.version == "1.0" && back.previous == nil)
        #expect(try version(of: f.paths.app(for: back)) == "1.0")
        #expect(f.fetcher.fetched.get == ["1.0", "1.1-dev"], "the previous app is swapped back, not fetched again")
        #expect(try f.readData(soh, "save.dat") == "stable progress")
        let newest = try #require(await f.library.snapshots(for: soh.id).first)
        #expect(newest.reason == .channelSwitch && newest.release == "1.1-dev" && newest.target == "1.0")
    }

    @Test func switchingToAnOlderReleaseNotKeptFetchesItAndRestoresItsData() async throws {
        let f = try Fixture()
        f.releases.set([.nightly: f.release("2.0-dev", channel: .nightly, day: 9)])
        _ = try await f.library.install(soh, channel: .nightly, progress: noProgress)
        try f.writeData(soh, "save.dat", "2.0 progress")
        f.releases.set([.stable: f.release("1.0", day: 1), .nightly: f.release("2.0-dev", channel: .nightly, day: 9)])

        let back = try await f.library.switchChannel(soh, to: .stable, progress: noProgress)

        #expect(back.release.version == "1.0" && back.channel == .stable && back.previous == nil)
        #expect(!f.exists(f.paths.previous(for: soh.id)))
        #expect(try f.readData(soh, "save.dat") == "2.0 progress", "no Snapshot from 1.0 exists, so the Data stays")
        let snapshot = try #require(await f.library.snapshots(for: soh.id).first)
        #expect(snapshot.reason == .channelSwitch && snapshot.release == "2.0-dev" && snapshot.target == "1.0")
    }
}

/// Build Assets live beside the app, in `Library/<port>/assets` (and `previous/assets`), and the app reaches them
/// through the Packager's link at `buildAssets.path`.
@Suite struct LibraryBuildAssetsTests {
    static func release(_ version: String) -> Release {
        Release(port: starship.id, version: version, tag: "v\(version)")
    }

    @Test func installKeepsBuildAssetsBesideTheApp() async throws {
        let f = try Fixture()
        try await f.roms.add("bbb")
        f.releases.set([.stable: Self.release("2.0.0")])

        let installation = try await f.library.install(starship, channel: .stable, progress: noProgress)

        #expect(f.builder.builds.get == [["bbb"]])
        #expect(installation.buildAssets == BuildAssetsRecord(roms: ["bbb"], format: "1"))
        #expect(try f.read(f.paths.assets(for: starship.id)) == "assets from bbb")
        #expect(f.destination(f.paths.app(for: installation).appending(path: sf64)) == "../../../assets")
        #expect(try f.read(f.paths.app(for: installation).appending(path: sf64)) == "assets from bbb")
        #expect(f.packager.packaged.get.map(\.installedAssets) == [f.paths.assets(for: starship.id)], "never staging")
        #expect(!f.exists(f.paths.staging(for: starship.id)))
    }

    @Test func updateClonesBuildAssetsForwardWhenROMAndFormatAreUnchanged() async throws {
        let f = try Fixture()
        try await f.roms.add("bbb")
        f.releases.set([.stable: Self.release("2.0.0")])
        _ = try await f.library.install(starship, channel: .stable, progress: noProgress)
        try await f.roms.remove("bbb")  // carrying Assets forward doesn't need the ROM

        let updated = try await f.library.update(starship, to: Self.release("2.1.0"), progress: noProgress)

        #expect(f.builder.builds.get == [["bbb"], []])
        #expect(updated.buildAssets == BuildAssetsRecord(roms: ["bbb"], format: "1"))
        #expect(try version(of: f.paths.app(for: updated)) == "v2.1.0")
        #expect(try f.read(f.paths.assets(for: starship.id)) == "assets from bbb")
        #expect(try f.read(f.paths.app(for: updated).appending(path: sf64)) == "assets from bbb")
        #expect(try f.read(f.paths.previousAssets(for: starship.id)) == "assets from bbb", "kept with the previous Release")
    }

    @Test func updateRegeneratesBuildAssetsWhenTheFormatChanges() async throws {
        let f = try Fixture()
        try await f.roms.add("bbb")
        f.releases.set([.stable: Self.release("2.0.0")])
        _ = try await f.library.install(starship, channel: .stable, progress: noProgress)
        var newFormat = starship
        newFormat.buildAssets?.format = "2"
        try await f.roms.add("ccc")

        let updated = try await f.library.update(newFormat, to: Self.release("2.1.0"), progress: noProgress)

        #expect(f.builder.builds.get == [["bbb"], ["bbb", "ccc"]])
        #expect(updated.buildAssets == BuildAssetsRecord(roms: ["bbb", "ccc"], format: "2"))
        #expect(try f.read(f.paths.assets(for: starship.id)) == "assets from bbb,ccc")
        #expect(try f.read(f.paths.previousAssets(for: starship.id)) == "assets from bbb")

        try await f.roms.remove("bbb")
        newFormat.buildAssets?.format = "3"
        await #expect(throws: FrontportError.romMissing(starship.id, requirement: "Star Fox 64")) {
            try await f.library.update(newFormat, to: Self.release("2.2.0"), progress: noProgress)
        }
    }

    /// The Recipe would now make Build Assets in a format the installed app wasn't built for, so they wait for the
    /// update, which regenerates them anyway. Placing them would also have let that update, and a later Rollback,
    /// carry them along as if they belonged to the installed Release.
    @Test func anExtraAddedWhileAFormatChangeWaitsIsAppliedByTheUpdate() async throws {
        let f = try Fixture()
        try await f.roms.add("bbb")
        f.releases.set([.stable: Self.release("2.0.0")])
        let installed = try await f.library.install(starship, channel: .stable, progress: noProgress)
        var newFormat = starship
        newFormat.buildAssets?.format = "2"

        try await f.roms.add("ccc")
        try await f.library.applyROMs(to: newFormat, progress: noProgress)

        #expect(f.builder.builds.get == [["bbb"]])
        #expect(await f.library.installation(for: starship.id) == installed)
        #expect(try f.read(f.paths.assets(for: starship.id)) == "assets from bbb")

        let updated = try await f.library.update(newFormat, to: Self.release("2.1.0"), progress: noProgress)
        #expect(f.builder.builds.get == [["bbb"], ["bbb", "ccc"]])
        #expect(updated.buildAssets == BuildAssetsRecord(roms: ["bbb", "ccc"], format: "2"))
        let rolledBack = try await f.library.rollback(newFormat, progress: noProgress)
        #expect(rolledBack.buildAssets == installed.buildAssets)
        #expect(try f.read(f.paths.assets(for: starship.id)) == "assets from bbb")
        #expect(try f.read(f.paths.app(for: rolledBack).appending(path: sf64)) == "assets from bbb")
    }

    /// Folders, as OpenGOAL's Build Assets are, move with their Release like files.
    @Test func rollbackBringsBackTheKeptBuildAssets() async throws {
        let f = try Fixture()
        f.builder.assetsFolder.set(true)
        try await f.roms.add("bbb")
        f.releases.set([.stable: Self.release("2.0.0")])
        _ = try await f.library.install(starship, channel: .stable, progress: noProgress)
        try await f.roms.add("ccc")
        var newFormat = starship
        newFormat.buildAssets?.format = "2"
        _ = try await f.library.update(newFormat, to: Self.release("2.1.0"), progress: noProgress)
        #expect(try f.read(f.paths.assets(for: starship.id).appending(path: "data")) == "assets from bbb,ccc")
        #expect(try f.read(f.paths.previousAssets(for: starship.id).appending(path: "data")) == "assets from bbb")

        let rolledBack = try await f.library.rollback(newFormat, progress: noProgress)

        #expect(try f.read(f.paths.assets(for: starship.id).appending(path: "data")) == "assets from bbb")
        #expect(try f.read(f.paths.app(for: rolledBack).appending(path: "\(sf64)/data")) == "assets from bbb")
        #expect(!f.exists(f.paths.previous(for: starship.id)))
    }

    /// Re-signing signs the app to read its Build Assets where they'll be: `Library/<port>/assets`.
    @Test func resigningKeepsTheBuildAssetsReadable() async throws {
        let f = try Fixture()
        try await f.roms.add("bbb")
        f.releases.set([.stable: Self.release("2.0.0")])
        _ = try await f.library.install(starship, channel: .stable, progress: noProgress)
        _ = try await f.library.update(starship, to: Self.release("2.1.0"), progress: noProgress)
        let permissions = Permissions(network: true)

        _ = try await f.library.setPermissions(permissions, for: starship)
        let rolledBack = try await f.library.rollback(starship, progress: noProgress)

        let installed = f.paths.assets(for: starship.id)
        let kept = f.paths.previous(for: starship.id).appending(path: "Starship.app", directoryHint: .isDirectory)
        #expect(f.packager.resigned.get.map(\.app) == [f.paths.app(for: rolledBack), kept])
        #expect(f.packager.resigned.get.map(\.installedAssets) == [installed, installed])
        #expect(f.packager.signed(kept, with: permissions))
    }

    @Test func aFailedFirstInstallLeavesNoBuildAssets() async throws {
        let f = try Fixture()
        try await f.roms.add("bbb")
        f.releases.set([.stable: Self.release("2.0.0")])
        let staged = f.paths.staging(for: starship.id).appending(path: "Starship.app")
        f.packager.afterPackaging.set { try Fixture.setMode(0o555, of: staged) }
        defer { try? f.setMode(0o755, of: staged) }

        await #expect(throws: FrontportError.self) {
            try await f.library.install(starship, channel: .stable, progress: noProgress)
        }

        #expect(!f.exists(f.paths.assets(for: starship.id)))
        #expect(await f.library.installation(for: starship.id) == nil)
    }

    @Test func rollbackWhileBlockedBringsBackTheKeptBuildAssets() async throws {
        let f = try Fixture()
        try await f.roms.add("bbb")
        f.releases.set([.stable: Self.release("2.0.0")])
        _ = try await f.library.install(starship, channel: .stable, progress: noProgress)
        try await f.roms.add("ccc")
        var newFormat = starship
        newFormat.buildAssets?.format = "2"
        _ = try await f.library.update(newFormat, to: Self.release("2.1.0"), progress: noProgress)
        newFormat.blocked = [Block(release: "2.1.0", severity: .stop, reason: "Broken.")]
        _ = try await f.library.enforceBlocks(f.catalog([newFormat]))

        let rolledBack = try await f.library.rollback(newFormat, progress: noProgress)

        #expect(!rolledBack.disabled && rolledBack.release.version == "2.0.0")
        #expect(try f.read(f.paths.assets(for: starship.id)) == "assets from bbb")
        #expect(try f.read(f.paths.app(for: rolledBack).appending(path: sf64)) == "assets from bbb")
        #expect(!f.exists(f.paths.blocked(for: starship.id)) && !f.exists(f.paths.previous(for: starship.id)))
    }

    /// A stop Block moves only the app aside; its link leads nowhere until it's back.
    @Test func aStopBlockLeavesTheBuildAssetsInPlace() async throws {
        let f = try Fixture()
        try await f.roms.add("bbb")
        f.releases.set([.stable: Self.release("2.0.0")])
        let installed = try await f.library.install(starship, channel: .stable, progress: noProgress)
        var blocked = starship
        blocked.blocked = [Block(release: "2.0.0", severity: .stop, reason: "Broken.")]

        _ = try await f.library.enforceBlocks(f.catalog([blocked]))

        let aside = f.paths.blocked(for: starship.id).appending(path: "Starship.app")
        #expect(try f.read(f.paths.assets(for: starship.id)) == "assets from bbb")
        #expect(f.destination(aside.appending(path: sf64)) == "../../../assets" && !f.exists(aside.appending(path: sf64)))
        _ = try await f.library.setPermissions(Permissions(network: true), for: blocked)
        #expect(f.packager.resigned.get.map(\.installedAssets) == [f.paths.assets(for: starship.id)])

        _ = try await f.library.enforceBlocks(f.catalog([starship]))
        #expect(try f.read(f.paths.app(for: installed).appending(path: sf64)) == "assets from bbb")

        try FileManager.default.createDirectory(at: f.paths.buildSource(for: starship.id), withIntermediateDirectories: true)
        try await f.library.uninstall(starship)
        #expect(!f.exists(f.paths.library(for: starship.id)))
        #expect(!f.exists(f.paths.builds(for: starship.id)))
    }
}

/// Installations from before Frontport kept Build Assets beside the app have them inside it, with no
/// `Library/<port>/assets`. The next change writes the new layout.
@Suite struct OldLayoutTests {
    /// Installs Starship, then puts its Build Assets back inside the app, as Frontport used to.
    fileprivate static func installInOldLayout(_ f: Fixture) async throws -> Installation {
        try await f.roms.add("bbb")
        f.releases.set([.stable: LibraryBuildAssetsTests.release("2.0.0")])
        let installation = try await f.library.install(starship, channel: .stable, progress: noProgress)
        let inside = f.paths.app(for: installation).appending(path: sf64)
        try FileManager.default.removeItem(at: inside)
        try FileManager.default.moveItem(at: f.paths.assets(for: starship.id), to: inside)
        return installation
    }

    @Test func anUpdateCarriesThemOutOfTheAppAndRollbackPutsThemBack() async throws {
        let f = try Fixture()
        let installed = try await Self.installInOldLayout(f)
        try await f.roms.remove("bbb")

        let updated = try await f.library.update(starship, to: LibraryBuildAssetsTests.release("2.1.0"), progress: noProgress)

        #expect(f.builder.builds.get == [["bbb"], []], "carried forward from inside the app")
        #expect(try f.read(f.paths.assets(for: starship.id)) == "assets from bbb")
        #expect(f.destination(f.paths.app(for: updated).appending(path: sf64)) == "../../../assets")
        let kept = f.paths.previous(for: starship.id).appending(path: "Starship.app")
        #expect(f.destination(kept.appending(path: sf64)) == nil && !f.exists(f.paths.previousAssets(for: starship.id)))

        let rolledBack = try await f.library.rollback(starship, progress: noProgress)

        #expect(rolledBack.release == installed.release)
        #expect(!f.exists(f.paths.assets(for: starship.id)))
        #expect(f.destination(f.paths.app(for: rolledBack).appending(path: sf64)) == nil)
        #expect(try f.read(f.paths.app(for: rolledBack).appending(path: sf64)) == "assets from bbb")
    }

    @Test func aFailedUpdateLeavesTheOldLayoutAlone() async throws {
        let f = try Fixture()
        let installed = try await Self.installInOldLayout(f)
        let staged = f.paths.staging(for: starship.id).appending(path: "Starship.app")
        f.packager.afterPackaging.set { try Fixture.setMode(0o555, of: staged) }
        defer { try? f.setMode(0o755, of: staged) }

        await #expect(throws: FrontportError.self) {
            try await f.library.update(starship, to: LibraryBuildAssetsTests.release("2.1.0"), progress: noProgress)
        }

        #expect(!f.exists(f.paths.assets(for: starship.id)))
        #expect(f.destination(f.paths.app(for: installed).appending(path: sf64)) == nil)
        #expect(try f.read(f.paths.app(for: installed).appending(path: sf64)) == "assets from bbb")
    }

    @Test func permissionsResignWithoutALink() async throws {
        let f = try Fixture()
        _ = try await Self.installInOldLayout(f)

        _ = try await f.library.setPermissions(Permissions(network: true), for: starship)

        #expect(f.packager.resigned.get.count == 1, "the real Packager finds no link, so signs no exception")
    }
}

@Suite struct DataTests {
    @Test func keepsTheLastThreeSnapshots() async throws {
        let f = try Fixture()
        f.releases.set([.stable: f.release("1.0", day: 1)])
        _ = try await f.library.install(soh, channel: .stable, progress: noProgress)
        for (index, next) in ["1.1", "1.2", "1.3", "1.4"].enumerated() {
            try f.writeData(soh, "save.dat", "before \(next)")
            f.releases.set([.stable: f.release(next, day: index + 2)])
            _ = try await f.library.update(soh, to: nil, progress: noProgress)
        }

        let snapshots = await f.library.snapshots(for: soh.id)

        #expect(snapshots.map(\.target) == ["1.4", "1.3", "1.2"])
        let folders = try FileManager.default.contentsOfDirectory(atPath: f.paths.snapshots(for: soh.id).path(percentEncoded: false))
        #expect(folders.count == 3)
    }

    @Test func restoreSnapshotsTheCurrentDataFirst() async throws {
        let f = try Fixture()
        f.releases.set([.stable: f.release("1.0", day: 1)])
        _ = try await f.library.install(soh, channel: .stable, progress: noProgress)
        try f.writeData(soh, "save.dat", "old")
        f.releases.set([.stable: f.release("1.1", day: 2)])
        _ = try await f.library.update(soh, to: nil, progress: noProgress)
        try f.writeData(soh, "save.dat", "new")
        let snapshot = try #require(await f.library.snapshots(for: soh.id).first)

        try await f.library.restore(snapshot, entry: soh)

        #expect(try f.readData(soh, "save.dat") == "old")
        let newest = try #require(await f.library.snapshots(for: soh.id).first)
        #expect(newest.id != snapshot.id && newest.release == "1.1" && newest.reason == .restore)
        #expect(try f.read(f.paths.snapshotData(newest.id, for: soh.id).appending(path: "save.dat")) == "new")
        #expect(f.metadataSurvives(soh))
    }

    @Test func deleteDataRemovesDataAndSnapshotsButNotTheContainer() async throws {
        let f = try Fixture()
        f.releases.set([.stable: f.release("1.0", day: 1)])
        let installation = try await f.library.install(soh, channel: .stable, progress: noProgress)
        try f.writeData(soh, "save.dat", "progress")
        f.releases.set([.stable: f.release("1.1", day: 2)])
        _ = try await f.library.update(soh, to: nil, progress: noProgress)

        try await f.library.deleteData(soh)

        #expect(!f.exists(f.data(soh)), "macOS rebuilds Data's standard layout only when it creates the folder")
        #expect(f.metadataSurvives(soh))
        #expect(!f.exists(f.paths.snapshots(for: soh.id)))
        #expect(await f.library.installation(for: soh.id)?.port == installation.port)
    }

    @Test func seedingWaitsForTheLaunchThatRecreatesDeletedData() async throws {
        let f = try Fixture()
        f.releases.set([.stable: f.release("1.0", day: 1)])
        _ = try await f.library.install(soh, channel: .stable, progress: noProgress)
        try await f.library.deleteData(soh)
        try await f.roms.add("aaa")

        try await f.library.applyROMs(to: soh, progress: noProgress)
        #expect(!f.exists(f.data(soh)))

        try FileManager.default.createDirectory(at: f.data(soh), withIntermediateDirectories: true)  // the Port launched
        try await f.library.applyROMs(to: soh, progress: noProgress)
        #expect(try f.readData(soh, "roms/aaa.z64") == "rom aaa")
    }

    @Test func primerRecreatesDeletedDataSoSeedingNeedNotWait() async throws {
        let f = try Fixture(primed: true)
        f.releases.set([.stable: f.release("1.0", day: 1)])
        _ = try await f.library.install(soh, channel: .stable, progress: noProgress)
        try await f.library.deleteData(soh)
        try await f.library.applyROMs(to: soh, progress: noProgress)
        #expect(f.primer?.runs.get == 0, "nothing to Seed, so nothing to prime")

        try await f.roms.add("aaa")
        try await f.library.applyROMs(to: soh, progress: noProgress)

        #expect(f.primer?.runs.get == 1)
        #expect(f.exists(f.data(soh).appending(path: "Library/Application Support")))
        #expect(try f.readData(soh, "roms/aaa.z64") == "rom aaa")
        #expect(f.metadataSurvives(soh))
    }

    @Test func seedsBeforeTheFirstLaunch() async throws {
        let f = try Fixture(launched: false)
        try await f.roms.add("aaa")
        f.releases.set([.stable: f.release("1.0", day: 1)])

        _ = try await f.library.install(soh, channel: .stable, progress: noProgress)

        #expect(try f.readData(soh, "roms/aaa.z64") == "rom aaa")
    }

    @Test func uninstallKeepsDataAndSnapshots() async throws {
        let f = try Fixture()
        f.releases.set([.stable: f.release("1.0", day: 1)])
        _ = try await f.library.install(soh, channel: .stable, progress: noProgress)
        try f.writeData(soh, "save.dat", "progress")
        f.releases.set([.stable: f.release("1.1", day: 2)])
        _ = try await f.library.update(soh, to: nil, progress: noProgress)

        try await f.library.uninstall(soh)

        #expect(!f.exists(f.paths.library(for: soh.id)))
        #expect(await f.library.installation(for: soh.id) == nil)
        #expect(try f.readData(soh, "save.dat") == "progress")
        #expect(await f.library.snapshots(for: soh.id).count == 1)
        await #expect(throws: FrontportError.notInstalled(soh.id)) { try await f.library.uninstall(soh) }

        // A new Library over the same folders sees the same state.
        #expect(await f.newLibrary().installations().isEmpty)
    }

    @Test func setPermissionsResignsTheApp() async throws {
        let f = try Fixture()
        f.releases.set([.stable: f.release("1.0", day: 1)])
        let installation = try await f.library.install(soh, channel: .stable, progress: noProgress)
        let permissions = Permissions(network: false, controllers: true, files: true)

        let changed = try await f.library.setPermissions(permissions, for: soh)

        #expect(changed.permissions == permissions)
        #expect(f.packager.resigned.get.map(\.permissions) == [permissions])
        #expect(f.packager.resigned.get.first?.app == f.paths.app(for: installation))
        #expect(await f.newLibrary().installation(for: soh.id)?.permissions == permissions)
    }
}

@Suite struct BlockTests {
    @Test func stopBlockDisablesAndUpdateRestores() async throws {
        let f = try Fixture()
        f.releases.set([.stable: f.release("1.0", day: 1)])
        let installed = try await f.library.install(soh, channel: .stable, progress: noProgress)
        var blocked = soh
        blocked.blocked = [Block(release: "1.0", severity: .stop, reason: "Corrupts saves.")]

        let changed = try await f.library.enforceBlocks(f.catalog([blocked]))

        #expect(changed.map(\.disabled) == [true])
        #expect(!f.exists(f.paths.app(for: installed)))
        #expect(try version(of: f.paths.blocked(for: soh.id).appending(path: "SoH.app")) == "1.0")
        #expect(try await f.library.enforceBlocks(f.catalog([blocked])).isEmpty, "already disabled")

        f.releases.set([.stable: f.release("1.1", day: 2)])
        let updated = try await f.library.update(blocked, to: nil, progress: noProgress)

        #expect(!updated.disabled && updated.release.version == "1.1")
        #expect(try version(of: f.paths.app(for: updated)) == "1.1")
        #expect(!f.exists(f.paths.blocked(for: soh.id)))
        await #expect(throws: FrontportError.blocked(soh.id, release: "1.0", reason: "Corrupts saves.")) {
            try await f.library.rollback(blocked, progress: noProgress)
        }
    }

    @Test func rollbackRestoresADisabledInstallation() async throws {
        let f = try Fixture()
        f.releases.set([.stable: f.release("1.0", day: 1)])
        _ = try await f.library.install(soh, channel: .stable, progress: noProgress)
        f.releases.set([.stable: f.release("1.1", day: 2)])
        _ = try await f.library.update(soh, to: nil, progress: noProgress)
        var blocked = soh
        blocked.blocked = [Block(release: "1.1", severity: .stop, reason: "Broken.")]
        _ = try await f.library.enforceBlocks(f.catalog([blocked]))

        let rolledBack = try await f.library.rollback(blocked, progress: noProgress)

        #expect(!rolledBack.disabled && rolledBack.release.version == "1.0")
        #expect(try version(of: f.paths.app(for: rolledBack)) == "1.0")
        #expect(!f.exists(f.paths.blocked(for: soh.id)))
    }

    @Test func warnBlockIsOnlyReportedAndLiftingAStopReenables() async throws {
        let f = try Fixture()
        f.releases.set([.stable: f.release("1.0", day: 1)])
        let installed = try await f.library.install(soh, channel: .stable, progress: noProgress)
        var warned = soh
        warned.blocked = [Block(release: "1.0", severity: .warn, reason: "Minor.")]
        var stopped = soh
        stopped.blocked = [Block(release: "1.0", severity: .stop, reason: "Major.")]

        #expect(try await f.library.enforceBlocks(f.catalog([warned])).isEmpty)
        #expect(f.exists(f.paths.app(for: installed)))

        _ = try await f.library.enforceBlocks(f.catalog([stopped]))
        let reenabled = try await f.library.enforceBlocks(f.catalog([soh]))

        #expect(reenabled.map(\.disabled) == [false])
        #expect(try version(of: f.paths.app(for: installed)) == "1.0")
        #expect(!f.exists(f.paths.blocked(for: soh.id)))
    }
}

@Suite struct ReleaseChangeSafetyTests {
    /// An update whose record can't be written leaves the Installation as the Library holds it, so a Rollback still
    /// finds in `previous/` the Release the record says is kept.
    @Test func aFailedUpdateKeepsPreviousAndTheRecordInStep() async throws {
        let f = try Fixture()
        f.releases.set([.stable: f.release("1.0", day: 1)])
        _ = try await f.library.install(soh, channel: .stable, progress: noProgress)
        f.releases.set([.stable: f.release("1.1", day: 2)])
        _ = try await f.library.update(soh, to: nil, progress: noProgress)
        // install.json can't be written: a folder stands in its way.
        let record = f.paths.installRecord(for: soh.id)
        try FileManager.default.removeItem(at: record)
        try FileManager.default.createDirectory(at: record, withIntermediateDirectories: false)
        f.releases.set([.stable: f.release("1.2", day: 3)])

        await #expect(throws: (any Error).self) { try await f.library.update(soh, to: nil, progress: noProgress) }
        let current = try #require(await f.library.installation(for: soh.id))
        #expect(current.release.version == "1.1")
        #expect(try version(of: f.paths.app(for: current)) == "1.1", "the app went back with the record")
        try FileManager.default.removeItem(at: record)
        let rolledBack = try await f.library.rollback(soh, progress: noProgress)

        #expect(rolledBack.release.version == "1.0")
        #expect(try version(of: f.paths.app(for: rolledBack)) == rolledBack.release.version)
    }

    /// The older Release's Data comes back only once its app is in place.
    @Test func aFailedSwitchToAnOlderReleaseLeavesTheDataAlone() async throws {
        let f = try Fixture()
        f.releases.set([.stable: f.release("1.0", day: 1), .nightly: f.release("2.0-dev", channel: .nightly, day: 5)])
        _ = try await f.library.install(soh, channel: .stable, progress: noProgress)
        try f.writeData(soh, "save.dat", "1.0 progress")
        _ = try await f.library.switchChannel(soh, to: .nightly, progress: noProgress)
        f.releases.set([.stable: f.release("1.0", day: 1), .nightly: f.release("2.1-dev", channel: .nightly, day: 6)])
        _ = try await f.library.update(soh, to: nil, progress: noProgress)  // previous/ now holds 2.0-dev
        try f.writeData(soh, "save.dat", "2.1 progress")
        let folder = f.paths.library(for: soh.id)
        f.packager.afterPackaging.set { try Fixture.setMode(0o555, of: folder) }
        defer { try? f.setMode(0o755, of: folder) }

        await #expect(throws: FrontportError.self) {
            try await f.library.switchChannel(soh, to: .stable, progress: noProgress)
        }
        #expect(try f.readData(soh, "save.dat") == "2.1 progress")
    }

    @Test func aFailedRollbackLeavesTheDataAlone() async throws {
        let f = try Fixture()
        f.releases.set([.stable: f.release("1.0", day: 1)])
        _ = try await f.library.install(soh, channel: .stable, progress: noProgress)
        try f.writeData(soh, "save.dat", "1.0 progress")
        f.releases.set([.stable: f.release("1.1", day: 2)])
        _ = try await f.library.update(soh, to: nil, progress: noProgress)
        try f.writeData(soh, "save.dat", "1.1 progress")
        let folder = f.paths.library(for: soh.id)
        try f.setMode(0o555, of: folder)
        defer { try? f.setMode(0o755, of: folder) }

        await #expect(throws: FrontportError.self) { try await f.library.rollback(soh, progress: noProgress) }
        #expect(try f.readData(soh, "save.dat") == "1.1 progress")
    }

    /// When the newest Release is stop-Blocked, an update can land on an older one: handled like a switch to it.
    @Test func updatingToAnOlderReleaseRestoresItsData() async throws {
        let f = try Fixture()
        f.releases.set([.stable: f.release("1.5", day: 1)])
        _ = try await f.library.install(soh, channel: .stable, progress: noProgress)
        try f.writeData(soh, "save.dat", "1.5 progress")
        f.releases.set([.stable: f.release("2.0", day: 2)])
        _ = try await f.library.update(soh, to: nil, progress: noProgress)
        f.releases.set([.stable: f.release("2.1", day: 3)])
        _ = try await f.library.update(soh, to: nil, progress: noProgress)
        try f.writeData(soh, "save.dat", "2.1 progress")
        var blocked = soh
        blocked.blocked = [Block(release: "2.1", severity: .stop, reason: "Corrupts saves.")]
        _ = try await f.library.enforceBlocks(f.catalog([blocked]))
        f.releases.set([.stable: f.release("1.5", day: 1)])  // the newest Release that isn't Blocked

        let updated = try await f.library.update(blocked, to: nil, progress: noProgress)

        #expect(updated.release.version == "1.5" && !updated.disabled && updated.previous == nil)
        #expect(try version(of: f.paths.app(for: updated)) == "1.5")
        #expect(try f.readData(soh, "save.dat") == "1.5 progress")
        let newest = try #require(await f.library.snapshots(for: soh.id).first)
        #expect(newest.reason == .update && newest.release == "2.1" && newest.target == "1.5")
        #expect(try f.read(f.paths.snapshotData(newest.id, for: soh.id).appending(path: "save.dat")) == "2.1 progress")
    }

    /// The app a Recipe leaves is untrusted: a link to another app must not be packaged in its place.
    @Test func refusesABuiltAppThatIsALink() async throws {
        let f = try Fixture()
        try await f.roms.add("bbb")
        let victim = try makeApp(named: "Victim", version: "victim", in: f.tmp.url.appending(path: "outside"))
        f.builder.linkedApp.set(victim)
        f.releases.set([.stable: Release(port: starship.id, version: "2.0.0", tag: "v2.0.0")])

        await #expect(throws: FrontportError.self) {
            try await f.library.install(starship, channel: .stable, progress: noProgress)
        }
        #expect(f.packager.packaged.get.isEmpty)
    }

    /// The change is complete before Seeding, so a Seeding failure doesn't fail it.
    @Test func aSeedingFailureDoesNotFailTheChange() async throws {
        let f = try Fixture()
        try await f.roms.add("aaa")
        // A file where the ROMs' folder goes, which Seeding refuses to replace.
        try f.writeData(soh, "roms", "in the way")
        f.releases.set([.stable: f.release("1.0", day: 1)])

        let installed = try await f.library.install(soh, channel: .stable, progress: noProgress)
        f.releases.set([.stable: f.release("1.1", day: 2)])
        let updated = try await f.library.update(soh, to: nil, progress: noProgress)
        let rolledBack = try await f.library.rollback(soh, progress: noProgress)

        #expect(installed.release.version == "1.0" && updated.release.version == "1.1" && rolledBack.release.version == "1.0")
        #expect(!f.exists(f.data(soh).appending(path: "roms/aaa.z64")))
        #expect(await f.unseeded(soh) == ["Ocarina of Time"])
        try FileManager.default.removeItem(at: f.data(soh).appending(path: "roms"))
        try await f.library.applyROMs(to: soh, progress: noProgress)
        #expect(try f.readData(soh, "roms/aaa.z64") == "rom aaa")
        #expect(await f.unseeded(soh).isEmpty)
    }

    /// An update to the Release kept in previous/ swaps it back, like a Rollback.
    @Test func updatingToThePreviousReleaseSwapsItBack() async throws {
        let f = try Fixture()
        f.releases.set([.stable: f.release("1.0", day: 1)])
        let installed = try await f.library.install(soh, channel: .stable, progress: noProgress)
        try f.writeData(soh, "save.dat", "1.0 progress")
        f.releases.set([.stable: f.release("1.1", day: 2)])
        _ = try await f.library.update(soh, to: nil, progress: noProgress)
        try f.writeData(soh, "save.dat", "1.1 progress")

        let back = try await f.library.update(soh, to: installed.release, progress: noProgress)

        #expect(back.release.version == "1.0" && back.previous == nil && back.channel == .stable)
        #expect(f.fetcher.fetched.get == ["1.0", "1.1"], "swapped back, not fetched again")
        #expect(try f.readData(soh, "save.dat") == "1.0 progress")
        #expect(await f.library.snapshots(for: soh.id).first?.reason == .update)
    }

    @Test func applyingROMsWaitsForThePortToQuit() async throws {
        let f = try Fixture()
        f.releases.set([.stable: f.release("1.0", day: 1)])
        _ = try await f.library.install(soh, channel: .stable, progress: noProgress)
        try await f.roms.add("aaa")
        f.launcher.runningPorts.set([soh.id])

        await #expect(throws: FrontportError.running(soh.id)) { try await f.library.applyROMs(to: soh, progress: noProgress) }
        #expect(!f.exists(f.data(soh).appending(path: "roms/aaa.z64")))
    }

    @Test func restoreRefusesAnotherPortsSnapshot() async throws {
        let f = try Fixture()
        f.releases.set([.stable: f.release("1.0", day: 1)])
        _ = try await f.library.install(soh, channel: .stable, progress: noProgress)
        try f.writeData(soh, "save.dat", "soh progress")
        f.releases.set([.stable: f.release("1.1", day: 2)])
        _ = try await f.library.update(soh, to: nil, progress: noProgress)
        let snapshot = try #require(await f.library.snapshots(for: soh.id).first)
        try f.writeData(starship, "save.dat", "starship progress")

        await #expect(throws: FrontportError.self) { try await f.library.restore(snapshot, entry: starship) }
        var forged = snapshot
        forged.id = "../../\(snapshot.id)"
        await #expect(throws: FrontportError.self) { try await f.library.restore(forged, entry: soh) }
        #expect(try f.readData(starship, "save.dat") == "starship progress")
    }

    /// Whatever the Catalog says, an id or bundle ID can't lead the Library to another folder.
    @Test func refusesEntriesThatWouldNameAnotherFolder() async throws {
        let f = try Fixture()
        f.releases.set([.stable: f.release("1.0", day: 1)])
        var parent = soh
        parent.id = ".."
        var container = soh
        container.bundleId = "../../Documents"
        let marker = f.paths.library.appending(path: "marker")
        try FileManager.default.createDirectory(at: f.paths.library, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: marker)

        for entry in [parent, container] {
            await #expect(throws: FrontportError.self) { try await f.library.install(entry, channel: .stable, progress: noProgress) }
            await #expect(throws: FrontportError.self) { try await f.library.uninstall(entry) }
            await #expect(throws: FrontportError.self) { try await f.library.deleteData(entry) }
        }
        #expect(try f.read(marker) == "keep")
        #expect(f.fetcher.fetched.get.isEmpty)
    }
}

/// Redirects lead from inside the app into the Port's Data, so their folders must exist whenever the app is signed or
/// runs. Frontport makes them without following a link.
@Suite struct RedirectTests {
    static let log = Redirect(path: "Contents/Resources/log", to: "Library/Application Support/SoH/log")
    static let redirected = {
        var entry = soh
        entry.redirects = [log]
        return entry
    }()

    fileprivate static func target(_ f: Fixture) -> URL { f.data(soh).appending(path: log.to) }

    @Test func installMakesTheFolderBeforeSigning() async throws {
        let f = try Fixture(launched: false)
        f.releases.set([.stable: f.release("1.0", day: 1)])

        let installation = try await f.library.install(Self.redirected, channel: .stable, progress: noProgress)

        #expect(FileOperations.isDirectory(Self.target(f)))
        let data = PortLinks.redirectData(bundleId: soh.bundleId, containers: f.paths.containers)
        #expect(f.destination(f.paths.app(for: installation).appending(path: Self.log.path)) == data + "/" + Self.log.to)
    }

    /// Delete Data primes the container and makes the folder again, so a launch from the Dock finds it.
    @Test func deleteDataPrimesAndMakesTheFolderAgain() async throws {
        let f = try Fixture(primed: true)
        f.releases.set([.stable: f.release("1.0", day: 1)])
        _ = try await f.library.install(Self.redirected, channel: .stable, progress: noProgress)
        try f.writeData(soh, "save.dat", "progress")

        try await f.library.deleteData(Self.redirected)

        #expect(f.primer?.runs.get == 1)
        #expect(FileOperations.isDirectory(Self.target(f)) && !f.exists(f.data(soh).appending(path: "save.dat")))
        #expect(f.metadataSurvives(soh))
    }

    @Test func restoringASnapshotWithoutTheFolderMakesItAgain() async throws {
        let f = try Fixture()
        f.releases.set([.stable: f.release("1.0", day: 1)])
        _ = try await f.library.install(Self.redirected, channel: .stable, progress: noProgress)
        try f.writeData(soh, "save.dat", "1.0 progress")
        f.releases.set([.stable: f.release("1.1", day: 2)])
        _ = try await f.library.update(Self.redirected, to: nil, progress: noProgress)
        let snapshot = try #require(await f.library.snapshots(for: soh.id).first)
        // As a Snapshot taken before the Port had its Redirect.
        try FileManager.default.removeItem(at: f.paths.snapshotData(snapshot.id, for: soh.id).appending(path: Self.log.to))

        try await f.library.restore(snapshot, entry: Self.redirected)

        #expect(try f.readData(soh, "save.dat") == "1.0 progress")
        #expect(FileOperations.isDirectory(Self.target(f)))
    }

    /// The folders come from the app's own links, so Rollback and Permission changes make them whatever the entry says.
    @Test func rollbackAndPermissionsMakeTheAppsFolders() async throws {
        let f = try Fixture()
        f.releases.set([.stable: f.release("1.0", day: 1)])
        _ = try await f.library.install(Self.redirected, channel: .stable, progress: noProgress)
        f.releases.set([.stable: f.release("1.1", day: 2)])
        _ = try await f.library.update(soh, to: nil, progress: noProgress)
        try FileManager.default.removeItem(at: Self.target(f))

        _ = try await f.library.rollback(soh, progress: noProgress)
        #expect(FileOperations.isDirectory(Self.target(f)))

        try FileManager.default.removeItem(at: Self.target(f))
        _ = try await f.library.setPermissions(Permissions(network: false), for: soh)
        #expect(FileOperations.isDirectory(Self.target(f)))
    }

    /// The Port can plant links in its Data; Frontport refuses them rather than make anything where they lead.
    @Test func neverFollowsALinkInData() async throws {
        let f = try Fixture()
        f.releases.set([.stable: f.release("1.0", day: 1)])
        _ = try await f.library.install(Self.redirected, channel: .stable, progress: noProgress)
        let outside = f.tmp.url.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let folder = f.data(soh).appending(path: "Library/Application Support/SoH")
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)

        await #expect(throws: FrontportError.self) {
            try await f.library.setPermissions(Permissions(network: false), for: Self.redirected)
        }
        #expect(try f.listing(outside).isEmpty)
        #expect(await f.library.installation(for: soh.id)?.permissions == Self.redirected.permissions)
    }

    /// The Data a Rollback restores may come from before the Port had its Redirect: the folder is made again after.
    @Test func rollbackMakesTheFolderAfterRestoring() async throws {
        let f = try Fixture()
        f.releases.set([.stable: f.release("1.0", day: 1)])
        _ = try await f.library.install(Self.redirected, channel: .stable, progress: noProgress)
        f.releases.set([.stable: f.release("1.1", day: 2)])
        _ = try await f.library.update(Self.redirected, to: nil, progress: noProgress)
        let snapshot = try #require(await f.library.snapshots(for: soh.id).first)
        try FileManager.default.removeItem(at: f.paths.snapshotData(snapshot.id, for: soh.id).appending(path: Self.log.to))

        let rolledBack = try await f.library.rollback(Self.redirected, progress: noProgress)

        #expect(rolledBack.release.version == "1.0")
        #expect(FileOperations.isDirectory(Self.target(f)))
    }

    /// So may the Data an update to an older Release restores.
    @Test func anUpdateToAnOlderReleaseMakesTheFolderAfterRestoring() async throws {
        let f = try Fixture()
        f.releases.set([.stable: f.release("1.5", day: 1)])
        _ = try await f.library.install(Self.redirected, channel: .stable, progress: noProgress)
        f.releases.set([.stable: f.release("2.0", day: 2)])
        _ = try await f.library.update(Self.redirected, to: nil, progress: noProgress)
        let snapshot = try #require(await f.library.snapshots(for: soh.id).first { $0.release == "1.5" })
        try FileManager.default.removeItem(at: f.paths.snapshotData(snapshot.id, for: soh.id).appending(path: Self.log.to))
        f.releases.set([.stable: f.release("2.1", day: 3)])
        _ = try await f.library.update(Self.redirected, to: nil, progress: noProgress)

        let updated = try await f.library.update(Self.redirected, to: f.release("1.5", day: 1), progress: noProgress)

        #expect(updated.release.version == "1.5" && updated.previous == nil, "fetched, not swapped back from previous/")
        #expect(FileOperations.isDirectory(Self.target(f)))
    }

    /// Making the folders after Data has changed is the last step of a change that is otherwise complete, so a failure
    /// is reported, not thrown: the Rollback still Seeds, and the Launcher makes the folders before the next launch.
    @Test func aFolderThatCannotBeMadeAfterRestoringDoesNotFailTheChange() async throws {
        let f = try Fixture()
        f.releases.set([.stable: f.release("1.0", day: 1)])
        _ = try await f.library.install(Self.redirected, channel: .stable, progress: noProgress)
        f.releases.set([.stable: f.release("1.1", day: 2)])
        _ = try await f.library.update(Self.redirected, to: nil, progress: noProgress)
        let snapshot = try #require(await f.library.snapshots(for: soh.id).first)
        let outside = f.tmp.url.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let planted = f.paths.snapshotData(snapshot.id, for: soh.id).appending(path: "Library/Application Support/SoH")
        try FileManager.default.removeItem(at: planted)
        try FileManager.default.createSymbolicLink(at: planted, withDestinationURL: outside)
        try await f.roms.add("aaa")
        let reported = Box<[ProgressUpdate]>([])

        let rolledBack = try await f.library.rollback(Self.redirected) { update in reported.update { $0.append(update) } }

        #expect(rolledBack.release.version == "1.0")
        #expect(reported.get.contains { $0.phase == .restoring && $0.message?.contains("Redirects couldn’t be prepared") == true })
        #expect(try f.listing(outside).isEmpty)
        #expect(try f.readData(soh, "roms/aaa.z64") == "rom aaa", "Seeding still runs")

        // Restoring a Snapshot, likewise.
        let again = try #require(await f.library.snapshots(for: soh.id).first { $0.id == snapshot.id })
        try await f.library.restore(again, entry: Self.redirected)
        #expect(try f.listing(outside).isEmpty)
    }

    /// Without a primer, Data that macOS manages can't be made again until the Port's next launch, which makes the
    /// folders too; Delete Data has done its work by then, so it doesn't fail.
    @Test func deleteDataWithoutAPrimerStillSucceeds() async throws {
        let f = try Fixture()
        f.releases.set([.stable: f.release("1.0", day: 1)])
        _ = try await f.library.install(Self.redirected, channel: .stable, progress: noProgress)

        try await f.library.deleteData(Self.redirected)

        #expect(!f.exists(f.data(soh)) && f.metadataSurvives(soh))
        #expect(await f.library.snapshots(for: soh.id).isEmpty)
    }
}

/// Extras remake Build Assets for the installed Release through the real Packager, which polices links: the app is
/// re-signed or packaged again with its Redirect, whose folder the Library makes first.
@Suite struct RedirectedExtrasTests {
    static let log = Redirect(path: "Contents/Resources/log", to: "Library/Application Support/Starship/log")
    static let redirected = {
        var entry = starship
        entry.redirects = [log]
        return entry
    }()

    fileprivate static func target(_ f: Fixture) -> URL { f.data(starship).appending(path: log.to) }

    /// Missing Build Assets re-sign the app, as its exception changes, after the Redirect's folder is back.
    @Test func anExtraThatResignsMakesTheFolderFirst() async throws {
        let f = try Fixture(signed: true)
        try await f.roms.add("bbb")
        f.releases.set([.stable: LibraryBuildAssetsTests.release("2.0.0")])
        let installation = try await f.library.install(Self.redirected, channel: .stable, progress: noProgress)
        let app = f.paths.app(for: installation)
        try FileManager.default.removeItem(at: f.paths.assets(for: starship.id))
        try FileManager.default.removeItem(at: Self.target(f))
        try await f.roms.add("ccc")

        try await f.library.applyROMs(to: Self.redirected, progress: noProgress)

        #expect(FileOperations.isDirectory(Self.target(f)))
        #expect(try f.read(app.appending(path: sf64)) == "assets from bbb,ccc")
        let data = PortLinks.redirectData(bundleId: starship.bundleId, containers: f.paths.containers)
        #expect(f.destination(app.appending(path: Self.log.path)) == data + "/" + Self.log.to)
        #expect(try await SignedBuildAssetsTests.verifies(app, "--strict=sideband"))
    }

    /// An app from before Frontport kept Build Assets beside it is packaged again, and gets the Redirect the Catalog
    /// has added since.
    @Test func anExtraThatPackagesAnOldLayoutAppAgainAddsTheRedirect() async throws {
        let f = try Fixture(signed: true)
        let installed = try await OldLayoutTests.installInOldLayout(f)
        try await f.roms.add("ccc")

        try await f.library.applyROMs(to: Self.redirected, progress: noProgress)

        let app = f.paths.app(for: installed)
        #expect(FileOperations.isDirectory(Self.target(f)))
        let data = PortLinks.redirectData(bundleId: starship.bundleId, containers: f.paths.containers)
        #expect(f.destination(app.appending(path: Self.log.path)) == data + "/" + Self.log.to)
        #expect(f.destination(app.appending(path: sf64)) == "../../../assets")
        #expect(try f.read(app.appending(path: sf64)) == "assets from bbb,ccc")
        #expect(try await SignedBuildAssetsTests.verifies(app, "--strict=sideband"))
    }
}

/// Through the real Packager, which, unlike the fake, signs and polices links: it finds the app's link to its Build
/// Assets in the app itself, whatever the Catalog now says, and signs the exception for where they're kept.
@Suite struct SignedBuildAssetsTests {
    /// The exception the app is signed with: absolute, as the test folder is outside the home folder.
    static func readable(_ app: URL) async throws -> [String]? {
        let result = try await ProcessRunner().run(
            URL(filePath: "/usr/bin/codesign"),
            arguments: ["-d", "--entitlements", "-", "--xml", app.path(percentEncoded: false)], stderr: .discard)
        let entitlements = try PropertyListSerialization.propertyList(from: result.stdout, format: nil) as? [String: Any]
        return entitlements?[PortEntitlements.absoluteReadOnly] as? [String]
    }

    static func verifies(_ app: URL, _ strictness: String) async throws -> Bool {
        try await ProcessRunner().run(
            URL(filePath: "/usr/bin/codesign"), arguments: ["--verify", strictness, app.path(percentEncoded: false)]
        ).succeeded
    }

    fileprivate static func installed(_ f: Fixture) async throws -> (installation: Installation, assets: String) {
        try await f.roms.add("bbb")
        f.releases.set([.stable: LibraryBuildAssetsTests.release("2.0.0")])
        let installation = try await f.library.install(starship, channel: .stable, progress: noProgress)
        let root = try #require(realpath(f.tmp.url.path(percentEncoded: false), nil))
        defer { free(root) }
        return (installation, String(cString: root) + "/root/Library/starship/assets")
    }

    /// A Catalog that moves `buildAssets.path` later doesn't stop Permission changes and Rollbacks.
    @Test func resignsAfterTheCatalogMovesBuildAssets() async throws {
        let f = try Fixture(signed: true)
        let (installation, assets) = try await Self.installed(f)
        #expect(try await Self.readable(f.paths.app(for: installation)) == [assets])
        _ = try await f.library.update(starship, to: LibraryBuildAssetsTests.release("2.1.0"), progress: noProgress)
        var moved = starship
        moved.buildAssets?.path = "Contents/Resources/moved/sf64.o2r"

        let changed = try await f.library.setPermissions(Permissions(network: true), for: moved)
        #expect(try await Self.readable(f.paths.app(for: changed)) == [assets])
        let rolledBack = try await f.library.rollback(moved, progress: noProgress)

        let app = f.paths.app(for: rolledBack)
        #expect(rolledBack.release.version == "2.0.0" && rolledBack.permissions == Permissions(network: true))
        #expect(try await Self.readable(app) == [assets])
        #expect(try await Self.verifies(app, "--strict=sideband"))
        #expect(try f.read(app.appending(path: sf64)) == "assets from bbb")
    }

    /// Build Assets deleted from beside the app: the app's link still says how it keeps them, so a re-sign keeps the
    /// exception and an extra puts them back.
    @Test func buildAssetsMissingBesideTheAppComeBack() async throws {
        let f = try Fixture(signed: true)
        let (installation, assets) = try await Self.installed(f)
        let app = f.paths.app(for: installation)
        try FileManager.default.removeItem(at: f.paths.assets(for: starship.id))

        _ = try await f.library.setPermissions(Permissions(network: true), for: starship)
        #expect(try await Self.readable(app) == [assets])
        try await f.roms.add("ccc")
        try await f.library.applyROMs(to: starship, progress: noProgress)

        #expect(try f.read(app.appending(path: sf64)) == "assets from bbb,ccc")
        #expect(try await Self.readable(app) == [assets])
        #expect(try await Self.verifies(app, "--strict=sideband"))
    }

    /// The exception names a file or a folder, so regenerated Build Assets of the other kind re-sign the app.
    @Test func anExtraThatTurnsTheBuildAssetsIntoAFolderResigns() async throws {
        let f = try Fixture(signed: true)
        let (installation, assets) = try await Self.installed(f)
        f.builder.assetsFolder.set(true)
        try await f.roms.add("ccc")

        try await f.library.applyROMs(to: starship, progress: noProgress)

        let app = f.paths.app(for: installation)
        #expect(try f.read(app.appending(path: "\(sf64)/data")) == "assets from bbb,ccc")
        #expect(try await Self.readable(app) == [assets + "/"])
        #expect(try await Self.verifies(app, "--strict=sideband"))
    }

    /// Re-signing changes the app in place, so when verifying fails the app is put back as it was: its signature still
    /// grants what its record says, and nothing is left beside it.
    @Test func aFailedResignLeavesTheAppAsItsRecordSays() async throws {
        let scripts = try TemporaryDirectory()
        let failing = scripts.url.appending(path: "failing")
        let codesign = scripts.url.appending(path: "codesign")
        try Data(
            """
            #!/bin/sh
            if [ "$1" = --verify ] && [ -e '\(failing.path(percentEncoded: false))' ]; then echo "invalid signature" >&2; exit 1; fi
            exec /usr/bin/codesign "$@"

            """.utf8
        ).write(to: codesign)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codesign.path(percentEncoded: false))
        let f = try Fixture(signed: true, codesign: codesign)
        f.releases.set([.stable: f.release("1.0", day: 1)])
        let installation = try await f.library.install(soh, channel: .stable, progress: noProgress)
        let app = f.paths.app(for: installation)
        #expect(try await Self.entitlement("com.apple.security.network.client", of: app) == true)
        try Data().write(to: failing)

        await #expect(throws: FrontportError.signingFailed("invalid signature")) {
            try await f.library.setPermissions(Permissions(network: false), for: soh)
        }

        #expect(try await Self.entitlement("com.apple.security.network.client", of: app) == true)
        #expect(await f.library.installation(for: soh.id)?.permissions == installation.permissions)
        #expect(try await Self.verifies(app, "--strict"))
        #expect(try f.listing(f.paths.library(for: soh.id)).sorted() == ["SoH.app", "install.json"])
    }

    static func entitlement(_ key: String, of app: URL) async throws -> Bool? {
        let result = try await ProcessRunner().run(
            URL(filePath: "/usr/bin/codesign"),
            arguments: ["-d", "--entitlements", "-", "--xml", app.path(percentEncoded: false)], stderr: .discard)
        let entitlements = try PropertyListSerialization.propertyList(from: result.stdout, format: nil) as? [String: Any]
        return entitlements?[key] as? Bool
    }

    /// The kept Release keeps its Build Assets inside its app, as before Frontport kept them beside it: re-signed
    /// for new Permissions, it gets no exception and verifies strictly.
    @Test func rollbackResignsAnOldLayoutReleaseWithoutTheException() async throws {
        let f = try Fixture(signed: true)
        let (installation, assets) = try await Self.installed(f)
        let inside = f.paths.app(for: installation).appending(path: sf64)
        try FileManager.default.removeItem(at: inside)
        try FileManager.default.moveItem(at: f.paths.assets(for: starship.id), to: inside)
        _ = try await f.library.update(starship, to: LibraryBuildAssetsTests.release("2.1.0"), progress: noProgress)
        _ = try await f.library.setPermissions(Permissions(network: true), for: starship)
        #expect(try await Self.readable(f.paths.app(for: installation)) == [assets])

        let rolledBack = try await f.library.rollback(starship, progress: noProgress)

        let app = f.paths.app(for: rolledBack)
        #expect(try await Self.readable(app) == nil)
        #expect(try await Self.verifies(app, "--strict"))
        #expect(!f.exists(f.paths.assets(for: starship.id)))
        #expect(try f.read(app.appending(path: sf64)) == "assets from bbb")
    }
}

// MARK: Fixture
// MARK: Fixture

private let soh = CatalogEntry(
    id: "soh", name: "Ship of Harkinian", kind: .decomp, game: "ocarina-of-time", developer: "HarbourMasters",
    summary: "", description: "", source: URL(string: "https://github.com/HarbourMasters/Shipwright")!,
    bundleId: "dev.frontport.port.soh",
    releases: .githubRelease(GitHubReleaseSource(repo: "HarbourMasters/Shipwright", asset: "SoH-*-Mac.zip", channels: [.stable, .nightly])),
    requirements: [Requirement(label: "Ocarina of Time", stage: .runtime, oneOf: ["aaa"], seedPath: "roms/")],
    permissions: Permissions(network: true))

private let starship = CatalogEntry(
    id: "starship", name: "Starship", kind: .decomp, game: "star-fox-64", developer: "HarbourMasters", summary: "",
    description: "", source: URL(string: "https://github.com/HarbourMasters/Starship")!,
    bundleId: "dev.frontport.port.starship",
    releases: .git(GitSource(repo: "HarbourMasters/Starship", refs: [.stable: "v2.0.0"], recipe: "recipes/starship.sh", recipeSHA256: "0")),
    requirements: [Requirement(label: "Star Fox 64", stage: .build, oneOf: ["bbb"], extras: ["ccc"])],
    buildAssets: BuildAssetsSpec(path: "Contents/Resources/sf64.o2r", format: "1"))

private let sf64 = "Contents/Resources/sf64.o2r"

private struct Fixture {
    static let metadata = ".com.apple.containermanagerd.metadata.plist"

    let tmp: TemporaryDirectory
    let paths: AppPaths
    let releases = Box<[Channel: Release]>([:])
    let fetcher = FakeFetcher(appName: "SoH")
    let builder: FakeBuilder
    let roms: StoredROMs
    let packager: RecordingPackager
    let launcher = FakeLauncher()
    let primer: FakePrimer?
    let library: Library

    /// `launched`: each Port's container exists as macOS leaves it after a launch. Otherwise there is none yet.
    /// `primed`: the Library has a primer to recreate deleted Data. `signed`: the Library signs with `codesign` rather
    /// than recording what the Packager would sign.
    init(
        launched: Bool = true, primed: Bool = false, signed: Bool = false,
        codesign: URL = URL(filePath: "/usr/bin/codesign")
    ) throws {
        tmp = try TemporaryDirectory()
        paths = AppPaths(root: tmp.url.appending(path: "root"), containers: tmp.url.appending(path: "Containers"))
        primer = primed ? FakePrimer(paths: paths) : nil
        packager = RecordingPackager(paths: paths, primer: primer)
        builder = FakeBuilder(paths: paths, appName: "Starship")
        roms = StoredROMs(store: ROMStore(paths: paths))
        for entry in [soh, starship] where launched {
            let container = paths.container(for: entry.bundleId)
            try FileManager.default.createDirectory(at: paths.data(for: entry.bundleId), withIntermediateDirectories: true)
            try Data("metadata".utf8).write(to: container.appending(path: Self.metadata))
        }
        library = Library(
            paths: paths, catalog: FakeCatalog(recipe: tmp.url.appending(path: "recipe.sh")),
            releases: FakeReleases(latest: releases), fetcher: fetcher, builder: builder, roms: roms.store,
            packager: signed ? PortPackager(paths: paths, primer: primer, signer: Codesign(codesign: codesign)) : packager, launcher: launcher,
            primer: primer)
    }

    func newLibrary() -> Library {
        Library(
            paths: paths, catalog: FakeCatalog(recipe: tmp.url), releases: FakeReleases(latest: releases), fetcher: fetcher,
            builder: builder, roms: roms.store, packager: packager, launcher: launcher)
    }

    func release(_ version: String, channel: Channel = .stable, day: Int) -> Release {
        Release(
            port: soh.id, version: version, tag: "v\(version)", channel: channel,
            published: Date(timeIntervalSince1970: 1_800_000_000 + Double(day) * 86_400),
            asset: ReleaseAsset(name: "SoH-\(version)-Mac.zip", url: URL(string: "https://example.com/\(version).zip")!, size: 1, sha256: "00"))
    }

    func catalog(_ ports: [CatalogEntry]) -> CatalogDocument {
        CatalogDocument(issued: Date(), platforms: [], games: [], roms: [], ports: ports)
    }

    func data(_ entry: CatalogEntry) -> URL { paths.data(for: entry.bundleId) }

    func writeData(_ entry: CatalogEntry, _ name: String, _ contents: String) throws {
        let url = data(entry).appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    func readData(_ entry: CatalogEntry, _ name: String) throws -> String {
        try read(data(entry).appending(path: name))
    }

    func read(_ url: URL) throws -> String {
        try String(decoding: Data(contentsOf: url), as: UTF8.self)
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    /// The labels of the entry's Requirements not Seeded into its Data, as Matching reads them.
    func unseeded(_ entry: CatalogEntry) async -> [String] {
        let installation = await library.installation(for: entry.id)
        let reading = await roms.store.matching([entry], installations: installation.map { [entry.id: $0] } ?? [:])
        return reading[entry.id]?.unseeded.map(\.label) ?? []
    }

    /// The file's inode, which changes when it's replaced.
    func inode(_ url: URL) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.systemFileNumber] as? Int
    }

    /// Where the link at `url` leads, or nil when it's no link.
    func destination(_ url: URL) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: url.path(percentEncoded: false))
    }

    /// File names in a folder, with their case as stored.
    func listing(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
    }

    func setMode(_ mode: Int, of url: URL) throws { try Self.setMode(mode, of: url) }

    /// For a closure a fake keeps, such as `afterPackaging`: one holding the Fixture would keep it, and its temporary
    /// folder, after the test.
    static func setMode(_ mode: Int, of url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path(percentEncoded: false))
    }

    /// The container's protected metadata is never touched.
    func metadataSurvives(_ entry: CatalogEntry) -> Bool {
        (try? read(paths.container(for: entry.bundleId).appending(path: Self.metadata))) == "metadata"
    }
}

extension Result where Failure == any Error {
    fileprivate init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}

@Suite struct ROMUnpackerTests {
    @Test func unpacksInItsOwnWorkspaceWithTheCatalogsRecipe() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ROMUnpackerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileOperations.removeUntrusted(directory) }
        let paths = AppPaths(root: directory, containers: directory.appending(path: "Containers", directoryHint: .isDirectory))
        let builder = FakeBuilder(paths: paths, appName: "Unused")
        builder.unpacked.set(["CARMA": ["DATA/GENERAL.TXT": Data("general".utf8)]])
        let unpacker = ROMUnpacker(catalog: FakeCatalog(recipe: directory.appending(path: "innoextract.sh")), builder: builder, paths: paths)
        let installer = KnownROM(
            sha1: String(repeating: "e", count: 40), game: nil, platform: "dos", name: "Installer", format: "exe",
            unpack: Unpack(recipe: "recipes/innoextract.sh", recipeSHA256: String(repeating: "a", count: 64), yields: []))

        let folders = try await unpacker.unpack(directory.appending(path: "setup.exe"), as: installer, progress: { _ in })

        let workspace: PortID = "unpack-innoextract"
        #expect(folders.map(\.lastPathComponent) == ["CARMA"])
        #expect(builder.unpacks.get.map(\.name) == ["\(installer.sha1).exe"])
        #expect(builder.unpacks.get.map(\.workspace) == [workspace])
        #expect(builder.unpacks.get.map(\.log) == [paths.buildLog(for: workspace)])

        var plain = installer
        plain.unpack = nil
        await #expect(throws: FrontportError.self) { try await unpacker.unpack(directory, as: plain, progress: { _ in }) }
    }
}

/// Nothing an operation is done with stays behind: a download once its Release is installed, a Recipe's output once it's
/// packaged, a failed install's folders once another try is no longer likely, and an uninstalled Port's logs.
@Suite struct LeftoverTests {
    /// What the Fetcher leaves in `Downloads/<port>/`, the asset it verified, or what a cut-short download left.
    @discardableResult
    fileprivate static func download(_ f: Fixture, _ port: PortID, _ name: String) throws -> URL {
        let file = f.paths.downloads(for: port).appending(path: name)
        try FileOperations.createDirectory(file.deletingLastPathComponent())
        try Data("archive".utf8).write(to: file)
        return file
    }

    fileprivate static func write(_ f: Fixture, _ url: URL) throws {
        try FileOperations.createDirectory(url.deletingLastPathComponent())
        try Data("left".utf8).write(to: url)
    }

    @Test func anInstalledReleaseKeepsNoDownload() async throws {
        let f = try Fixture()
        f.releases.set([.stable: f.release("1.0", day: 1)])
        try Self.download(f, soh.id, "SoH-1.0-Mac.zip")
        try Self.download(f, soh.id, ".SoH-0.9-Mac.zip.1234.part")
        _ = try await f.library.install(soh, channel: .stable, progress: noProgress)
        #expect(!f.exists(f.paths.downloads(for: soh.id)))

        try Self.download(f, soh.id, "SoH-1.1-Mac.zip")
        f.releases.set([.stable: f.release("1.1", day: 2)])
        _ = try await f.library.update(soh, to: nil, progress: noProgress)
        #expect(!f.exists(f.paths.downloads(for: soh.id)))
    }

    @Test func aFailedUpdateKeepsItsDownloadForAnotherTry() async throws {
        let f = try Fixture()
        f.releases.set([.stable: f.release("1.0", day: 1)])
        _ = try await f.library.install(soh, channel: .stable, progress: noProgress)
        let download = try Self.download(f, soh.id, "SoH-1.1-Mac.zip")
        f.releases.set([.stable: f.release("1.1", day: 2)])
        f.launcher.runningPorts.set([soh.id])
        await #expect(throws: FrontportError.running(soh.id)) { try await f.library.update(soh, to: nil, progress: noProgress) }
        #expect(f.exists(download))
    }

    @Test func aSourceBuildLeavesNoOutputOnceItsProductIsTaken() async throws {
        let f = try Fixture()
        try await f.roms.add("bbb")
        f.releases.set([.stable: LibraryBuildAssetsTests.release("2.0.0")])
        let installation = try await f.library.install(starship, channel: .stable, progress: noProgress)
        #expect(!f.exists(f.paths.buildOutput(for: starship.id)))
        #expect(try f.read(f.paths.app(for: installation).appending(path: sf64)) == "assets from bbb")

        // An extra remakes the Build Assets, and an update builds again.
        try await f.roms.add("ccc")
        try await f.library.applyROMs(to: starship, progress: noProgress)
        #expect(f.builder.builds.get.count == 2)
        #expect(!f.exists(f.paths.buildOutput(for: starship.id)))
        #expect(try f.read(f.paths.app(for: installation).appending(path: sf64)) == "assets from bbb,ccc")
        #expect(await f.library.installation(for: starship.id)?.buildAssets == BuildAssetsRecord(roms: ["bbb", "ccc"], format: "1"))
        f.releases.set([.stable: LibraryBuildAssetsTests.release("2.0.1")])
        _ = try await f.library.update(starship, to: nil, progress: noProgress)
        #expect(!f.exists(f.paths.buildOutput(for: starship.id)))
    }

    /// The build folder, download and build log stay for another try, and the next launch removes them; the
    /// `Library/<port>/` folder the install started holds nothing and goes at once.
    @Test func aFailedFirstInstallLeavesOnlyWhatAnotherTryReuses() async throws {
        let f = try Fixture()
        try await f.roms.add("bbb")
        f.releases.set([.stable: LibraryBuildAssetsTests.release("2.0.0")])
        let source = f.paths.buildSource(for: starship.id).appending(path: "tree")
        try Self.write(f, source)
        try Self.write(f, f.paths.buildLog(for: starship.id))
        try Self.download(f, starship.id, "unused.zip")
        f.builder.linkedApp.set(try makeApp(named: "Elsewhere", version: "x", in: f.tmp.url))

        await #expect(throws: FrontportError.self) {
            try await f.library.install(starship, channel: .stable, progress: noProgress)
        }

        #expect(!f.exists(f.paths.library(for: starship.id)))
        #expect(!f.exists(f.paths.buildOutput(for: starship.id)))
        #expect(f.exists(source) && f.exists(f.paths.buildLog(for: starship.id)))
        #expect(f.exists(f.paths.downloads(for: starship.id)))

        await f.library.removeLeftovers()
        for folder in [f.paths.builds(for: starship.id), f.paths.logs(for: starship.id), f.paths.downloads(for: starship.id)] {
            #expect(!f.exists(folder), "\(folder.lastPathComponent)")
        }
    }

    /// At launch nothing is under way, so any `staging/` and download are what was cut short. An installed Port's build
    /// folder and logs stay, and so do an unpack Recipe's workspace and the folders of a record that can't be read.
    @Test func leftoversAtLaunchSpareWhatInstallationsUse() async throws {
        let f = try Fixture()
        try await f.roms.add("bbb")
        f.releases.set([.stable: LibraryBuildAssetsTests.release("2.0.0")])
        let installation = try await f.library.install(starship, channel: .stable, progress: noProgress)
        try Self.write(f, f.paths.staging(for: starship.id).appending(path: "Starship.app/Contents/Info.plist"))
        try f.setMode(0o555, of: f.paths.staging(for: starship.id).appending(path: "Starship.app/Contents"))
        try Self.download(f, starship.id, "unused.zip")
        let kept = [
            f.paths.buildSource(for: starship.id).appending(path: "tree"), f.paths.buildLog(for: starship.id),
            f.paths.buildSource(for: "unpack-innoextract").appending(path: "innoextract"),
            f.paths.buildLog(for: "unpack-innoextract"),
            f.paths.installRecord(for: "unreadable"), f.paths.buildSource(for: "unreadable").appending(path: "tree"),
        ]
        for file in kept { try Self.write(f, file) }
        try Self.write(f, f.paths.library(for: "abandoned").appending(path: "staging/Abandoned.app/Contents/Info.plist"))
        try Self.write(f, f.paths.logs(for: "uninstalled").appending(path: "20261024-101146-373-5089.log"))
        try Self.write(f, f.paths.builds.appending(path: "Not A Port/tree"))

        await f.library.removeLeftovers()

        #expect(!f.exists(f.paths.staging(for: starship.id)))
        #expect(!f.exists(f.paths.downloads(for: starship.id)))
        #expect(!f.exists(f.paths.library(for: "abandoned")))
        #expect(!f.exists(f.paths.logs(for: "uninstalled")))
        for file in kept { #expect(f.exists(file), "\(file.path(percentEncoded: false))") }
        #expect(f.exists(f.paths.builds.appending(path: "Not A Port/tree")), "only what a Port's id names is touched")
        #expect(try f.read(f.paths.app(for: installation).appending(path: sf64)) == "assets from bbb")
        #expect(await f.newLibrary().installations() == [installation])
    }

    @Test func uninstallRemovesTheLogsAndDownloads() async throws {
        let f = try Fixture()
        f.releases.set([.stable: f.release("1.0", day: 1)])
        _ = try await f.library.install(soh, channel: .stable, progress: noProgress)
        try Self.write(f, f.paths.runLog("20261024-101146-373-5089", for: soh.id))
        try Self.download(f, soh.id, "SoH-1.1-Mac.zip")
        try f.writeData(soh, "save.dat", "progress")

        try await f.library.uninstall(soh)

        #expect(!f.exists(f.paths.logs(for: soh.id)))
        #expect(!f.exists(f.paths.downloads(for: soh.id)))
        #expect(try f.readData(soh, "save.dat") == "progress")
    }

    /// Only the build folder goes, read-only folders and all, without following a link the Recipe left there.
    @Test func removingTheBuildFolderKeepsTheInstallation() async throws {
        let f = try Fixture()
        try await f.roms.add("bbb")
        f.releases.set([.stable: LibraryBuildAssetsTests.release("2.0.0")])
        let installation = try await f.library.install(starship, channel: .stable, progress: noProgress)
        try Self.write(f, f.paths.buildSource(for: starship.id).appending(path: "tree"))
        try f.setMode(0o555, of: f.paths.buildSource(for: starship.id))
        let outside = f.tmp.url.appending(path: "outside")
        try Self.write(f, outside)
        try FileManager.default.createSymbolicLink(
            at: f.paths.builds(for: starship.id).appending(path: "link"), withDestinationURL: outside)

        try await f.library.removeBuildFolder(starship)

        #expect(!f.exists(f.paths.builds(for: starship.id)))
        #expect(f.exists(outside))
        #expect(try f.read(f.paths.app(for: installation).appending(path: sf64)) == "assets from bbb")
        #expect(await f.newLibrary().installations() == [installation])
    }

    /// A read-only folder in staging is removed with it, so the next try can start.
    @Test func aFailedInstallWithAReadOnlyFolderDoesNotBlockTheNext() async throws {
        let f = try Fixture()
        f.releases.set([.stable: f.release("1.0", day: 1)])
        let staged = f.paths.staging(for: soh.id).appending(path: "SoH.app")
        f.packager.afterPackaging.set { try Fixture.setMode(0o555, of: staged) }

        await #expect(throws: FrontportError.self) { try await f.library.install(soh, channel: .stable, progress: noProgress) }
        #expect(!f.exists(f.paths.library(for: soh.id)))

        f.packager.afterPackaging.set(nil)
        _ = try await f.library.install(soh, channel: .stable, progress: noProgress)
        #expect(!f.exists(f.paths.staging(for: soh.id)))
    }

    /// Build Assets a Recipe left with a read-only folder pass through staging on every update, as the ones replaced and
    /// as the previous Release's, and leave with it.
    @Test func readOnlyBuildAssetsDoNotBlockTheNextUpdate() async throws {
        let f = try Fixture()
        f.builder.assetsFolder.set(true)
        try await f.roms.add("bbb")
        f.releases.set([.stable: LibraryBuildAssetsTests.release("2.0.0")])
        _ = try await f.library.install(starship, channel: .stable, progress: noProgress)
        let folder = f.paths.assets(for: starship.id).appending(path: "read-only")
        try Self.write(f, folder.appending(path: "file"))
        try f.setMode(0o555, of: folder)

        for version in ["2.0.1", "2.0.2", "2.0.3"] {
            f.releases.set([.stable: LibraryBuildAssetsTests.release(version)])
            let updated = try await f.library.update(starship, to: nil, progress: noProgress)
            #expect(updated.release.version == version)
            #expect(!f.exists(f.paths.staging(for: starship.id)))
        }
        try await f.library.uninstall(starship)
        #expect(!f.exists(f.paths.library(for: starship.id)))
    }

    /// A container made only for the install's Redirects goes with it; one that was there before stays, Seeded ROMs
    /// and all.
    @Test func aFailedFirstInstallRemovesOnlyTheContainerItMade() async throws {
        for before in [false, true] {
            let f = try Fixture(launched: false)
            f.releases.set([.stable: f.release("1.0", day: 1)])
            if before { try f.writeData(soh, "roms/aaa.z64", "rom aaa") }
            let staged = f.paths.staging(for: soh.id).appending(path: "SoH.app")
            f.packager.afterPackaging.set { try Fixture.setMode(0o555, of: staged) }

            await #expect(throws: FrontportError.self) {
                try await f.library.install(RedirectTests.redirected, channel: .stable, progress: noProgress)
            }

            #expect(f.exists(f.paths.container(for: soh.bundleId)) == before)
            if before { #expect(try f.readData(soh, "roms/aaa.z64") == "rom aaa") }
            #expect(!f.exists(f.paths.library(for: soh.id)))
        }
    }

    /// macOS has never run anything with the bundle ID there, so Frontport made the container and removes it whole; once
    /// macOS manages it, the container and its metadata stay.
    @Test func deleteDataRemovesAContainerMacOSDoesNotManage() async throws {
        let f = try Fixture(launched: false)
        try f.writeData(soh, "roms/aaa.z64", "rom aaa")

        try await f.library.deleteData(soh)

        #expect(!f.exists(f.paths.container(for: soh.bundleId)))

        // Installed, the Redirects' folders come back at once, in a container Frontport makes again.
        f.releases.set([.stable: f.release("1.0", day: 1)])
        _ = try await f.library.install(RedirectTests.redirected, channel: .stable, progress: noProgress)
        try await f.library.deleteData(RedirectTests.redirected)
        #expect(FileOperations.isDirectory(RedirectTests.target(f)))
    }

    @Test func pruningRemovesSnapshotsWithReadOnlyFoldersWhole() async throws {
        let f = try Fixture()
        f.releases.set([.stable: f.release("1.0", day: 1)])
        _ = try await f.library.install(soh, channel: .stable, progress: noProgress)
        try f.writeData(soh, "ro/file", "x")
        try f.setMode(0o555, of: f.data(soh).appending(path: "ro"))
        defer { try? f.setMode(0o755, of: f.data(soh).appending(path: "ro")) }
        // What a removal that stopped part way left before: a Snapshot folder without its record.
        try Self.write(f, f.paths.snapshotData("20261001-000000-000-dead", for: soh.id).appending(path: "ro/file"))
        try f.setMode(0o555, of: f.paths.snapshotData("20261001-000000-000-dead", for: soh.id).appending(path: "ro"))

        for (index, next) in ["1.1", "1.2", "1.3", "1.4"].enumerated() {
            f.releases.set([.stable: f.release(next, day: index + 2)])
            _ = try await f.library.update(soh, to: nil, progress: noProgress)
        }

        let listed = await f.library.snapshots(for: soh.id)
        #expect(listed.map(\.target) == ["1.4", "1.3", "1.2"])
        #expect(try Set(f.listing(f.paths.snapshots(for: soh.id))) == Set(listed.map(\.id)))

        try await f.library.deleteData(soh)
        #expect(!f.exists(f.data(soh)) && !f.exists(f.paths.snapshots(for: soh.id)))
    }

    @Test func discardingAnUnpackRemovesWhatTheInstallerHeld() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ROMUnpackerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileOperations.removeUntrusted(directory) }
        let paths = AppPaths(root: directory, containers: directory.appending(path: "Containers", directoryHint: .isDirectory))
        let builder = FakeBuilder(paths: paths, appName: "Unused")
        builder.unpacked.set(["CARMA": ["DATA/GENERAL.TXT": Data("general".utf8)], "__support": ["dosbox.exe": Data()]])
        let unpacker = ROMUnpacker(catalog: FakeCatalog(recipe: directory.appending(path: "innoextract.sh")), builder: builder, paths: paths)
        let installer = KnownROM(
            sha1: String(repeating: "e", count: 40), game: nil, platform: "dos", name: "Installer", format: "exe",
            unpack: Unpack(recipe: "recipes/innoextract.sh", recipeSHA256: String(repeating: "a", count: 64), yields: []))
        let source = paths.buildSource(for: "unpack-innoextract").appending(path: "innoextract")
        try FileOperations.createDirectory(source.deletingLastPathComponent())
        try Data("tool".utf8).write(to: source)

        let folders = try await unpacker.unpack(directory.appending(path: "setup.exe"), as: installer, progress: { _ in })
        #expect(folders.count == 2)
        unpacker.discard(installer)

        #expect(!FileManager.default.fileExists(atPath: paths.buildOutput(for: "unpack-innoextract").path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: source.path(percentEncoded: false)), "the unpacker stays for the next installer")
    }
}
