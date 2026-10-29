import CryptoKit
import Foundation
import FrontportCore
import Testing
@testable import FrontportCatalog

/// A signing key, a document and the folders a CatalogStore works with.
struct CatalogFixture {
    static let recipe = Data("#!/bin/sh\necho build\n".utf8)

    let directory: TemporaryDirectory
    let key = Curve25519.Signing.PrivateKey()
    let paths: AppPaths
    let bundled: URL
    let server = StubServer()

    init() throws {
        directory = try TemporaryDirectory()
        paths = AppPaths(root: try directory.folder("Frontport"), containers: try directory.folder("Containers"))
        bundled = try directory.folder("Bundled")
    }

    func store(bundled: URL? = nil, key: Curve25519.Signing.PublicKey? = nil) -> CatalogStore {
        CatalogStore(
            paths: paths, bundled: bundled ?? self.bundled, baseURL: server.url("catalog/"),
            publicKey: key ?? self.key.publicKey, session: server.session)
    }

    static func document(
        issued: Date = Date(timeIntervalSince1970: 1_792_800_000), version: Int = CatalogDocument.supportedVersion,
        recipe: Data = CatalogFixture.recipe, recipePath: String = "recipes/starship.sh"
    ) -> CatalogDocument {
        let sf64 = "09f0d105f476b00efa5303a3ebc42e60a7753b7a"
        return CatalogDocument(
            version: version, issued: issued,
            platforms: [Platform(id: "n64", name: "Nintendo 64", shortName: "N64", medium: .cartridge)],
            games: [Game(id: "star-fox-64", name: "Star Fox 64", platform: "n64", steamgriddb: 36615)],
            roms: [KnownROM(sha1: sf64, game: "star-fox-64", name: "NTSC 1.1 (US)", format: "z64")],
            ports: [
                CatalogEntry(
                    id: "starship", name: "Starship", kind: .decomp, game: "star-fox-64", developer: "HarbourMasters",
                    summary: "Star Fox 64.", description: "", source: URL(string: "https://github.com/HarbourMasters/Starship")!,
                    bundleId: "dev.frontport.port.starship",
                    releases: .git(GitSource(
                        repo: "HarbourMasters/Starship", refs: [.stable: "v2.0.0"], recipe: recipePath,
                        recipeSHA256: Hashing.sha256(recipe))),
                    requirements: [Requirement(label: "Star Fox 64", stage: .build, oneOf: [sf64])],
                    buildAssets: BuildAssetsSpec(path: "Contents/Resources/sf64.o2r", format: "1")),
                CatalogEntry(
                    id: "shipwright", name: "Ship of Harkinian", kind: .decomp, game: "star-fox-64",
                    developer: "HarbourMasters", summary: "x", description: "",
                    source: URL(string: "https://github.com/HarbourMasters/Shipwright")!,
                    bundleId: "dev.frontport.port.shipwright",
                    releases: .githubRelease(GitHubReleaseSource(repo: "HarbourMasters/Shipwright", asset: "SoH-*-Mac.zip"))),
            ])
    }

    /// The document's bytes and their signature file.
    func signed(_ document: CatalogDocument, with key: Curve25519.Signing.PrivateKey? = nil) throws -> (Data, Data) {
        let data = try JSON.encode(document)
        return (data, try CatalogSignature.sign(data, with: key ?? self.key))
    }

    func write(_ document: CatalogDocument, to folder: URL, recipe: Data? = CatalogFixture.recipe) throws {
        let (data, signature) = try signed(document)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appending(path: "catalog.json"))
        try signature.write(to: folder.appending(path: "catalog.json.sig"))
        if let recipe {
            try FileManager.default.createDirectory(at: folder.appending(path: "recipes"), withIntermediateDirectories: true)
            try recipe.write(to: folder.appending(path: "recipes/starship.sh"))
        }
    }

    func serve(_ document: CatalogDocument, signature: Data? = nil) throws {
        let (data, valid) = try signed(document)
        server.set("catalog/catalog.json", body: data)
        server.set("catalog/catalog.json.sig", body: signature ?? valid)
    }

    func cachedBytes() -> Data? { try? Data(contentsOf: paths.catalogDocument) }
}

