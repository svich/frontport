import CryptoKit
import Foundation
import FrontportCore

/// Loads, verifies and caches one signed Catalog: Frontport's own in `AppPaths.catalog`, or an added one in its own
/// folder.
///
/// Every copy is verified with `publicKey` before use: the cache, the bundled copy the app ships in
/// `Contents/Resources/catalog`, and each fetched document. The cache is replaced only by a verified
/// document, as a whole folder swapped in atomically.
public actor CatalogStore: CatalogProviding {
    public static let defaultBaseURL = URL(string: "https://raw.githubusercontent.com/svich/frontport/main/catalog/")!

    static let documentName = "catalog.json"
    static let signatureName = "catalog.json.sig"

    private let paths: AppPaths
    private let folder: URL
    private let bundled: URL?
    private let baseURL: URL
    private let publicKey: Curve25519.Signing.PublicKey
    private let lints: Bool
    private let session: URLSession
    private var loaded: CatalogDocument?

    /// - Parameters:
    ///   - folder: the cache, `AppPaths.catalog` when nil.
    ///   - bundled: a folder holding `catalog.json`, `catalog.json.sig` and `recipes/`, used to seed the cache.
    ///   - baseURL: where `refresh()` fetches `catalog.json`, its signature and Recipes from.
    ///   - lints: refuse a fetched document with `problems()`, as for a Catalog the user added, which no one checked
    ///     before signing.
    public init(
        paths: AppPaths, folder: URL? = nil, bundled: URL?, baseURL: URL = CatalogStore.defaultBaseURL,
        publicKey: Curve25519.Signing.PublicKey = CatalogSignature.builtInPublicKey, lints: Bool = false,
        session: URLSession = .shared
    ) {
        self.paths = paths
        self.folder = folder ?? paths.catalog
        self.bundled = bundled
        self.baseURL = baseURL
        self.publicKey = publicKey
        self.lints = lints
        self.session = session
    }

    // MARK: CatalogProviding

    public func current() async throws -> CatalogDocument {
        if let loaded { return loaded }
        let cached = try? read(folder)
        let shipped: CatalogDocument?
        var shippedError: (any Error)?
        do {
            shipped = try bundled.map(read)
        } catch {
            shipped = nil
            shippedError = error
        }

        let document: CatalogDocument
        if let shipped, let bundled, shipped.issued > (cached?.issued ?? .distantPast) {
            // No cache yet, or an app update shipped a newer Catalog than the cache: seed from it. If the
            // cache can't be written, the verified bundled copy still serves.
            try? replaceCache(with: shipped, from: bundled)
            document = shipped
        } else if let cached {
            document = cached
        } else {
            let detail = shippedError.map { "The bundled Catalog is invalid. \(Self.describe($0))" }
                ?? "There is no cached or bundled Catalog."
            throw FrontportError.catalogUnavailable(detail)
        }
        loaded = document
        return document
    }

    public func refresh() async throws -> CatalogDocument {
        let documentURL = baseURL.appending(path: Self.documentName)
        let signatureURL = baseURL.appending(path: Self.signatureName)
        async let data = fetch(documentURL)
        async let signature = fetch(signatureURL)
        let (documentData, signatureData) = try await (data, signature)
        let document = try CatalogSignature.verifiedDocument(documentData, signature: signatureData, publicKey: publicKey)
        if lints, let problem = document.problems().first {
            throw FrontportError.catalogInvalid(problem)
        }

        // A CDN can briefly serve an older document; never step back to it.
        if let existing = try? await current(), existing.issued > document.issued {
            return existing
        }
        let staged = try stage(documentData, signature: signatureData)
        defer { try? FileManager.default.removeItem(at: staged) }
        try replaceCache(with: document, from: staged)
        loaded = document
        return document
    }

    public func recipe(for entry: CatalogEntry) async throws -> URL {
        guard case .git(let source) = entry.releases else {
            throw FrontportError.catalogInvalid("\(entry.id) isn’t built from source, so it has no Recipe.")
        }
        return try await recipe(at: source.recipe, sha256: source.recipeSHA256)
    }

    /// This store's Recipe at `path`: a store reads one Catalog, so `catalog` is `Catalogs`' to route by.
    public func recipe(at path: String, sha256: String, in catalog: URL?) async throws -> URL {
        try await recipe(at: path, sha256: sha256)
    }

    public func recipe(at path: String, sha256: String) async throws -> URL {
        let relative = try Self.checkedRelativePath(path)
        let destination = folder.appending(path: relative)
        if Self.file(destination, matches: sha256) { return destination }

        if let bundled {
            let shipped = bundled.appending(path: relative)
            if Self.file(shipped, matches: sha256) {
                try install(Data(contentsOf: shipped), at: destination)
                return destination
            }
        }

        let data = try await fetch(baseURL.appending(path: relative))
        guard Hashing.sha256(data) == sha256.lowercased() else {
            throw FrontportError.catalogInvalid("The Recipe \(relative) doesn’t match the Catalog.")
        }
        try install(data, at: destination)
        return destination
    }

    // MARK: Loading

    /// Reads and verifies `catalog.json` and its signature in a folder.
    private func read(_ folder: URL) throws -> CatalogDocument {
        let data = try Data(contentsOf: folder.appending(path: Self.documentName))
        let signature = try Data(contentsOf: folder.appending(path: Self.signatureName))
        return try CatalogSignature.verifiedDocument(data, signature: signature, publicKey: publicKey)
    }

    /// Writes a fetched document and signature into a new folder next to the cache.
    private func stage(_ data: Data, signature: Data) throws -> URL {
        let folder = paths.root.appending(path: ".Catalog-download-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileOperations.createDirectory(folder)
        do {
            try data.write(to: folder.appending(path: Self.documentName))
            try signature.write(to: folder.appending(path: Self.signatureName))
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw FrontportError.fileOperation("Couldn’t save the Catalog: \(error.localizedDescription)")
        }
        return folder
    }

    /// Builds a complete new cache folder from `source` (its catalog.json and signature, which must be the
    /// verified `document`) and swaps it in. Recipes that still match the document are carried over from the
    /// old cache or taken from `source` and the bundled copy; others are fetched on demand.
    private func replaceCache(with document: CatalogDocument, from source: URL) throws {
        let fileManager = FileManager.default
        let staging = paths.root.appending(path: ".Catalog-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: staging) }
        do {
            try FileOperations.createDirectory(staging)
            for name in [Self.documentName, Self.signatureName] {
                try FileOperations.clone(source.appending(path: name), to: staging.appending(path: name))
            }
            for pinned in document.pinnedRecipes {
                guard let relative = try? Self.checkedRelativePath(pinned.path) else { continue }
                let candidates = [folder, source, bundled].compactMap { $0?.appending(path: relative) }
                guard let match = candidates.first(where: { Self.file($0, matches: pinned.sha256) }) else { continue }
                let target = staging.appending(path: relative)
                guard !fileManager.fileExists(atPath: target.path(percentEncoded: false)) else { continue }
                try FileOperations.createDirectory(target.deletingLastPathComponent())
                try FileOperations.clone(match, to: target)
            }
            // Other caches kept in the folder, such as the Releases' responses, stay.
            let kept = (try? fileManager.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
            for name in kept where ![Self.documentName, Self.signatureName, "recipes"].contains(name) {
                try FileOperations.clone(folder.appending(path: name), to: staging.appending(path: name))
            }
            if fileManager.fileExists(atPath: folder.path(percentEncoded: false)) {
                try FileOperations.swap(staging, folder)
            } else {
                try FileOperations.createDirectory(folder.deletingLastPathComponent())
                try fileManager.moveItem(at: staging, to: folder)
            }
        } catch let error as FrontportError {
            throw error
        } catch {
            throw FrontportError.fileOperation("Couldn’t save the Catalog: \(error.localizedDescription)")
        }
    }

    private func install(_ data: Data, at destination: URL) throws {
        do {
            try FileOperations.createDirectory(destination.deletingLastPathComponent())
            try data.write(to: destination, options: .atomic)
        } catch let error as FrontportError {
            throw error
        } catch {
            throw FrontportError.fileOperation("Couldn’t save \(destination.lastPathComponent): \(error.localizedDescription)")
        }
    }

    // MARK: Network

    private func fetch(_ url: URL) async throws -> Data {
        try await Self.fetch(url, session: session)
    }

    /// The most Frontport reads of any Catalog file, about 100 times the largest Catalog or Recipe: a Catalog the user
    /// added can't fill memory or the disk by serving a huge one.
    static let maxFileSize = 4 << 20

    /// The body of a 200 response, fetched past any local cache. Stops reading, and fails, past `limit` bytes.
    static func fetch(_ url: URL, session: URLSession, limit: Int = maxFileSize) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let tooLarge = FrontportError.catalogInvalid(
            "\(url.lastPathComponent) is larger than \(limit.formatted(.byteCount(style: .file))).")
        var data = Data()
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw FrontportError.network("\(url.lastPathComponent): HTTP \(status)")
            }
            guard response.expectedContentLength <= Int64(limit) else { throw tooLarge }
            for try await byte in bytes {
                guard data.count < limit else { throw tooLarge }
                data.append(byte)
            }
        } catch let error as FrontportError {
            throw error
        } catch {
            try Task.checkCancellation()
            throw FrontportError.network("\(url.lastPathComponent): \(error.localizedDescription)")
        }
        return data
    }

    // MARK: Helpers

    /// A Recipe path must stay inside the Catalog folder.
    static func checkedRelativePath(_ path: String) throws -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else {
            throw FrontportError.catalogInvalid("The Recipe path \(path) isn’t inside the Catalog.")
        }
        return path
    }

    static func file(_ url: URL, matches sha256: String) -> Bool {
        guard let actual = try? Hashing.sha256(file: url) else { return false }
        return actual == sha256.lowercased()
    }

    private static func describe(_ error: any Error) -> String {
        (error as? FrontportError)?.errorDescription ?? error.localizedDescription
    }
}
