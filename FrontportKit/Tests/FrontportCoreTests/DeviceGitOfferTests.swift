import Foundation
import Testing
@testable import FrontportCore

/// What an Installation of a source-built iOS version is offered: the signed Catalog decides, by the ref it pins for the
/// Channel and the iOS Recipe it pins, never by comparing commit hashes or GitHub's dates.
@Suite struct DeviceGitOfferTests {
    static let old = "f" + String(repeating: "1", count: 39)
    static let new = "0" + String(repeating: "a", count: 39)
    static let recipe = String(repeating: "b", count: 64)

    /// Tiny's iOS version, built by its Recipe from the ref the Catalog pins on stable.
    static func entry(pinning ref: String, recipe: String = recipe) -> CatalogEntry {
        var entry = DeviceInstallationTests.installation(profileExpires: .distantFuture, certificateExpires: .distantFuture).entry
        entry.ios?.releases = .git(GitSource(
            repo: "tests/tiny", refs: [.stable: ref, .nightly: "main"], recipe: "recipes/tiny-ios.sh", recipeSHA256: recipe))
        return entry
    }

    static func version(pinning ref: String, recipe: String = recipe) -> IOSVersion {
        IOSVersion(entry(pinning: ref, recipe: recipe))!
    }

    /// The pinned ref's Release as Releases makes it offline: no dates, the hash's first 7 characters as its version.
    static func release(_ ref: String, created: Date? = nil, channel: Channel = .stable) -> Release {
        Release(port: "tiny", version: String(ref.prefix(7)), tag: ref, channel: channel, created: created)
    }

    static func installation(at ref: String, created: Date? = nil, recipe: String? = recipe) -> DeviceInstallation {
        var installation = DeviceInstallationTests.installation(profileExpires: .distantFuture, certificateExpires: .distantFuture)
        installation.release = release(ref, created: created)
        installation.recipeSHA256 = recipe
        installation.entry = entry(pinning: ref)
        return installation
    }

    @Test func aNewlyPinnedCommitIsAnUpdateWhateverItsHash() {
        let newest = Self.release(Self.new)
        #expect(!newest.isNewer(than: Self.release(Self.old)), "as hashes, 0aaaaaa sorts before f111111")

        #expect(Self.version(pinning: Self.new).update(for: Self.installation(at: Self.old), newest: newest) == newest)
        #expect(Self.version(pinning: Self.new).isForward(Self.installation(at: Self.old), to: newest))
    }

    /// The Catalog going back to an older commit is an Update too, whatever GitHub's dates say, as on the Mac.
    @Test func aCatalogRollbackIsAnUpdate() {
        let installed = Self.installation(at: Self.new, created: Date(timeIntervalSince1970: 1_800_000_000))
        let older = Self.release(Self.old, created: Date(timeIntervalSince1970: 1_700_000_000))

        #expect(Self.version(pinning: Self.old).update(for: installed, newest: older) == older)
    }

    /// Only the ref pinned for the Channel, and not the one installed with the same Recipe.
    @Test func onlyThePinnedRefMovesItForward() {
        let installed = Self.installation(at: Self.old)
        #expect(Self.version(pinning: Self.old).update(for: installed, newest: Self.release(Self.old)) == nil)
        let newer = Self.release(Self.new, created: .distantFuture)
        #expect(Self.version(pinning: Self.old).update(for: installed, newest: newer) == nil,
            "a ref the Catalog doesn't pin, however new")
        #expect(!Self.version(pinning: Self.old).isForward(installed, to: newer))
        // Another Channel's pinned ref is installed only when asked for, never offered.
        let nightly = Self.release("main", channel: .nightly)
        #expect(Self.version(pinning: Self.old).isForward(installed, to: nightly))
        #expect(Self.version(pinning: Self.old).update(for: installed, newest: nightly) == nil)
    }

    /// A Recipe the Catalog changed at the same ref is an Update, and so is one from a record that didn't keep it.
    @Test func aNewRecipeAtTheSameRefIsAnUpdate() {
        let newest = Self.release(Self.old)
        let changed = Self.version(pinning: Self.old, recipe: String(repeating: "c", count: 64))

        #expect(changed.update(for: Self.installation(at: Self.old), newest: newest) == newest)
        #expect(Self.version(pinning: Self.old).update(for: Self.installation(at: Self.old, recipe: nil), newest: newest)
            == newest)
    }

    /// The prepared app is stale once the Catalog changes the Recipe, though the ref stays.
    @Test func aPreparedAppIsForItsRecipe() {
        let release = Self.release(Self.old)
        let prepared = PreparedDeviceApp(
            port: "tiny", release: release, channel: .stable, appName: "Tiny.app", minimumOS: "15.0", families: [1, 2],
            recipeSHA256: Self.recipe)

        #expect(prepared.isCurrent(for: Self.version(pinning: Self.old), latest: release))
        #expect(!prepared.isCurrent(for: Self.version(pinning: Self.old, recipe: String(repeating: "c", count: 64)), latest: release))
        #expect(!prepared.isFor(release, on: .stable, recipeSHA256: nil), "nor taken for a download")
    }

    /// Records written before Frontport kept the Recipe still read, as made by none: the next build replaces them.
    @Test func recordsFromBeforeTheRecipeWasKeptStillRead() throws {
        let installation = try Self.withoutRecipe(Self.installation(at: Self.old))
        #expect(installation.recipeSHA256 == nil && installation.release.tag == Self.old)

        let prepared = try Self.withoutRecipe(PreparedDeviceApp(
            port: "tiny", release: Self.release(Self.old), channel: .stable, appName: "Tiny.app", minimumOS: "15.0",
            families: [1], recipeSHA256: Self.recipe))
        #expect(prepared.recipeSHA256 == nil)
        #expect(!prepared.isCurrent(for: Self.version(pinning: Self.old), latest: Self.release(Self.old)))
    }

    /// `value` encoded, then read back without its `recipeSHA256`, as an older Frontport wrote it.
    private static func withoutRecipe<T: Codable>(_ value: T) throws -> T {
        var object = try #require(try JSONSerialization.jsonObject(with: JSON.encode(value)) as? [String: Any])
        #expect(object.removeValue(forKey: "recipeSHA256") != nil)
        return try JSON.decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