@Suite struct CatalogSignatureTests {
    @Test func builtInKeyIsAnEd25519Key() {
        #expect(CatalogSignature.builtInPublicKey.rawRepresentation.count == 32)
    }

    @Test func verifiesExactBytes() throws {
        let key = Curve25519.Signing.PrivateKey()
        let data = Data("{\"a\": 1}".utf8)
        let signature = try CatalogSignature.sign(data, with: key)
        #expect(String(decoding: signature, as: UTF8.self).hasSuffix("\n"))
        #expect(CatalogSignature.isValid(signature, for: data, publicKey: key.publicKey))
        #expect(!CatalogSignature.isValid(signature, for: Data("{\"a\":1}".utf8), publicKey: key.publicKey))
        #expect(!CatalogSignature.isValid(signature, for: data, publicKey: Curve25519.Signing.PrivateKey().publicKey))
        #expect(!CatalogSignature.isValid(Data("not base64".utf8), for: data, publicKey: key.publicKey))
    }

    @Test func rejectsOtherVersions() throws {
        let fixture = try CatalogFixture()
        let (data, signature) = try fixture.signed(CatalogFixture.document(version: CatalogDocument.supportedVersion + 1))
        #expect(throws: FrontportError.self) {
            try CatalogSignature.verifiedDocument(data, signature: signature, publicKey: fixture.key.publicKey)
        }
    }

    @Test func privateKeyFileRoundTrips() throws {
        let directory = try TemporaryDirectory()
        let file = directory.url.appending(path: "test.key")
        let key = Curve25519.Signing.PrivateKey()
        try CatalogSignature.write(key, to: file)
        #expect(try CatalogSignature.privateKey(contentsOf: file).rawRepresentation == key.rawRepresentation)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(throws: FrontportError.self) { try CatalogSignature.write(key, to: file) }
    }
}

@Suite struct CatalogStoreTests {
    @Test func seedsCacheFromBundledCopy() async throws {
        let fixture = try CatalogFixture()
        let document = CatalogFixture.document()
        try fixture.write(document, to: fixture.bundled)

        let current = try await fixture.store().current()
        #expect(current == document)
        #expect(fixture.cachedBytes() == (try Data(contentsOf: fixture.bundled.appending(path: "catalog.json"))))
        #expect(FileManager.default.fileExists(atPath: fixture.paths.catalogSignature.path(percentEncoded: false)))
        #expect(try Data(contentsOf: fixture.paths.recipe("recipes/starship.sh")) == CatalogFixture.recipe)
        #expect(fixture.server.requests.isEmpty)
    }

    @Test func prefersTheNewerOfCacheAndBundledCopy() async throws {
        let fixture = try CatalogFixture()
        let older = CatalogFixture.document(issued: Date(timeIntervalSince1970: 1_700_000_000))
        let newer = CatalogFixture.document(issued: Date(timeIntervalSince1970: 1_800_000_000))

        try fixture.write(older, to: fixture.paths.catalog)
        try fixture.write(newer, to: fixture.bundled)
        #expect(try await fixture.store().current().issued == newer.issued)
        // The newer bundled copy replaced the cache.
        #expect(try await fixture.store(bundled: try fixture.directory.folder("Empty")).current().issued == newer.issued)

        try fixture.write(older, to: fixture.bundled)
        #expect(try await fixture.store().current().issued == newer.issued)
    }

    @Test func skipsATamperedCache() async throws {
        let fixture = try CatalogFixture()
        let document = CatalogFixture.document()
        try fixture.write(document, to: fixture.paths.catalog)
        try Data("{}".utf8).write(to: fixture.paths.catalogDocument)
        try fixture.write(document, to: fixture.bundled)
        #expect(try await fixture.store().current() == document)
    }

