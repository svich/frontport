import Foundation

/// A Catalog the user added by link: where Frontport fetches it, and the key every document from it must be signed
/// with, pinned when it was added. See ADR 0012.
public struct AddedCatalog: Codable, Hashable, Sendable, Identifiable {
    /// The folder holding its `catalog.json`, ending in "/".
    public var url: URL
    /// Its Ed25519 public key, base64.
    public var publicKey: String
    public var added: Date

    public var id: URL { url }

    public init(url: URL, publicKey: String, added: Date) {
        self.url = url
        self.publicKey = publicKey
        self.added = added
    }

    /// Names the Catalog's folders: its cache in `Catalogs/` and its installers' unpack workspaces.
    public var folderName: String { Self.folderName(for: url) }

    public static func folderName(for url: URL) -> String {
        String(Hashing.sha256(Data(url.absoluteString.utf8)).prefix(16))
    }

    /// The first 16 bytes of the key's SHA-256, in groups of four hex digits, for the user to compare.
    public var fingerprint: String {
        let hash = Hashing.sha256(Data(base64Encoded: publicKey) ?? Data(publicKey.utf8))
        var groups: [Substring] = []
        var rest = hash.prefix(32)[...]
        while !rest.isEmpty {
            groups.append(rest.prefix(4))
            rest = rest.dropFirst(4)
        }
        return groups.joined(separator: " ")
    }
}

/// An added Catalog as Settings and the Add Catalog sheet show it.
public struct CatalogSummary: Hashable, Sendable, Identifiable {
    public var catalog: AddedCatalog
    /// Its document's name, or its URL's host.
    public var name: String
    /// Its Ports' names.
    public var ports: [String]
    public var issued: Date?
    /// Why it couldn't be read or refreshed, such as "HTTP 404"; nil when it was.
    public var problem: String?

    public var id: URL { catalog.url }

    public init(catalog: AddedCatalog, name: String, ports: [String], issued: Date?, problem: String? = nil) {
        self.catalog = catalog
        self.name = name
        self.ports = ports
        self.issued = issued
        self.problem = problem
    }

    /// The summary of `document`, fetched from `catalog`. A Port whose name another Port shares, as a Project's Ports
    /// do, is named with its Game: "nxnative for Tears of the Kingdom".
    public init(catalog: AddedCatalog, document: CatalogDocument?, problem: String? = nil) {
        let name = document?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = document?.ports ?? []
        let shared = Set(Dictionary(grouping: entries, by: \.name).filter { $0.value.count > 1 }.keys)
        let ports = entries.map { entry in
            guard shared.contains(entry.name), let game = document?.game(for: entry) else { return entry.name }
            return "\(entry.name) for \(game.displayName)"
        }
        self.init(
            catalog: catalog, name: name.flatMap { $0.isEmpty ? nil : $0 } ?? catalog.url.host() ?? catalog.url.absoluteString,
            ports: ports.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, issued: document?.issued,
            problem: problem)
    }
}

extension CatalogDocument {
    /// The document with every Port and ROM marked as listed by the Catalog at `url`, or by Frontport's own for nil,
    /// whatever the document itself says.
    public func listed(by url: URL?) -> CatalogDocument {
        var document = self
        for index in document.ports.indices { document.ports[index].catalog = url }
        for index in document.roms.indices { document.roms[index].catalog = url }
        return document
    }

    /// Frontport's own Catalog and the added ones, each marked with `listed(by:)`, read as one: Platforms, Genres,
    /// Games, ROMs and Ports merged by id, each kept from the first document that lists it. The first document's
    /// version, issue date and name stand for the whole.
    public static func merged(_ documents: [CatalogDocument]) -> CatalogDocument? {
        guard var merged = documents.first else { return nil }
        func append<T>(_ items: [T], to list: inout [T], id: (T) -> String) {
            var seen = Set(list.map(id))
            for item in items where seen.insert(id(item)).inserted { list.append(item) }
        }
        for document in documents.dropFirst() {
            append(document.platforms, to: &merged.platforms) { $0.id.rawValue }
            append(document.genres, to: &merged.genres) { $0.id.rawValue }
            append(document.games, to: &merged.games) { $0.id.rawValue }
            append(document.roms, to: &merged.roms) { $0.sha1 }
            // A bundle ID is always the id's (`checkIdentity()`), so one id per Port keeps each Port's Data its own.
            append(document.ports, to: &merged.ports) { $0.id.rawValue }
        }
        return merged
    }

    /// The document without the Ports installed from another Catalog, so another Catalog listing the same id doesn't
    /// take over an Installation and its Data. An Installation without a recorded entry came from Frontport's own.
    public func excludingPorts(installedFromOtherCatalogs installations: [PortID: Installation]) -> CatalogDocument {
        var document = self
        document.ports.removeAll { entry in
            guard let installation = installations[entry.id] else { return false }
            return installation.entry?.catalog != entry.catalog
        }
        return document
    }
}
