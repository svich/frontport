import Foundation
import Testing
@testable import FrontportCore

/// A Port's Data made ready for its app, over a temporary containers folder: no Library, Packager or Launcher.
@Suite struct PortDataTests {
    static let log = Redirect(path: "Contents/Resources/log", to: "Library/Application Support/Tiny/log")
    static let entry = {
        var entry = CatalogEntry(
            id: "tiny", name: "Tiny", kind: .decomp, game: "tiny", developer: "Tests", summary: "", description: "",
            source: URL(string: "https://example.org/tiny")!, bundleId: "dev.frontport.port.tiny",
            releases: .githubRelease(GitHubReleaseSource(repo: "a/tiny", asset: "*.zip", channels: [.stable])))
        entry.redirects = [log]
        return entry
    }()

    @Test func makesDataInAContainerMacOSDoesNotManageYet() async throws {
        let f = try Fixture()
        let data = PortData(paths: f.paths, primer: f.primer)

        #expect(try await data.prepare(Self.entry))

        #expect(FileOperations.isDirectory(f.data) && f.primer.runs.get == 0, "macOS adopts it at the first launch")
    }

    /// Once macOS manages the container, only the primer can have it lay out Data again; without one, it waits.
    @Test func primesDataMacOSManages() async throws {
        let f = try Fixture(managed: true)

        #expect(try await !PortData(paths: f.paths, primer: nil).prepare(Self.entry))
        #expect(!FileOperations.exists(f.data))

        #expect(try await PortData(paths: f.paths, primer: f.primer).prepare(Self.entry))
        #expect(f.primer.runs.get == 1 && FileOperations.isDirectory(f.data.appending(path: "Library/Application Support")))
    }

    /// The folders come from the app's own links, not from the entry, which may have changed since it was packaged.
    @Test func makesTheFoldersTheAppsRedirectsLeadTo() async throws {
        let f = try Fixture(managed: true)
        let app = try f.app(redirects: [Self.log])
        var unlisted = Self.entry
        unlisted.redirects = []

        try await PortData(paths: f.paths, primer: f.primer).prepareRedirects(of: app, for: unlisted)

        #expect(FileOperations.isDirectory(f.data.appending(path: Self.log.to)))
        #expect(f.primer.runs.get == 1, "Data first, primed since macOS manages it")
    }

    @Test func refusesALinkWhereNoRedirectMayBe() async throws {
        let f = try Fixture()
        let app = try f.app(redirects: [Redirect(path: "Contents/MacOS/log", to: "log")])

        await #expect(throws: FrontportError.self) {
            try await PortData(paths: f.paths, primer: nil).prepareRedirects(of: app, for: Self.entry)
        }
    }

    @Test func refusesTargetsOutsideData() async throws {
        let f = try Fixture()

        await #expect(throws: FrontportError.fileOperation("Tiny redirects outside its Data.")) {
            try await PortData(paths: f.paths, primer: nil).prepareRedirects(["../escape"], for: Self.entry)
        }
        #expect(!FileOperations.exists(f.data))
    }

    /// The Port can plant a link anywhere in its Data; nothing is made where it leads.
    @Test func neverFollowsALinkInData() async throws {
        let f = try Fixture()
        let outside = f.tmp.url.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let planted = f.data.appending(path: "Library/Application Support/Tiny")
        try FileManager.default.createDirectory(at: planted.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: planted, withDestinationURL: outside)

        await #expect(throws: FrontportError.self) {
            try await PortData(paths: f.paths, primer: nil).prepareRedirects([Self.log.to], for: Self.entry)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path(percentEncoded: false)).isEmpty)
    }

    /// After a change that is otherwise complete, a failure is returned to be reported, never thrown.
    @Test func afterAChangeReportsWhatWentWrong() async throws {
        let f = try Fixture(managed: true)
        let app = try f.app(redirects: [Self.log])

        let message = await PortData(paths: f.paths, primer: nil).prepareRedirectsAfterChange(of: app, for: Self.entry)

        #expect(message == "Tiny’s Redirects couldn’t be prepared in its Data. Tiny’s Data is gone, so its Redirects lead nowhere.")
        #expect(await PortData(paths: f.paths, primer: f.primer).prepareRedirectsAfterChange(of: app, for: Self.entry) == nil)
    }

    private struct Fixture {
        let tmp: TemporaryDirectory
        let paths: AppPaths
        let primer: FakePrimer

        /// `managed`: macOS manages the Port's container, whose Data is gone, as after Delete Data.
        init(managed: Bool = false) throws {
            tmp = try TemporaryDirectory()
            paths = AppPaths(root: tmp.url.appending(path: "root"), containers: tmp.url.appending(path: "Containers"))
            primer = FakePrimer(paths: paths)
            let container = paths.container(for: PortDataTests.entry.bundleId)
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
            if managed { try Data("metadata".utf8).write(to: container.appending(path: PortData.containerMetadata)) }
        }

        var data: URL { paths.data(for: PortDataTests.entry.bundleId) }

        /// An app holding a link for each Redirect, as the Packager places them.
        func app(redirects: [Redirect]) throws -> URL {
            let app = tmp.url.appending(path: "Tiny.app", directoryHint: .isDirectory)
            let data = PortLinks.redirectData(bundleId: PortDataTests.entry.bundleId, containers: paths.containers)
            for redirect in redirects {
                let link = app.appending(path: redirect.path)
                try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(
                    atPath: link.path(percentEncoded: false),
                    withDestinationPath: PortLinks.redirectDestination(redirect.to, data: data))
            }
            return app
        }
    }

    /// Creates `Data/` as macOS does when a sandboxed process with the bundle ID starts, and counts the runs.
    private struct FakePrimer: ContainerPriming {
        let paths: AppPaths
        let runs = Count()

        final class Count: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            var get: Int { lock.withLock { count } }
            func add() { lock.withLock { count += 1 } }
        }

        func prime(_ entry: CatalogEntry) async throws {
            runs.add()
            try FileManager.default.createDirectory(
                at: paths.data(for: entry.bundleId).appending(path: "Library/Application Support"),
                withIntermediateDirectories: true)
        }
    }
}
