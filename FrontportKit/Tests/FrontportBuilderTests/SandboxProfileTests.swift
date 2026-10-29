import Foundation
import FrontportCore
import Testing
@testable import FrontportBuilder

/// Runs small scripts under the real fetch and build profiles to prove their boundaries. The Frontport
/// folder sits inside a stand-in home folder, as it does inside the real one.
struct SandboxFixture {
    let temp: TemporaryDirectory
    let home: URL
    let paths: AppPaths
    let workspace: Workspace
    let toolchain: URL
    let developer: URL
    let recipe: URL

    init(developer: URL? = Host.developerDirectory) throws {
        temp = try TemporaryDirectory()
        home = try temp.folder("home")
        paths = AppPaths(
            root: try temp.folder("home/Library/Application Support/Frontport"),
            containers: try temp.folder("home/Library/Containers"))
        workspace = try Workspace(paths: paths, port: "testport")
        try workspace.prepare(ref: "v1", recipeSHA256: "0")
        toolchain = paths.toolchain(version: "1")
        try FileOperations.createDirectory(toolchain.appending(path: "bin"))
        self.developer = try developer ?? temp.folder("Developer")
        recipe = paths.recipe("recipes/test.sh")
        try temp.file("home/Documents/secret.txt", contents: "TOP-SECRET-CONTENT\n")
        try temp.file("outside/existing.txt", contents: "outside\n")
    }

    var outside: URL { temp.url.appending(path: "outside", directoryHint: .isDirectory) }

    /// Runs `script` as the Recipe's `step`, with `denied` as the home folder the profile shuts out, and `metal` as
    /// Xcode's Metal toolchain.
    func run(
        _ step: RecipeStep, _ script: String, denying denied: URL? = nil, metal: URL? = nil
    ) async throws -> (status: Int32, output: String) {
        try FileOperations.createDirectory(recipe.deletingLastPathComponent())
        try Data(script.utf8).write(to: recipe)
        let sandbox = BuildSandbox(
            step: step, home: denied ?? home, developer: DeveloperTools.sandboxRoot(of: developer), toolchain: toolchain,
            recipe: recipe, source: workspace.source, builds: workspace.root, temporary: workspace.temporary, metal: metal)
        var environment = try workspace.environment(
            port: "testport", ref: "v1", toolchain: toolchain, toolchainBin: toolchain.appending(path: "bin"),
            developer: developer, sdk: await DeveloperTools.system.sdk(developer), metal: metal)
        environment["FAKE_HOME"] = home.path(percentEncoded: false)
        environment["OUTSIDE"] = outside.path(percentEncoded: false)
        environment["BUILDS"] = workspace.root.path(percentEncoded: false)
        let result = try await ProcessRunner().run(
            BuildSandbox.sandboxExec,
            arguments: try sandbox.arguments(running: ["/bin/bash", try BuildSandbox.canonical(recipe), step.rawValue]),
            environment: environment, currentDirectory: workspace.source, stdout: .capture, stderr: .capture)
        return (result.status, result.output + result.errorOutput)
    }
}

