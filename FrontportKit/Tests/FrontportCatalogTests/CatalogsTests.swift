import CryptoKit
import Foundation
import FrontportCore
import Testing
@testable import FrontportCatalog

/// Frontport's own Catalog, bundled and served under `catalog/`, and one the user adds, served under `extra/` and
/// signed with a key of its own.
struct CatalogsFixture {
    static let lylatRecipe = Data("#!/bin/sh\necho lylat\n".utf8)

    let fixture: CatalogFixture
    let key = Curve25519.Signing.PrivateKey()

    init() throws {
        fixture = try CatalogFixture()
        try fixture.write(CatalogFixture.document(), to: fixture.bundled)
        try fixture.serve(CatalogFixture.document())
    }

    var folder: URL { fixture.server.url("extra/") }
    var paths: AppPaths { fixture.paths }

    func catalogs() -> Catalogs {
        Catalogs(
            paths: fixture.paths, builtIn: fixture.store(), builtInURL: fixture.server.url("catalog/"),
            session: fixture.server.session)
    }

    /// One Port of its own, and one with an id Frontport's Catalog uses, both playing Frontport's Game.
    static func document(issued: Date = Date(timeIntervalSince1970: 1_792_800_000), bundleId: String? = nil) -> CatalogDocument {
        let own = CatalogFixture.document()
        return CatalogDocument(
            issued: issued, name: "Extra Ports", platforms: own.platforms, games: own.games, roms: own.roms,
            ports: [
                CatalogEntry(
                    id: "lylat", name: "Lylat", kind: .decomp, game: "star-fox-64", developer: "Someone", summary: "x",
                    description: "", source: URL(string: "https://github.com/someone/lylat")!,
                    bundleId: bundleId ?? "dev.frontport.port.lylat",
                    releases: .git(GitSource(
                        repo: "someone/lylat", refs: [.stable: "v1"], recipe: "recipes/lylat.sh",
                        recipeSHA256: Hashing.sha256(lylatRecipe))),
                    requirements: [Requirement(label: "Star Fox 64", stage: .build, oneOf: [own.roms[0].sha1])],
                    buildAssets: BuildAssetsSpec(path: "Contents/Resources/sf64.o2r", format: "1")),
                CatalogEntry(
                    id: "starship", name: "Impostor", kind: .decomp, game: "star-fox-64", developer: "Someone",
                    summary: "x", description: "", source: URL(string: "https://github.com/someone/impostor")!,
                    bundleId: "dev.frontport.port.starship",
                    releases: .githubRelease(GitHubReleaseSource(repo: "someone/impostor", asset: "*.zip"))),
            ])
    }

    /// Serves `document` signed with `signer` (this Catalog's key by default), its Recipe, and `catalog.pub`.
    func serve(_ document: CatalogDocument = Self.document(), signer: Curve25519.Signing.PrivateKey? = nil, publicKey: Bool = true) throws {
        let data = try JSON.encode(document)
        fixture.server.set("extra/catalog.json", body: data)
        fixture.server.set("extra/catalog.json.sig", body: try CatalogSignature.sign(data, with: signer ?? key))
        fixture.server.set("extra/recipes/lylat.sh", body: Self.lylatRecipe)
        if publicKey {
            fixture.server.set("extra/catalog.pub", body: Data((CatalogSignature.base64(key.publicKey) + "\n").utf8))
        } else {
            fixture.server.remove("extra/catalog.pub")
        }
    }

    func stopServing() {
        for path in ["catalog.json", "catalog.json.sig", "catalog.pub", "recipes/lylat.sh"] {
            fixture.server.remove("extra/" + path)
        }
    }

    /// Adds the served Catalog through `preview(_:)`, as Settings does.
    @discardableResult
    func add(to catalogs: Catalogs) async throws -> CatalogSummary {
        let summary = try await catalogs.preview(folder)
        try await catalogs.add(summary.catalog)
        return summary
    }
}

