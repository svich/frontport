import Foundation
import FrontportCore
import Testing
@testable import FrontportLauncher

@Suite(.timeLimit(.minutes(1))) struct PortLauncherTests {
    @Test func launchesSandboxedPortAndCapturesItsOutput() async throws {
        let fixture = try await Fixture(sandboxed: true)
        var entry = fixture.entry
        entry.launch = LaunchSpec(arguments: ["--fullscreen", "hello"], environment: ["FRONTPORT_TEST": "port"])
        let launcher = PortLauncher(paths: fixture.paths)
        let events = await launcher.events()

        let run = try await launcher.launch(entry, installation: fixture.installation)
        let ended = try await endOf(run, in: events)

        let log = try String(decoding: Data(contentsOf: run.log), as: UTF8.self)
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Containers/\(entry.bundleId)/Data", directoryHint: .notDirectory)
        #expect(log.contains("HOME=\(container.path(percentEncoded: false))\n"), "the sandbox applies to a directly run Port")
        #expect(log.contains("arg=--fullscreen\narg=hello\n"))
        #expect(log.contains("FRONTPORT_TEST=port\n"))
        #expect(ended.exitStatus == 0 && !ended.crashed)
        #expect(run.log == fixture.paths.runLog(run.id, for: entry.id))

        let stored = try JSON.read(Run.self, from: fixture.paths.runRecord(run.id, for: entry.id))
        #expect(stored == ended)
        #expect(await launcher.runs(for: entry.id) == [ended])
    }

    @Test func recordsExitStatus() async throws {
        let fixture = try await Fixture()
        var entry = fixture.entry
        entry.launch = LaunchSpec(arguments: ["exit=3"])
        let launcher = PortLauncher(paths: fixture.paths)
        let events = await launcher.events()

        let ended = try await endOf(try await launcher.launch(entry, installation: fixture.installation), in: events)

        #expect(ended.exitStatus == 3)
        #expect(ended.crashed)
    }

    /// The Port may have removed a folder its Redirect leads to; it's back before each launch.
    @Test func makesRedirectFoldersBeforeLaunching() async throws {
        let fixture = try await Fixture()
        let data = fixture.paths.data(for: fixture.entry.bundleId)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try fixture.redirect()
        let launcher = PortLauncher(paths: fixture.paths)
        let events = await launcher.events()

        _ = try await endOf(try await launcher.launch(fixture.entry, installation: fixture.installation), in: events)

        #expect(FileOperations.isDirectory(data.appending(path: Fixture.logFolder)))
    }

    /// A cleaner app or Finder may have removed the whole Data: it comes back as the Library makes it, made before
    /// the Port's first launch, or by the primer once macOS manages the container, and then the Redirect's folder.
    @Test func makesDataAgainBeforeLaunching() async throws {
        let fixture = try await Fixture()
        try fixture.redirect()
        let data = fixture.paths.data(for: fixture.entry.bundleId)
        let primer = FakePrimer(paths: fixture.paths)
        let launcher = PortLauncher(paths: fixture.paths, primer: primer)
        let events = await launcher.events()

        _ = try await endOf(try await launcher.launch(fixture.entry, installation: fixture.installation), in: events)
        #expect(FileOperations.isDirectory(data.appending(path: Fixture.logFolder)) && primer.runs.get == 0)

        try FileManager.default.removeItem(at: data)
        try Data("metadata".utf8).write(
            to: fixture.paths.container(for: fixture.entry.bundleId).appending(path: PortData.containerMetadata))
        _ = try await endOf(try await launcher.launch(fixture.entry, installation: fixture.installation), in: events)
        #expect(primer.runs.get == 1)
        #expect(FileOperations.isDirectory(data.appending(path: "Library/Caches")), "macOS's layout, from the primer")
        #expect(FileOperations.isDirectory(data.appending(path: Fixture.logFolder)))
    }

    /// Two launches at once while Data is gone run the primer once between them, and get the same run.
    @Test func primesOnceForLaunchesAtOnce() async throws {
        let fixture = try await Fixture()
        try fixture.redirect()
        var entry = fixture.entry
        entry.launch = LaunchSpec(arguments: ["sleep"])
        try FileManager.default.createDirectory(
            at: fixture.paths.container(for: entry.bundleId), withIntermediateDirectories: true)
        try Data("metadata".utf8).write(
            to: fixture.paths.container(for: entry.bundleId).appending(path: PortData.containerMetadata))
        let primer = FakePrimer(paths: fixture.paths, delay: .milliseconds(300))
        let launcher = PortLauncher(paths: fixture.paths, primer: primer)
        let events = await launcher.events()

        let (sleeping, installation) = (entry, fixture.installation)
        async let first = launcher.launch(sleeping, installation: installation)
        async let second = launcher.launch(sleeping, installation: installation)
        let runs = try await [first, second]

        #expect(runs[0] == runs[1])
        #expect(primer.runs.get == 1 && primer.runs.mostAtOnce == 1)
        await launcher.stop(entry)
        _ = try await endOf(runs[0], in: events)
    }

    /// The Port may start from the Dock or Finder while the primer runs: the launch is refused then, as before it.
    @Test func refusesALaunchOnceThePortRunsElsewhere() async throws {
        let fixture = try await Fixture()
        try fixture.redirect()
        try FileManager.default.createDirectory(
            at: fixture.paths.container(for: fixture.entry.bundleId), withIntermediateDirectories: true)
        try Data("metadata".utf8).write(
            to: fixture.paths.container(for: fixture.entry.bundleId).appending(path: PortData.containerMetadata))
        let elsewhere = Elsewhere()
        let primer = FakePrimer(paths: fixture.paths, delay: .milliseconds(300))
        let launcher = PortLauncher(paths: fixture.paths, primer: primer) { _ in elsewhere.get }

        let launch = Task { try await launcher.launch(fixture.entry, installation: fixture.installation) }
        try await Task.sleep(for: .milliseconds(100))
        elsewhere.set(true)

        await #expect(throws: FrontportError.running(fixture.entry.id)) { try await launch.value }
        #expect(primer.runs.get == 1)
        #expect(await launcher.runs(for: fixture.entry.id).isEmpty, "never launched")
    }

    /// The Port can plant a link or a file anywhere in its Data: the launch is refused, and nothing is made where a
    /// link leads.
    @Test func refusesALinkOrAFileOnTheWayToARedirectsFolder() async throws {
        let fixture = try await Fixture()
        try fixture.redirect()
        let data = fixture.paths.data(for: fixture.entry.bundleId)
        let outside = fixture.tmp.url.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let launcher = PortLauncher(paths: fixture.paths)

        for planted in ["Library", "Library/Application Support/Tiny", "Library/Application Support/Tiny/log"] {
            try? FileManager.default.removeItem(at: data)
            let url = data.appending(path: planted)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            for link in [true, false] {
                try? FileManager.default.removeItem(at: url)
                if link {
                    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside)
                } else {
                    try Data("planted".utf8).write(to: url)
                }
                await #expect(throws: FrontportError.self, "\(planted), link: \(link)") {
                    try await launcher.launch(fixture.entry, installation: fixture.installation)
                }
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path(percentEncoded: false)).isEmpty)
        #expect(await launcher.runs(for: fixture.entry.id).isEmpty, "never launched")
    }

    @Test func refusesDisabledInstallation() async throws {
        let fixture = try await Fixture()
        var installation = fixture.installation
        installation.disabled = true
        let launcher = PortLauncher(paths: fixture.paths)

        await #expect(throws: FrontportError.disabled(fixture.entry.id, reason: "")) {
            try await launcher.launch(fixture.entry, installation: installation)
        }
    }

    @Test func keepsTheLastFiveRuns() async throws {
        let fixture = try await Fixture()
        let launcher = PortLauncher(paths: fixture.paths)
        let events = await launcher.events()

        var ids: [String] = []
        for _ in 0..<7 {
            let run = try await launcher.launch(fixture.entry, installation: fixture.installation)
            _ = try await endOf(run, in: events)
            ids.append(run.id)
        }

        let runs = await launcher.runs(for: fixture.entry.id)
        #expect(runs.map(\.id) == ids.suffix(5).reversed())
        let files = try FileManager.default.contentsOfDirectory(atPath: fixture.paths.logs(for: fixture.entry.id).path(percentEncoded: false))
        #expect(files.count == 10)
    }

    @Test func stopsARunningPort() async throws {
        let fixture = try await Fixture()
        var entry = fixture.entry
        entry.launch = LaunchSpec(arguments: ["sleep"])
        let launcher = PortLauncher(paths: fixture.paths)
        let events = await launcher.events()

        let run = try await launcher.launch(entry, installation: fixture.installation)
        #expect(await launcher.isRunning(entry))
        #expect(await launcher.running() == [entry.id])
        #expect(try await launcher.launch(entry, installation: fixture.installation) == run, "a second launch returns the running one")

        await launcher.stop(entry)
        let ended = try await endOf(run, in: events)

        #expect(ended.signaled && ended.exitStatus == SIGTERM)
        #expect(await !launcher.isRunning(entry))
        #expect(await launcher.running().isEmpty)
    }

    @Test func closesRunsLeftOpenByAnEarlierSession() async throws {
        let fixture = try await Fixture()
        let port = fixture.entry.id
        try FileOperations.createDirectory(fixture.paths.logs(for: port))
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let log = fixture.paths.runLog("old", for: port)
        try Data("output".utf8).write(to: log)
        try JSON.write(Run(id: "old", port: port, release: "1.0", started: started, log: log), to: fixture.paths.runRecord("old", for: port))

        let runs = await PortLauncher(paths: fixture.paths).runs(for: port)

        #expect(runs.count == 1)
        #expect(runs.first?.isRunning == false)
        #expect(try JSON.read(Run.self, from: fixture.paths.runRecord("old", for: port)).isRunning == false)
    }
}

