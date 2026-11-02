import Foundation
import FrontportBuilder
import FrontportCore
import Testing
@testable import FrontportPackager

/// Builds a real iOS Recipe end to end in the build sandbox, as Devices get it: installs the pinned toolchain, fetches
/// upstream and builds with Xcode's iOS SDK in `Builds/<port>.ios/`, then reads the app as the Device Packager will.
/// Opt-in and slow; needs the network and Xcode with the iOS platform. Nothing goes on a Device.
///
///     FRONTPORT_NETWORK_TESTS=1 FRONTPORT_RECIPE=fallout-ce-ios [FRONTPORT_RECIPE_REF=<ref>] \
///     [FRONTPORT_RECIPE_ROOT=/path/kept/between/runs] swift test --filter DeviceRecipeIntegrationTests
///
/// The entry is the one in `catalog/catalog.json` whose `ios` names the Recipe, and the Recipe the one in
/// `catalog/recipes`. As in `RecipeIntegrationTests`, the Frontport folder lives at
/// `<root>/home/Library/Application Support/Frontport`, and the sandbox denies `<root>/home`.
enum DeviceRecipeRun {
    static var recipe: String? { Integration.environment["FRONTPORT_RECIPE"].flatMap { $0.hasSuffix("-ios") ? $0 : nil } }
    static var requested: Bool { Integration.requested && recipe != nil }
}

@Suite(.enabled(if: DeviceRecipeRun.requested, "Set FRONTPORT_NETWORK_TESTS=1 and FRONTPORT_RECIPE=<name>-ios"), .serialized)
struct DeviceRecipeIntegrationTests {
    @Test func buildsTheRequestedIOSRecipe() async throws {
        let name = try #require(DeviceRecipeRun.recipe)
        let relative = "recipes/\(name).sh"
        let document = try JSON.decode(
            CatalogDocument.self, from: Data(contentsOf: Integration.repository.appending(path: "catalog/catalog.json")))
        let entry = try #require(
            document.ports.first { port in
                if case .git(let source)? = port.ios?.releases { source.recipe == relative } else { false }
            }, "No entry's ios names \(relative)")
        let version = try IOSVersion(of: entry)
        let view = version.view
        guard case .git(let source) = view.releases else { throw FrontportError.catalogInvalid("\(entry.id) isn’t built") }
        let ref = try #require(Integration.environment["FRONTPORT_RECIPE_REF"] ?? source.refs[view.defaultChannel])

        let scratch = try Scratch()
        let root = Integration.environment["FRONTPORT_RECIPE_ROOT"].map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? scratch.url
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        let paths = AppPaths(
            root: home.appending(path: "Library/Application Support/Frontport", directoryHint: .isDirectory),
            containers: home.appending(path: "Library/Containers", directoryHint: .isDirectory))
        try FileOperations.createDirectory(paths.root)
        let builder = RecipeBuilder(paths: paths, home: home)
        // The Recipe as the Catalog would cache it.
        let recipe = paths.recipe(relative)
        try FileOperations.createDirectory(recipe.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: recipe)
        try FileManager.default.copyItem(at: Integration.repository.appending(path: "catalog/\(relative)"), to: recipe)

        let started = ContinuousClock.now
        let progress: ProgressHandler = { update in
            if update.fraction == nil, let message = update.message { print("[\(update.phase.rawValue)] \(message)") }
        }
        try await builder.prepareToolchain(progress: progress)
        let workspace = BuildSDK.iphoneos.workspace(for: entry.id)
        let log = paths.buildLog(for: workspace)
        let product = try await builder.build(
            view, ref: ref, recipe: recipe, roms: .none, sdk: .iphoneos, log: log, progress: progress)
        print("built \(path(product.app)) after \(ContinuousClock.now - started); log: \(path(log))")

