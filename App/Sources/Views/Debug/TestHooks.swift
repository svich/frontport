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
/// - `FRONTPORT_FAKE_DEVICE=<port>`, in the environment: `FakeDevices` stand in for `devicectl`, the keychain and the
///   Device Packager, with one iPhone that's ready to install on and one Apple Team, and the Port gets an iOS version
///   from its own Releases, its Runtime ROMs Seeded into `Documents/`, so it can be installed on that iPhone, Seeded and
///   uninstalled without Xcode or a real Device. With `FRONTPORT_FAKE_DEVICE_RENEW` too, what's installed there is due
///   to be Renewed at once.
enum TestHooks {
    static let importedROMs: [URL]? = value(of: "-FrontportImportROMs").map { [URL(filePath: $0)] }

    static let catalog: (url: URL, key: String)? = {
        guard let url = value(of: "-FrontportCatalogURL").flatMap(URL.init(string:)),
            let key = value(of: "-FrontportCatalogKey")
        else { return nil }
        return (url, key)
    }()

    static let gitHubAPI: URL? = value(of: "-FrontportGitHubAPI").flatMap(URL.init(string:))

    static let fakeDevicePort: PortID? = ProcessInfo.processInfo.environment["FRONTPORT_FAKE_DEVICE"]
        .flatMap { $0.isEmpty ? nil : PortID($0) }

    private static let acceptedROM: (port: PortID, sha1: String)? = {
        guard let value = value(of: "-FrontportAcceptROM") else { return nil }
        let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (PortID(parts[0]), parts[1].lowercased())
    }()

    /// The Catalog with `-FrontportAcceptROM` and `FRONTPORT_FAKE_DEVICE` applied; unchanged without them.
    static func prepared(_ catalog: CatalogDocument) -> CatalogDocument {
        var result = catalog
        if let fakeDevicePort, let port = result.ports.firstIndex(where: { $0.id == fakeDevicePort }),
            result.ports[port].ios == nil
        {
            let seedPaths = result.ports[port].requirements.map { $0.stage == .runtime ? "Documents/" : nil }
            result.ports[port].ios = IOSSpec(releases: result.ports[port].releases, seedPaths: seedPaths)
        }
        guard let accepted = acceptedROM,
            let port = result.ports.firstIndex(where: { $0.id == accepted.port }),
            let requirement = result.ports[port].requirements.firstIndex(where: { $0.stage == .runtime }),
            !result.ports[port].requirements[requirement].oneOf.contains(accepted.sha1)
        else { return result }
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
