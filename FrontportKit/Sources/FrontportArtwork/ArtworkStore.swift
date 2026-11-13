import Foundation
import FrontportCore

/// What Frontport knows about one cached piece of artwork: `Artwork/<id>/<kind>.json`.
public struct ArtworkRecord: Codable, Hashable, Sendable {
    public var kind: ArtworkKind
    /// SteamGridDB game id.
    public var steamgriddb: Int
    /// SteamGridDB asset id; nil when SteamGridDB had no artwork of this kind for the game.
    public var assetID: Int?
    /// File name inside `Artwork/<id>/`.
    public var file: String?
    /// The artist, for the credit line.
    public var author: String?
    public var source: URL?
    public var fetched: Date

    public init(
        kind: ArtworkKind, steamgriddb: Int, assetID: Int? = nil, file: String? = nil, author: String? = nil,
        source: URL? = nil, fetched: Date
    ) {
        self.kind = kind
        self.steamgriddb = steamgriddb
        self.assetID = assetID
        self.file = file
        self.author = author
        self.source = source
        self.fetched = fetched
    }
}

/// SteamGridDB artwork, fetched through Frontport's artwork Worker and cached in `Artwork/`. The Worker holds the
/// SteamGridDB key and keeps every image in Cloudflare R2, with SteamGridDB's permission (ADR 0018).
public actor ArtworkStore: ArtworkProviding {
    public static let defaultBase = URL(string: "https://frontport-artwork.frontport.workers.dev/v1/")!
    /// Cached artwork older than this is checked again by `refresh`.
    public static let defaultMaxAge: TimeInterval = 7 * 24 * 60 * 60

    private struct CacheKey: Hashable {
        var id: Int
        var kind: ArtworkKind
    }

    private let paths: AppPaths
    private let worker: ArtworkWorker
    private let maxAge: TimeInterval
    private let now: @Sendable () -> Date
    private var inFlight: [CacheKey: Task<ArtworkRecord?, Never>] = [:]

    public init(
        paths: AppPaths, session: URLSession = .shared, base: URL = ArtworkStore.defaultBase,
        maxAge: TimeInterval = ArtworkStore.defaultMaxAge, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.paths = paths
        self.worker = ArtworkWorker(base: base, session: session)
        self.maxAge = maxAge
        self.now = now
    }

    // MARK: ArtworkProviding

    public func artwork(_ kind: ArtworkKind, for entry: CatalogEntry) async -> URL? {
        await artwork(kind, ids: Self.ids(for: entry))
    }

    public func artwork(_ kind: ArtworkKind, for game: Game) async -> URL? {
        await artwork(kind, ids: game.steamgriddb.map { [$0] } ?? [])
    }

    public func refresh(_ entries: [CatalogEntry]) async {
        let ids = Set(entries.flatMap(Self.ids(for:)))
        for id in ids.sorted() {
            for kind in ArtworkKind.allCases {
                // Only what the app has asked for before is cached, so only that is refreshed.
                guard let record = record(kind, id: id), isStale(record) else { continue }
                _ = await fetch(kind, id: id)
            }
        }
    }

    public func compact() async {
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: paths.artwork.path(percentEncoded: false))) ?? []
        for id in folders.compactMap(Int.init).sorted() {
            for kind in ArtworkKind.allCases {
                guard let record = record(kind, id: id), let file = file(for: record) else { continue }
                let scaled = await Task.detached(priority: .utility) {
                    ArtworkScaling.scaled(contentsOf: file, kind: kind)
                }.value
                // A fetch may have replaced the file meanwhile.
                guard let scaled, self.record(kind, id: id) == record else { continue }
                var compacted = record
                compacted.file = "\(kind.rawValue).\(scaled.fileExtension)"
                try? save(compacted, data: scaled.data)
            }
        }
    }

    // MARK: Credits

    /// The record behind the file `artwork(_:for:)` returns, for crediting its author.
    public func record(_ kind: ArtworkKind, for entry: CatalogEntry) -> ArtworkRecord? {
        Self.ids(for: entry).lazy.compactMap { self.record(kind, id: $0) }.first { self.file(for: $0) != nil }
    }

    // MARK: Lookup

    /// The Port's own SteamGridDB entry first, then the Game's.
    private static func ids(for entry: CatalogEntry) -> [Int] {
        var ids: [Int] = []
        for id in [entry.artwork.steamgriddb, entry.artwork.fallback].compactMap(\.self) where !ids.contains(id) {
            ids.append(id)
        }
        return ids
    }

    private func artwork(_ kind: ArtworkKind, ids: [Int]) async -> URL? {
        for id in ids {
            if let record = record(kind, id: id) {
                if let file = file(for: record) { return file }
                // SteamGridDB had none of this kind recently: try the next id without asking again.
                if record.assetID == nil, !isStale(record) { continue }
            }
            if let record = await fetch(kind, id: id), let file = file(for: record) {
                return file
            }
        }
        return nil
    }

    private func isStale(_ record: ArtworkRecord) -> Bool {
        now().timeIntervalSince(record.fetched) >= maxAge
    }

    // MARK: Cache

    private func folder(_ id: Int) -> URL { paths.artwork(steamgriddb: id) }

    private func recordURL(_ kind: ArtworkKind, id: Int) -> URL {
        folder(id).appending(path: "\(kind.rawValue).json")
    }

    private func record(_ kind: ArtworkKind, id: Int) -> ArtworkRecord? {
        try? JSON.read(ArtworkRecord.self, from: recordURL(kind, id: id))
    }

    private func file(for record: ArtworkRecord) -> URL? {
        guard let name = record.file else { return nil }
        let url = folder(record.steamgriddb).appending(path: name)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    // MARK: Fetching

    /// Fetches once per kind and id at a time; concurrent callers share the result.
    private func fetch(_ kind: ArtworkKind, id: Int) async -> ArtworkRecord? {
        let cacheKey = CacheKey(id: id, kind: kind)
        if let running = inFlight[cacheKey] { return await running.value }
        let task = Task { await self.download(kind, id: id) }
        inFlight[cacheKey] = task
        let result = await task.value
        inFlight[cacheKey] = nil
        return result
    }

    /// Asks the Worker for the artwork and caches it. Nil on any failure, leaving the cache as it was.
    private func download(_ kind: ArtworkKind, id: Int) async -> ArtworkRecord? {
        let previous = record(kind, id: id)
        let cachedAsset = previous.flatMap { file(for: $0) == nil ? nil : $0.assetID }
        do {
            switch try await worker.artwork(kind, game: id, unless: cachedAsset) {
            case .none:
                let none = ArtworkRecord(kind: kind, steamgriddb: id, fetched: now())
                try save(none, data: nil)
                return none
            case .unchanged(let credit):
                guard var refreshed = previous, cachedAsset == credit.asset else { return nil }
                refreshed.author = credit.author
                refreshed.fetched = now()
                try save(refreshed, data: nil)
                return refreshed
            case .image(let credit, let original, let mime):
                let scaled = await Task.detached(priority: .utility) { ArtworkScaling.scaled(original, kind: kind) }.value
                let fileExtension = scaled?.fileExtension ?? ArtworkWorker.fileExtension(mime: mime, source: credit.source)
                let record = ArtworkRecord(
                    kind: kind, steamgriddb: id, assetID: credit.asset, file: "\(kind.rawValue).\(fileExtension)",
                    author: credit.author, source: credit.source, fetched: now())
                try save(record, data: scaled?.data ?? original)
                return record
            }
        } catch {
            return nil
        }
    }

    /// Writes the image (when given) and then its record, removing older images of the same kind.
    private func save(_ record: ArtworkRecord, data: Data?) throws {
        let folder = folder(record.steamgriddb)
        try FileOperations.createDirectory(folder)
        if let data, let name = record.file {
            try data.write(to: folder.appending(path: name), options: .atomic)
        }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        for name in contents where name.hasPrefix("\(record.kind.rawValue).") && name != record.file
            && name != "\(record.kind.rawValue).json"
        {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
        try JSON.write(record, to: recordURL(record.kind, id: record.steamgriddb))
    }
}
