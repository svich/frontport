#if DEBUG
import Foundation
import FrontportCore

/// Launch arguments the UI tests (App/UITests) use to reach flows that need a file or a ROM they can't provide.
///
/// - `-FrontportImportROMs <file>`: Add ROMs… adds this file instead of showing the open panel.
/// - `-FrontportAcceptROM <port>=<sha1>`: the Catalog also accepts this hash for the Port's first Runtime
///   Requirement, so a made-up file can stand in for its ROM and the Port can be Seeded and played.
/// - `-FrontportCatalogURL <url> -FrontportCatalogKey <base64>`: the Catalog comes from this folder, verified with
///   this Ed25519 public key instead of the built-in one, and the bundled Catalog isn't used.
/// - `-FrontportGitHubAPI <url>`: Releases are discovered from this stand-in for GitHub's API.
enum TestHooks {
    static let importedROMs: [URL]? = value(of: "-FrontportImportROMs").map { [URL(filePath: $0)] }

    static let catalog: (url: URL, key: String)? = {
        guard let url = value(of: "-FrontportCatalogURL").flatMap(URL.init(string:)),
            let key = value(of: "-FrontportCatalogKey")
        else { return nil }
        return (url, key)
    }()

    static let gitHubAPI: URL? = value(of: "-FrontportGitHubAPI").flatMap(URL.init(string:))

    private static let acceptedROM: (port: PortID, sha1: String)? = {
        guard let value = value(of: "-FrontportAcceptROM") else { return nil }
        let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (PortID(parts[0]), parts[1].lowercased())
    }()

    /// The Catalog with `-FrontportAcceptROM` applied; unchanged without it.
    static func prepared(_ catalog: CatalogDocument) -> CatalogDocument {
        guard let accepted = acceptedROM,
            let port = catalog.ports.firstIndex(where: { $0.id == accepted.port }),
            let requirement = catalog.ports[port].requirements.firstIndex(where: { $0.stage == .runtime }),
            !catalog.ports[port].requirements[requirement].oneOf.contains(accepted.sha1)
        else { return catalog }
        var result = catalog
        result.ports[port].requirements[requirement].oneOf.append(accepted.sha1)
        return result
    }

    private static func value(of argument: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: argument), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
#endif