/// Waits for the run's ended event.
private func endOf(_ run: Run, in events: AsyncStream<LaunchEvent>) async throws -> Run {
    for await event in events {
        if case .ended(let ended) = event, ended.id == run.id { return ended }
    }
    throw CancellationError()
}

/// Creates `Data/` with part of the layout macOS makes when a sandboxed process with the bundle ID starts, after
/// `delay`, and counts the runs, and the most at once.
private struct FakePrimer: ContainerPriming {
    let paths: AppPaths
    var delay: Duration = .zero
    let runs = Runs()

    final class Runs: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var now = 0
        private var most = 0
        var get: Int { lock.withLock { count } }
        var mostAtOnce: Int { lock.withLock { most } }
        func begin() { lock.withLock { count += 1; now += 1; most = max(most, now) } }
        func end() { lock.withLock { now -= 1 } }
    }

    func prime(_ entry: CatalogEntry) async throws {
        runs.begin()
        defer { runs.end() }
        try await Task.sleep(for: delay)
        try FileManager.default.createDirectory(
            at: paths.data(for: entry.bundleId).appending(path: "Library/Caches"), withIntermediateDirectories: true)
    }
}

/// Whether a stand-in says the Port runs, started some other way.
private final class Elsewhere: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    var get: Bool { lock.withLock { running } }
    func set(_ value: Bool) { lock.withLock { running = value } }
}

