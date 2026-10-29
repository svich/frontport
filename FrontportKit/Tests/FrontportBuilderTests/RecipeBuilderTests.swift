import Darwin
import Foundation
import FrontportCore
import Testing
@testable import FrontportBuilder

/// A RecipeBuilder over a temporary Frontport folder, with a toolchain built from local fixture archives.
struct BuilderFixture {
    let temp: TemporaryDirectory
    let paths: AppPaths
    let manifest: ToolchainManifest
    let developer: URL
    let home: URL
    let installRequests: Counter

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }

    init(commandLineTools: Bool = true, corruptDigest: Bool = false) throws {
        temp = try TemporaryDirectory()
        paths = AppPaths(root: try temp.folder("Frontport"), containers: try temp.folder("Containers"))
        developer = try temp.folder("Developer")
        home = try temp.folder("home")
        try temp.folder("Developer/usr/bin")
        installRequests = Counter()

        // A tarball whose top folder holds a command, and a zip holding a bare command.
        try temp.file("archives/tool-1.0/bin/tool", contents: "#!/bin/sh\necho tool-1.0\n", executable: true)
        try temp.file("archives/zip/helper", contents: "#!/bin/sh\necho helper\n", executable: true)
        let tarball = temp.url.appending(path: "archives/tool-1.0.tar.gz")
        let zip = temp.url.appending(path: "archives/helper.zip")
        try Self.shell("/usr/bin/tar", "-czf", tarball.path(percentEncoded: false), "-C",
            temp.url.appending(path: "archives").path(percentEncoded: false), "tool-1.0")
        try Self.shell("/usr/bin/ditto", "-c", "-k", temp.url.appending(path: "archives/zip").path(percentEncoded: false),
            zip.path(percentEncoded: false))
        manifest = ToolchainManifest(packages: [
            ToolchainPackage(
                name: "tool", version: "1.0", url: tarball,
                sha256: corruptDigest ? String(repeating: "0", count: 64) : try Hashing.sha256(file: tarball),
                archive: .tarGz, root: "tool-1.0", commands: ["tool": "bin/tool"]),
            ToolchainPackage(
                name: "helper", version: "2.0", url: zip, sha256: try Hashing.sha256(file: zip), archive: .zip,
                commands: ["helper": "helper"]),
        ])
        hasCommandLineTools = commandLineTools
    }

    private let hasCommandLineTools: Bool

    func builder() -> RecipeBuilder {
        let developer = hasCommandLineTools ? self.developer : nil
        let requests = installRequests
        return RecipeBuilder(
            paths: paths, manifest: manifest,
            developerTools: DeveloperTools(
                directory: { developer }, requestInstall: { requests.increment() }, sdk: { _ in nil }),
            download: { url, destination, progress in
                progress(0.5)
                try FileManager.default.copyItem(at: url, to: destination)
                progress(1)
            },
            home: home)
    }

    /// A builder with its toolchain installed.
    func readyBuilder() async throws -> RecipeBuilder {
        let builder = builder()
        try await builder.prepareToolchain { _ in }
        return builder
    }

    func recipe(_ script: String, named name: String = "test.sh") throws -> URL {
        let recipe = paths.recipe("recipes/\(name)")
        try FileOperations.createDirectory(recipe.deletingLastPathComponent())
        try Data(("#!/bin/bash\nset -euo pipefail\n" + script).utf8).write(to: recipe)
        return recipe
    }

    var log: URL { temp.url.appending(path: "build.log") }

    /// A ROM in ROMs, as the Library hands it to the build.
    func buildROMs(contents: String = "rom bytes") throws -> BuildROMs {
        let data = Data(contents.utf8)
        let sha1 = Hashing.sha1(data)
        let file = paths.rom(sha1, format: "z64")
        try FileOperations.createDirectory(paths.roms)
        try data.write(to: file)
        let record = ROMRecord(sha1: sha1, game: "test-game", name: "Test", format: "z64", size: Int64(data.count),
            added: Date(), originalFilename: "test.z64")
        return BuildROMs([ROMFile(record: record, url: file)])
    }

    static func shell(_ command: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw FrontportError.processFailed(command: command, status: process.terminationStatus, output: "") }
    }
}