@Suite struct CatalogsTests {
    @Test func addsACatalogByItsURLWithTheKeyBesideIt() async throws {
        let fixture = try CatalogsFixture()
        try fixture.serve()
        let catalogs = fixture.catalogs()

        let summary = try await catalogs.preview(fixture.folder.appending(path: "catalog.json"))
        #expect(summary.name == "Extra Ports")
        #expect(summary.ports == ["Impostor", "Lylat"])
        #expect(summary.catalog.url == fixture.folder)
        #expect(summary.catalog.publicKey == CatalogSignature.base64(fixture.key.publicKey))
        #expect(await catalogs.added().isEmpty)

        try await catalogs.add(summary.catalog)
        let document = try await catalogs.current()
        #expect(document.entry("lylat")?.catalog == fixture.folder)
        // Frontport's own Catalog keeps its ids and ROMs.
        #expect(document.entry("starship")?.name == "Starship")
        #expect(document.entry("starship")?.catalog == nil)
        #expect(document.roms.count == 1 && document.roms[0].catalog == nil)
        #expect(document.ports.count == 3)

        // The list is a setting: another reader over the same folder has it.
        let again = fixture.catalogs()
        #expect(await again.added().map(\.catalog.url) == [fixture.folder])
        #expect(await again.added().first?.catalog.publicKey == summary.catalog.publicKey)
        #expect(try await again.current().entry("lylat") != nil)
    }

    @Test func aLinkCarriesTheKey() async throws {
        let fixture = try CatalogsFixture()
        try fixture.serve(publicKey: false)
        let catalogs = fixture.catalogs()
        let key = CatalogSignature.base64(fixture.key.publicKey)
        let link = try #require(CatalogLink.link(url: fixture.folder, key: key))
        #expect(try await catalogs.preview(link).catalog.publicKey == key)

        // A link with another key doesn't verify the document.
        let other = CatalogSignature.base64(Curve25519.Signing.PrivateKey().publicKey)
        await #expect(throws: FrontportError.self) {
            try await catalogs.preview(try #require(CatalogLink.link(url: fixture.folder, key: other)))
        }
        // Without a key in the link, nor beside the Catalog, there's nothing to verify it with.
        await #expect(throws: FrontportError.self) { try await catalogs.preview(fixture.folder) }
    }

    @Test func refusesADocumentWithProblems() async throws {
        let fixture = try CatalogsFixture()
        try fixture.serve(CatalogsFixture.document(bundleId: "dev.frontport.port.starship"))
        await #expect(throws: FrontportError.self) { try await fixture.catalogs().preview(fixture.folder) }
    }

    @Test func readsNoFileLargerThanTheCap() async throws {
        let fixture = try CatalogsFixture()
        let server = fixture.fixture.server
        server.set("extra/big", body: Data(count: 64))
        #expect(try await CatalogStore.fetch(server.url("extra/big"), session: server.session, limit: 64).count == 64)
        await #expect(throws: FrontportError.catalogInvalid("big is larger than 63 bytes.")) {
            try await CatalogStore.fetch(server.url("extra/big"), session: server.session, limit: 63)
        }