    @Test func failsWithoutAVerifiedCopy() async throws {
        let fixture = try CatalogFixture()
        try fixture.write(CatalogFixture.document(), to: fixture.bundled)
        let stranger = Curve25519.Signing.PrivateKey().publicKey
        await #expect(throws: FrontportError.self) { try await fixture.store(key: stranger).current() }

        let empty = try CatalogFixture()
        do {
            _ = try await empty.store().current()
            Issue.record("expected catalogUnavailable")
        } catch FrontportError.catalogUnavailable {
        }
    }

    @Test func refreshVerifiesAndReplacesTheCache() async throws {
        let fixture = try CatalogFixture()
        try fixture.write(CatalogFixture.document(issued: Date(timeIntervalSince1970: 1_700_000_000)), to: fixture.bundled)
        let store = fixture.store()
        _ = try await store.current()

        let fetched = CatalogFixture.document(issued: Date(timeIntervalSince1970: 1_800_000_000))
        try fixture.serve(fetched)
        #expect(try await store.refresh() == fetched)
        #expect(try await store.current() == fetched)
        #expect(fixture.cachedBytes() == (try fixture.signed(fetched).0))
        // The Recipe still matches, so it was carried over.
        #expect(try Data(contentsOf: fixture.paths.recipe("recipes/starship.sh")) == CatalogFixture.recipe)
        // A new store reads the refreshed cache.
        #expect(try await fixture.store(bundled: try fixture.directory.folder("Empty")).current() == fetched)
        // No staging folders are left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.paths.root.path(percentEncoded: false))
        #expect(leftovers == ["Catalog"])
    }

    @Test func refreshKeepsOtherCachesInTheFolder() async throws {
        let fixture = try CatalogFixture()
        try fixture.write(CatalogFixture.document(issued: Date(timeIntervalSince1970: 1_700_000_000)), to: fixture.bundled)
        let store = fixture.store()
        _ = try await store.current()
        let cached = fixture.paths.catalog.appending(path: "releases/response.json")
        try FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("etag".utf8).write(to: cached)

        try fixture.serve(CatalogFixture.document(issued: Date(timeIntervalSince1970: 1_800_000_000)))
        _ = try await store.refresh()

        #expect(try Data(contentsOf: cached) == Data("etag".utf8), "GitHubReleases keeps its responses in Catalog/releases")
    }

    @Test func refreshKeepsTheCacheWhenTheSignatureIsBad() async throws {
        let fixture = try CatalogFixture()
        try fixture.write(CatalogFixture.document(issued: Date(timeIntervalSince1970: 1_700_000_000)), to: fixture.bundled)
        let store = fixture.store()
        let before = try await store.current()
        let cached = fixture.cachedBytes()

        let forged = CatalogFixture.document(issued: Date(timeIntervalSince1970: 1_800_000_000))
        let (_, otherSignature) = try fixture.signed(forged, with: Curve25519.Signing.PrivateKey())
        try fixture.serve(forged, signature: otherSignature)
        do {
            _ = try await store.refresh()
            Issue.record("expected catalogInvalid")
        } catch FrontportError.catalogInvalid {
        }
        #expect(try await store.current() == before)
        #expect(fixture.cachedBytes() == cached)
    }

    @Test func refreshRejectsUndecodableAndUnsupportedDocuments() async throws {
        let fixture = try CatalogFixture()
        let store = fixture.store()

        let garbage = Data("{\"version\": 1}".utf8)
        fixture.server.set("catalog/catalog.json", body: garbage)
        fixture.server.set("catalog/catalog.json.sig", body: try CatalogSignature.sign(garbage, with: fixture.key))
        do {
            _ = try await store.refresh()
            Issue.record("expected catalogInvalid")
        } catch FrontportError.catalogInvalid(let detail) {
            #expect(detail.contains("couldn’t be read"))
        }

        let newer = CatalogDocument.supportedVersion + 1
        try fixture.serve(CatalogFixture.document(version: newer))
        do {
            _ = try await store.refresh()
            Issue.record("expected catalogInvalid")
        } catch FrontportError.catalogInvalid(let detail) {
            #expect(detail.contains("version \(newer)"))
        }
        #expect(fixture.cachedBytes() == nil)
    }