/// A build step that leaves a minimal app.
let makeApp = """
    mkdir -p "$FRONTPORT_OUT/Test.app/Contents/MacOS"
    printf '#!/bin/sh\\n' > "$FRONTPORT_OUT/Test.app/Contents/MacOS/Test"
    """

@Suite struct ToolchainTests {
    @Test func installsThePinnedPrefix() async throws {
        let fixture = try BuilderFixture()
        let stale = try fixture.temp.folder("Frontport/Toolchain/old-version")
        let builder = fixture.builder()
        #expect(await builder.toolchainStatus() == .needsPrefix)

        let progress = ProgressLog()
        try await builder.prepareToolchain(progress: progress.handler)

        #expect(await builder.toolchainStatus() == .ready)
        let root = fixture.paths.toolchain(version: fixture.manifest.version)
        #expect(fixture.manifest.version == "tool-1.0+helper-2.0")
        let tool = try await ProcessRunner().run(root.appending(path: "bin/tool"))
        let helper = try await ProcessRunner().run(root.appending(path: "bin/helper"))
        #expect(tool.output == "tool-1.0\n")
        #expect(helper.output == "helper\n")
        #expect(!exists(stale))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.paths.toolchain.path(percentEncoded: false))
        #expect(leftovers == [fixture.manifest.version])
        let phases = Set(progress.updates.map(\.phase))
        #expect(phases.isSuperset(of: [.downloading, .verifying, .extracting]))
    }

    @Test func pinnedManifestNamesOfficialDownloads() {
        let packages = ToolchainManifest.pinned.packages
        #expect(packages.map(\.name) == ["cmake", "ninja"])
        for package in packages {
            #expect(package.url.host() == "github.com")
            #expect(package.sha256.count == 64)
        }
        #expect(ToolchainManifest.pinned.version == "cmake-4.4.4+ninja-1.13.2")
    }

    @Test func rejectsADigestMismatch() async throws {
        let fixture = try BuilderFixture(corruptDigest: true)
        let builder = fixture.builder()
        await #expect {
            try await builder.prepareToolchain { _ in }
        } throws: { error in
            guard case FrontportError.digestMismatch(let asset, _, _) = error else { return false }
            return asset == "tool-1.0.tar.gz"
        }
        #expect(await builder.toolchainStatus() == .needsPrefix)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.paths.toolchain.path(percentEncoded: false))
        #expect(leftovers.isEmpty)
    }

    @Test func asksForTheCommandLineToolsWithoutWaiting() async throws {
        let fixture = try BuilderFixture(commandLineTools: false)
        let builder = fixture.builder()
        #expect(await builder.toolchainStatus() == .needsCommandLineTools)
        await #expect {
            try await builder.prepareToolchain { _ in }
        } throws: { error in
            if case FrontportError.toolchainMissing = error { return true }
            return false
        }
        #expect(fixture.installRequests.value == 1)
        #expect(!exists(fixture.paths.toolchain(version: fixture.manifest.version)))
    }

    @Test func buildNeedsTheToolchain() async throws {
        let fixture = try BuilderFixture()
        let builder = fixture.builder()
        await #expect {
            try await builder.build(.fixture(), ref: "v1", recipe: try fixture.recipe(""), roms: .none, log: fixture.log) { _ in }
        } throws: { error in
            if case FrontportError.toolchainMissing = error { return true }
            return false
        }
    }

    @Test func sandboxRootIsTheWholeXcodeApp() {
        #expect(
            DeveloperTools.sandboxRoot(of: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"))
                == URL(fileURLWithPath: "/Applications/Xcode.app", isDirectory: true))
        let tools = URL(fileURLWithPath: "/Library/Developer/CommandLineTools", isDirectory: true)
        #expect(DeveloperTools.sandboxRoot(of: tools) == tools)
    }
}