@Suite struct SandboxProfileTests {
    @Test(.enabled(if: Host.hasDeveloperTools)) func buildRunsTheCompiler() async throws {
        let fixture = try SandboxFixture()
        let result = try await fixture.run(.build, """
            set -e
            printf '#include <stdio.h>\\nint main(void) { puts("compiled"); return 0; }\\n' > hello.c
            cc hello.c -o hello
            ./hello
            c++ --version >/dev/null
            """)
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("compiled"))
    }

    /// Xcode mounts its Metal toolchain inside the home folder, which the profiles otherwise shut out.
    @Test func onlyBuildRunsTheMetalToolchainInsideTheHomeFolder() async throws {
        let fixture = try SandboxFixture()
        let metal = try fixture.temp.folder("home/Library/Developer/DVTDownloads/MetalToolchain/mounts/1/Metal.xctoolchain")
        try fixture.temp.file(
            "home/Library/Developer/DVTDownloads/MetalToolchain/mounts/1/Metal.xctoolchain/usr/bin/metal",
            contents: "#!/bin/sh\necho METAL_RAN\n", executable: true)
        let script = """
            "$FRONTPORT_METAL/metal"
            echo bad > "$FRONTPORT_METAL/new" && echo WROTE_METAL
            cat "$FAKE_HOME/Documents/secret.txt" && echo READ_DOCUMENT
            true
            """
        let build = try await fixture.run(.build, script, metal: metal)
        #expect(build.status == 0, "\(build.output)")
        #expect(build.output.contains("METAL_RAN"), "\(build.output)")
        for token in ["WROTE_METAL", "READ_DOCUMENT"] {
            #expect(!build.output.contains(token), "\(token): \(build.output)")
        }
        let fetch = try await fixture.run(.fetch, script, metal: metal)
        #expect(!fetch.output.contains("METAL_RAN"), "\(fetch.output)")
    }

    /// A Recipe may boot the game during the build to capture the shaders it compiles at run time.
    @Test(.enabled(if: Host.hasDeveloperTools)) func onlyBuildGetsTheGPU() async throws {
        let fixture = try SandboxFixture()
        let probe = """
            #import <Metal/Metal.h>
            #include <stdio.h>
            int main(void) {
                id<MTLDevice> device = MTLCreateSystemDefaultDevice();
                puts(device && [device newMTL4CommandQueue] && [device newSharedEvent] ? "GPU_FOUND" : "NO_GPU");
                return 0;
            }
            """
        let source = try fixture.temp.file("probe.m", contents: probe)
        let compile = try await ProcessRunner().run(
            URL(filePath: "/usr/bin/clang"),
            arguments: ["-framework", "Metal", "-framework", "Foundation", "-o",
                        fixture.workspace.source.appending(path: "probe").path(percentEncoded: false), source.path(percentEncoded: false)])
        #expect(compile.status == 0, "\(compile.errorOutput)")
        let build = try await fixture.run(.build, "\"$FRONTPORT_SRC/probe\"")
        #expect(build.output.contains("GPU_FOUND"), "\(build.output)")
        let fetch = try await fixture.run(.fetch, "\"$FRONTPORT_SRC/probe\"")
        #expect(!fetch.output.contains("GPU_FOUND"), "\(fetch.output)")
    }

    @Test func findsOnlyARealMetalToolchain() throws {
        let temp = try TemporaryDirectory()
        let toolchain = try temp.folder("mounts/1/Metal.xctoolchain")
        let found = DeveloperTools.metalToolchain(containing: toolchain.path(percentEncoded: false) + "/usr/bin/metal")
        #expect(found?.path(percentEncoded: false) == (try BuildSandbox.canonical(toolchain)) + "/")
        #expect(DeveloperTools.metalToolchain(containing: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/metal") == nil)
        #expect(DeveloperTools.metalToolchain(containing: temp.url.path(percentEncoded: false) + "/missing/Metal.xctoolchain/usr/bin/metal") == nil)
        // A link named like a toolchain that leads elsewhere, such as the home folder, isn't one.
        let home = try temp.folder("home")
        let disguised = temp.url.appending(path: "mounts/2/Metal.xctoolchain")
        try FileManager.default.createDirectory(at: disguised.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: disguised, withDestinationURL: home)
        #expect(DeveloperTools.metalToolchain(containing: disguised.path(percentEncoded: false) + "/usr/bin/metal") == nil)
    }

    @Test func buildWritesOnlyBuildsAndTmp() async throws {
        let fixture = try SandboxFixture()
        let result = try await fixture.run(.build, """
            echo ok > "$BUILDS/written" && echo WROTE_BUILDS
            echo ok > "$FRONTPORT_OUT/written" && echo WROTE_OUT
            echo ok > "$TMPDIR/written" && echo WROTE_TMP
            echo ok > "$HOME/written" && echo WROTE_STEP_HOME
            echo bad > "$OUTSIDE/new.txt" && echo WROTE_OUTSIDE
            echo bad > "$OUTSIDE/existing.txt" && echo OVERWROTE_OUTSIDE
            echo bad > "$FAKE_HOME/new.txt" && echo WROTE_HOME
            echo bad > "$FRONTPORT_TOOLCHAIN/bin/new" && echo WROTE_TOOLCHAIN
            echo bad > /private/tmp/frontport-sandbox-test-$$ && echo WROTE_SYSTEM_TMP
            true
            """)
        #expect(result.status == 0, "\(result.output)")
        for token in ["WROTE_BUILDS", "WROTE_OUT", "WROTE_TMP", "WROTE_STEP_HOME"] {
            #expect(result.output.contains(token), "\(token): \(result.output)")
        }
        for token in ["WROTE_OUTSIDE", "OVERWROTE_OUTSIDE", "WROTE_HOME", "WROTE_TOOLCHAIN", "WROTE_SYSTEM_TMP"] {
            #expect(!result.output.contains(token), "\(token): \(result.output)")
        }
        #expect(!exists(fixture.outside.appending(path: "new.txt")))
        #expect(try read(fixture.outside.appending(path: "existing.txt")) == "outside\n")
        #expect(!exists(fixture.home.appending(path: "new.txt")))
    }

    @Test func buildCannotReadTheHomeFolder() async throws {
        let fixture = try SandboxFixture()
        let result = try await fixture.run(.build, """
            cat "$FAKE_HOME/Documents/secret.txt" && echo READ_DOCUMENT
            ls "$FAKE_HOME/Documents" && echo LISTED_DOCUMENTS
            stat "$FAKE_HOME/Documents/secret.txt" && echo STAT_DOCUMENT
            cat "$OUTSIDE/existing.txt" && echo READ_OUTSIDE
            ls /opt /usr/local && echo LISTED_PACKAGE_MANAGERS
            ls "$BUILDS" >/dev/null && echo LISTED_BUILDS
            true
            """)
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("LISTED_BUILDS"))
        for token in ["READ_DOCUMENT", "LISTED_DOCUMENTS", "STAT_DOCUMENT", "READ_OUTSIDE", "LISTED_PACKAGE_MANAGERS"] {
            #expect(!result.output.contains(token), "\(token): \(result.output)")
        }
        #expect(!result.output.contains("TOP-SECRET-CONTENT"))
    }

    @Test(arguments: RecipeStep.allCases) func neitherStepCanReadTheRealDocumentsFolder(_ step: RecipeStep) async throws {
        let fixture = try SandboxFixture()
        let realHome = FileManager.default.homeDirectoryForCurrentUser
        let result = try await fixture.run(step, """
            ls "\(realHome.path(percentEncoded: false))Documents" && echo LISTED_DOCUMENTS
            ls "\(realHome.path(percentEncoded: false))" && echo LISTED_HOME
            true
            """, denying: realHome)
        #expect(result.status == 0, "\(result.output)")
        #expect(!result.output.contains("LISTED_DOCUMENTS"), "\(result.output)")
        #expect(!result.output.contains("LISTED_HOME"), "\(result.output)")
    }

    @Test func fetchWritesOnlySourceAndTmpAndNeverSeesROMs() async throws {
        let fixture = try SandboxFixture()
        try Data("rom\n".utf8).write(to: fixture.workspace.roms.appending(path: "x.z64"))
        let result = try await fixture.run(.fetch, """
            echo ok > "$FRONTPORT_SRC/written" && echo WROTE_SRC
            echo ok > "$TMPDIR/written" && echo WROTE_TMP
            echo bad > "$FRONTPORT_OUT/written" && echo WROTE_OUT
            echo bad > "$BUILDS/written" && echo WROTE_BUILDS
            echo bad > "$OUTSIDE/new.txt" && echo WROTE_OUTSIDE
            cat "$FRONTPORT_ROMS/x.z64" && echo READ_ROM
            ls "$FRONTPORT_ROMS" && echo LISTED_ROMS
            cat "$FAKE_HOME/Documents/secret.txt" && echo READ_DOCUMENT
            true
            """)
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("WROTE_SRC"))
        #expect(result.output.contains("WROTE_TMP"))
        for token in ["WROTE_OUT", "WROTE_BUILDS", "WROTE_OUTSIDE", "READ_ROM", "LISTED_ROMS", "READ_DOCUMENT"] {
            #expect(!result.output.contains(token), "\(token): \(result.output)")
        }
    }

    @Test func onlyFetchCanConnect() async throws {
        let listener = try LocalListener()
        let fixture = try SandboxFixture()
        let script = "exec 3<>/dev/tcp/127.0.0.1/\(listener.port) && echo CONNECTED; true"
        let fetch = try await fixture.run(.fetch, script)
        let build = try await fixture.run(.build, script)
        #expect(fetch.output.contains("CONNECTED"), "\(fetch.output)")
        #expect(!build.output.contains("CONNECTED"), "\(build.output)")
    }

    /// Fetch may reach the internet, but no local agent through its Unix socket (a container engine, say).
    @Test(arguments: RecipeStep.allCases) func neitherStepReachesALocalSocket(_ step: RecipeStep) async throws {
        let listener = try UnixListener()
        let unsandboxed = try await ProcessRunner().run(
            URL(fileURLWithPath: "/usr/bin/nc"), arguments: ["-U", "-w", "1", listener.path], stdout: .discard, stderr: .discard)
        #expect(unsandboxed.succeeded, "the listener takes connections")

        let fixture = try SandboxFixture()
        let result = try await fixture.run(step, "nc -U -w 1 '\(listener.path)' </dev/null && echo CONNECTED; true")
        #expect(!result.output.contains("CONNECTED"), "\(result.output)")
    }

    @Test(.enabled(if: Host.networkTests)) func onlyFetchReachesTheInternet() async throws {
        let fixture = try SandboxFixture()
        let script = "curl -fsS -m 20 -o /dev/null https://github.com && echo REACHED; true"
        let fetch = try await fixture.run(.fetch, script)
        let build = try await fixture.run(.build, script)
        #expect(fetch.output.contains("REACHED"), "\(fetch.output)")
        #expect(!build.output.contains("REACHED"), "\(build.output)")
    }

    @Test(.enabled(if: Host.networkTests && Host.hasDeveloperTools)) func fetchCanClone() async throws {
        let fixture = try SandboxFixture()
        let result = try await fixture.run(.fetch, """
            set -e
            git clone -q --depth 1 https://github.com/ninja-build/ninja.git "$FRONTPORT_SRC/ninja"
            test -f "$FRONTPORT_SRC/ninja/README.md" && echo CLONED
            """)
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("CLONED"))
    }
}
