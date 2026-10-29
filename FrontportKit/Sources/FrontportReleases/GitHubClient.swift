import Foundation
import FrontportCore

/// A GitHub REST client that keeps every response with its ETag on disk and revalidates with
/// `If-None-Match`. GitHub doesn't count a 304 against the rate limit, so update checks every 6 hours stay
/// well within the 60 unauthenticated requests per hour.
struct GitHubClient: Sendable {
    struct Response: Sendable {
        /// Nil for 404.
        var body: Data?
        /// HTTP status as received, or 0 when GitHub couldn't be reached.
        var status: Int
        /// True when `body` is the cached copy.
        var cached: Bool
    }

    let api: URL
    let cache: URL
    let session: URLSession
    let token: String?

    /// GETs `path` under the API root. Serves the cached body on 304, and also when GitHub is unreachable,
    /// rate limited or failing, so a stale list beats no list.
    func get(_ path: String, query: [URLQueryItem] = []) async throws -> Response {
        var components = URLComponents(url: api.appending(path: path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw FrontportError.network("Invalid GitHub request \(path).") }

        let entry = cacheFile(for: url)
        let cached = try? JSON.read(CachedResponse.self, from: entry)

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Frontport", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let cached { request.setValue(cached.etag, forHTTPHeaderField: "If-None-Match") }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if let cached { return Response(body: cached.body, status: 0, cached: true) }
            throw FrontportError.network("Couldn’t reach GitHub. \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw FrontportError.network("GitHub sent an unexpected response.")
        }

        switch http.statusCode {
        case 200..<300:
            if let etag = http.value(forHTTPHeaderField: "ETag") {
                try? FileOperations.createDirectory(cache)
                try? JSON.write(CachedResponse(etag: etag, body: data), to: entry)
            }
            return Response(body: data, status: http.statusCode, cached: false)
        case 304:
            guard let cached else { throw FrontportError.network("GitHub answered 304 for \(path) with nothing cached.") }
            return Response(body: cached.body, status: 304, cached: true)
        case 404:
            return Response(body: nil, status: 404, cached: false)
        default:
            if let cached { return Response(body: cached.body, status: http.statusCode, cached: true) }
            throw FrontportError.network(Self.describeFailure(http, path: path))
        }
    }

    private func cacheFile(for url: URL) -> URL {
        // Keyed by URL only: GitHub varies its ETag on Authorization, and a stale ETag just yields a 200.
        cache.appending(path: "\(Hashing.sha256(Data(url.absoluteString.utf8)).prefix(32)).json")
    }

    private static func describeFailure(_ response: HTTPURLResponse, path: String) -> String {
        let status = response.statusCode
        if status == 429 || (status == 403 && response.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0") {
            if let reset = response.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(TimeInterval.init) {
                let time = Date(timeIntervalSince1970: reset).formatted(date: .omitted, time: .shortened)
                return "GitHub’s rate limit was reached. It resets at \(time)."
            }
            return "GitHub’s rate limit was reached."
        }
        return "GitHub returned HTTP \(status) for \(path)."
    }
}

private struct CachedResponse: Codable {
    var etag: String
    var body: Data
}

// MARK: GitHub models

/// The fields Frontport reads from GitHub's release object.
struct GitHubRelease: Decodable, Sendable {
    var tagName: String
    var name: String?
    var body: String?
    var draft: Bool
    var prerelease: Bool
    var createdAt: Date?
    var publishedAt: Date?
    var htmlURL: URL?
    var assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name", name, body, draft, prerelease, createdAt = "created_at"
        case publishedAt = "published_at", htmlURL = "html_url", assets
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try c.decode(String.self, forKey: .tagName)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        body = try c.decodeIfPresent(String.self, forKey: .body)
        draft = try c.decodeIfPresent(Bool.self, forKey: .draft) ?? false
        prerelease = try c.decodeIfPresent(Bool.self, forKey: .prerelease) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        publishedAt = try c.decodeIfPresent(Date.self, forKey: .publishedAt)
        htmlURL = try c.decodeIfPresent(URL.self, forKey: .htmlURL)
        assets = try c.decodeIfPresent([GitHubAsset].self, forKey: .assets) ?? []
    }
}

struct GitHubAsset: Decodable, Sendable {
    var name: String
    var size: Int64
    var browserDownloadURL: URL
    /// "sha256:<hex>"; absent on assets uploaded before GitHub started computing digests (mid 2025).
    var digest: String?

    enum CodingKeys: String, CodingKey {
        case name, size, browserDownloadURL = "browser_download_url", digest
    }

    /// Lowercase hex SHA-256 from `digest`, or nil when there is none or it uses another algorithm.
    var sha256: String? {
        guard let digest else { return nil }
        let parts = digest.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "sha256" else { return nil }
        let hex = parts[1].lowercased()
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex
    }
}

/// The fields Frontport reads from GitHub's commit object.
struct GitHubCommit: Decodable, Sendable {
    struct Detail: Decodable, Sendable {
        struct Signature: Decodable, Sendable { var date: Date? }
        var committer: Signature?
        var author: Signature?
    }

    var commit: Detail

    var date: Date? { commit.committer?.date ?? commit.author?.date }
}
