import Foundation
import FrontportCore

/// Frontport's artwork Worker (`worker/`): SteamGridDB artwork, picked and stored in Cloudflare R2 by a server that
/// holds the SteamGridDB key, so the app needs none (ADR 0018).
struct ArtworkWorker: Sendable {
    /// Who made the image, for the credit line.
    struct Credit: Sendable, Equatable {
        /// SteamGridDB asset id.
        var asset: Int
        var author: String?
        var source: URL?
    }

    enum Answer: Sendable {
        case image(Credit, data: Data, mime: String?)
        /// SteamGridDB has no artwork of this kind for the game.
        case none
        /// The asset asked about with `unless` is still SteamGridDB's pick.
        case unchanged(Credit)
    }

    enum Failure: Error {
        case http(Int)
        case malformed
    }

    /// Sent with every request, so the Worker's logs and SteamGridDB can tell Frontport's traffic apart.
    static let userAgent = "Frontport"

    let base: URL
    let session: URLSession

    /// The artwork of a kind for a SteamGridDB game. With `unless`, the asset already cached, the Worker answers
    /// `unchanged` instead of sending the same image again.
    func artwork(_ kind: ArtworkKind, game: Int, unless asset: Int? = nil) async throws -> Answer {
        var request = URLRequest(url: base.appending(path: "\(game)/\(kind.rawValue)"))
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        // Frontport caches in Artwork/ itself.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let asset { request.setValue("\"\(asset)\"", forHTTPHeaderField: "If-None-Match") }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.malformed }
        switch http.statusCode {
        case 200:
            guard !data.isEmpty, let credit = Self.credit(http) else { throw Failure.malformed }
            return .image(credit, data: data, mime: http.mimeType)
        case 304:
            guard let credit = Self.credit(http) else { throw Failure.malformed }
            return .unchanged(credit)
        case 404:
            struct Body: Decodable { var error: String }
            guard (try? JSONDecoder().decode(Body.self, from: data))?.error == "none" else { throw Failure.http(404) }
            return .none
        default:
            throw Failure.http(http.statusCode)
        }
    }

    private static func credit(_ response: HTTPURLResponse) -> Credit? {
        guard let asset = response.value(forHTTPHeaderField: "X-Artwork-Asset").flatMap(Int.init) else { return nil }
        return Credit(
            asset: asset,
            author: response.value(forHTTPHeaderField: "X-Artwork-Author").flatMap { $0.removingPercentEncoding },
            source: response.value(forHTTPHeaderField: "X-Artwork-Source").flatMap(URL.init(string:)))
    }

    static func fileExtension(mime: String?, source: URL?) -> String {
        switch mime?.lowercased() {
        case "image/png": "png"
        case "image/jpeg", "image/jpg": "jpg"
        case "image/webp": "webp"
        case "image/vnd.microsoft.icon", "image/x-icon": "ico"
        default: source.map { $0.pathExtension.isEmpty ? "img" : $0.pathExtension.lowercased() } ?? "img"
        }
    }
}