        // One flat, unsigned app, for iOS on arm64, that the Device Packager takes.
        let app = product.app
        let output = paths.buildOutput(for: workspace)
        #expect(try FileManager.default.contentsOfDirectory(atPath: path(output)).filter { $0.hasSuffix(".app") }
            == [app.lastPathComponent])
        #expect(!exists(app.appending(path: "Contents")) && !exists(app.appending(path: "_CodeSignature")))
        let info = try await DevicePackager().inspect(app, version: version)
        let executable = app.appending(path: info.executable)
        let build = try #require(MachO.build(of: executable))
        #expect(build.platform == .iOS && !build.isEncrypted)
        #expect(info.sdk == build.sdk.description && build.minimumOS.description == info.minimumOS)
        let archs = try await tool("/usr/bin/lipo", ["-archs", path(executable)])
        #expect(archs.output.trimmingCharacters(in: .whitespacesAndNewlines) == "arm64")

        // Its Info.plist is whole for iOS without a storyboard (README › iOS Recipes).
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appending(path: "Info.plist")), format: nil)
                as? [String: Any])
        #expect(plist["MinimumOSVersion"] as? String == info.minimumOS, "LC_BUILD_VERSION's minimum")
        let families = plist["UIDeviceFamily"] as? [Int]
        #expect([[1], [2], [1, 2]].contains(families), "\(families ?? [])")
        #expect(families == info.families)
        #expect(plist["CFBundleSupportedPlatforms"] as? [String] == ["iPhoneOS"])
        #expect(plist["UILaunchScreen"] is [String: Any] && plist["UILaunchStoryboardName"] == nil)
        // An app linked against the iOS 27 SDK or later has a scene delegate, or iOS ends it at launch.
        if plist["UIApplicationSceneManifest"] == nil {
            #expect(build.sdk < MachO.Version(packed: 27 << 16), "SDK \(build.sdk), with no scene manifest")
        }
        // Files shows Documents when the iOS version Seeds anything there.
        let seedsDocuments = view.requirements.compactMap(\.seedPath).contains { path in
            path.split(separator: "/").first == "Documents"
        }
        if seedsDocuments {
            #expect(plist["UIFileSharingEnabled"] as? Bool == true)
            #expect(plist["LSSupportsOpeningDocumentsInPlace"] as? Bool == true)
        }
        // At most three integers each, as iOS takes them.
        for key in ["CFBundleShortVersionString", "CFBundleVersion"] {
            let version = try #require(plist[key] as? String, "\(key)")
            let numbers = version.split(separator: ".", omittingEmptySubsequences: false)
            let isInteger = { (part: Substring) in !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber } }
            #expect((1...3).contains(numbers.count) && numbers.allSatisfy(isInteger), "\(key) \(version)")
        }

        // Every icon it lists is there, and nothing only Xcode compiles. Code besides its executable is only libraries,
        // in frameworks or as dylibs, which the Packager signs.
        let files = FileManager.default.enumerator(atPath: path(app))?.allObjects as? [String] ?? []
        var icons: [String] = []
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            let primary = (plist[key] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any]
            icons += primary?["CFBundleIconFiles"] as? [String] ?? []
        }
        #expect(!icons.isEmpty)
        for icon in Set(icons) {
            #expect(files.contains { $0.hasPrefix(icon + "@") && $0.hasSuffix(".png") }, "\(icon)")
        }
        #expect(!files.contains { $0.hasSuffix(".xcassets") || $0.hasSuffix(".storyboard") || $0.hasSuffix(".storyboardc") })
        #expect(try CodeLayout(app: app, layout: .flat).refused.isEmpty)
        let programs = files.filter { $0 != info.executable && MachO.fileType(of: app.appending(path: $0)) == .executable }
        #expect(programs.isEmpty, "\(programs)")

        print(try await tool("/usr/bin/xcrun", ["vtool", "-show-build", path(executable)]).output)
        print(try await tool("/usr/bin/plutil", ["-p", path(app.appending(path: "Info.plist"))]).output)
    }
}
