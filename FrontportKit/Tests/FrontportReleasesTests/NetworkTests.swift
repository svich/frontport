import Foundation
import FrontportCore
import Testing

@testable import FrontportReleases

private let environment = ProcessInfo.processInfo.environment

/// Real GitHub and real downloads. Run with `FRONTPORT_NETWORK_TESTS=1 swift test --filter NetworkTests`.
/// `FRONTPORT_NETWORK_SCRATCH` keeps downloads and extracted apps in that folder for inspection;
/// `FRONTPORT_GITHUB_TOKEN` authenticates API requests.
@Suite(
    .enabled(if: environment["FRONTPORT_NETWORK_TESTS"] == "1", "Set FRONTPORT_NETWORK_TESTS=1 to reach GitHub"),
    .timeLimit(.minutes(10)))
struct NetworkTests {
    struct Port: Sendable, CustomTestStringConvertible {
        var id: PortID
        var source: GitHubReleaseSource
        var testDescription: String { id.rawValue }
    }

    static let ports = [
        Port(
            id: "shipwright",
            source: GitHubReleaseSource(repo: "HarbourMasters/Shipwright", asset: "SoH-*-Mac.zip", channels: [.stable, .nightly])),
        Port(
            id: "zelda64recomp",
            source: GitHubReleaseSource(repo: "Zelda64Recomp/Zelda64Recomp", asset: "*-macOS.zip")),
    ]

    /// A fresh folder for one test: under `FRONTPORT_NETWORK_SCRATCH` and kept, or temporary.
    private static func scratch(_ name: String) throws -> (url: URL, owner: TemporaryDirectory?) {
        guard let root = environment["FRONTPORT_NETWORK_SCRATCH"] else {
            let temp = try TemporaryDirectory()
            return (temp.url, temp)
        }
        let url = URL(filePath: root, directoryHint: .isDirectory).appending(path: "\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (url, nil)
    }

    private static func entry(_ port: Port) -> CatalogEntry {
        var entry = makeEntry(.githubRelease(port.source))
        entry.id = port.id
        return entry
    }

    @Test(arguments: ports)
    func discoversReleasesWithDigests(_ port: Port) async throws {
        let (folder, owner) = try Self.scratch("discover-\(port.id)")
        defer { withExtendedLifetime(owner) {} }
        let releases = GitHubReleases(cache: folder.appending(path: "cache"), token: environment["FRONTPORT_GITHUB_TOKEN"])

        let found = try await releases.releases(for: Self.entry(port), channel: .stable)
        for release in found {
            print("[\(port.id)] \(release.tag) \(release.asset?.name ?? "-") sha256=\(release.asset?.sha256 ?? "none")")
        }
        let newest = try #require(found.first)
        print("[\(port.id)] summary: \(ReleaseNotes.summary(newest.notes ?? ""))")

        #expect(newest.published != nil)
        #expect(newest.notesURL != nil)
        #expect(!ReleaseNotes.summary(newest.notes ?? "").isEmpty)
        let asset = try #require(newest.asset)
        #expect(Glob.matches(port.source.asset, asset.name))
        #expect(asset.sha256?.count == 64, "GitHub publishes a digest for \(asset.name)")
        #expect(found.allSatisfy { !$0.isSourceBuilt })

        // A second check revalidates with the ETag and costs no rate limit.
        let client = GitHubClient(
            api: URL(string: "https://api.github.com")!, cache: folder.appending(path: "cache"),
            session: GitHubReleases.defaultSession, token: environment["FRONTPORT_GITHUB_TOKEN"])
        let again = try await client.get(
            "repos/\(port.source.repo)/releases", query: [URLQueryItem(name: "per_page", value: "50")])
        #expect(again.status == 304)
        #expect(try await releases.releases(for: Self.entry(port), channel: .stable) == found)
    }

    @Test(arguments: ports)
    func fetchesTheNewestMacBuild(_ port: Port) async throws {
        let (folder, owner) = try Self.scratch("fetch-\(port.id)")
        defer { withExtendedLifetime(owner) {} }
        let paths = AppPaths(
            root: folder.appending(path: "Frontport", directoryHint: .isDirectory),
            containers: folder.appending(path: "Containers", directoryHint: .isDirectory))
        let releases = GitHubReleases(cache: paths.catalog.appending(path: "releases"), token: environment["FRONTPORT_GITHUB_TOKEN"])
        let release = try #require(try await releases.latest(for: Self.entry(port), channel: .stable))
        let fetcher = AssetFetcher(paths: paths)
        let staging = paths.staging(for: port.id)
        let progress = ProgressLog()

        let start = ContinuousClock.now
        let app = try await fetcher.fetch(release, into: staging, progress: progress.handler)
        print("[\(port.id)] \(release.tag): \(release.asset!.name) → \(app.lastPathComponent) in \(ContinuousClock.now - start)")
        for update in progress.all where update.phase == .extracting {
            print("[\(port.id)]   extracting \(update.message ?? "")")
        }

        #expect(path(app.deletingLastPathComponent()) == path(staging))
        #expect(app.pathExtension == "app")
        #expect(exists(app.appending(path: "Contents/Info.plist")))
        let executables = try FileManager.default.contentsOfDirectory(atPath: path(app.appending(path: "Contents/MacOS")))
        #expect(!executables.isEmpty)
        #expect(FileOperations.extendedAttribute(FileOperations.quarantineAttribute, at: app) == nil)
        let download = paths.download(release.asset!, for: port.id)
        #expect(try Hashing.sha256(file: download) == release.asset?.sha256)

        // The verified download is reused.
        let again = ProgressLog()
        _ = try await fetcher.fetch(release, into: staging, progress: again.handler)
        #expect(!again.all.contains { $0.phase == .downloading })
    }
}
