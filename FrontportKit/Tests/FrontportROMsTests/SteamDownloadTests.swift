import Foundation
import FrontportCore
import Testing
@testable import FrontportROMs

@Suite struct SteamDownloadTests {
    /// Half-Life's depot 1, as Steam downloads it: the files in its own folder, its manifest in `depotcache`.
    static let depot = KnownROM.Steam.Depot(depot: 1, manifest: "2667117727132184734")

    /// A Steam folder with nothing installed whose command line acts as `download_depot` does: it logs the command,
    /// then either fails with `failure` or downloads the depot and logs that it's complete.
    func steam(in tmp: TemporaryDirectory, failure: String? = nil, calls: Calls = Calls()) throws -> SteamLibrary {
        let root = tmp.url.appending(path: "Steam", directoryHint: .isDirectory)
        try tmp.file("Steam/logs/console_log.txt", Data("[2026-10-31 14:00:00] Startup\n".utf8))
        let files = SteamTests.valve.merging(SteamTests.gearbox) { $1 }
        let commandLine: @Sendable ([String]) throws -> Void = { arguments in
            calls.append(arguments)
            let log = root.appending(path: "logs/console_log.txt")
            var lines = ["ExecCommandLine: \"'steam_osx' '\(arguments.joined(separator: "' '"))'\""]
            if let failure {
                lines.append("Depot download failed : \(failure)")
            } else {
                let folder = root.appending(path: "Steam.AppBundle/Steam/Contents/MacOS/steamapps/content/app_70/depot_1")
                lines.append("Downloading depot 1 (\(files.count) files, 1 MB) ... ")
                for (path, data) in files {
                    try FileManager.default.createDirectory(at: folder.appending(path: path).deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: folder.appending(path: path))
                }
                try Data("state".utf8).write(to: folder.deletingLastPathComponent().appending(path: "state_70_1.patch"))
                try FileManager.default.createDirectory(at: root.appending(path: "depotcache"), withIntermediateDirectories: true)
                try SteamTests.manifest(files, configs: ["valve/config.cfg"]).write(to: root.appending(path: "depotcache/1_2667117727132184734.manifest"))
                lines.append("Depot download complete : \"\(root.path(percentEncoded: false))Steam.AppBundle/Steam/Contents/MacOS\\steamapps\\content\\app_70\\depot_1\" (manifest 2667117727132184734) ")
            }
            let handle = try FileHandle(forWritingTo: log)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(lines.map { "[2026-10-31 14:00:01] \($0)\n" }.joined().utf8))
            try handle.close()
        }
        return SteamLibrary(root: root, client: { commandLine })
    }

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [[String]] = []
        func append(_ arguments: [String]) { lock.withLock { all.append(arguments) } }
        var arguments: [[String]] { lock.withLock { all } }
    }

    func catalog(depots: [KnownROM.Steam.Depot]? = [depot]) -> CatalogDocument {
        let sha1 = SteamTests.valveIdentity
        return CatalogDocument(
            issued: Date(timeIntervalSince1970: 0),
            platforms: [Platform(id: "windows", name: "Windows", shortName: "Windows", medium: .file)],
            games: [Game(id: "half-life", name: "Half-Life", platform: "windows")],
            roms: [
                KnownROM(
                    sha1: sha1, game: "half-life", name: "Steam: the valve folder", format: ROMRecord.folderFormat,
                    configs: ["config.cfg"], steam: KnownROM.Steam(app: 70, folder: "valve", depots: depots))
            ],
            ports: [Catalogs.entry("xash3d-half-life", game: "half-life", requirements: [
                Requirement(label: "Half-Life", stage: .runtime, oneOf: [sha1], seedPath: "Library/Application Support/Xash3D FWGS/valve"),
            ])])
    }

    @Test func aROMWithDepotsCanBeDownloadedUntilItIsAdded() async throws {
        let tmp = try TemporaryDirectory()
        let calls = Calls()
        let store = ROMStore(paths: tmp.paths, steam: try steam(in: tmp, calls: calls))
        #expect(await store.steamDownloads(catalog: catalog(depots: nil)).isEmpty)
        #expect(await store.steamDownloads(catalog: catalog()) == [SteamTests.valveIdentity])

        let results = await store.downloadFromSteam(SteamTests.valveIdentity, catalog: catalog()) { _ in }
        guard case .added(let record) = results.first else { Issue.record("\(results)"); return }
        #expect(record.sha1 == SteamTests.valveIdentity)
        #expect(calls.arguments == [["+download_depot", "70", "1", "2667117727132184734"]])
        // What Steam downloaded is gone; the ROM is a copy.
        #expect(!FileManager.default.fileExists(atPath: tmp.url.appending(path: "Steam/Steam.AppBundle/Steam/Contents/MacOS/steamapps/content/app_70").path(percentEncoded: false)))
        #expect(await store.steamDownloads(catalog: catalog()).isEmpty)
    }

    @Test func steamsReasonForAFailedDownloadIsReported() async throws {
        let tmp = try TemporaryDirectory()
        let store = ROMStore(paths: tmp.paths, steam: try steam(in: tmp, failure: "missing license for depot (No subscription)"))
        let results = await store.downloadFromSteam(SteamTests.valveIdentity, catalog: catalog()) { _ in }
        guard case .rejected(_, _, let reason) = results.first else { Issue.record("\(results)"); return }
        #expect(reason == "Steam couldn’t download Half-Life: missing license for depot (No subscription).")
    }

    @Test func withoutSteamNothingCanBeDownloadedUntilItIsInstalled() async throws {
        let tmp = try TemporaryDirectory()
        let installed = Calls()
        let commandLine: @Sendable ([String]) throws -> Void = { _ in }
        let steam = SteamLibrary(root: tmp.url.appending(path: "Steam"), client: {
            installed.arguments.isEmpty ? nil : commandLine
        })
        let store = ROMStore(paths: tmp.paths, steam: steam)
        #expect(await store.steamDownloads(catalog: catalog()).isEmpty)
        let results = await store.downloadFromSteam(SteamTests.valveIdentity, catalog: catalog()) { _ in }
        guard case .rejected(_, _, let reason) = results.first else { Issue.record("\(results)"); return }
        #expect(reason == "Steam isn’t installed. Install Steam, sign in, then try again.")

        // Installed while Frontport is open.
        installed.append([])
        #expect(await store.steamDownloads(catalog: catalog()) == [SteamTests.valveIdentity])
    }
}
