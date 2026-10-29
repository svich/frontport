import CryptoKit
import Foundation
import FrontportCore
import Testing
@testable import FrontportCatalog

@Suite struct CatalogToolTests {
    /// A Catalog source folder like `catalog/`: a key, catalog.json and a Recipe.
    struct Source {
        let directory: TemporaryDirectory
        let folder: URL
        let keyFile: URL
        let publicKey: Curve25519.Signing.PublicKey
        var catalog: URL { folder.appending(path: "catalog.json") }

        init(recipe: Data? = CatalogFixture.recipe, recipeSHA256: String? = nil) throws {
            directory = try TemporaryDirectory()
            folder = try directory.folder("catalog")
            keyFile = folder.appending(path: "dev.key")
            publicKey = try CatalogSignature.publicKey(base64: CatalogTool.keygen(keyFile: keyFile))
            var document = CatalogFixture.document()
            if let recipeSHA256, case .git(var git) = document.ports[0].releases {
                git.recipeSHA256 = recipeSHA256
                document.ports[0].releases = .git(git)
            }
            try JSON.encode(document).write(to: catalog)
            if let recipe {
                try FileManager.default.createDirectory(at: folder.appending(path: "recipes"), withIntermediateDirectories: true)
                try recipe.write(to: folder.appending(path: "recipes/starship.sh"))
            }
        }
    }

