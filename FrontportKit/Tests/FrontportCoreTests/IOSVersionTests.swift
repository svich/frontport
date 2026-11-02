import Foundation
import Testing
@testable import FrontportCore

/// A Port's iOS version: what it offers, what it Seeds, what Seeding goes by once the Catalog drops it, and the entry it
/// gives Releases, the Fetcher and the Builder.
@Suite struct IOSVersionTests {
    /// Tiny on the iPhone, on Release 1.0.
    static let installed = DeviceInstallationTests.installation(profileExpires: .distantFuture, certificateExpires: .distantFuture)
    static let entry = installed.entry
    static let version = IOSVersion(entry)!

    static func release(_ version: String, day: Double, channel: Channel = .stable) -> Release {
        Release(
            port: "tiny", version: version, tag: "v\(version)", channel: channel,
            published: Date(timeIntervalSince1970: 1_800_000_000 + day * 86_400),
            asset: ReleaseAsset(name: "Tiny-\(version).ipa", url: URL(string: "https://example.com/Tiny.ipa")!, size: 3, sha256: "0"))
    }

    @Test func onlyAnEntryWithIOSHasOne() throws {
        #expect(Self.version.entry == Self.entry && Self.version.id == "tiny")
        #expect(try IOSVersion(of: Self.entry) == Self.version)
        var mac = Self.entry
        mac.ios = nil
        #expect(IOSVersion(mac) == nil)
        #expect(throws: FrontportError.notForDevice("Tiny has no iOS version.")) { try IOSVersion(of: mac) }
    }

    @Test func itsOwnChannels() throws {
        var entry = Self.entry
        entry.ios?.releases = .githubRelease(GitHubReleaseSource(repo: "tests/tiny", asset: "*.ipa", channels: [.nightly, .stable]))
        let version = try IOSVersion(of: entry)
        #expect(version.channels == [.nightly, .stable] && version.defaultChannel == .nightly)
        #expect(Self.version.defaultChannel == .stable, "whatever the Mac's are")
        #expect(!version.isSourceBuilt && version.recipeSHA256 == nil)
    }

    // MARK: Offered

    /// Its own Blocks apply, by its own version; the Mac's don't. A Channel it doesn't have offers nothing.
    @Test func offersAReleaseOnItsChannelsThatItDoesntBlock() throws {
        let release = Self.release("2.0", day: 2)
        #expect(Self.version.offers(release, on: .stable))

        var blocked = Self.entry
        blocked.ios?.blocked = [Block(release: "2.0", severity: .warn, reason: "Crashes on load.")]
        #expect(throws: FrontportError.blocked("tiny", release: "2.0", reason: "Crashes on load.")) {
            try IOSVersion(of: blocked).check(release, on: .stable)
        }
        var macBlocked = Self.entry
        macBlocked.blocked = [Block(release: "2.0", severity: .stop, reason: "Mac only.")]
        #expect(try IOSVersion(of: macBlocked).offers(release, on: .stable))

