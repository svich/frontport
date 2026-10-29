import Foundation
import FrontportCore

/// Frontport's own Catalog and the ones the user added by link, read as one (ADR 0012).
///
/// Each added Catalog has a `CatalogStore` of its own, caching it in `Catalogs/<folder name>/` and verifying every
/// document with the key pinned when it was added. One that can't be refreshed keeps its cache, with the reason kept
/// for Settings.
public actor Catalogs: CatalogProviding, CatalogManaging {
    private let paths: AppPaths
    private let builtIn: any CatalogProviding
    private let builtInURL: URL
    private let session: URLSession
    /// Read from `Catalogs/added.json` on first use.
    private var list: [AddedCatalog]?
    private var stores: [URL: CatalogStore] = [:]
    private var problems: [URL: String] = [:]

    /// - Parameters:
    ///   - builtIn: Frontport's own Catalog.
    ///   - builtInURL: where it's fetched from, which can't be added again.
    public init(
        paths: AppPaths, builtIn: any CatalogProviding, builtInURL: URL = CatalogStore.defaultBaseURL,
        session: URLSession = .shared
    ) {
        self.paths = paths
        self.builtIn = builtIn
        self.builtInURL = builtInURL
        self.session = session
    }

    // MARK: CatalogProviding

    public func current() async throws -> CatalogDocument {
        let own = try await builtIn.current()
        return await merged(own)
    }

    /// Refreshes every Catalog at once. Fails when Frontport's own can't be refreshed, as before there were others; an
    /// added one that can't be keeps its cache, and its reason.
    public func refresh() async throws -> CatalogDocument {
        let added = addedCatalogs().compactMap { catalog in (try? store(for: catalog)).map { (catalog.url, $0) } }
        async let own = builtIn.refresh()
        let results = await withTaskGroup(of: (URL, String?).self) { group in
            for (url, store) in added {
                group.addTask {
                    do {
                        _ = try await store.refresh()
                        return (url, nil)
                    } catch {
                        return (url, Self.describe(error))
                    }
                }
            }
            var results: [(URL, String?)] = []
            for await result in group { results.append(result) }
            return results
        }
        for (url, problem) in results where stores[url] != nil { problems[url] = problem }
        try Task.checkCancellation()
        return await merged(try await own)
    }

    public func recipe(for entry: CatalogEntry) async throws -> URL {
        if let url = entry.catalog {
            return try await store(listing: url).recipe(for: entry)
        }
        return try await builtIn.recipe(for: entry)
    }

    public func recipe(at path: String, sha256: String, in catalog: URL?) async throws -> URL {
        if let catalog {
            return try await store(listing: catalog).recipe(at: path, sha256: sha256)
        }
        return try await builtIn.recipe(at: path, sha256: sha256, in: nil)
    }

    // MARK: CatalogManaging

    public func added() async -> [CatalogSummary] {
        var summaries: [CatalogSummary] = []
        for catalog in addedCatalogs() {
            do {
                let document = try await store(for: catalog).current()
                summaries.append(CatalogSummary(catalog: catalog, document: document, problem: problems[catalog.url]))
            } catch {
                summaries.append(CatalogSummary(catalog: catalog, document: nil, problem: Self.describe(error)))
            }
        }
        return summaries
    }

    public func preview(_ link: URL) async throws -> CatalogSummary {
        let (url, key) = try CatalogLink.parse(link)
        try checkNew(url)
        let text: String
        if let key {
            text = key
        } else {
            let data = try await CatalogStore.fetch(url.appending(path: CatalogLink.publicKeyName), session: session)
            text = String(decoding: data, as: UTF8.self)
        }
        let publicKey: String
        do {
            publicKey = CatalogSignature.base64(try CatalogSignature.publicKey(base64: text))
        } catch {
            throw FrontportError.catalogNotAdded("Its public key isn’t an Ed25519 key in base64.")
        }
        let catalog = AddedCatalog(url: url, publicKey: publicKey, added: .now)
        async let data = CatalogStore.fetch(url.appending(path: CatalogStore.documentName), session: session)
        async let signature = CatalogStore.fetch(url.appending(path: CatalogStore.signatureName), session: session)
        let document = try CatalogSignature.verifiedDocument(
            try await data, signature: try await signature, publicKey: try CatalogSignature.publicKey(base64: publicKey))
        if let problem = document.problems().first {
            throw FrontportError.catalogInvalid(problem)
        }
        return CatalogSummary(catalog: catalog, document: document)
    }

    public func add(_ catalog: AddedCatalog) async throws {
        try checkNew(catalog.url)
        let store = try makeStore(catalog)
        do {
            _ = try await store.refresh()
        } catch {
            try? FileManager.default.removeItem(at: paths.addedCatalog(catalog.url))
            throw error
        }
        // Another add of the same Catalog may have finished while this one fetched.
        guard !addedCatalogs().contains(where: { $0.url == catalog.url }) else { return }
        let before = addedCatalogs()
        list = before + [catalog]
        do {
            try save()
        } catch {
            list = before
            try? FileManager.default.removeItem(at: paths.addedCatalog(catalog.url))
            throw error
        }
        stores[catalog.url] = store
        problems[catalog.url] = nil
    }

    public func remove(_ url: URL) async throws {
        let before = addedCatalogs()
        list = before.filter { $0.url != url }
        do {
            try save()
        } catch {
            list = before
            throw error
        }
        stores[url] = nil
        problems[url] = nil
        try? FileManager.default.removeItem(at: paths.addedCatalog(url))
    }

    // MARK: Helpers

    /// Frontport's own Catalog with every added one that can be read, each marked with the Catalog that lists it.
    private func merged(_ own: CatalogDocument) async -> CatalogDocument {
        var documents = [own.listed(by: nil)]
        for catalog in addedCatalogs() {
            do {
                documents.append(try await store(for: catalog).current().listed(by: catalog.url))
            } catch {
                problems[catalog.url] = Self.describe(error)
            }
        }
        return CatalogDocument.merged(documents) ?? own
    }

    private func addedCatalogs() -> [AddedCatalog] {
        if let list { return list }
        let read = (try? JSON.read([AddedCatalog].self, from: paths.addedCatalogList)) ?? []
        list = read
        return read
    }

    private func save() throws {
        do {
            try FileOperations.createDirectory(paths.addedCatalogs)
            try JSON.write(addedCatalogs(), to: paths.addedCatalogList)
        } catch let error as FrontportError {
            throw error
        } catch {
            throw FrontportError.fileOperation("Couldn’t save the list of Catalogs: \(error.localizedDescription)")
        }
    }

    private func checkNew(_ url: URL) throws {
        guard url != builtInURL else {
            throw FrontportError.catalogNotAdded("That’s Frontport’s own Catalog, which is always there.")
        }
        guard !addedCatalogs().contains(where: { $0.url == url }) else {
            throw FrontportError.catalogNotAdded("It’s already in Settings › Catalogs.")
        }
    }

    /// The store of the added Catalog at `url`.
    private func store(listing url: URL) throws -> CatalogStore {
        guard let catalog = addedCatalogs().first(where: { $0.url == url }) else {
            throw FrontportError.catalogUnavailable("The Catalog at \(url.absoluteString) was removed.")
        }
        return try store(for: catalog)
    }

    private func store(for catalog: AddedCatalog) throws -> CatalogStore {
        if let store = stores[catalog.url] { return store }
        let store = try makeStore(catalog)
        stores[catalog.url] = store
        return store
    }

    private func makeStore(_ catalog: AddedCatalog) throws -> CatalogStore {
        CatalogStore(
            paths: paths, folder: paths.addedCatalog(catalog.url), bundled: nil, baseURL: catalog.url,
            publicKey: try CatalogSignature.publicKey(base64: catalog.publicKey), lints: true, session: session)
    }

    private static func describe(_ error: any Error) -> String {
        (error as? FrontportError)?.errorDescription ?? error.localizedDescription
    }
}