    @Test func signsAndVerifies() throws {
        let source = try Source()
        #expect(try CatalogTool.sign(catalog: source.catalog, keyFile: source.keyFile).isEmpty)
        let document = try CatalogTool.verify(catalog: source.catalog, publicKey: source.publicKey)
        #expect(document.ports.count == 2)
        #expect(throws: FrontportError.self) {
            try CatalogTool.verify(catalog: source.catalog, publicKey: Curve25519.Signing.PrivateKey().publicKey)
        }
    }

    @Test func refusesAMismatchedOrMissingRecipe() throws {
        let mismatched = try Source(recipeSHA256: String(repeating: "0", count: 64))
        #expect(throws: FrontportError.self) { try CatalogTool.sign(catalog: mismatched.catalog, keyFile: mismatched.keyFile) }

        let missing = try Source(recipe: nil)
        #expect(throws: FrontportError.self) { try CatalogTool.sign(catalog: missing.catalog, keyFile: missing.keyFile) }
        let warnings = try CatalogTool.sign(catalog: missing.catalog, keyFile: missing.keyFile, allowMissingRecipes: true)
        #expect(warnings.count == 1)
        #expect(try CatalogTool.verify(catalog: missing.catalog, publicKey: missing.publicKey).ports.count == 2)
    }

    @Test func updatesRecipeHashesInPlace() throws {
        let placeholder = String(repeating: "0", count: 64)
        let source = try Source(recipeSHA256: placeholder)
        let before = try String(decoding: Data(contentsOf: source.catalog), as: UTF8.self)

        try CatalogTool.sign(catalog: source.catalog, keyFile: source.keyFile, updateRecipeHashes: true)
        let after = try String(decoding: Data(contentsOf: source.catalog), as: UTF8.self)
        let hash = Hashing.sha256(CatalogFixture.recipe)
        #expect(after == before.replacingOccurrences(of: placeholder, with: hash))
        let document = try CatalogTool.verify(catalog: source.catalog, publicKey: source.publicKey)
        guard case .git(let git) = document.ports[0].releases else {
            Issue.record("expected a git source")
            return
        }
        #expect(git.recipeSHA256 == hash)
    }

    @Test func replacesEachHashByTheRecipeItPins() throws {
        let text = #"{ "a": { "recipe": "r/a.sh", "recipeSHA256": "x" }, "b": { "recipe" : "r/b.sh", "recipeSHA256" :"y" }, "c": { "recipe": "r/a.sh", "recipeSHA256": "z" } }"#
        #expect(try CatalogTool.replacingRecipeHashes(in: text, with: ["r/a.sh": "1", "r/b.sh": "2"])
            == #"{ "a": { "recipe": "r/a.sh", "recipeSHA256": "1" }, "b": { "recipe" : "r/b.sh", "recipeSHA256" :"2" }, "c": { "recipe": "r/a.sh", "recipeSHA256": "1" } }"#)
        #expect(throws: FrontportError.self) { try CatalogTool.replacingRecipeHashes(in: text, with: ["r/a.sh": "1"]) }
        #expect(throws: FrontportError.self) {
            try CatalogTool.replacingRecipeHashes(in: #"{ "recipeSHA256": "x" }"#, with: ["r/a.sh": "1"])
        }
    }

    /// An installer's unpack Recipe is pinned like a Port's: signed, hashed and bundled.
    @Test func pinsAnInstallersUnpackRecipe() throws {
        let source = try Source()
        let unpacker = Data("#!/bin/bash\necho unpack\n".utf8)
        try unpacker.write(to: source.folder.appending(path: "recipes/innoextract.sh"))
        var document = try JSON.decode(CatalogDocument.self, from: Data(contentsOf: source.catalog))
        document.roms[0].format = ROMRecord.folderFormat
        document.roms.append(KnownROM(
            sha1: String(repeating: "e", count: 40), game: nil, platform: "n64", name: "Installer", format: "exe",
            unpack: Unpack(recipe: "recipes/innoextract.sh", recipeSHA256: String(repeating: "0", count: 64), yields: [document.roms[0].sha1])))
        try JSON.encode(document).write(to: source.catalog)

        #expect(throws: FrontportError.self) { try CatalogTool.sign(catalog: source.catalog, keyFile: source.keyFile) }
        try CatalogTool.sign(catalog: source.catalog, keyFile: source.keyFile, updateRecipeHashes: true)
        let signed = try CatalogTool.verify(catalog: source.catalog, publicKey: source.publicKey)
        #expect(signed.roms[1].unpack?.recipeSHA256 == Hashing.sha256(unpacker))
        #expect(signed.pinnedRecipes.map(\.path) == ["recipes/innoextract.sh", "recipes/starship.sh"])

        let output = try source.directory.folder("Bundled")
        try CatalogTool.bundle(catalogFolder: source.folder, into: output, publicKey: source.publicKey)
        #expect(try Data(contentsOf: output.appending(path: "recipes/innoextract.sh")) == unpacker)
    }

    @Test func installersYieldFolderROMsAndNoPortTakesTheUnpackPrefix() {
        var document = CatalogFixture.document()
        let rom = document.roms[0].sha1
        let installer = String(repeating: "e", count: 40)
        let unpack = Unpack(recipe: "recipes/innoextract.sh", recipeSHA256: String(repeating: "a", count: 64), yields: [rom])
        document.roms.append(KnownROM(sha1: installer, game: nil, platform: "n64", name: "Installer", format: "exe", unpack: unpack))
        #expect(document.problems() == ["Installer \(installer) yields \(rom), which isn’t a folder ROM in roms."])

        document.roms[0].format = ROMRecord.folderFormat
        #expect(document.problems() == [])

        document.ports[0].requirements[0].oneOf.append(installer)
        document.ports[0].id = "unpack-starship"
        document.ports[0].bundleId = "dev.frontport.port.unpack-starship"
        #expect(document.problems() == [
            "Installer \(installer) is accepted by a Requirement; accept what it yields.",
            "Port unpack-starship may not start with unpack-, which names the unpack Recipes’ build folders.",
        ])
    }

    @Test func refusesAnInconsistentDocument() throws {
        let source = try Source()
        var document = try JSON.decode(CatalogDocument.self, from: Data(contentsOf: source.catalog))
        document.ports[0].requirements[0].oneOf.append("ffffffffffffffffffffffffffffffffffffffff")
        try JSON.encode(document).write(to: source.catalog)
        #expect(throws: FrontportError.self) { try CatalogTool.sign(catalog: source.catalog, keyFile: source.keyFile) }
    }

    @Test func stripPathsStayInsideTheApp() {
        var document = CatalogFixture.document()
        document.ports[1].strip = ["Contents/MacOS/updater", "../escape", "/Applications/Port.app", "Info.plist"]
        #expect(document.problems() == [
            "Port shipwright strips a path outside the app's Contents: ../escape.",
            "Port shipwright strips a path outside the app's Contents: /Applications/Port.app.",
            "Port shipwright strips a path outside the app's Contents: Info.plist.",
        ])
    }

    /// The Packager's link climbs "../" once per component, so each must be a real one.
    @Test func buildAssetsPathsArePlainlyInsideTheApp() {
        for path in ["", "/Contents/Resources/sf64.o2r", "Contents/../sf64.o2r", "Contents/./Resources/sf64.o2r",
            "Contents//Resources/sf64.o2r", "Contents/Resources/"]
        {
            var document = CatalogFixture.document()
            document.ports[0].buildAssets?.path = path
            #expect(document.problems() == ["Port starship has a buildAssets path that isn’t plainly inside the app: \(path)."])
        }
    }

    /// The lint goes by the rule Seeding does, so a Catalog it passes can't fail at Seeding.
    @Test func seedPathsStayInsideData() {
        func document(seedPath: String, extras: [String] = []) -> CatalogDocument {
            var document = CatalogFixture.document()
            document.ports[1].requirements = [
                Requirement(
                    label: "Star Fox 64", stage: .runtime, oneOf: [document.roms[0].sha1], extras: extras, seedPath: seedPath)
            ]
            return document
        }
        #expect(document(seedPath: "roms/").problems() == [])
        #expect(document(seedPath: "roms/sf64.z64").problems() == [])
        for path in ["../escape/", "/etc/", "roms/../../x.z64", "./roms/", "", "/", "roms//sf64.z64"] {
            #expect(document(seedPath: path).problems() == ["Port shipwright Requirement Star Fox 64 has a seedPath outside Data: \(path)."])
        }
        #expect(document(seedPath: "roms/sf64.z64", extras: [document(seedPath: "").roms[0].sha1]).problems() == [
            "Port shipwright Requirement Star Fox 64 has extras, so its seedPath must be a folder."
        ])
    }

    @Test func redirectsLeadFromContentsIntoData() {
        var document = CatalogFixture.document()
        let log = Redirect(path: "Contents/Resources/log", to: "Library/Application Support/Starship/log")
        document.ports[0].redirects = [log]
        #expect(document.problems() == [])

        document.ports[0].redirects = [
            Redirect(path: "Resources/log", to: "Library/log"),
            Redirect(path: "Contents/./log", to: "../Documents"),
            Redirect(path: "Contents/MacOS/log", to: "/Users"),
            Redirect(path: "Contents/Shared//log", to: ""),
        ]
        #expect(document.problems() == [
            "Port starship redirects a path that isn’t plainly inside the app’s Contents/Resources: Resources/log.",
            "Port starship redirects a path that isn’t plainly inside the app’s Contents/Resources: Contents/./log.",
            "Port starship redirects to a folder that isn’t plainly inside Data: ../Documents.",
            "Port starship redirects a path that isn’t plainly inside the app’s Contents/Resources: Contents/MacOS/log.",
            "Port starship redirects to a folder that isn’t plainly inside Data: /Users.",
            "Port starship redirects a path that isn’t plainly inside the app’s Contents/Resources: Contents/Shared//log.",
            "Port starship redirects to a folder that isn’t plainly inside Data: .",
            "Port starship links a path at, above or inside the app’s code or signature: Contents/MacOS/log.",
        ])

        document.ports[0].redirects = [log, log, Redirect(path: "Contents/Resources/log/inner", to: "Library/inner"),
            Redirect(path: "Contents/Resources/sf64.o2r", to: "Library/assets")]
        #expect(document.problems() == [
            "Port starship links both Contents/Resources/log and Contents/Resources/log, which overlap.",
            "Port starship links both Contents/Resources/log and Contents/Resources/log/inner, which overlap.",
            "Port starship links both Contents/Resources/log and Contents/Resources/log/inner, which overlap.",
            "Port starship links both Contents/Resources/sf64.o2r and Contents/Resources/sf64.o2r, which overlap.",
        ])
    }

    /// Through a link where the app's code or what its signature rests on is, the Port could swap in, from its Data,
    /// a program that runs outside its sandbox: in the app, or in an app nested in it, whatever the case.
    @Test func packagerLinksStayClearOfTheAppsCode() {
        for path in ["Contents/Resources/Helper.app", "Contents/Resources/Helper.app/Contents/MacOS/log",
            "Contents/Resources/Nested.APP/Contents/Info.plist"]
        {
            var document = CatalogFixture.document()
            document.ports[0].redirects = [Redirect(path: path, to: "Library/log")]
            #expect(document.problems() == ["Port starship links a path at, above or inside the app’s code or signature: \(path)."])
        }
        for path in ["Contents", "Contents/MacOS/sf64.o2r", "Contents/Frameworks", "Contents/PlugIns/a/b", "Contents/Library",
            "Contents/library/LoginItems/sf64.o2r", "Contents/Info.plist", "Contents/_CodeSignature/sf64.o2r",
            "Contents/CodeResources", "Contents/PkgInfo"]
        {
            var document = CatalogFixture.document()
            document.ports[0].buildAssets?.path = path
            #expect(document.problems() == ["Port starship links a path at, above or inside the app’s code or signature: \(path)."])
        }
    }

    /// The volume folds "ſ" into "s" and composes accents, so only plain ASCII names are compared as they'd be found.
    @Test func packagerLinksArePlainASCII() {
        var document = CatalogFixture.document()
        document.ports[0].redirects = [
            Redirect(path: "Contents/Resources/Helper.app/Content\u{017F}", to: "Library/log"),
            Redirect(path: "Contents/Resources/lo\u{0301}g", to: "Library/lo\u{0301}g"),
        ]
        document.ports[0].buildAssets?.path = "Contents/Re\u{017F}ources/sf64.o2r"
        #expect(document.problems() == [
            "Port starship has a buildAssets path that isn’t plainly inside the app: Contents/Re\u{017F}ources/sf64.o2r.",
            "Port starship redirects a path that isn’t plainly inside the app’s Contents/Resources: "
                + "Contents/Resources/Helper.app/Content\u{017F}.",
            "Port starship redirects a path that isn’t plainly inside the app’s Contents/Resources: Contents/Resources/lo\u{0301}g.",
            "Port starship redirects to a folder that isn’t plainly inside Data: Library/lo\u{0301}g.",
        ])
    }

    @Test func portIDsAndBundleIDsFollowTheConvention() {
        var document = CatalogFixture.document()
        document.ports[0].id = "../starship"
        document.ports[0].bundleId = "dev.frontport.port.../starship"
        document.ports[1].bundleId = "com.example.shipwright"
        let problems = document.problems()
        #expect(problems.contains { $0.contains("../starship") && $0.contains("lowercase") })
        #expect(problems.contains { $0.contains("com.example.shipwright") && $0.contains("dev.frontport.port.shipwright") })

        for id in ["Starship", "-starship", "star ship", "", "star_ship", "starship."] {
            var document = CatalogFixture.document()
            document.ports[0].id = PortID(id)
            document.ports[0].bundleId = PortID(id).conventionalBundleID
            #expect(!document.problems().isEmpty, "\(id)")
        }
        #expect(CatalogFixture.document().problems().isEmpty)
    }

    @Test func duplicateCodeSigningExceptionsAreAProblemNotACrash() {
        var document = CatalogFixture.document()
        document.ports[1].codeSigning = CodeSigning(exceptions: ["allow-jit", "allow-jit"])
        #expect(document.problems() == ["Port shipwright lists code-signing exception allow-jit twice."])
    }

    @Test func gamesNameOnlyListedGenresAndEveryGenreHasAGame() {
        var document = CatalogFixture.document()
        document.genres = [Genre(id: "racing", name: "Racing"), Genre(id: "racing", name: "Racing")]
        document.games[0].genres = ["shooter"]
        #expect(document.problems().sorted() == [
            "Game \(document.games[0].id) names unknown Genre shooter.",
            "Genre racing has no Games.",
            "Genre racing has no Games.",
            "Genre racing is listed twice.",
        ])
    }

    /// Ports from one repository are one Project, which the app names and describes from its first Port.
    @Test func portsOfOneProjectShowTheSameProject() {
        var document = CatalogFixture.document()
        var second = document.ports[0]
        second.id = "starship-2"
        second.bundleId = "dev.frontport.port.starship-2"
        document.ports.append(second)
        #expect(document.problems() == [])

        document.ports[2].name = "Starship 2"
        document.ports[2].kind = .recomp
        document.ports[2].website = URL(string: "https://example.com")
        #expect(document.problems() == [
            "Port starship-2 shares HarbourMasters/Starship with starship, so its name, kind, website must match."
        ])
    }

    @Test func everyKnownROMIsAcceptedBySomeRequirement() {
        var document = CatalogFixture.document()
        let unlisted = String(repeating: "a", count: 40)
        document.roms.append(KnownROM(sha1: unlisted, game: "star-fox-64", name: "Unlisted", format: "z64"))
        #expect(document.problems() == ["ROM \(unlisted) isn’t accepted by any Requirement."])
    }

    @Test func onlyAGamesUpdateOrDLCHasAType() {
        var document = CatalogFixture.document()
        document.roms[0].type = .update
        #expect(document.problems().isEmpty)
        document.roms[0].type = .cartridge
        #expect(document.problems() == ["ROM \(document.roms[0].sha1) may have a type only as a Game’s update or dlc."])
    }

    @Test func platformFilesBelongToTheGamesPlatform() {
        var document = CatalogFixture.document()
        document.platforms.append(Platform(id: "switch", name: "Nintendo Switch", shortName: "Switch", medium: .cartridge))
        let keys = String(repeating: "b", count: 40), other = String(repeating: "c", count: 40)
        let neither = String(repeating: "d", count: 40), both = String(repeating: "e", count: 40)
        document.roms += [
            KnownROM(sha1: keys, game: nil, platform: "n64", name: "Keys", format: "keys"),
            KnownROM(sha1: other, game: nil, platform: "switch", name: "Switch keys", format: "keys"),
            KnownROM(sha1: neither, game: nil, name: "Nothing", format: "bin"),
            KnownROM(sha1: both, game: "star-fox-64", platform: "n64", name: "Both", format: "bin"),
        ]
        document.ports[0].requirements.append(Requirement(label: "Keys", stage: .build, oneOf: [keys, other, neither, both]))
        #expect(document.problems().sorted() == [
            "Port starship Requirement Keys lists \(other), a file of switch.",
            "ROM \(neither) must name either its Game or, for a Platform’s own files, its Platform.",
            "ROM \(both) must name either its Game or, for a Platform’s own files, its Platform.",
        ])
    }

    /// Intake keeps the newest console keys a Requirement accepts, so each accepts them from the newest on.
    @Test func platformFilesAreAcceptedFromTheNewestWithoutAGap() {
        var document = CatalogFixture.document()
        let forms = ["1", "2", "3"].map { String(repeating: $0, count: 40) }
        document.roms += forms.map { KnownROM(sha1: $0, game: nil, platform: "n64", name: "Keys", format: "keys") }
        document.ports[0].requirements.append(Requirement(label: "Keys", stage: .build, oneOf: [forms[0], forms[1]]))
        #expect(document.problems() == ["ROM \(forms[2]) isn’t accepted by any Requirement."])

        for oneOf in [[forms[1]], [forms[0], forms[2]]] {
            document.ports[0].requirements[1].oneOf = oneOf
            let problem = "Port starship Requirement Keys must accept n64’s .keys files from the first in roms on, without a gap."
            #expect(document.problems().filter { !$0.hasPrefix("ROM ") } == [problem])
        }
    }

    @Test func bundlesTheSignedCatalogAndItsRecipes() throws {
        let source = try Source()
        try CatalogTool.sign(catalog: source.catalog, keyFile: source.keyFile)
        let output = source.directory.url.appending(path: "App/Resources/catalog")
        try FileManager.default.createDirectory(at: output.appending(path: "recipes"), withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: output.appending(path: "recipes/old.sh"))

        #expect(try CatalogTool.bundle(catalogFolder: source.folder, into: output, publicKey: source.publicKey).isEmpty)
        let files = try FileManager.default.subpathsOfDirectory(atPath: output.path(percentEncoded: false)).sorted()
        #expect(files == ["catalog.json", "catalog.json.sig", "recipes", "recipes/starship.sh"])
        #expect(try Data(contentsOf: output.appending(path: "catalog.json")) == Data(contentsOf: source.catalog))

        // An unsigned change is refused.
        try Data(" ".utf8).write(to: source.catalog, options: .atomic)
        #expect(throws: FrontportError.self) {
            try CatalogTool.bundle(catalogFolder: source.folder, into: output, publicKey: source.publicKey)
        }
    }
}

