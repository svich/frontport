import Foundation
import FrontportCore
import Testing
@testable import FrontportBuilder

/// iOS Recipes: the same Builder and sandbox, with Xcode's iOS SDK, in `Builds/<port>.ios/`, while a Mac build stays
/// exactly as it was.
@Suite struct DeviceRecipeBuilderTests {
    /// Every variable a Mac Recipe gets, and nothing more: what it got before iOS Recipes.
    @Test func theMacEnvironmentIsAsItWas() throws {
        let temp = try TemporaryDirectory()
        let paths = AppPaths(root: try temp.folder("Frontport"), containers: try temp.folder("Containers"))
        let workspace = try Workspace(paths: paths, port: "testport")
        try workspace.prepare(ref: "v1.2", recipeSHA256: "abc")
        let toolchain = try temp.folder("Frontport/Toolchain/tool-1.0")
        let developer = try temp.folder("Developer")
        try temp.folder("Developer/usr/bin")
        let sdk = temp.url.appending(path: "MacOSX.sdk", directoryHint: .isDirectory)
        let metal = temp.url.appending(path: "Metal.xctoolchain", directoryHint: .isDirectory)

        let environment = try workspace.environment(
            port: "testport", ref: "v1.2", toolchain: toolchain, toolchainBin: toolchain.appending(path: "bin"),
            developer: developer, sdk: sdk, metal: metal)

        let root = try BuildSandbox.canonical(paths.builds) + "/testport"
        #expect(environment == [
            "FRONTPORT_PORT": "testport",
            "FRONTPORT_REF": "v1.2",
            "FRONTPORT_SRC": root + "/src",
            "FRONTPORT_OUT": root + "/out",
            "FRONTPORT_TOOLCHAIN": try BuildSandbox.canonical(toolchain),
            "FRONTPORT_ROMS": root + "/roms",
            "FRONTPORT_JOBS": String(ProcessInfo.processInfo.activeProcessorCount),
            "TMPDIR": root + "/tmp",
            "HOME": root + "/tmp/home",
            "PATH": toolchain.path(percentEncoded: false) + "bin:" + developer.path(percentEncoded: false) + "usr/bin"
                + ":/usr/bin:/bin:/usr/sbin:/sbin",
            "DEVELOPER_DIR": developer.path(percentEncoded: false),
            "SDKROOT": sdk.path(percentEncoded: false),
            "FRONTPORT_METAL": metal.path(percentEncoded: false) + "usr/bin",
            "LANG": "en_US.UTF-8",
        ])
    }

    /// The Mac's call, as the Library makes it, builds for the Mac in `Builds/<port>/` with the active developer folder.
    @Test func theMacsCallBuildsForTheMac() async throws {
        let fixture = try BuilderFixture()
        let builder: any RecipeBuilding = try await fixture.readyBuilder()
        let recipe = try fixture.recipe(environmentRecipe)

        let product = try await builder.build(.fixture(), ref: "v1", recipe: recipe, roms: .none, log: fixture.log) { _ in }

        let workspace = try Workspace(paths: fixture.paths, port: "testport")
        #expect(product.app.deletingLastPathComponent().standardizedFileURL == workspace.output.standardizedFileURL)
        let environment = try readEnvironment(workspace.output)
        #expect(environment["FRONTPORT_SDK"] == nil && environment["xcrun_db"] == nil)
        #expect(environment["DEVELOPER_DIR"] == fixture.developer.path(percentEncoded: false))
        #expect(!exists(fixture.paths.builds(for: "testport.ios")))
    }

    @Test func anIOSBuildRunsWithXcodesIOSSDKInItsOwnFolder() async throws {
        let fixture = try BuilderFixture()
        let xcode = try FakeXcode(in: fixture.temp)
        let builder = try await fixture.iosBuilder(xcode: xcode.locator)
        let recipe = try fixture.recipe(environmentRecipe)
        // The Device Library keeps its prepared app beside the Recipe's folders.
        let prepared = try fixture.temp.file("Frontport/Builds/testport.ios/prepared/prepared.json", contents: "{}")
        let log = fixture.paths.buildLog(for: "testport.ios")
        let progress = ProgressLog()

        let product = try await builder.build(
            .fixture(), ref: "v1.2", recipe: recipe, roms: .none, sdk: .iphoneos, log: log, progress: progress.handler)

        let workspace = try Workspace(paths: fixture.paths, port: "testport.ios")
        #expect(product.app.deletingLastPathComponent().standardizedFileURL == workspace.output.standardizedFileURL)
        #expect(product.assets == nil)
        let environment = try readEnvironment(workspace.output)
        let root = try BuildSandbox.canonical(workspace.root)
        #expect(environment["FRONTPORT_SDK"] == "iphoneos")
        #expect(environment["FRONTPORT_PORT"] == "testport", "still the Port's id")
        #expect(environment["FRONTPORT_REF"] == "v1.2")
        #expect(environment["DEVELOPER_DIR"] == xcode.developer.path(percentEncoded: false))
        #expect(environment["SDKROOT"] == Xcode(developer: xcode.developer).iosSDK.path(percentEncoded: false))
        #expect(environment["xcrun_db"] == root + "/tmp/xcrun_db")
        #expect(environment["FRONTPORT_SRC"] == root + "/src" && environment["FRONTPORT_OUT"] == root + "/out")
        #expect(environment["FRONTPORT_ROMS"] == root + "/roms" && environment["TMPDIR"] == root + "/tmp")
        #expect(environment["HOME"] == root + "/tmp/home")
        let path = try #require(environment["PATH"]).split(separator: ":").map(String.init)
        #expect(Array(path.prefix(2)) == [
            fixture.paths.toolchain(version: fixture.manifest.version).appending(path: "bin").path(percentEncoded: false),
            xcode.developer.appending(path: "usr/bin").path(percentEncoded: false),
        ])
        #expect(try read(workspace.output.appending(path: "pwd.txt")) == root + "/src\n")

        #expect(try read(prepared) == "{}", "a build leaves what's beside its folders")
        #expect(!exists(fixture.paths.builds(for: "testport")), "and the Mac's build folder alone")
        let text = try read(log)
        #expect(text.contains("fetch testport at v1.2") && text.contains("build stdout"))
        #expect(Set(progress.updates.map(\.phase)).isSuperset(of: [.fetching, .building]))
    }

    @Test func anIOSBuildNeedsXcodeWithItsIOSPlatform() async throws {
        let fixture = try BuilderFixture()
        let recipe = try fixture.recipe(environmentRecipe)
        let none = try await fixture.iosBuilder(xcode: Xcode.Locator(selected: { nil }, installed: { [] }))
        await #expect(throws: FrontportError.xcodeMissing) {
            try await none.build(.fixture(), ref: "v1", recipe: recipe, roms: .none, sdk: .iphoneos, log: fixture.log) { _ in }
        }

        let xcode = try FakeXcode(in: fixture.temp, iOS: false)
        let withoutIOS = try await fixture.iosBuilder(xcode: xcode.locator)
        await #expect(throws: FrontportError.noIOSPlatform) {
            try await withoutIOS.build(.fixture(), ref: "v1", recipe: recipe, roms: .none, sdk: .iphoneos, log: fixture.log) { _ in }
        }
        #expect(!exists(fixture.paths.builds(for: "testport.ios")) && !exists(fixture.paths.builds(for: "testport")))
    }

    /// An iOS build runs with Xcode's own tools, so with Xcode found it needs only the pinned prefix: it never asks for
    /// the Command Line Tools, which a Mac build still does.
    @Test func anIOSBuildNeedsXcodeRatherThanTheCommandLineTools() async throws {
        let fixture = try BuilderFixture()
        let xcode = try FakeXcode(in: fixture.temp)
        let builder = fixture.builderWithoutCommandLineTools(xcode: xcode.locator)

        #expect(await builder.toolchainStatus() == .needsCommandLineTools)
        #expect(await builder.toolchainStatus(for: .macosx) == .needsCommandLineTools)
        #expect(await builder.toolchainStatus(for: .iphoneos) == .needsPrefix)
        try await builder.prepareToolchain(for: .iphoneos) { _ in }
        #expect(await builder.toolchainStatus(for: .iphoneos) == .ready)
        #expect(fixture.installRequests.value == 0, "the Command Line Tools' installer never opened")

        let product = try await builder.build(
            .fixture(), ref: "v1", recipe: try fixture.recipe(environmentRecipe), roms: .none, sdk: .iphoneos,
            log: fixture.log) { _ in }
        #expect(try readEnvironment(product.app.deletingLastPathComponent())["DEVELOPER_DIR"]
            == xcode.developer.path(percentEncoded: false))

        await #expect(throws: FrontportError.toolchainMissing(
            "Install the Command Line Tools from the window macOS just opened, then try again.")) {
            try await builder.prepareToolchain(for: .macosx) { _ in }
        }
        #expect(fixture.installRequests.value == 1)
    }

    /// Without Xcode with the iOS platform, preparing for an iOS build says so, rather than offering the Command Line
    /// Tools, which wouldn't help.
    @Test func withoutXcodeAnIOSBuildIsntReady() async throws {
        let fixture = try BuilderFixture()
        let none = fixture.builderWithoutCommandLineTools(xcode: Xcode.Locator(selected: { nil }, installed: { [] }))
        #expect(await none.toolchainStatus(for: .iphoneos) == .needsCommandLineTools)
        await #expect(throws: FrontportError.xcodeMissing) { try await none.prepareToolchain(for: .iphoneos) { _ in } }

        let withoutIOS = fixture.builderWithoutCommandLineTools(xcode: try FakeXcode(in: fixture.temp, iOS: false).locator)
        #expect(await withoutIOS.toolchainStatus(for: .iphoneos) == .needsCommandLineTools)
        await #expect(throws: FrontportError.noIOSPlatform) { try await withoutIOS.prepareToolchain(for: .iphoneos) { _ in } }
        #expect(fixture.installRequests.value == 0)
        #expect(!exists(fixture.paths.toolchain(version: fixture.manifest.version)), "nor the prefix installed")
    }

    @Test func eachSDKHasItsOwnWorkspace() {
        #expect(BuildSDK.macosx.workspace(for: "fallout-ce") == "fallout-ce")
        #expect(BuildSDK.iphoneos.workspace(for: "fallout-ce") == "fallout-ce.ios")
    }
}