@Suite struct RecipeBuilderTests {
    @Test func runsFetchThenBuildWithTheContractEnvironment() async throws {
        let fixture = try BuilderFixture()
        let builder = try await fixture.readyBuilder()
        let roms = try fixture.buildROMs()
        let recipe = try fixture.recipe("""
            case "$1" in
            fetch)
                echo "fetch stdout"
                echo "fetch stderr" >&2
                { ls "$FRONTPORT_ROMS" 2>/dev/null || echo unreadable; } > "$FRONTPORT_SRC/roms-at-fetch"
                echo fetched > "$FRONTPORT_SRC/fetched.txt"
                ;;
            build)
                echo "build stdout"
                echo "build stderr" >&2
                \(makeApp)
                cat "$FRONTPORT_ROMS"/*.z64 > "$FRONTPORT_OUT/assets"
                cp "$FRONTPORT_SRC/fetched.txt" "$FRONTPORT_SRC/roms-at-fetch" "$FRONTPORT_OUT/"
                env > "$FRONTPORT_OUT/env.txt"
                pwd > "$FRONTPORT_OUT/pwd.txt"
                tool > "$FRONTPORT_OUT/tool.txt"
                ;;
            esac
            """)

        let product = try await builder.build(.fixture(), ref: "v1.2", recipe: recipe, roms: roms, log: fixture.log) { _ in }

        let workspace = try Workspace(paths: fixture.paths, port: "testport")
        #expect(product.app.lastPathComponent == "Test.app")
        #expect(product.app.deletingLastPathComponent().standardizedFileURL == workspace.output.standardizedFileURL)
        #expect(try read(#require(product.assets)) == "rom bytes")
        let out = workspace.output
        #expect(try read(out.appending(path: "fetched.txt")) == "fetched\n")
        #expect(try read(out.appending(path: "roms-at-fetch")) == "unreadable\n")
        #expect(try read(out.appending(path: "tool.txt")) == "tool-1.0\n")

        let environment = Dictionary(
            uniqueKeysWithValues: try read(out.appending(path: "env.txt")).split(separator: "\n").compactMap { line in
                line.firstIndex(of: "=").map { (String(line[..<$0]), String(line[line.index(after: $0)...])) }
            })
        let canonical = { (url: URL) in try BuildSandbox.canonical(url) }
        #expect(environment["FRONTPORT_PORT"] == "testport")
        #expect(environment["FRONTPORT_REF"] == "v1.2")
        #expect(try environment["FRONTPORT_SRC"] == canonical(workspace.source))
        #expect(try environment["FRONTPORT_OUT"] == canonical(workspace.output))
        #expect(try environment["FRONTPORT_TOOLCHAIN"] == canonical(fixture.paths.toolchain(version: fixture.manifest.version)))
        #expect(try environment["FRONTPORT_ROMS"] == canonical(workspace.roms.deletingLastPathComponent()) + "/roms")
        #expect(environment["FRONTPORT_JOBS"] == String(ProcessInfo.processInfo.activeProcessorCount))
        #expect(try environment["TMPDIR"] == canonical(workspace.root) + "/tmp")
        #expect(environment["HOME"]?.hasPrefix(try canonical(workspace.root)) == true)
        let path = try #require(environment["PATH"]).split(separator: ":").map(String.init)
        #expect(path.first == fixture.paths.toolchain(version: fixture.manifest.version).appending(path: "bin").path(percentEncoded: false))
        #expect(!path.contains { $0.hasPrefix("/opt") || $0.hasPrefix("/usr/local") })
        #expect(try read(out.appending(path: "pwd.txt")) == canonical(workspace.source) + "\n")

        let log = try read(fixture.log)
        for line in ["fetch stdout", "fetch stderr", "build stdout", "build stderr"] {
            #expect(log.contains(line), "\(line)")
        }
        #expect(log.range(of: "fetch stdout")!.lowerBound < log.range(of: "build stdout")!.lowerBound)
        #expect(!exists(workspace.roms), "ROMs are removed after the build")
        #expect(!exists(workspace.temporary), "and so is the tmp folder")
    }

