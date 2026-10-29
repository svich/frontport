import Foundation
import FrontportCore
import Testing

@testable import FrontportReleases

/// A GitHub release object as the API returns it, trimmed to what matters.
private func githubRelease(
    _ tag: String, name: String? = nil, prerelease: Bool = false, draft: Bool = false, created: String,
    published: String? = nil, body: String = "", assets: [(name: String, digest: String?)]
) -> [String: Any] {
    var object: [String: Any] = [
        "tag_name": tag, "name": name ?? tag, "prerelease": prerelease, "draft": draft, "created_at": created,
        "html_url": "https://github.com/HarbourMasters/Shipwright/releases/tag/\(tag)", "body": body,
        "assets": assets.enumerated().map { index, asset -> [String: Any] in
            var item: [String: Any] = [
                "name": asset.name, "size": 1000 + index,
                "browser_download_url": "https://github.com/HarbourMasters/Shipwright/releases/download/\(tag)/\(asset.name)",
            ]
            item["digest"] = asset.digest
            return item
        },
    ]
    object["published_at"] = draft ? NSNull() : (published ?? created)
    return object
}

private let digestA = String(repeating: "a", count: 64)
private let digestB = String(repeating: "b", count: 64)

/// Shaped like Shipwright: full releases, a prerelease, a draft and one without a Mac build.
private var shipwrightList: [[String: Any]] {
    [
        githubRelease(
            "9.3.1", name: "Dewey Bravo 9.3.1", created: "2026-10-18T21:00:00Z", published: "2026-10-18T21:06:27Z",
            body: "## Changes\r\nQuiet patch release.",
            assets: [("SoH-Dewey-Bravo-Mac.zip", "sha256:\(digestA.uppercased())"), ("SoH-Dewey-Bravo-Win64.zip", "sha256:\(digestB)")]),
        githubRelease("9.4.0-rc1", prerelease: true, created: "2026-10-12T00:00:00Z", assets: [("SoH-Eagle-RC-Mac.zip", "sha256:\(digestB)")]),
        githubRelease("9.4.0-draft", draft: true, created: "2026-10-20T00:00:00Z", assets: [("SoH-Draft-Mac.zip", "sha256:\(digestB)")]),
        githubRelease("9.3.0", created: "2026-10-06T00:00:00Z", assets: [("SoH-Dewey-Alpha-Win64.zip", "sha256:\(digestB)")]),
        githubRelease("9.2.3", created: "2026-04-14T00:00:00Z", assets: [("SoH-Ackbar-Delta-Mac.zip", nil)]),
    ]
}

private let shipwrightSource = GitHubReleaseSource(
    repo: "HarbourMasters/Shipwright", asset: "SoH-*-Mac.zip", channels: [.stable, .nightly])

private struct Harness {
    let temp: TemporaryDirectory
    let host: String
    let requests: RequestLog
    let releases: GitHubReleases

    init(token: String? = nil, _ handler: @escaping StubURLProtocol.Handler) throws {
        temp = try TemporaryDirectory()
        (host, requests) = StubURLProtocol.host(handler)
        releases = GitHubReleases(
            cache: temp.url.appending(path: "releases-cache"), token: token, session: StubURLProtocol.session(),
            api: URL(string: "https://\(host)")!)
    }

    /// Another instance on the same cache folder, as after relaunching, with GitHub now answering `handler`.
    func relaunched(_ handler: @escaping StubURLProtocol.Handler) -> (GitHubReleases, RequestLog) {
        let log = StubURLProtocol.route(host, handler)
        let releases = GitHubReleases(
            cache: temp.url.appending(path: "releases-cache"), session: StubURLProtocol.session(),
            api: URL(string: "https://\(host)")!)
        return (releases, log)
    }
}

@Suite struct GitHubReleasesTests {
    // MARK: Channels and filtering

