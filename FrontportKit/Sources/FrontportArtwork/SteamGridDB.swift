import Foundation
import FrontportCore

/// The parts of the SteamGridDB v2 API Frontport uses: one list of images per kind and game.
struct SteamGridDB: Sendable {
    struct Image: Decodable, Sendable {
        struct Author: Decodable, Sendable {
            var name: String?
        }

        var id: Int
        var url: URL
        var mime: String?
        var width: Int?
        var height: Int?
        var author: Author?
    }

    private struct Response: Decodable {
        var success: Bool
        var data: [Image]?
        var errors: [String]?
    }

    enum Failure: Error {
        /// The key was rejected (HTTP 401 or 403).
        case unauthorized
        case http(Int)
        case malformed
    }

    /// Sent with every request, so SteamGridDB can tell Frontport's traffic apart.
    static let userAgent = "Frontport"

    let base: URL
    let session: URLSession

    /// Static images of a kind for a game, best first. Empty when SteamGridDB has none or doesn't know the game.
    func images(_ kind: ArtworkKind, game: Int, key: String) async throws -> [Image] {
        var components = URLComponents(
            url: base.appending(path: "\(Self.endpoint(kind))/game/\(game)"), resolvingAgainstBaseURL: false)
        components?.queryItems = Self.query(kind)
        guard let url = components?.url else { throw Failure.malformed }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: break
        case 404: return []
        case 401, 403: throw Failure.unauthorized
        default: throw Failure.http(status)
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data), decoded.success else {
            throw Failure.malformed
        }
        return decoded.data ?? []
    }

    /// Downloads an image without credentials; they're only for the API.
    func download(_ image: Image) async throws -> (data: Data, mime: String?) {
        guard image.url.scheme == "https" else { throw Failure.malformed }
        var request = URLRequest(url: image.url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, !data.isEmpty else { throw Failure.http(status) }
        return (data, response.mimeType)
    }

    /// The image to use: for grids the 920×430 landscape, else 460×215, else SteamGridDB's top pick.
    static func choose(_ images: [Image], for kind: ArtworkKind) -> Image? {
        guard kind == .grid else { return images.first }
        return images.first { $0.width == 920 && $0.height == 430 }
            ?? images.first { $0.width == 460 && $0.height == 215 }
            ?? images.first
    }

    static func endpoint(_ kind: ArtworkKind) -> String {
        switch kind {
        case .grid: "grids"
        case .hero: "heroes"
        case .logo: "logos"
        case .icon: "icons"
        }
    }

    static func query(_ kind: ArtworkKind) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "types", value: "static")]
        switch kind {
        case .grid: items.append(URLQueryItem(name: "dimensions", value: "920x430,460x215"))
        case .icon: items.append(URLQueryItem(name: "mimes", value: "image/png"))
        case .hero, .logo: break
        }
        for flag in ["nsfw", "humor", "epilepsy"] {
            items.append(URLQueryItem(name: flag, value: "false"))
        }
        return items
    }

    static func fileExtension(mime: String?, url: URL) -> String {
        switch mime?.lowercased() {
        case "image/png": "png"
        case "image/jpeg", "image/jpg": "jpg"
        case "image/webp": "webp"
        case "image/vnd.microsoft.icon", "image/x-icon": "ico"
        default: url.pathExtension.isEmpty ? "img" : url.pathExtension.lowercased()
        }
    }
}