/// A tiny Port installed in a temporary Library: it prints its HOME, arguments and FRONTPORT_TEST, then sleeps
/// on "sleep" or exits with N on "exit=N".
private struct Fixture {
    /// Where the Redirect `redirect()` adds leads, in Data.
    static let logFolder = "Library/Application Support/Tiny/log"

    let tmp: TemporaryDirectory
    let paths: AppPaths
    let entry: CatalogEntry
    let installation: Installation

    init(sandboxed: Bool = false) async throws {
        tmp = try TemporaryDirectory()
        paths = AppPaths(root: tmp.url.appending(path: "root"), containers: tmp.url.appending(path: "Containers"))
        let port = PortID("tiny")
        entry = CatalogEntry(
            id: port, name: "Tiny", kind: .recomp, game: "tiny-game", developer: "Tests", summary: "", description: "",
            source: URL(string: "https://example.com/tiny")!, bundleId: "dev.frontport.tests.launcher",
            releases: .githubRelease(GitHubReleaseSource(repo: "tests/tiny", asset: "*.zip")))
        installation = Installation(
            port: port, release: Release(port: port, version: "1.0"), channel: .stable, installedAt: Date(), appName: "Tiny.app")

        let app = paths.app(for: installation)
        let contents = app.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        try Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict>
            <key>CFBundleIdentifier</key><string>\(entry.bundleId)</string>
            <key>CFBundleExecutable</key><string>Tiny</string>
            <key>CFBundlePackageType</key><string>APPL</string>
            </dict></plist>
            """.utf8
        ).write(to: contents.appending(path: "Info.plist"))
        let source = tmp.url.appending(path: "main.c")
        try Data(
            #"""
            #include <stdio.h>
            #include <stdlib.h>
            #include <string.h>
            #include <unistd.h>
            int main(int argc, char **argv) {
                printf("HOME=%s\n", getenv("HOME"));
                const char *test = getenv("FRONTPORT_TEST");
                printf("FRONTPORT_TEST=%s\n", test ? test : "(unset)");
                for (int i = 1; i < argc; i++) {
                    printf("arg=%s\n", argv[i]);
                    fflush(stdout);
                    if (strcmp(argv[i], "sleep") == 0) sleep(30);
                    if (strncmp(argv[i], "exit=", 5) == 0) return atoi(argv[i] + 5);
                }
                return 0;
            }
            """#.utf8
        ).write(to: source)
        try await run("/usr/bin/xcrun", ["clang", "-o", contents.appending(path: "MacOS/Tiny").path(percentEncoded: false), source.path(percentEncoded: false)])

        if sandboxed {
            let entitlements = tmp.url.appending(path: "port.entitlements")
            try PropertyListSerialization.data(
                fromPropertyList: ["com.apple.security.app-sandbox": true], format: .xml, options: 0
            ).write(to: entitlements)
            try await run("/usr/bin/codesign", [
                "--force", "--sign", "-", "--options", "runtime", "--entitlements", entitlements.path(percentEncoded: false),
                app.path(percentEncoded: false),
            ])
        }
    }

    /// Adds a Redirect to the app, as the Packager links one: from `Contents/Resources/log` to `logFolder` in Data.
    func redirect() throws {
        let link = paths.app(for: installation).appending(path: "Contents/Resources/log")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = PortLinks.redirectData(bundleId: entry.bundleId, containers: paths.containers)
        try FileManager.default.createSymbolicLink(
            atPath: link.path(percentEncoded: false), withDestinationPath: PortLinks.redirectDestination(Self.logFolder, data: data))
    }

    private func run(_ tool: String, _ arguments: [String]) async throws {
        try await ProcessRunner().run(URL(filePath: tool), arguments: arguments).check(tool)
    }
}

private final class TemporaryDirectory: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "FrontportLauncherTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    // Folder ROMs and some tests leave read-only folders, which a plain removal stops at.
    deinit { try? FileOperations.removeUntrusted(url) }
}
