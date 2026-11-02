import Foundation
import FrontportCore
import Testing
@testable import FrontportCatalog

/// The lint's rules for an entry's `ios`, and `frontport-catalog` pinning iOS Recipes.
@Suite struct DeviceCatalogLintTests {
    static let iosRecipe = Data("#!/bin/sh\necho build for iOS\n".utf8)
    static let placeholder = String(repeating: "0", count: 64)

    /// The fixture with a valid `ios` on both Ports: Starship's from an iOS Recipe making Build Assets, Ship of
    /// Harkinian's a prebuilt `.ipa` that takes a ROM into Documents.
    static func document() -> CatalogDocument {
        var document = CatalogFixture.document()
        document.ports[0].ios = IOSSpec(
            releases: .git(GitSource(
                repo: "HarbourMasters/Starship", refs: [.stable: "v2.0.0"], recipe: "recipes/starship-ios.sh",
                recipeSHA256: Hashing.sha256(iosRecipe))),
            seedPaths: [nil], buildAssets: BuildAssetsSpec(path: "sf64.o2r", format: "1"))
        document.ports[1].requirements = [
            Requirement(label: "Star Fox 64", stage: .runtime, oneOf: [document.roms[0].sha1], seedPath: "roms/")
        ]
        document.ports[1].ios = IOSSpec(
            releases: .githubRelease(GitHubReleaseSource(repo: "HarbourMasters/Shipwright", asset: "SoH-*-iOS.ipa")),
            seedPaths: ["Documents/sf64.z64"], strip: ["Settings.bundle"],
            blocked: [Block(release: "9.3.0", severity: .warn, reason: "x")])
        return document
    }

    /// Frontport's own Catalog, as the repository has it, passes the lint with the iOS rules too.
    @Test func theBundledCatalogVerifies() throws {
        let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let document = try CatalogTool.verify(catalog: repository.appending(path: "catalog/catalog.json"))
        #expect(!document.ports.isEmpty)
    }

    /// Fallout CE's iOS version: built by its own iOS Recipe from the Mac Port's commit, pinned by the signature, with the
    /// game's folder Seeded into Documents itself.
    @Test func falloutCEsIOSVersionIsPinnedAndSeedsDocuments() throws {
        let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let catalog = repository.appending(path: "catalog/catalog.json")
        let document = try CatalogTool.verify(catalog: catalog)
        let entry = try #require(document.entry("fallout-ce"))
        guard case .git(let mac) = entry.releases, case .git(let ios)? = entry.ios?.releases else {
            Issue.record("Fallout CE and its iOS version are built from source")
            return
        }
        #expect(ios.repo == mac.repo && ios.refs == mac.refs && ios.recipe == "recipes/fallout-ce-ios.sh")
        let pinned = try #require(document.pinnedRecipes.first { $0.owner == "fallout-ce (iOS)" })
        #expect(pinned.path == ios.recipe && pinned.sha256 == ios.recipeSHA256)
        #expect(try Hashing.sha256(file: repository.appending(path: "catalog/\(ios.recipe)")) == ios.recipeSHA256)

        let view = try IOSVersion(of: entry).view
        #expect(view.requirements.map(\.label) == ["Fallout"])
        #expect(try view.requirements[0].seedTarget() == .file(folder: [], name: "Documents"))
        #expect(view.isSourceBuilt && view.buildAssets == nil && view.strip.isEmpty && view.blocked.isEmpty)
    }

    @Test func aValidIOSHasNoProblems() {
        #expect(Self.document().problems() == [])
        // A whole folder ROM goes in Documents itself: a file-shaped seedPath, as on the Mac.
        var document = Self.document()
        document.ports[1].ios?.seedPaths = ["Documents"]
        #expect(document.problems() == [])
    }