        #expect(throws: FrontportError.noRelease("tiny", .nightly)) { try Self.version.check(release, on: .nightly) }
        #expect(!Self.version.offers(release, on: .nightly))
    }

    // MARK: Update

    @Test func anUpdateIsANewerReleaseOnItsChannel() {
        let newer = Self.release("2.0", day: 2)
        #expect(Self.version.update(for: Self.installed, newest: newer) == newer)
        #expect(Self.version.isForward(Self.installed, to: newer))
    }

    @Test func neverTheSameOrAnOlderOne() {
        var installed = Self.installed
        installed.release = Self.release("2.0", day: 2)
        #expect(Self.version.update(for: installed, newest: Self.release("2.0", day: 2)) == nil)
        #expect(Self.version.update(for: installed, newest: Self.release("1.0", day: 1)) == nil)
        #expect(!Self.version.isForward(installed, to: Self.release("1.0", day: 1)))
        #expect(Self.version.update(for: installed, newest: nil) == nil)
    }

    @Test func neverOneItDoesntOffer() throws {
        var blocked = Self.entry
        blocked.ios?.blocked = [Block(release: "2.0", severity: .warn, reason: "Crashes on load.")]
        #expect(try IOSVersion(of: blocked).update(for: Self.installed, newest: Self.release("2.0", day: 2)) == nil)
        #expect(Self.version.update(for: Self.installed, newest: Self.release("2.0", day: 2, channel: .nightly)) == nil)
    }

    // MARK: Seeding

    /// The Catalog's entry while it has an iOS version, else the record's; one for another Port goes as it is.
    @Test func seedsByTheListedEntryWhileItHasAnIOSVersion() {
        let installation = Self.installed
        var listed = installation.entry
        listed.name = "Tiny, listed"
        #expect(IOSVersion(seeding: installation, listed: listed)?.entry == listed)
        #expect(IOSVersion(seeding: installation, listed: nil)?.entry == installation.entry)
        listed.ios = nil
        #expect(IOSVersion(seeding: installation, listed: listed)?.entry == installation.entry)
        listed.id = "other"
        #expect(IOSVersion(seeding: installation, listed: listed) == nil)
        listed.ios = installation.entry.ios
        #expect(IOSVersion(seeding: installation, listed: listed)?.entry == listed)
    }

    /// Only Runtime Requirements with an iOS seedPath, which they take; a Build-Stage one goes to the Builder alone.
    @Test func seedsTheRuntimeRequirementsWithAnIOSSeedPath() throws {
        var entry = try DeviceCatalogTests.entry()
        entry.requirements.append(Requirement(label: "Extras", stage: .runtime, oneOf: [DeviceCatalogTests.sf64]))
        entry.requirements.append(Requirement(label: "Star Fox 64", stage: .build, oneOf: [DeviceCatalogTests.sf64]))
        entry.ios?.seedPaths = ["Documents", nil, nil]
        entry.ios?.buildAssets = BuildAssetsSpec(path: "sf64.o2r", format: "1")
        let version = try IOSVersion(of: entry)
        #expect(version.requirements == [
            Requirement(label: "Fallout", stage: .runtime, oneOf: [DeviceCatalogTests.fallout], seedPath: "Documents")
        ])
        #expect(version.view.requirements.map(\.label) == ["Fallout", "Star Fox 64"])
    }

    // MARK: View

    @Test func theViewSwapsInTheIOSVersionsFields() throws {
        let entry = try DeviceCatalogTests.entry()
        let view = try IOSVersion(of: entry).view
        #expect(view.id == entry.id)
        #expect(view.name == entry.name)
        #expect(view.game == entry.game)
        #expect(view.releases == entry.ios?.releases)
        #expect(view.requirements == [
            Requirement(label: "Fallout", stage: .runtime, oneOf: [DeviceCatalogTests.fallout], seedPath: "Documents")
        ])
        #expect(view.strip == ["Settings.bundle"])
        #expect(view.blocked == entry.ios?.blocked)
        #expect(view.buildAssets == nil)
        #expect(view.redirects.isEmpty)
        #expect(view.launch == LaunchSpec())
        #expect(view.codeSigning == CodeSigning())
        #expect(view.ios == nil)
        #expect(view.bundleId != entry.bundleId)
        #expect(view.isSourceBuilt)
    }

    @Test func theViewKeepsTheCatalogItCameFrom() throws {
        var entry = try DeviceCatalogTests.entry()
        entry.catalog = URL(string: "https://example.org/ports/")
        #expect(try IOSVersion(of: entry).view.catalog == entry.catalog)
    }

    /// A Runtime Requirement without an iOS seedPath, and a Build-Stage one without iOS Build Assets, aren't the iOS
    /// version's.
    @Test func theViewLeavesOutRequirementsTheIOSVersionDoesntUse() throws {
        var entry = try DeviceCatalogTests.entry()
        entry.requirements.append(Requirement(label: "Star Fox 64", stage: .build, oneOf: [DeviceCatalogTests.sf64]))
        entry.ios?.seedPaths = [nil, nil]
        #expect(try IOSVersion(of: entry).view.requirements == [])

        entry.ios?.buildAssets = BuildAssetsSpec(path: "sf64.o2r", format: "1")
        let view = try IOSVersion(of: entry).view
        #expect(view.requirements.map(\.label) == ["Star Fox 64"])
        #expect(view.requirements[0].seedPath == nil)
        #expect(view.buildAssets == entry.ios?.buildAssets)

        // Too few seedPaths, which the lint refuses, leave the rest out rather than trap.
        entry.ios?.seedPaths = []
        #expect(try IOSVersion(of: entry).view.requirements.map(\.label) == ["Star Fox 64"])

        // Only an iOS Recipe makes Build Assets, so a prebuilt iOS version takes no Build-Stage ROM.
        entry.ios?.releases = .githubRelease(GitHubReleaseSource(repo: "alexbatalov/fallout1-ce", asset: "fallout-ce-ios.ipa"))
        #expect(try IOSVersion(of: entry).view.requirements == [])
    }

    /// So the view can't reach the Library or Seeding on the Mac, which would write the Mac's container, nor be taken
    /// for the bundle ID a Device's app has.
    @Test func theViewFailsTheIdentityCheck() throws {
        let entry = try DeviceCatalogTests.entry()
        try entry.checkIdentity()
        let view = try IOSVersion(of: entry).view
        #expect(throws: FrontportError.self) { try view.checkIdentity() }
        #expect(view.bundleId != entry.id.deviceBundleID(team: DeviceInstallationTests.team))
    }
}