/// The Catalog in this repository: `catalog/` and the copy bundled into the app.
@Suite struct RepositoryCatalogTests {
    static let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    @Test func verifiesWithTheBuiltInKeyAndIsConsistent() throws {
        let document = try CatalogTool.verify(catalog: Self.root.appending(path: "catalog/catalog.json"))
        #expect(document.problems() == [])
        #expect(Set(document.ports.map(\.id)) == [
            "2ship", "starship", "zelda64recomp", "ghostship", "opengoal-jak1",
            "opengoal-jak2", "opengoal-jak3", "banjorecomp", "sm64coopdx", "zelda3",
            "uzdoom-doom", "uzdoom-doom2", "uzdoom-heretic", "uzdoom-hexen",
            "dethrace", "dethrace-splat-pack", "fallout-ce",
        ])
        for entry in document.ports {
            #expect(entry.bundleId == entry.id.conventionalBundleID)
            #expect(entry.isInstallable || !(entry.unsupported ?? "").isEmpty)
            #expect(entry.artwork.fallback == document.game(for: entry)?.steamgriddb)
            #expect(entry.screenshots.isEmpty)
        }
    }

    @Test func appBundlesTheSameCatalog() throws {
        let bundled = Self.root.appending(path: "App/Resources/catalog")
        for name in ["catalog.json", "catalog.json.sig"] {
            #expect(try Data(contentsOf: bundled.appending(path: name)) == Data(contentsOf: Self.root.appending(path: "catalog/\(name)")))
        }
    }
}
