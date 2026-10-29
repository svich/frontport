import Foundation
import Testing
@testable import FrontportCore

/// Reading Frontport's own Catalog and added ones as one (ADR 0012).
@Suite struct AddedCatalogTests {
    static let added = URL(string: "https://example.org/extra/")!

    /// An added Catalog listing one Port of its own, one with an id Frontport's Catalog uses, and Frontport's Game.
    static var addedDocument: CatalogDocument {
        var document = CatalogDocument(
            issued: .now, name: "Extra", platforms: LineupTests.catalog.platforms, games: LineupTests.catalog.games,
            roms: [], ports: [
                LineupTests.entry("lylat", "Lylat", game: "oot", repo: "someone/lylat"),
                LineupTests.entry("soh", "Impostor", game: "oot", repo: "someone/impostor"),
            ])
        // What a document says about its own Catalog never counts.
        document.ports[0].catalog = URL(string: "https://example.org/forged/")
        return document
    }

    @Test func eachIdIsKeptFromTheFirstCatalogListingIt() throws {
        let merged = try #require(CatalogDocument.merged([
            LineupTests.catalog.listed(by: nil), Self.addedDocument.listed(by: Self.added),
        ]))
        #expect(merged.entry("soh")?.name == LineupTests.catalog.entry("soh")?.name)
        #expect(merged.entry("soh")?.catalog == nil)
        #expect(merged.entry("lylat")?.catalog == Self.added)
        #expect(merged.ports.count == LineupTests.catalog.ports.count + 1)
        #expect(merged.games == LineupTests.catalog.games)
        #expect(merged.name == nil)
        #expect(merged.issued == LineupTests.catalog.issued)
    }

    @Test func installedPortsStayWithTheirCatalog() throws {
        let merged = try #require(CatalogDocument.merged([
            LineupTests.catalog.listed(by: nil), Self.addedDocument.listed(by: Self.added),
        ]))
        let lylat = try #require(merged.entry("lylat"))
        var lylatFromOwn = lylat
        lylatFromOwn.catalog = nil
        var sohFromAdded = try #require(merged.entry("soh"))
        sohFromAdded.catalog = Self.added
        func listed(_ port: PortID, installedWith entry: CatalogEntry?) -> Bool {
            merged.excludingPorts(installedFromOtherCatalogs: [port: Self.installation(port, entry: entry)]).entry(port) != nil
        }
        // A record without an entry was installed from Frontport's Catalog.
        #expect(listed("soh", installedWith: nil))
        #expect(!listed("lylat", installedWith: nil))
        #expect(!listed("lylat", installedWith: lylatFromOwn))
        #expect(listed("lylat", installedWith: lylat))
        #expect(!listed("soh", installedWith: sohFromAdded))
        #expect(merged.excludingPorts(installedFromOtherCatalogs: [:]).ports == merged.ports)
    }

    static func installation(_ port: PortID, entry: CatalogEntry?) -> Installation {
        Installation(
            port: port, release: Release(port: port, version: "1.0.0"), channel: .stable, installedAt: .now,
            appName: "\(port).app", entry: entry)
    }

    @Test func anInstallationKeepsItsEntrysCatalog() throws {
        var entry = try #require(LineupTests.catalog.entry("soh"))
        entry.catalog = Self.added
        let installation = Self.installation("soh", entry: entry)
        let decoded = try JSON.decode(Installation.self, from: JSON.encode(installation))
        #expect(decoded.entry?.catalog == Self.added)
    }

    @Test func addedCatalogsNameTheirFolders() {
        let catalog = AddedCatalog(url: Self.added, publicKey: "vcdxGTYC02uARNy6AP5En27gbhD+1WdiM3ZEfPWlQTg=", added: .now)
        #expect(catalog.folderName.count == 16)
        #expect(catalog.folderName == AddedCatalog.folderName(for: Self.added))
        #expect(catalog.folderName != AddedCatalog.folderName(for: URL(string: "https://example.org/other/")!))
        #expect(catalog.fingerprint.split(separator: " ").map(\.count) == Array(repeating: 4, count: 8))
        let summary = CatalogSummary(catalog: catalog, document: nil)
        #expect(summary.name == "example.org")
        #expect(CatalogSummary(catalog: catalog, document: Self.addedDocument).ports == ["Impostor", "Lylat"])
        var shared = Self.addedDocument
        shared.ports[1].name = "Lylat"
        shared.ports[1].game = "mm"
        #expect(CatalogSummary(catalog: catalog, document: shared).ports == ["Lylat for Majora’s Mask", "Lylat for Ocarina of Time"])
    }
}
