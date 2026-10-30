import Foundation
import FrontportCore
import Testing
@testable import FrontportBuilder

/// Builds a real Catalog Recipe end to end: installs the pinned toolchain, fetches upstream and builds.
/// Opt-in and slow; needs the network and the Command Line Tools.
///
///     FRONTPORT_NETWORK_TESTS=1 FRONTPORT_RECIPE=starship [FRONTPORT_RECIPE_REF=v2.0.0] \
///     [FRONTPORT_RECIPE_ROOT=/path/kept/between/runs] [FRONTPORT_RECIPE_ROMS=/path/a.z64,...] \
///     [FRONTPORT_RECIPE_PORT=opengoal-jak2] [FRONTPORT_RECIPE_FILE=/path/recipe.sh] \
///     swift test --filter RecipeIntegrationTests
///
/// `FRONTPORT_RECIPE_PORT` names the Port when it isn't the Recipe's name, as for OpenGOAL's per-game Ports.
/// `FRONTPORT_RECIPE_FILE` builds a Recipe from outside `catalog/recipes`, such as an added Catalog's, which then
/// needs `FRONTPORT_RECIPE_REF`.
///
/// The Frontport folder lives at `<root>/home/Library/Application Support/Frontport`, and the sandbox denies
/// `<root>/home` as it would the user's home folder.
enum RecipeRun {
    static let environment = ProcessInfo.processInfo.environment
    static var recipe: String? { environment["FRONTPORT_RECIPE"] }
    static var requested: Bool { Host.networkTests && Host.hasDeveloperTools && recipe != nil }

    static let defaultRefs = [
        "starship": "v2.0.0", "zelda3": "45a149d8b4bb8098f53d1009f76e76e7d8b79bbf", "opengoal": "v0.3.9",
        "dethrace": "v0.10.1", "fallout-ce": "0609bcfd0ec40ff0571d0f57fab2821eb461dc8b",
        "smw": "eae20c65c58930c8b62c76188d259579ad4130f1",
    ]

    static var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
}

@Suite(.enabled(if: RecipeRun.requested), .serialized) struct RecipeIntegrationTests {
    @Test func buildsTheRequestedRecipe() async throws {
        let name = try #require(RecipeRun.recipe)
        let port = PortID(RecipeRun.environment["FRONTPORT_RECIPE_PORT"] ?? name)
        let ref = try #require(RecipeRun.environment["FRONTPORT_RECIPE_REF"] ?? RecipeRun.defaultRefs[name])
        let temporary = try TemporaryDirectory()
        let root = RecipeRun.environment["FRONTPORT_RECIPE_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? temporary.url
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        let paths = AppPaths(
            root: home.appending(path: "Library/Application Support/Frontport", directoryHint: .isDirectory),
            containers: home.appending(path: "Library/Containers", directoryHint: .isDirectory))
        try FileOperations.createDirectory(paths.root)
        let builder = RecipeBuilder(paths: paths, home: home)

        // The Recipe as the Catalog would cache it.
        let recipe = paths.recipe("recipes/\(name).sh")
        try FileOperations.createDirectory(recipe.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: recipe)
        let source = RecipeRun.environment["FRONTPORT_RECIPE_FILE"].map { URL(fileURLWithPath: $0) }
            ?? RecipeRun.repository.appending(path: "catalog/recipes/\(name).sh")
        try FileManager.default.copyItem(at: source, to: recipe)

        let roms = try (RecipeRun.environment["FRONTPORT_RECIPE_ROMS"] ?? "").split(separator: ",").map { path in
            let url = URL(fileURLWithPath: String(path))
            let sha1 = try Hashing.sha1(file: url)
            let record = ROMRecord(
                sha1: sha1, game: "test", name: url.lastPathComponent, format: url.pathExtension,
                size: Int64(try FileOperations.size(of: url)), added: Date(), originalFilename: url.lastPathComponent)
            return ROMFile(record: record, url: url)
        }

        let started = ContinuousClock.now
        let progress: ProgressHandler = { update in
            if update.fraction == nil, let message = update.message { print("[\(update.phase.rawValue)] \(message)") }
        }
        try await builder.prepareToolchain(progress: progress)
        print("toolchain ready after \(ContinuousClock.now - started)")

        let entry = CatalogEntry(
            id: port, name: name, kind: .decomp, game: "test", developer: "test", summary: "", description: "",
            source: URL(string: "https://github.com")!, bundleId: port.conventionalBundleID,
            releases: .git(GitSource(repo: "", refs: [.stable: ref], recipe: "recipes/\(name).sh", recipeSHA256: "")))
        let log = root.appending(path: "\(port.rawValue).log")
        let product = try await builder.build(entry, ref: ref, recipe: recipe, roms: BuildROMs(roms), log: log, progress: progress)
        print("built \(product.app.path(percentEncoded: false)) after \(ContinuousClock.now - started); log: \(log.path(percentEncoded: false))")

        let info = try #require(NSDictionary(contentsOf: product.app.appending(path: "Contents/Info.plist")))
        let executable = try #require(info["CFBundleExecutable"] as? String)
        #expect(FileManager.default.isExecutableFile(atPath: product.app.appending(path: "Contents/MacOS/\(executable)").path(percentEncoded: false)))
        #expect((product.assets != nil) == !roms.isEmpty)
    }
}