/// A Recipe whose build step leaves an app and what it was run with: its environment and working folder.
private let environmentRecipe = """
    case "$1" in
    fetch) echo fetched > "$FRONTPORT_SRC/fetched.txt" ;;
    build)
        echo "build stdout"
        \(makeApp)
        env > "$FRONTPORT_OUT/env.txt"
        pwd > "$FRONTPORT_OUT/pwd.txt"
        ;;
    esac
    """

private func readEnvironment(_ output: URL) throws -> [String: String] {
    Dictionary(
        uniqueKeysWithValues: try read(output.appending(path: "env.txt")).split(separator: "\n").compactMap { line in
            line.firstIndex(of: "=").map { (String(line[..<$0]), String(line[line.index(after: $0)...])) }
        })
}

/// An Xcode.app with the iOS platform's SDK folder, or without the platform, that its locator selects.
private struct FakeXcode {
    let developer: URL
    let locator: Xcode.Locator

    init(in temp: TemporaryDirectory, iOS: Bool = true) throws {
        let developer = try temp.folder("Xcode.app/Contents/Developer")
        try temp.folder("Xcode.app/Contents/Developer/usr/bin")
        if iOS { try temp.folder("Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk") }
        self.developer = developer
        locator = Xcode.Locator(selected: { developer }, installed: { [] })
    }
}

extension BuilderFixture {
    /// A builder without the Command Line Tools, finding Xcode with `xcode`, its toolchain not installed.
    func builderWithoutCommandLineTools(xcode: Xcode.Locator) -> RecipeBuilder {
        let requests = installRequests
        return RecipeBuilder(
            paths: paths, manifest: manifest,
            developerTools: DeveloperTools(directory: { nil }, requestInstall: { requests.increment() }, sdk: { _ in nil }),
            download: { url, destination, _ in try FileManager.default.copyItem(at: url, to: destination) },
            home: home, xcode: xcode)
    }

    /// A builder with its toolchain installed, finding Xcode with `xcode`.
    func iosBuilder(xcode: Xcode.Locator) async throws -> RecipeBuilder {
        let developer = self.developer
        let builder = RecipeBuilder(
            paths: paths, manifest: manifest,
            developerTools: DeveloperTools(directory: { developer }, requestInstall: {}, sdk: { _ in nil }),
            download: { url, destination, _ in try FileManager.default.copyItem(at: url, to: destination) },
            home: home, xcode: xcode)
        try await builder.prepareToolchain { _ in }
        return builder
    }
}