    @Test func stableTakesFullReleasesWithAMatchingAsset() async throws {
        let harness = try Harness { _ in .json(shipwrightList) }
        let releases = try await harness.releases.releases(for: makeEntry(.githubRelease(shipwrightSource)), channel: .stable)

        #expect(releases.map(\.tag) == ["9.3.1", "9.2.3"])
        let newest = try #require(releases.first)
        #expect(newest.port == "shipwright")
        #expect(newest.version == "9.3.1")
        #expect(newest.title == "Dewey Bravo 9.3.1")
        #expect(newest.channel == .stable)
        #expect(newest.published == date("2026-10-18T21:06:27Z"))
        #expect(newest.notes == "## Changes\r\nQuiet patch release.")
        #expect(newest.notesURL == URL(string: "https://github.com/HarbourMasters/Shipwright/releases/tag/9.3.1"))
        #expect(newest.asset == ReleaseAsset(
            name: "SoH-Dewey-Bravo-Mac.zip",
            url: URL(string: "https://github.com/HarbourMasters/Shipwright/releases/download/9.3.1/SoH-Dewey-Bravo-Mac.zip")!,
            size: 1000, sha256: digestA))
        #expect(releases[1].asset?.sha256 == nil, "older assets have no digest")
    }

    @Test func otherChannelsIncludePrereleases() async throws {
        let harness = try Harness { _ in .json(shipwrightList) }
        let releases = try await harness.releases.releases(for: makeEntry(.githubRelease(shipwrightSource)), channel: .nightly)
        #expect(releases.map(\.tag) == ["9.3.1", "9.4.0-rc1", "9.2.3"])
        #expect(releases.allSatisfy { $0.channel == .nightly })
    }

    @Test func tagGlobsDecideChannels() async throws {
        let list = jsonData([
            githubRelease("nightly-2026-10-20", created: "2026-10-20T00:00:00Z", assets: [("Port-macOS.zip", "sha256:\(digestA)")]),
            githubRelease("v2.1.0-beta", prerelease: true, created: "2026-10-10T00:00:00Z", assets: [("Port-macOS.zip", "sha256:\(digestA)")]),
            githubRelease("v2.0.0", created: "2026-09-01T00:00:00Z", assets: [("Port-macOS.zip", "sha256:\(digestA)")]),
        ])
        let source = GitHubReleaseSource(
            repo: "Owner/Port", asset: "*-macOS.zip", channels: [.stable, .nightly],
            tags: [.stable: "v*", .nightly: "nightly-*"])
        let harness = try Harness { _ in .json(list) }
        let entry = makeEntry(.githubRelease(source))

        // A glob replaces the prerelease rule, in both directions.
        #expect(try await harness.releases.releases(for: entry, channel: .stable).map(\.tag) == ["v2.1.0-beta", "v2.0.0"])
        #expect(try await harness.releases.releases(for: entry, channel: .nightly).map(\.tag) == ["nightly-2026-10-20"])
    }

    @Test func blockedReleasesAreLeftOut() async throws {
        let harness = try Harness { _ in .json(shipwrightList) }
        let entry = makeEntry(
            .githubRelease(shipwrightSource),
            blocked: [Block(release: "9.3.1", severity: .stop, reason: "Corrupts saves.")])

        #expect(try await harness.releases.releases(for: entry, channel: .stable).map(\.tag) == ["9.2.3"])
        #expect(try await harness.releases.latest(for: entry, channel: .stable) == nil, "9.2.3 has no digest")
    }

    @Test func latestSkipsReleasesWithoutADigest() async throws {
        let list = jsonData([
            githubRelease("v1.2.2", created: "2025-08-27T00:00:00Z", assets: [("Port-v1.2.2-macOS.zip", nil)]),
            githubRelease("v1.2.1", created: "2025-08-18T00:00:00Z", assets: [("Port-v1.2.1-macOS.zip", "sha256:\(digestA)")]),
            githubRelease("v1.2.0", created: "2025-08-01T00:00:00Z", assets: [("Port-v1.2.0-macOS.zip", "md5:\(digestB)")]),
        ])
        let harness = try Harness { _ in .json(list) }
        let entry = makeEntry(.githubRelease(GitHubReleaseSource(repo: "Owner/Port", asset: "*-macOS.zip")))

        #expect(try await harness.releases.releases(for: entry, channel: .stable).map(\.tag) == ["v1.2.2", "v1.2.1", "v1.2.0"])
        #expect(try await harness.releases.latest(for: entry, channel: .stable)?.tag == "v1.2.1")
    }

    @Test func blocksMatchTagsToo() async throws {
        let list = jsonData([
            githubRelease("v1.2.2", created: "2025-08-27T00:00:00Z", assets: [("Zelda64Recompiled-v1.2.2-macOS.zip", "sha256:\(digestA)")]),
            githubRelease("v1.2.1", created: "2025-08-18T00:00:00Z", assets: [("Zelda64Recompiled-v1.2.1-macOS.zip", "sha256:\(digestA)")]),
        ])
        let source = GitHubReleaseSource(repo: "Zelda64Recomp/Zelda64Recomp", asset: "*-macOS.zip")
        let harness = try Harness { _ in .json(list) }
        let entry = makeEntry(.githubRelease(source), blocked: [Block(release: "v1.2.2", severity: .warn, reason: "")])

        let releases = try await harness.releases.releases(for: entry, channel: .stable)
        #expect(releases.map(\.version) == ["1.2.1"])
    }

    @Test func newestFirstByCreationDate() async throws {
        // SpaghettiKart's 0.9.9 was created before 0.9.9.1 but published after it.
        let list = jsonData([
            githubRelease("0.9.9", prerelease: true, created: "2025-06-20T12:43:48Z", published: "2025-11-15T22:28:00Z",
                          assets: [("spaghetti-mac-arm64.zip", "sha256:\(digestA)")]),
            githubRelease("1.0.0", created: "2026-02-25T02:23:44Z", assets: [("spaghetti-mac-arm64.zip", "sha256:\(digestA)")]),
            githubRelease("0.9.9.1", prerelease: true, created: "2025-06-21T20:07:20Z", published: "2025-11-15T22:21:45Z",
                          assets: [("spaghetti-mac-arm64.zip", "sha256:\(digestA)")]),
        ])
        let source = GitHubReleaseSource(repo: "HarbourMasters/SpaghettiKart", asset: "spaghetti-mac-arm64.zip", channels: [.stable, .nightly])
        let harness = try Harness { _ in .json(list) }

        let releases = try await harness.releases.releases(for: makeEntry(.githubRelease(source)), channel: .nightly)
        #expect(releases.map(\.tag) == ["1.0.0", "0.9.9.1", "0.9.9"])
        #expect(releases[2].published == date("2025-11-15T22:28:00Z") && releases[2].created == date("2025-06-20T12:43:48Z"))
        // Updates and Rollback order Releases by the same rule, so 0.9.9 counts as older than 0.9.9.1 everywhere.
        #expect(zip(releases, releases.dropFirst()).allSatisfy { $0.isNewer(than: $1) && !$1.isNewer(than: $0) })
    }

    @Test func channelNotOfferedHasNoReleases() async throws {
        let harness = try Harness { _ in .json(shipwrightList) }
        let source = GitHubReleaseSource(repo: "HarbourMasters/Shipwright", asset: "SoH-*-Mac.zip")
        #expect(try await harness.releases.releases(for: makeEntry(.githubRelease(source)), channel: .nightly).isEmpty)
        #expect(harness.requests.count == 0)
    }

    @Test(arguments: [
        ("sha256:\(String(repeating: "AB", count: 32))", String(repeating: "ab", count: 32)),
        ("SHA256:\(digestA)", digestA),
        ("sha512:\(digestA)", nil),
        ("sha256:abc", nil),
        ("sha256:\(String(repeating: "g", count: 64))", nil),
        ("", nil),
    ] as [(String, String?)])
    func parsesGitHubDigests(_ digest: String, _ expected: String?) {
        let asset = GitHubAsset(name: "a.zip", size: 1, browserDownloadURL: URL(string: "https://example.com/a.zip")!, digest: digest)
        #expect(asset.sha256 == expected)
    }

    @Test(arguments: [
        ("SoH-*-Mac.zip", "SoH-Dewey-Bravo-Mac.zip", true),
        ("SoH-*-Mac.zip", "SoH-Dewey-Bravo-Win64.zip", false),
        ("SoH-*-Mac.zip", "soh-dewey-bravo-mac.zip", false),
        ("*-macOS.zip", "Zelda64Recompiled-v1.2.2-macOS.zip", true),
        ("*-macOS.zip", "Zelda64Recompiled-v1.2.2-Linux-ARM64.zip", false),
        ("2Ship-?????*-Mac.zip", "2Ship-Battler-Bravo-Mac.zip", true),
        ("spaghetti-mac-[a]rm64.zip", "spaghetti-mac-arm64.zip", true),
        ("spaghetti-mac-[!a]*.zip", "spaghetti-mac-arm64.zip", false),
        ("spaghetti-mac-[!a]*.zip", "spaghetti-mac-intel-x64.zip", true),
    ])
    func matchesAssetGlobs(_ pattern: String, _ name: String, _ matches: Bool) {
        #expect(Glob.matches(pattern, name) == matches)
    }

    @Test(arguments: [
        ("v1.2.2", "1.2.2"), ("V2.0.0", "2.0.0"), ("9.3.1", "9.3.1"), ("vanilla", "vanilla"),
        ("nightly-2026-10-20", "nightly-2026-10-20"),
        ("0123456789abcdef0123456789abcdef01234567", "0123456"),
    ])
    func displaysVersions(_ tag: String, _ version: String) {
        #expect(GitHubReleases.displayVersion(tag) == version)
    }

    // MARK: Requests and the ETag cache

    @Test func requestsTheNewestFiftyReleases() async throws {
        let harness = try Harness { _ in .json(shipwrightList) }
        _ = try await harness.releases.releases(for: makeEntry(.githubRelease(shipwrightSource)), channel: .stable)

        let request = try #require(harness.requests.all.first)
        let components = try #require(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        #expect(components.path == "/repos/HarbourMasters/Shipwright/releases")
        #expect(components.queryItems == [URLQueryItem(name: "per_page", value: "50")])
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test func sendsAnInjectedToken() async throws {
        let harness = try Harness(token: "ghp_test") { _ in .json(shipwrightList) }
        let entry = makeEntry(.githubRelease(shipwrightSource))
        _ = try await harness.releases.releases(for: entry, channel: .stable)
        #expect(harness.requests.all.last?.value(forHTTPHeaderField: "Authorization") == "Bearer ghp_test")

        await harness.releases.setToken(nil)
        _ = try await harness.releases.releases(for: entry, channel: .stable)
        #expect(harness.requests.all.last?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func revalidatesWithTheCachedETag() async throws {
        let etag = #"W/"5f2c""#
        let handler: StubURLProtocol.Handler = { request in
            if request.value(forHTTPHeaderField: "If-None-Match") == etag { return StubResponse(status: 304) }
            return .json(shipwrightList, headers: ["ETag": etag])
        }
        let harness = try Harness(handler)
        let entry = makeEntry(.githubRelease(shipwrightSource))

        let first = try await harness.releases.releases(for: entry, channel: .stable)
        let second = try await harness.releases.releases(for: entry, channel: .stable)
        #expect(second == first)
        #expect(harness.requests.all.map { $0.value(forHTTPHeaderField: "If-None-Match") } == [nil, etag])

        // The cache is on disk, so it outlives the instance.
        let (relaunched, log) = harness.relaunched(handler)
        #expect(try await relaunched.releases(for: entry, channel: .stable) == first)
        #expect(log.all.map { $0.value(forHTTPHeaderField: "If-None-Match") } == [etag])
    }

    @Test func clientReportsNotModified() async throws {
        let etag = #""abc""#
        let temp = try TemporaryDirectory()
        let (host, _) = StubURLProtocol.host { request in
            request.value(forHTTPHeaderField: "If-None-Match") == etag
                ? StubResponse(status: 304) : StubResponse(headers: ["ETag": etag], body: Data("[]".utf8))
        }
        let client = GitHubClient(
            api: URL(string: "https://\(host)")!, cache: temp.url, session: StubURLProtocol.session(), token: nil)
        let first = try await client.get("repos/o/r/releases")
        let second = try await client.get("repos/o/r/releases")
        #expect((first.status, first.cached) == (200, false))
        #expect((second.status, second.cached) == (304, true))
        #expect(second.body == Data("[]".utf8))
    }

    @Test func servesTheCacheWhenGitHubIsUnreachableOrLimited() async throws {
        let harness = try Harness { _ in .json(shipwrightList, headers: ["ETag": #""v1""#]) }
        let entry = makeEntry(.githubRelease(shipwrightSource))
        let fresh = try await harness.releases.releases(for: entry, channel: .stable)

        let (offline, _) = harness.relaunched { _ in StubResponse(error: URLError(.notConnectedToInternet)) }
        #expect(try await offline.releases(for: entry, channel: .stable) == fresh)

        let (limited, _) = harness.relaunched { _ in
            StubResponse(status: 403, headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1790000000"])
        }
        #expect(try await limited.releases(for: entry, channel: .stable) == fresh)
    }

    @Test func failsWithoutACache() async throws {
        let entry = makeEntry(.githubRelease(shipwrightSource))

        let offline = try Harness { _ in StubResponse(error: URLError(.notConnectedToInternet)) }
        await #expect {
            try await offline.releases.releases(for: entry, channel: .stable)
        } throws: { error in
            guard case .network = error as? FrontportError else { return false }
            return true
        }

        let limited = try Harness { _ in
            StubResponse(status: 403, headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1790000000"])
        }
        await #expect {
            try await limited.releases.releases(for: entry, channel: .stable)
        } throws: { error in
            guard case .network(let detail) = error as? FrontportError else { return false }
            return detail.contains("rate limit")
        }

        let missing = try Harness { _ in .notFound }
        await #expect {
            try await missing.releases.releases(for: entry, channel: .stable)
        } throws: { error in
            guard case .network = error as? FrontportError else { return false }
            return true
        }
    }

    @Test func rejectsMalformedRepositories() async throws {
        let harness = try Harness { _ in .json([]) }
        let source = GitHubReleaseSource(repo: "../../user", asset: "*.zip")
        await #expect(throws: FrontportError.self) {
            try await harness.releases.releases(for: makeEntry(.githubRelease(source)), channel: .stable)
        }
        #expect(harness.requests.count == 0)
    }

    // MARK: git sources

    private static let starship = GitSource(
        repo: "HarbourMasters/Starship", refs: [.stable: "v2.0.0", .nightly: "0123456789abcdef0123456789abcdef01234567"],
        recipe: "recipes/starship.sh", recipeSHA256: digestA)

    @Test func pinnedRefUsesItsGitHubRelease() async throws {
        let harness = try Harness { request in
            guard request.url?.path == "/repos/HarbourMasters/Starship/releases/tags/v2.0.0" else { return .notFound }
            return .json(githubRelease(
                "v2.0.0", name: "Starship 2.0.0", created: "2025-05-25T10:00:00Z", body: "Big update.", assets: []))
        }
        let releases = try await harness.releases.releases(for: makeEntry(.git(Self.starship)), channel: .stable)

        let release = try #require(releases.first)
        #expect(releases.count == 1)
        #expect(release.version == "2.0.0")
        #expect(release.tag == "v2.0.0")
        #expect(release.isSourceBuilt)
        #expect(release.title == "Starship 2.0.0")
        #expect(release.published == date("2025-05-25T10:00:00Z"))
        #expect(release.notes == "Big update.")
        #expect(release.notesURL == URL(string: "https://github.com/HarbourMasters/Shipwright/releases/tag/v2.0.0"))
    }

    @Test func pinnedCommitUsesTheCommitDate() async throws {
        let sha = "0123456789abcdef0123456789abcdef01234567"
        let harness = try Harness { request in
            guard request.url?.path == "/repos/HarbourMasters/Starship/commits/\(sha)" else { return .notFound }
            return .json(["sha": sha, "commit": ["committer": ["date": "2026-01-02T03:04:05Z"]]])
        }
        let release = try #require(
            try await harness.releases.latest(for: makeEntry(.git(Self.starship)), channel: .nightly))
        #expect(release.version == "0123456")
        #expect(release.tag == sha)
        #expect(release.published == date("2026-01-02T03:04:05Z"))
        #expect(release.notesURL == URL(string: "https://github.com/HarbourMasters/Starship/tree/\(sha)"))
        #expect(harness.requests.all.map { $0.url?.path } == [
            "/repos/HarbourMasters/Starship/releases/tags/\(sha)", "/repos/HarbourMasters/Starship/commits/\(sha)",
        ])
    }

    @Test func pinnedRefWorksOffline() async throws {
        let harness = try Harness { _ in StubResponse(error: URLError(.notConnectedToInternet)) }
        let release = try #require(try await harness.releases.latest(for: makeEntry(.git(Self.starship)), channel: .stable))
        #expect(release.tag == "v2.0.0")
        #expect(release.published == nil)
        #expect(release.asset == nil)
    }

    @Test func pinnedRefHonorsBlocksAndChannels() async throws {
        let harness = try Harness { _ in .notFound }
        let blocked = makeEntry(.git(Self.starship), blocked: [Block(release: "2.0.0", severity: .stop, reason: "")])
        #expect(try await harness.releases.releases(for: blocked, channel: .stable).isEmpty)
        #expect(try await harness.releases.releases(for: makeEntry(.git(Self.starship)), channel: "beta").isEmpty)
    }
}
