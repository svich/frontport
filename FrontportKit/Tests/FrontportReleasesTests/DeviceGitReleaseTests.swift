import Foundation
import FrontportCore
import Testing

@testable import FrontportReleases

/// An iOS version built from an iOS Recipe: its Release is its pinned ref, as a source-built Mac Port's is, so its
/// version shows on Install on iPhone or iPad… and the store page without GitHub.
@Suite struct DeviceGitReleaseTests {
    static let commit = "0609bcfd0ec40ff0571d0f57fab2821eb461dc8b"

    /// Like Fallout CE: a pinned commit for the Mac and the same one for its iOS version, from another Recipe.
    static let entry = CatalogEntry(
        id: "fallout-ce", name: "Fallout Community Edition", kind: .decomp, game: "fallout", developer: "alexbatalov",
        summary: "", description: "", source: URL(string: "https://github.com/alexbatalov/fallout1-ce")!,
        bundleId: "dev.frontport.port.fallout-ce",
        releases: .git(GitSource(
            repo: "alexbatalov/fallout1-ce", refs: [.stable: commit], recipe: "recipes/fallout-ce.sh",
            recipeSHA256: String(repeating: "a", count: 64))),
        ios: IOSSpec(
            releases: .git(GitSource(
                repo: "alexbatalov/fallout1-ce", refs: [.stable: commit], recipe: "recipes/fallout-ce-ios.sh",
                recipeSHA256: String(repeating: "b", count: 64))),
            seedPaths: ["Documents"]))

    @Test func theIOSVersionsReleaseIsItsPinnedRefOffline() async throws {
        let temp = try TemporaryDirectory()
        let (host, _) = StubURLProtocol.host { _ in StubResponse(error: URLError(.notConnectedToInternet)) }
        let releases = GitHubReleases(
            cache: temp.url.appending(path: "releases-cache"), session: StubURLProtocol.session(),
            api: URL(string: "https://\(host)")!)
        let version = try IOSVersion(of: Self.entry)

        let release = try #require(try await releases.latest(for: version.view, channel: .stable))

        #expect(release.port == "fallout-ce" && release.tag == Self.commit && release.version == "0609bcf")
        #expect(release.asset == nil && release.channel == .stable)
        let prepared = PreparedDeviceApp(
            port: "fallout-ce", release: release, channel: .stable, appName: "fallout-ce.app", minimumOS: "15.0",
            families: [1, 2], recipeSHA256: String(repeating: "b", count: 64))
        #expect(prepared.isCurrent(for: version, latest: release), "so Install asks about it at once")
        var moved = release
        moved.tag = String(repeating: "c", count: 40)
        #expect(!prepared.isCurrent(for: version, latest: moved), "until the Catalog pins another commit")
    }
}
