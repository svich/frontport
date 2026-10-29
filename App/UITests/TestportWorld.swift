import CryptoKit
import Foundation
import FrontportCatalog
import FrontportCore

/// Testport (App/Testport) published the way an upstream Port is: a test Catalog signed with a key made here,
/// GitHub's release list and the zipped app, all served from the loopback interface. A Session launched with it
/// points the Debug app at this server instead of the real Catalog and GitHub, so nothing leaves the Mac.
struct TestportWorld {
    static let port = "testport"
    static let name = "Testport"
    static let game = "synthetic-64"
    static let repo = "frontport-tests/testport"
    static let seedPath = "Library/Application Support/Testport/Testport.z64"

    let server: LocalServer
    /// The ROM the Catalog accepts for Testport's Runtime Requirement.
    let rom = SyntheticROM(marker: "accepted")
    /// Another dump of the Game that Testport also accepts.
    let spare = SyntheticROM(marker: "spare")
    let catalog: Data
    let signature: Data
    /// The base64 public half of the key the Catalog is signed with.
    let publicKey: String

    /// Serves the Catalog and one Release of Testport per version, newest last.
    init(versions: [String] = ["1.0"]) async throws {
        server = try await LocalServer()
        let key = Curve25519.Signing.PrivateKey()
        publicKey = CatalogSignature.base64(key.publicKey)
        catalog = try JSON.encode(Self.document(accepting: rom.sha1, spare: spare.sha1))
        signature = try CatalogSignature.sign(catalog, with: key)
        server.serve("catalog/catalog.json", .json(catalog))
        server.serve("catalog/catalog.json.sig", .ok(signature))
        try publish(versions)
    }

    /// Launch arguments that point the Debug app at this server.
    var arguments: [String] {
        [
            "-FrontportCatalogURL", server.url("catalog/").absoluteString,
            "-FrontportCatalogKey", publicKey,
            "-FrontportGitHubAPI", server.url("api/").absoluteString,
        ]
    }

    /// Writes the Catalog into a root's cache, so the app opens on it before it first refreshes.
    func seedCatalog(in root: URL) throws {
        let folder = root.appending(path: "Catalog", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try catalog.write(to: folder.appending(path: "catalog.json"))
        try signature.write(to: folder.appending(path: "catalog.json.sig"))
    }

    private static func document(accepting sha1: String, spare: String) -> CatalogDocument {
        let entry = CatalogEntry(
            id: PortID(port), name: name, kind: .recomp, game: GameID(game), developer: "Frontport tests",
            summary: "A stand-in Port that reports the ROM it finds.", description: "",
            source: URL(string: "https://github.com/\(repo)")!, bundleId: PortID(port).conventionalBundleID,
            releases: .githubRelease(GitHubReleaseSource(repo: repo, asset: "Testport-*-mac.zip")),
            requirements: [Requirement(label: "Synthetic 64", stage: .runtime, oneOf: [sha1, spare], seedPath: seedPath)],
            launch: LaunchSpec(arguments: [seedPath]))
        return CatalogDocument(
            issued: .now,
            platforms: [Platform(id: "n64", name: "Nintendo 64", shortName: "N64", medium: .cartridge)],
            games: [Game(id: GameID(game), name: "Synthetic 64", platform: "n64")],
            roms: [
                KnownROM(sha1: sha1, game: GameID(game), name: "Synthetic (Test)", format: "z64"),
                KnownROM(sha1: spare, game: GameID(game), name: "Synthetic (Spare)", format: "z64"),
            ],
            ports: [entry])
    }

    /// Serves GitHub's release list, newest first, and each Release's zip with its digest.
    private func publish(_ versions: [String]) throws {
        let built = try Self.builtApp()
        let work = FileManager.default.temporaryDirectory.appending(
            path: "FrontportUITests/testport-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileOperations.removeUntrusted(work) }

        var list: [[String: Any]] = []
        for (index, version) in versions.enumerated().reversed() {
            let zip = try Self.zip(built, version: version, in: work.appending(path: version, directoryHint: .isDirectory))
            let name = "Testport-\(version)-mac.zip"
            let download = "download/v\(version)/\(name)"
            server.serve(download, .ok(zip))
            let date = Date.now.addingTimeInterval(Double(index - versions.count) * 86_400).formatted(.iso8601)
            list.append([
                "tag_name": "v\(version)", "name": "Testport \(version)", "body": "Testport \(version).",
                "draft": false, "prerelease": false, "created_at": date, "published_at": date,
                "html_url": server.url("releases/v\(version)").absoluteString,
                "assets": [[
                    "name": name, "size": zip.count, "browser_download_url": server.url(download).absoluteString,
                    "digest": "sha256:\(Hashing.sha256(zip))",
                ]],
            ])
        }
        server.serve("api/repos/\(Self.repo)/releases", .json(try JSONSerialization.data(withJSONObject: list)))
    }

    /// Testport.app as its target built it, copied into this test bundle's resources.
    private static func builtApp() throws -> URL {
        guard let app = Bundle(for: Session.self).url(forResource: "Testport", withExtension: "app") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Testport.app isn't in the test bundle"])
        }
        return app
    }

    /// The app at `version`, signed ad hoc as upstream would have, zipped as upstream publishes it.
    private static func zip(_ built: URL, version: String, in folder: URL) throws -> Data {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let app = folder.appending(path: "Testport.app", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: built, to: app)
        let plist = app.appending(path: "Contents/Info.plist")
        var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any] ?? [:]
        info["CFBundleShortVersionString"] = version
        info["CFBundleVersion"] = version
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)
        try run("/usr/bin/codesign", ["--force", "--sign", "-", app.path(percentEncoded: false)])
        let archive = folder.appending(path: "Testport-\(version)-mac.zip")
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path(percentEncoded: false), archive.path(percentEncoded: false)])
        return try Data(contentsOf: archive)
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableLoad, userInfo: [
                NSLocalizedDescriptionKey: "\(executable) \(arguments.joined(separator: " ")) exited with \(process.terminationStatus)"
            ])
        }
    }
}

/// What Testport writes to `Library/Application Support/Testport/report.json` in its Data at each launch.
struct TestportReport: Decodable {
    struct ROM: Decodable {
        var path: String
        var sha1: String
        var size: Int
    }

    var version: String
    var sandboxed: Bool
    var launches: Int
    var rom: ROM?

    static func read(from data: URL) -> TestportReport? {
        let file = data.appending(path: "Library/Application Support/Testport/report.json")
        return (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(TestportReport.self, from: $0) }
    }
}