    @Test func oneSeedPathPerRequirement() {
        var document = Self.document()
        document.ports[0].ios?.seedPaths = []
        document.ports[1].ios?.seedPaths = ["Documents/", nil]
        #expect(document.problems() == [
            "Port starship has 0 iOS seedPaths for 1 Requirements.",
            "Port shipwright has 2 iOS seedPaths for 1 Requirements.",
        ])
    }

    @Test func aBuildStageRequirementHasNoIOSSeedPath() {
        var document = Self.document()
        document.ports[0].ios?.seedPaths = ["Documents/"]
        #expect(document.problems() == ["Port starship Requirement Star Fox 64 is Build Stage but has an iOS seedPath."])
    }

    /// The same rule Seeding goes by, from the app's container.
    @Test func iosSeedPathsStayInsideTheContainer() {
        for path in ["../escape/", "/Documents/", "Documents/../../x", "./Documents", "", "Documents//x"] {
            var document = Self.document()
            document.ports[1].ios?.seedPaths = [path]
            #expect(document.problems() == [
                "Port shipwright Requirement Star Fox 64 has an iOS seedPath outside its container: \(path)."
            ])
        }
        var document = Self.document()
        document.ports[1].requirements[0].extras = [document.roms[0].sha1]
        #expect(document.problems() == [
            "Port shipwright Requirement Star Fox 64 has extras, so its iOS seedPath must be a folder."
        ])
        document.ports[1].ios?.seedPaths = ["Documents/roms/"]
        #expect(document.problems() == [])
    }

    @Test func anIOSRecipeIsPinnedInsideTheCatalog() {
        var document = Self.document()
        document.ports[0].ios?.releases = .git(GitSource(
            repo: "HarbourMasters/Starship", refs: [.stable: "v2.0.0"], recipe: "../starship-ios.sh", recipeSHA256: "abc"))
        #expect(document.problems() == [
            "Port starship has an iOS Recipe path outside the Catalog: ../starship-ios.sh.",
            "Port starship has a malformed iOS recipeSHA256.",
        ])
    }

    @Test func anIOSVersionOffersAChannel() {
        var document = Self.document()
        document.ports[0].ios?.releases = .git(GitSource(
            repo: "HarbourMasters/Starship", refs: [:], recipe: "recipes/starship-ios.sh",
            recipeSHA256: Hashing.sha256(Self.iosRecipe)))
        document.ports[1].ios?.releases = .githubRelease(GitHubReleaseSource(
            repo: "HarbourMasters/Shipwright", asset: "SoH-*-iOS.ipa", channels: []))
        #expect(document.problems() == ["Port starship offers no iOS Channel.", "Port shipwright offers no iOS Channel."])
    }

    /// Only an iOS Recipe makes Build Assets, and only from a Build-Stage Requirement's ROM.
    @Test func iosBuildAssetsNeedAnIOSRecipeAndABuildStageRequirement() {
        var document = Self.document()
        document.ports[1].ios?.buildAssets = BuildAssetsSpec(path: "sf64.o2r", format: "1")
        #expect(document.problems() == [
            "Port shipwright has iOS buildAssets but no iOS Recipe and Build-Stage Requirement to make them."
        ])

        document = Self.document()
        let recipe = document.ports[0].ios!.releases
        document.ports[1].ios?.releases = recipe
        document.ports[1].ios?.buildAssets = BuildAssetsSpec(path: "sf64.o2r", format: "1")
        #expect(document.problems() == [
            "Port shipwright has iOS buildAssets but no iOS Recipe and Build-Stage Requirement to make them."
        ])
    }

    /// The Packager clones Build Assets into the flat app, where they may not replace its code or signature.
    @Test func iosBuildAssetsStayClearOfTheAppsCode() {
        for path in ["Frameworks/sf64.o2r", "Info.plist", "_CodeSignature", "Lib.framework/sf64.o2r", "a/../sf64.o2r", "/sf64.o2r"] {
            var document = Self.document()
            document.ports[0].ios?.buildAssets?.path = path
            #expect(document.problems() == [
                "Port starship has an iOS buildAssets path that isn’t plainly inside the app, clear of its code: \(path)."
            ])
        }
    }

    @Test func iosStripPathsArePlainAndSpareTheSignature() {
        var document = Self.document()
        let bad = [
            "Contents/MacOS/updater", "contents/x", "Info.plist", "_CodeSignature/CodeResources",
            "embedded.mobileprovision", "../x", "/x", "",
        ]
        document.ports[1].ios?.strip = ["Settings.bundle", "Frameworks/Updater.framework"] + bad
        #expect(document.problems() == bad.map {
            "Port shipwright strips an iOS path that isn’t plainly inside the app or that its signature rests on: \($0)."
        })
    }

    @Test func anUnsupportedPortHasNoIOS() {
        var document = Self.document()
        document.ports[1].unsupported = "Needs a kernel extension."
        #expect(document.problems() == ["Port shipwright is Unsupported, so it may not have ios."])
    }

    /// iOS gives no app Frontport signs JIT.
    @Test func aPortNeedingJITHasNoIOS() {
        var document = Self.document()
        document.ports[0].codeSigning.exceptions = ["allow-jit", "disable-library-validation", "allow-unsigned-executable-memory"]
        #expect(document.problems() == [
            "Port starship needs allow-jit, which iOS doesn’t allow, so it may not have ios.",
            "Port starship needs allow-unsigned-executable-memory, which iOS doesn’t allow, so it may not have ios.",
        ])
        document.ports[0].ios = nil
        #expect(document.problems() == [])
    }

    /// A Mac Release takes the first asset its glob matches, so it may never take the iOS version's `.ipa`.
    @Test func aMacAssetGlobMatchesNoIPA() {
        for asset in ["*", "SoH-*", "SoH-*.ipa", "SoH-?.IPA", "SoH.ip?", "SoH.[ai]pa", "*.zip*"] {
            var document = CatalogFixture.document()
            document.ports[1].releases = .githubRelease(GitHubReleaseSource(repo: "HarbourMasters/Shipwright", asset: asset))
            #expect(document.problems() == ["Port shipwright has an asset glob that could match an .ipa: \(asset)."])
        }
    }

    @Test func globsThatMayEndInASuffix() {
        for pattern in ["*", "a*", "*.ipa", "x.ipa", "x?ipa", "x.?pa", "x.[!z]pa", "x.ip[]a]", "[ab]*", "ipa*", "[.ipa"] {
            #expect(CatalogDocument.glob(pattern, mayEndWith: ".ipa"), "\(pattern)")
        }
        for pattern in ["", "ipa", "pa", ".ipb", "SoH-*-Mac.zip", "*.zip", "*.ipa.zip", "x.ip\\?"] {
            #expect(!CatalogDocument.glob(pattern, mayEndWith: ".ipa"), "\(pattern)")
        }
    }

    // MARK: frontport-catalog

    /// A source with Starship's iOS Recipe beside its own, pinned with a placeholder hash.
    static func source() throws -> CatalogToolTests.Source {
        let source = try CatalogToolTests.Source()
        var document = try JSON.decode(CatalogDocument.self, from: Data(contentsOf: source.catalog))
        document.ports[0].ios = Self.document().ports[0].ios
        if case .git(var git) = document.ports[0].ios?.releases {
            git.recipeSHA256 = placeholder
            document.ports[0].ios?.releases = .git(git)
        }
        try JSON.encode(document).write(to: source.catalog)
        try iosRecipe.write(to: source.folder.appending(path: "recipes/starship-ios.sh"))
        return source
    }

    @Test func signingChecksAndUpdatesTheIOSRecipesHash() throws {
        let source = try Self.source()
        let before = try String(decoding: Data(contentsOf: source.catalog), as: UTF8.self)
        #expect(throws: FrontportError.self) { try CatalogTool.sign(catalog: source.catalog, keyFile: source.keyFile) }

        try CatalogTool.sign(catalog: source.catalog, keyFile: source.keyFile, updateRecipeHashes: true)
        let after = try String(decoding: Data(contentsOf: source.catalog), as: UTF8.self)
        #expect(after == before.replacingOccurrences(of: Self.placeholder, with: Hashing.sha256(Self.iosRecipe)))
        let document = try CatalogTool.verify(catalog: source.catalog, publicKey: source.publicKey)
        guard case .git(let mac) = document.ports[0].releases, case .git(let ios) = document.ports[0].ios?.releases else {
            Issue.record("expected git sources")
            return
        }
        #expect(mac.recipeSHA256 == Hashing.sha256(CatalogFixture.recipe))
        #expect(ios.recipeSHA256 == Hashing.sha256(Self.iosRecipe))
    }

    @Test func aMissingIOSRecipeIsNamedByItsOwner() throws {
        let source = try Self.source()
        try FileManager.default.removeItem(at: source.folder.appending(path: "recipes/starship-ios.sh"))
        let warnings = try CatalogTool.sign(
            catalog: source.catalog, keyFile: source.keyFile, updateRecipeHashes: true, allowMissingRecipes: true)
        #expect(warnings == ["starship (iOS): recipes/starship-ios.sh doesn’t exist; recipeSHA256 left as it is."])
    }

    @Test func bundlingCopiesTheIOSRecipe() throws {
        let source = try Self.source()
        try CatalogTool.sign(catalog: source.catalog, keyFile: source.keyFile, updateRecipeHashes: true)
        let output = try source.directory.folder("Bundled")
        #expect(try CatalogTool.bundle(catalogFolder: source.folder, into: output, publicKey: source.publicKey).isEmpty)
        let files = try FileManager.default.subpathsOfDirectory(atPath: output.path(percentEncoded: false)).sorted()
        #expect(files == ["catalog.json", "catalog.json.sig", "recipes", "recipes/starship-ios.sh", "recipes/starship.sh"])
        #expect(try Data(contentsOf: output.appending(path: "recipes/starship-ios.sh")) == Self.iosRecipe)
    }
}