    @Test func noROMsMeansNoBuildAssets() async throws {
        let fixture = try BuilderFixture()
        let builder = try await fixture.readyBuilder()
        let recipe = try fixture.recipe("""
            [ "$1" = fetch ] && exit 0
            \(makeApp)
            [ -d "$FRONTPORT_ROMS" ] && [ -z "$(ls -A "$FRONTPORT_ROMS")" ]
            for rom in "$FRONTPORT_ROMS"/*.z64; do [ -e "$rom" ] && cp "$rom" "$FRONTPORT_OUT/assets"; done
            true
            """)
        let product = try await builder.build(.fixture(), ref: "v1", recipe: recipe, roms: .none, log: fixture.log) { _ in }
        #expect(product.assets == nil)
    }

    @Test func aFailingStepThrowsWithTheLog() async throws {
        let fixture = try BuilderFixture()
        let builder = try await fixture.readyBuilder()
        let recipe = try fixture.recipe("""
            [ "$1" = fetch ] && exit 0
            echo "compiler exploded" >&2
            exit 3
            """)
        await #expect {
            try await builder.build(.fixture(), ref: "v1", recipe: recipe, roms: .none, log: fixture.log) { _ in }
        } throws: { error in
            guard case FrontportError.buildFailed(let port, let status, let log) = error else { return false }
            return port == "testport" && status == 3 && log == fixture.log
        }
        #expect(try read(fixture.log).contains("compiler exploded"))
    }

    @Test func requiresExactlyOneApp() async throws {
        let fixture = try BuilderFixture()
        let builder = try await fixture.readyBuilder()
        for script in ["true", "mkdir -p \"$FRONTPORT_OUT/A.app\" \"$FRONTPORT_OUT/B.app\""] {
            let recipe = try fixture.recipe("[ \"$1\" = fetch ] && exit 0\n" + script)
            await #expect {
                try await builder.build(.fixture(), ref: "v1", recipe: recipe, roms: .none, log: fixture.log) { _ in }
            } throws: { error in
                if case FrontportError.appNotFound = error { return true }
                return false
            }
        }
    }

    @Test func fetchesOncePerRefAndRecipe() async throws {
        let fixture = try BuilderFixture()
        let builder = try await fixture.readyBuilder()
        let script = """
            if [ "$1" = fetch ]; then
                echo "$FRONTPORT_REF" >> "$FRONTPORT_SRC/fetches"
            else
                \(makeApp)
                cp "$FRONTPORT_SRC/fetches" "$FRONTPORT_OUT/fetches"
            fi
            """
        let recipe = try fixture.recipe(script)
        let fetches = try Workspace(paths: fixture.paths, port: "testport").output.appending(path: "fetches")
        let build = { (ref: String, recipe: URL) in
            _ = try await builder.build(.fixture(), ref: ref, recipe: recipe, roms: .none, log: fixture.log) { _ in }
            return try read(fetches)
        }

        #expect(try await build("v1", recipe) == "v1\n")
        #expect(try await build("v1", recipe) == "v1\n", "the second build reuses the source tree")
        #expect(try await build("v2", recipe) == "v2\n", "a new ref starts from an empty source tree")
        let changed = try fixture.recipe(script + "\n# changed\n")
        #expect(try await build("v2", changed) == "v2\n", "a changed Recipe fetches again")
    }

    @Test func aFailedFetchIsRetriedFromScratch() async throws {
        let fixture = try BuilderFixture()
        let builder = try await fixture.readyBuilder()
        let failing = try fixture.recipe("""
            if [ "$1" = fetch ]; then echo partial > "$FRONTPORT_SRC/partial"; exit 1; fi
            """)
        await #expect(throws: FrontportError.self) {
            try await builder.build(.fixture(), ref: "v1", recipe: failing, roms: .none, log: fixture.log) { _ in }
        }
        let recipe = try fixture.recipe("""
            [ "$1" = fetch ] && exit 0
            \(makeApp)
            [ ! -e "$FRONTPORT_SRC/partial" ]
            """, named: "test.sh")
        _ = try await builder.build(.fixture(), ref: "v1", recipe: recipe, roms: .none, log: fixture.log) { _ in }
    }

    @Test func reportsProgressFromBuildOutput() async throws {
        let fixture = try BuilderFixture()
        let builder = try await fixture.readyBuilder()
        let recipe = try fixture.recipe("""
            [ "$1" = fetch ] && { echo "==> Cloning"; exit 0; }
            echo "==> Building the game"
            echo "[1/4] Building C object a.o"
            sleep 0.2
            echo "[4/4] Linking Test"
            \(makeApp)
            """)
        let progress = ProgressLog()
        _ = try await builder.build(.fixture(), ref: "v1", recipe: recipe, roms: .none, log: fixture.log, progress: progress.handler)

        let updates = progress.updates
        #expect(updates.contains { $0.phase == .fetching && $0.message == "Cloning" })
        #expect(updates.contains { $0.phase == .building && $0.fraction == 0.25 && $0.message == "Building the game" })
        #expect(updates.contains { $0.phase == .building && $0.fraction == 1 && $0.message == "Building the game" })
    }

    @Test func cancellingKillsTheProcessGroup() async throws {
        let fixture = try BuilderFixture()
        let builder = try await fixture.readyBuilder()
        let recipe = try fixture.recipe("""
            [ "$1" = fetch ] && exit 0
            sleep 600 &
            echo $! > "$FRONTPORT_SRC/background.pid"
            sleep 600
            """)
        let pidFile = try Workspace(paths: fixture.paths, port: "testport").source.appending(path: "background.pid")
        let task = Task {
            try await builder.build(.fixture(), ref: "v1", recipe: recipe, roms: .none, log: fixture.log) { _ in }
        }
        let deadline = ContinuousClock.now + .seconds(20)
        while !exists(pidFile), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let pid = try #require(Int32(read(pidFile).trimmingCharacters(in: .whitespacesAndNewlines)))
        let started = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(10))

        var alive = kill(pid, 0) == 0
        let gone = ContinuousClock.now + .seconds(5)
        while alive, ContinuousClock.now < gone {
            try await Task.sleep(for: .milliseconds(50))
            alive = kill(pid, 0) == 0
        }
        #expect(!alive, "the Recipe's background process was killed with its group")
    }

    /// Each step leaves `sleep 60` in the background: in its process group, in a group of its own, and in a session
    /// of its own. None may survive the step, whether it succeeds, fails or is cancelled, nor hold the build up.
    @Test(arguments: [LeftoverEnd.success, .failure, .cancel])
    func leavesNoProcessBehind(_ end: LeftoverEnd) async throws {
        let fixture = try BuilderFixture()
        let builder = try await fixture.readyBuilder()
        let leave = """
            sleep 60 &
            echo $! >> "$FRONTPORT_SRC/pids"
            set -m
            sleep 60 &
            echo $! >> "$FRONTPORT_SRC/pids"
            set +m
            if [ -x /usr/bin/perl ]; then
                /usr/bin/perl -MPOSIX -e 'if (my $pid = fork) { print "$pid\n" } else { POSIX::setsid(); exec "sleep", "60" }' >> "$FRONTPORT_SRC/pids"
            fi
            """
        let finish = switch end {
        case .success: makeApp
        case .failure: "exit 3"
        case .cancel: "touch \"$FRONTPORT_SRC/ready\"; sleep 60"
        }
        let recipe = try fixture.recipe("""
            \(leave)
            [ "$1" = fetch ] && exit 0
            \(finish)
            """)
        let workspace = try Workspace(paths: fixture.paths, port: "testport")
        let started = ContinuousClock.now
        let task = Task {
            try await builder.build(.fixture(), ref: "v1", recipe: recipe, roms: .none, log: fixture.log) { _ in }
        }
        if end == .cancel {
            let ready = workspace.source.appending(path: "ready")
            let deadline = ContinuousClock.now + .seconds(20)
            while !exists(ready), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            task.cancel()
        }
        let result = await task.result
        #expect(ContinuousClock.now - started < .seconds(30), "nothing left behind holds the step's output open")
        switch end {
        case .success: _ = try result.get()
        case .failure: #expect(throws: FrontportError.self) { try result.get() }
        case .cancel: #expect(throws: CancellationError.self) { try result.get() }
        }

        let pids = try read(workspace.source.appending(path: "pids")).split(separator: "\n").compactMap { Int32($0) }
        #expect(pids.count >= 4, "both steps left their processes")
        var alive = pids.filter { kill($0, 0) == 0 }
        let deadline = ContinuousClock.now + .seconds(5)
        while !alive.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            alive = alive.filter { kill($0, 0) == 0 }
        }
        for pid in alive { kill(pid, SIGKILL) }
        #expect(alive.isEmpty, "left running: \(alive)")
    }

    @Test func eachBuildLogHoldsOnlyItsOwnRun() async throws {
        let fixture = try BuilderFixture()
        let builder = try await fixture.readyBuilder()
        let recipe = try fixture.recipe("""
            echo "recipe $1 at $FRONTPORT_REF"
            [ "$1" = fetch ] && exit 0
            \(makeApp)
            """)
        _ = try await builder.build(.fixture(), ref: "v1", recipe: recipe, roms: .none, log: fixture.log) { _ in }
        _ = try await builder.build(.fixture(), ref: "v2", recipe: recipe, roms: .none, log: fixture.log) { _ in }

        let log = try read(fixture.log)
        #expect(log.contains("recipe fetch at v2") && log.contains("recipe build at v2"))
        #expect(!log.contains("v1"), "\(log)")
    }

    /// Every run starts with empty ROMs, tmp and output folders, so a run leaves none of them behind: only its product,
    /// for the caller to take and remove, and a fetched source tree, which the next build reuses.
    @Test func aRunLeavesOnlyItsProductAndWhatTheNextReuses() async throws {
        let fixture = try BuilderFixture()
        let builder = try await fixture.readyBuilder()
        let workspace = try Workspace(paths: fixture.paths, port: "testport")
        let recipe = { (fetch: String, build: String) in
            try fixture.recipe("""
                echo scratch > "$TMPDIR/scratch"
                if [ "$1" = fetch ]; then echo tree > "$FRONTPORT_SRC/tree"; \(fetch); exit 0; fi
                \(makeApp)
                cat "$FRONTPORT_ROMS"/*.z64 > "$FRONTPORT_OUT/assets"
                \(build)
                """)
        }
        let build = { (recipe: URL) in
            try await builder.build(.fixture(), ref: "v1", recipe: recipe, roms: try fixture.buildROMs(), log: fixture.log) { _ in }
        }

        let product = try await build(try recipe("true", "true"))
        #expect(exists(product.app) && product.assets.map(exists) == true)
        #expect(exists(workspace.source.appending(path: "tree")))
        #expect(!exists(workspace.temporary) && !exists(workspace.roms))

        await #expect(throws: FrontportError.self) { try await build(try recipe("true", "exit 3")) }
        #expect(!exists(workspace.output) && !exists(workspace.temporary) && !exists(workspace.roms))
        #expect(exists(workspace.source.appending(path: "tree")), "fetched, so the next build reuses it")

        await #expect(throws: FrontportError.self) { try await build(try recipe("exit 1", "true")) }
        #expect(!exists(workspace.source) && !exists(workspace.output) && !exists(workspace.temporary))

        // The next run makes every folder again.
        _ = try await build(try recipe("true", "true"))
        #expect(exists(workspace.source.appending(path: "tree")))
    }

    @Test func anUnpackLeavesOnlyTheFoldersItMadeAndItsOwnLog() async throws {
        let fixture = try BuilderFixture()
        let builder = try await fixture.readyBuilder()
        let recipe = try fixture.recipe("""
            echo "unpacker $1 $(cat "$FRONTPORT_ROMS"/*.exe 2>/dev/null)"
            echo scratch > "$TMPDIR/scratch"
            [ "$1" = fetch ] && exit 0
            mkdir -p "$FRONTPORT_OUT/GAME"
            cp "$FRONTPORT_ROMS"/*.exe "$FRONTPORT_OUT/GAME/"
            """, named: "unpacker.sh")
        let workspace = try Workspace(paths: fixture.paths, port: "unpack-unpacker")
        let unpack = { (contents: String) in
            let installer = try fixture.temp.file("setup-\(contents).exe", contents: contents)
            return try await builder.unpack(
                installer, named: "setup.exe", workspace: "unpack-unpacker", recipe: recipe, log: fixture.log) { _ in }
        }

        #expect(try await unpack("first").map(\.lastPathComponent) == ["GAME"])
        #expect(!exists(workspace.temporary) && !exists(workspace.roms))
        #expect(try await unpack("second").map(\.lastPathComponent) == ["GAME"])
        #expect(try read(workspace.output.appending(path: "GAME/setup.exe")) == "second")
        let log = try read(fixture.log)
        #expect(log.contains("unpacker build second") && !log.contains("first"), "\(log)")
    }

    @Test func theStepShellKeepsTheRecipesStatus() async throws {
        let fixture = try BuilderFixture()
        let builder = try await fixture.readyBuilder()
        let recipe = try fixture.recipe("""
            [ "$1" = fetch ] && exit 0
            exit 42
            """)
        await #expect {
            try await builder.build(.fixture(), ref: "v1", recipe: recipe, roms: .none, log: fixture.log) { _ in }
        } throws: { error in
            guard case FrontportError.buildFailed(_, let status, _) = error else { return false }
            return status == 42
        }
    }
}