/// What a link to add a Catalog names: the folder holding its `catalog.json`, and its public key when the link
/// carries one. Without one, the key is read from `catalog.pub` in the folder.
public enum CatalogLink {
    public static let scheme = "frontport"
    /// `frontport://add-catalog?url=<folder>&key=<base64 public key>`.
    public static let action = "add-catalog"
    /// The file beside `catalog.json` holding the Catalog's public key, base64.
    public static let publicKeyName = "catalog.pub"

    /// A `frontport://add-catalog` link, or the URL of the folder or of its `catalog.json`.
    public static func parse(_ link: URL) throws -> (url: URL, key: String?) {
        guard link.scheme?.lowercased() == scheme else { return (try folder(link), nil) }
        guard link.host()?.lowercased() == action,
            let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems,
            let value = items.first(where: { $0.name == "url" })?.value, let url = URL(string: value)
        else {
            throw FrontportError.catalogNotAdded("The link doesn’t name a Catalog.")
        }
        let key = items.first(where: { $0.name == "key" })?.value.flatMap { $0.isEmpty ? nil : $0 }
        return (try folder(url), key)
    }

    /// The link that adds the Catalog at `url` with `key`.
    public static func link(url: URL, key: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = action
        components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString), URLQueryItem(name: "key", value: key)]
        // Keep "+" and "/" in the key from reading as a space or a path.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    /// An https folder URL (http only to this Mac, for testing), without credentials, query or fragment, ending in "/".
    static func folder(_ url: URL) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased(), !host.isEmpty
        else {
            throw FrontportError.catalogNotAdded("That isn’t a Catalog’s URL.")
        }
        let loopback = ["localhost", "127.0.0.1", "::1"].contains(host)
        guard scheme == "https" || (scheme == "http" && loopback) else {
            throw FrontportError.catalogNotAdded("A Catalog’s URL starts with https://.")
        }
        components.scheme = scheme
        components.host = host
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        var path = components.path
        if path.hasSuffix("/" + CatalogStore.documentName) { path.removeLast(CatalogStore.documentName.count) }
        if !path.hasSuffix("/") { path += "/" }
        components.path = path
        guard let folder = components.url else {
            throw FrontportError.catalogNotAdded("That isn’t a Catalog’s URL.")
        }
        return folder
    }
}