    @Test func refreshReportsNetworkFailures() async throws {
        let fixture = try CatalogFixture()
        try fixture.write(CatalogFixture.document(), to: fixture.bundled)
        let store = fixture.store()
        do {
            _ = try await store.refresh()
            Issue.record("expected a network error")
        } catch FrontportError.network(let detail) {
            #expect(detail.contains("404"))
        }
        #expect(try await store.current() == CatalogFixture.document())
    }

    @Test func refreshNeverStepsBackToAnOlderDocument() async throws {
        let fixture = try CatalogFixture()
        let newer = CatalogFixture.document(issued: Date(timeIntervalSince1970: 1_800_000_000))
        try fixture.write(newer, to: fixture.bundled)
        let store = fixture.store()
        try fixture.serve(CatalogFixture.document(issued: Date(timeIntervalSince1970: 1_700_000_000)))
        #expect(try await store.refresh() == newer)
        #expect(try await store.current() == newer)
    }

    @Test func recipeComesFromCacheThenBundledThenNetwork() async throws {
        let fixture = try CatalogFixture()
        let document = CatalogFixture.document()
        let entry = try #require(document.entry("starship"))

        // Bundled copy (no cache yet).
        try fixture.write(document, to: fixture.bundled)
        let store = fixture.store()
        let fromBundle = try await store.recipe(for: entry)
        #expect(fromBundle == fixture.paths.recipe("recipes/starship.sh"))
        #expect(try Data(contentsOf: fromBundle) == CatalogFixture.recipe)

        // A damaged cached copy and no bundled one: fetched.
        try Data("tampered".utf8).write(to: fromBundle)
        let networkOnly = fixture.store(bundled: try fixture.directory.folder("Empty"))
        fixture.server.set("catalog/recipes/starship.sh", body: CatalogFixture.recipe)
        #expect(try Data(contentsOf: try await networkOnly.recipe(for: entry)) == CatalogFixture.recipe)
        #expect(fixture.server.requests(to: "catalog/recipes/starship.sh").count == 1)

        // Now cached: no further request.
        _ = try await networkOnly.recipe(for: entry)
        #expect(fixture.server.requests(to: "catalog/recipes/starship.sh").count == 1)
    }

    @Test func recipeMustMatchItsHash() async throws {
        let fixture = try CatalogFixture()
        let entry = try #require(CatalogFixture.document().entry("starship"))
        fixture.server.set("catalog/recipes/starship.sh", body: Data("rm -rf /".utf8))
        do {
            _ = try await fixture.store().recipe(for: entry)
            Issue.record("expected catalogInvalid")
        } catch FrontportError.catalogInvalid {
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.recipe("recipes/starship.sh").path(percentEncoded: false)))
    }

    @Test func recipeRejectsPrebuiltEntriesAndEscapingPaths() async throws {
        let fixture = try CatalogFixture()
        let document = CatalogFixture.document(recipePath: "../outside.sh")
        let store = fixture.store()
        await #expect(throws: FrontportError.self) { try await store.recipe(for: try #require(document.entry("shipwright"))) }
        await #expect(throws: FrontportError.self) { try await store.recipe(for: try #require(document.entry("starship"))) }
        #expect(fixture.server.requests.isEmpty)
        for bad in ["/etc/passwd", "recipes/../../x", "", "recipes//x", "./x"] {
            #expect(throws: FrontportError.self) { try CatalogStore.checkedRelativePath(bad) }
        }
        #expect(try CatalogStore.checkedRelativePath("recipes/zelda3.sh") == "recipes/zelda3.sh")
    }
}