enum LeftoverEnd: Sendable, CustomTestStringConvertible {
    case success, failure, cancel
    var testDescription: String {
        switch self {
        case .success: "success"
        case .failure: "failure"
        case .cancel: "cancel"
        }
    }
}

@Suite struct BuildProgressParserTests {
    @Test func parsesNinjaCMakeAndSteps() {
        var parser = BuildProgressParser(phase: .building)
        #expect(parser.parse("[3/12] Building CXX object src/a.cpp.o") == ProgressUpdate(.building, fraction: 0.25, message: "Building CXX object src/a.cpp.o"))
        #expect(parser.parse("[ 45%] Built target SDL2") == ProgressUpdate(.building, fraction: 0.45, message: "Built target SDL2"))
        #expect(parser.parse("[100%] Linking C executable zelda3") == ProgressUpdate(.building, fraction: 1, message: "Linking C executable zelda3"))
        #expect(parser.parse("==> Building libzip") == ProgressUpdate(.building, fraction: nil, message: "Building libzip"))
        #expect(parser.parse("[6/12] Building C object x.o") == ProgressUpdate(.building, fraction: 0.5, message: "Building libzip"))
        #expect(parser.parse("-- Configuring done") == nil)
        #expect(parser.parse("[0/0] nothing") == nil)
        #expect(parser.parse("warning: [1/2] inside a line") == nil)
    }
}