        // An added Catalog serving a huge document is refused before it's read whole.
        try fixture.serve()
        server.set("extra/catalog.json", body: Data(count: CatalogStore.maxFileSize + 1))
        await #expect(throws: FrontportError.self) { try await fixture.catalogs().preview(fixture.folder) }
    }

    @Test func refusesFrontportsOwnAndOnesAlreadyAdded() async throws {
        let fixture = try CatalogsFixture()
        try fixture.serve()
        let catalogs = fixture.catalogs()
        await #expect(throws: FrontportError.catalogNotAdded("That’s Frontport’s own Catalog, which is always there.")) {
            try await catalogs.preview(fixture.fixture.server.url("catalog"))
        }
        let summary = try await fixture.add(to: catalogs)
        await #expect(throws: FrontportError.self) { try await catalogs.preview(fixture.folder) }
        await #expect(throws: FrontportError.self) { try await catalogs.add(summary.catalog) }
        #expect(await catalogs.added().count == 1)
    }

    @Test func laterDocumentsMustBeSignedWithThePinnedKey() async throws {
        let fixture = try CatalogsFixture()
        try fixture.serve()
        let catalogs = fixture.catalogs()
        try await fixture.add(to: catalogs)

        var forged = CatalogsFixture.document(issued: Date(timeIntervalSince1970: 1_792_900_000))
        forged.ports[0].name = "Forged"
        try fixture.serve(forged, signer: Curve25519.Signing.PrivateKey())
        let document = try await catalogs.refresh()
        #expect(document.entry("lylat")?.name == "Lylat")
        #expect(await catalogs.added().first?.problem?.contains("signature") == true)
    }

    @Test func anUnreachableCatalogKeepsItsCache() async throws {
        let fixture = try CatalogsFixture()
        try fixture.serve()
        let catalogs = fixture.catalogs()
        try await fixture.add(to: catalogs)

        fixture.stopServing()
        let document = try await catalogs.refresh()
        #expect(document.entry("lylat") != nil)
        #expect(await catalogs.added().first?.problem?.contains("404") == true)

        try fixture.serve()
        _ = try await catalogs.refresh()
        #expect(await catalogs.added().first?.problem == nil)
    }

    @Test func recipesComeFromTheCatalogListingThem() async throws {
        let fixture = try CatalogsFixture()
        try fixture.serve()
        let catalogs = fixture.catalogs()
        try await fixture.add(to: catalogs)
        let document = try await catalogs.current()

        let lylat = try await catalogs.recipe(for: try #require(document.entry("lylat")))
        #expect(try Data(contentsOf: lylat) == CatalogsFixture.lylatRecipe)
        #expect(lylat.path().hasPrefix(fixture.paths.addedCatalog(fixture.folder).path()))
        let starship = try await catalogs.recipe(for: try #require(document.entry("starship")))
        #expect(try Data(contentsOf: starship) == CatalogFixture.recipe)
        #expect(starship.path().hasPrefix(fixture.paths.catalog.path()))
        let unpack = try await catalogs.recipe(
            at: "recipes/lylat.sh", sha256: Hashing.sha256(CatalogsFixture.lylatRecipe), in: fixture.folder)
        #expect(unpack == lylat)
    }

    @Test func removingForgetsTheCatalogAndItsCache() async throws {
        let fixture = try CatalogsFixture()
        try fixture.serve()
        let catalogs = fixture.catalogs()
        try await fixture.add(to: catalogs)
        let lylat = try #require(try await catalogs.current().entry("lylat"))

        try await catalogs.remove(fixture.folder)
        #expect(await catalogs.added().isEmpty)
        #expect(try await catalogs.current().entry("lylat") == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.addedCatalog(fixture.folder).path(percentEncoded: false)))
        await #expect(throws: FrontportError.self) { try await catalogs.recipe(for: lylat) }
        #expect(await fixture.catalogs().added().isEmpty)
    }
}

@Suite struct CatalogLinkTests {
    @Test func aURLNamesTheFolderHoldingTheCatalog() throws {
        let folder = URL(string: "https://raw.githubusercontent.com/someone/ports/main/")!
        for written in [
            "https://raw.githubusercontent.com/someone/ports/main", "https://raw.githubusercontent.com/someone/ports/main/",
            "https://raw.githubusercontent.com/someone/ports/main/catalog.json",
            "HTTPS://Raw.GitHubUserContent.com/someone/ports/main/?x=1#top",
        ] {
            let parsed = try CatalogLink.parse(URL(string: written)!)
            #expect(parsed.url == folder, "\(written)")
            #expect(parsed.key == nil)
        }
    }

    @Test func onlyHTTPSOrThisMac() throws {
        #expect(throws: FrontportError.self) { try CatalogLink.parse(URL(string: "http://example.org/catalog/")!) }
        #expect(throws: FrontportError.self) { try CatalogLink.parse(URL(string: "file:///tmp/catalog/")!) }
        #expect(throws: FrontportError.self) { try CatalogLink.parse(URL(string: "frontport://add-catalog?url=http://example.org/")!) }
        #expect(try CatalogLink.parse(URL(string: "http://127.0.0.1:8080/catalog")!).url.absoluteString == "http://127.0.0.1:8080/catalog/")
    }

    @Test func aFrontportLinkCarriesTheURLAndKey() throws {
        let folder = URL(string: "https://example.org/ports/")!
        let key = "vcdxGTYC02uARNy6AP5En27gbhD+1WdiM3ZEfPWlQTg="
        let link = try #require(CatalogLink.link(url: folder, key: key))
        #expect(link.scheme == "frontport")
        let parsed = try CatalogLink.parse(link)
        #expect(parsed.url == folder)
        #expect(parsed.key == key)
        #expect(throws: FrontportError.self) { try CatalogLink.parse(URL(string: "frontport://add-catalog")!) }
        #expect(throws: FrontportError.self) { try CatalogLink.parse(URL(string: "frontport://open?url=https://example.org/")!) }
    }
}
