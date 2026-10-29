import Foundation
import Testing
@testable import FrontportCore

@Suite struct CatalogCodingTests {
    static let oot10 = "ad69c91157f6705e8ab06c79fe08aad47bb57ba7"
    static let masterQuest = "50bebedad9e0f10746a52b07239e47fa6c284d03"
    static let sf64 = "09f0d105f476b00efa5303a3ebc42e60a7753b7a"

    static let documentJSON = """
        {
          "version": 1,
          "issued": "2026-10-24T09:00:00Z",
          "platforms": [{ "id": "n64", "name": "Nintendo 64", "shortName": "N64", "medium": "cartridge" }],
          "genres": [{ "id": "adventure", "name": "Adventure" }],
          "games": [
            { "id": "ocarina-of-time", "name": "The Legend of Zelda: Ocarina of Time",
              "shortName": "Ocarina of Time", "platform": "n64", "genres": ["adventure"], "steamgriddb": 21202 },
            { "id": "star-fox-64", "name": "Star Fox 64", "platform": "n64", "steamgriddb": 36615 }
          ],
          "roms": [
            { "sha1": "\(oot10)", "game": "ocarina-of-time", "name": "NTSC 1.0 (US)", "format": "z64" },
            { "sha1": "\(masterQuest)", "game": "ocarina-of-time", "name": "Master Quest (US)", "format": "z64" },
            { "sha1": "\(sf64)", "game": "star-fox-64", "name": "NTSC 1.1 (US)", "format": "z64" }
          ],
          "ports": [
            {
              "id": "shipwright",
              "name": "Ship of Harkinian",
              "kind": "decomp",
              "game": "ocarina-of-time",
              "developer": "HarbourMasters",
              "summary": "Ocarina of Time, rebuilt from its decompiled source as a native Mac app.",
              "description": "Ship of Harkinian is a native port of Ocarina of Time.\\n\\nIt runs at your display's frame rate.",
              "website": "https://www.shipofharkinian.com",
              "source": "https://github.com/HarbourMasters/Shipwright",
              "bundleId": "dev.frontport.port.shipwright",
              "releases": {
                "type": "github-release",
                "repo": "HarbourMasters/Shipwright",
                "asset": "SoH-*-Mac.zip",
                "channels": ["stable", "nightly"]
              },
              "requirements": [
                {
                  "label": "Ocarina of Time",
                  "stage": "runtime",
                  "oneOf": ["\(oot10)"],
                  "extras": ["\(masterQuest)"],
                  "seedPath": "Library/Application Support/com.shipofharkinian.soh/"
                }
              ],
              "permissions": { "network": false, "controllers": true, "files": false },
              "artwork": { "steamgriddb": 5335518, "fallback": 21202 },
              "codeSigning": { "exceptions": [] },
              "blocked": [{ "release": "9.3.0", "severity": "warn", "reason": "Saves may not load." }],
              "screenshots": ["https://example.org/soh/1.jpg"],
              "firstRelease": "2022-03-22T22:03:34Z"
            },
            {
              "id": "starship",
              "name": "Starship",
              "kind": "decomp",
              "game": "star-fox-64",
              "developer": "HarbourMasters",
              "summary": "Star Fox 64, rebuilt from its decompiled source.",
              "source": "https://github.com/HarbourMasters/Starship",
              "bundleId": "dev.frontport.port.starship",
              "releases": {
                "type": "git",
                "repo": "HarbourMasters/Starship",
                "refs": { "stable": "v2.0.0" },
                "recipe": "recipes/starship.sh",
                "recipeSHA256": "0f343b0931126a20f133d67c2b018a3b1b0a8f2c2ad5d6a7d0a1a4b6c7d8e9f0"
              },
              "requirements": [{ "label": "Star Fox 64", "stage": "build", "oneOf": ["\(sf64)"] }],
              "artwork": { "fallback": 36615 },
              "codeSigning": { "exceptions": ["allow-jit"] },
              "launch": { "arguments": ["--fullscreen"] },
              "buildAssets": { "path": "Contents/Resources/sf64.o2r", "format": "1" },
              "redirects": [{ "path": "Contents/Resources/logs", "to": "Library/Application Support/Starship/logs" }]
            }
          ]
        }
        """

    func decodeDocument() throws -> CatalogDocument {
        try JSON.decode(CatalogDocument.self, from: Data(Self.documentJSON.utf8))
    }

    @Test func decodesPrebuiltEntry() throws {
        let catalog = try decodeDocument()
        let soh = try #require(catalog.entry("shipwright"))
        #expect(soh.kind == .decomp)
        #expect(soh.bundleId == "dev.frontport.port.shipwright")
        #expect(soh.website == URL(string: "https://www.shipofharkinian.com"))
        guard case .githubRelease(let source) = soh.releases else {
            Issue.record("expected a github-release source")
            return
        }
        #expect(source.asset == "SoH-*-Mac.zip")
        #expect(source.tags == nil)
        #expect(soh.channels == [.stable, .nightly])
        #expect(soh.defaultChannel == .stable)
        #expect(!soh.isSourceBuilt)
        #expect(soh.requirements.first?.extras == [Self.masterQuest])
        #expect(soh.artwork.preferred == 5335518)
        #expect(soh.launch == LaunchSpec())
        #expect(soh.buildAssets == nil)
        #expect(soh.redirects.isEmpty, "Catalogs and records from before Redirects still decode")
        #expect(soh.tags.isEmpty)
        #expect(soh.isInstallable)
        #expect(catalog.game(for: soh)?.displayName == "Ocarina of Time")
        #expect(catalog.platform(for: soh)?.shortName == "N64")
        #expect(catalog.issued == Date(timeIntervalSince1970: 1_792_832_400))
    }

    @Test func decodesSourceBuiltEntryWithDefaults() throws {
        let starship = try #require(try decodeDocument().entry("starship"))
        #expect(starship.isSourceBuilt)
        guard case .git(let source) = starship.releases else {
            Issue.record("expected a git source")
            return
        }
        #expect(source.refs == [.stable: "v2.0.0"])
        #expect(source.recipe == "recipes/starship.sh")
        #expect(starship.description == "")
        #expect(starship.website == nil)
        #expect(starship.permissions == .default)
        #expect(starship.permissions.controllers && !starship.permissions.network && !starship.permissions.files)
        #expect(starship.requirements.first?.extras == [])
        #expect(starship.requirements.first?.seedPath == nil)
        #expect(starship.artwork.preferred == 36615)
        #expect(starship.blocked.isEmpty)
        #expect(starship.screenshots.isEmpty)
        #expect(starship.launch.arguments == ["--fullscreen"])
        #expect(starship.launch.environment.isEmpty)
        #expect(starship.buildAssets == BuildAssetsSpec(path: "Contents/Resources/sf64.o2r", format: "1"))
        #expect(starship.redirects == [Redirect(path: "Contents/Resources/logs", to: "Library/Application Support/Starship/logs")])
        #expect(starship.codeSigning.entitlements == ["com.apple.security.cs.allow-jit": true])
        #expect(starship.firstRelease == nil)
    }

    @Test func decodesGenresAndFirstRelease() throws {
        let catalog = try decodeDocument()
        #expect(catalog.genres == [Genre(id: "adventure", name: "Adventure")])
        #expect(catalog.game("ocarina-of-time")?.genres == ["adventure"])
        #expect(catalog.game("star-fox-64")?.genres == [])
        #expect(catalog.entry("shipwright")?.firstRelease == ISO8601DateFormatter().date(from: "2022-03-22T22:03:34Z"))
    }

    @Test func roundTripsDocument() throws {
        let catalog = try decodeDocument()
        let data = try JSON.encode(catalog)
        let decoded = try JSON.decode(CatalogDocument.self, from: data)
        #expect(decoded == catalog)

        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let ports = try #require(object["ports"] as? [[String: Any]])
        let releases = try #require(ports[1]["releases"] as? [String: Any])
        #expect(releases["type"] as? String == "git")
        // Channel-keyed dictionaries encode as JSON objects, matching the Catalog sketch.
        #expect((releases["refs"] as? [String: String]) == ["stable": "v2.0.0"])
        #expect((ports[0]["releases"] as? [String: Any])?["type"] as? String == "github-release")
        #expect(object["issued"] as? String == "2026-10-24T09:00:00Z")
    }

    @Test func rejectsUnknownReleaseSource() {
        let json = #"{ "type": "sourceforge", "repo": "x/y" }"#
        #expect(throws: DecodingError.self) {
            try JSON.decode(ReleaseSource.self, from: Data(json.utf8))
        }
    }

    @Test func gitChannelsPutStableFirst() {
        let source = ReleaseSource.git(GitSource(
            repo: "a/b", refs: ["nightly": "main", "beta": "v3-beta", .stable: "v2"], recipe: "r.sh", recipeSHA256: ""))
        #expect(source.channels == [.stable, "beta", .nightly])
    }

    @Test func blocksMatchVersionOrTag() throws {
        let soh = try #require(try decodeDocument().entry("shipwright"))
        let blocked = Release(port: "shipwright", version: "9.3.0", tag: "9.3.0")
        let tagged = Release(port: "shipwright", version: "9.3.0", tag: "v9.3.0")
        let fine = Release(port: "shipwright", version: "9.3.1")
        #expect(soh.block(for: blocked)?.severity == .warn)
        #expect(soh.block(for: tagged) != nil)
        #expect(soh.block(for: fine) == nil)
    }

    @Test func acceptedAndKnownROMs() throws {
        let catalog = try decodeDocument()
        let soh = try #require(catalog.entry("shipwright"))
        #expect(soh.acceptedROMs == [Self.oot10, Self.masterQuest])
        #expect(catalog.knownROM(Self.oot10)?.name == "NTSC 1.0 (US)")
    }

    /// One answer per hash, for intake, the ROMs screen and the store page alike.
    @Test func listsInstallersROMsAndNothingElse() throws {
        var catalog = try decodeDocument()
        let oot = try #require(catalog.knownROM(Self.oot10))
        let folder = KnownROM(sha1: "f0", game: "ocarina-of-time", name: "PC folder", format: ROMRecord.folderFormat)
        let installer = KnownROM(
            sha1: "e0", game: "ocarina-of-time", name: "Setup", format: "exe",
            unpack: Unpack(recipe: "recipes/innoextract.sh", recipeSHA256: "", yields: ["f0"]))
        catalog.roms += [folder, installer, KnownROM(sha1: "ab", game: "ocarina-of-time", name: "Unlisted", format: "z64")]
        catalog.ports[0].requirements[0].oneOf += ["f0", "cd"]

        #expect(catalog.listing(Self.oot10) == .rom(oot, .cartridge))
        #expect(catalog.listing("f0") == .rom(folder, .folder))
        #expect(catalog.listing("e0") == .installer(installer))
        #expect(catalog.listing("ab") == .unknown, "named in roms, but no Requirement accepts it")
        #expect(catalog.listing("cd") == .unknown, "accepted, but roms names nothing")
        #expect(catalog.listing("ff") == .unknown)
        #expect(catalog.installers(holding: "f0") == [installer] && catalog.installers(holding: Self.oot10).isEmpty)
        #expect(catalog.game(for: catalog.ports[0].requirements[0])?.id == "ocarina-of-time")
    }

    @Test func romTypes() throws {
        let game: GameID = "ocarina-of-time"
        #expect(ROMType(format: "z64", game: game, medium: .cartridge) == .cartridge)
        // A Switch game's NSP is as much a cartridge as its XCI.
        #expect(ROMType(format: "nsp", game: game, medium: .cartridge) == .cartridge)
        #expect(ROMType(format: "bin", game: game, medium: .iso) == .iso)
        #expect(ROMType(format: "iso", game: game, medium: .file) == .iso)
        #expect(ROMType(format: ROMRecord.folderFormat, game: game, medium: .file) == .folder)
        #expect(ROMType(format: "wad", game: game, medium: .file) == .file)
        #expect(ROMType(format: "z64", game: game, medium: nil) == .file)
        #expect(ROMType(format: "keys", game: nil, medium: nil) == .key)
        #expect(ROMType(format: ROMRecord.folderFormat, game: nil, medium: nil) == .firmware)

        var catalog = try decodeDocument()
        #expect(catalog.platform("n64")?.medium == .cartridge)
        let oot = try #require(catalog.knownROM(Self.oot10))
        #expect(catalog.type(of: oot) == .cartridge)
        // A stored ROM has the Type of the ROM the Catalog knows, whatever format it was stored in.
        let stored = ROMRecord(
            sha1: Self.oot10, game: game, name: oot.name, format: "iso", size: 1, added: .now, originalFilename: "oot.iso")
        #expect(catalog.type(of: stored) == .cartridge && ROMType(stored, in: nil) == .iso)
        var unlisted = stored
        unlisted.sha1 = "ab"
        unlisted.game = "unlisted"
        unlisted.format = "z64"
        #expect(catalog.type(of: unlisted) == .file, "no Catalog entry, no Platform")
        // Only the Catalog tells an update or DLC from the Game itself.
        catalog.roms[0].type = .update
        #expect(catalog.type(of: stored) == .update && ROMType(catalog.roms[0], in: nil) == .update)
        let decoded = try JSONDecoder().decode(KnownROM.self, from: Data(#"{ "sha1": "x", "game": "g", "name": "DLC", "format": "nsp", "type": "dlc" }"#.utf8))
        #expect(decoded.type == .dlc)
    }

    @Test func permissionsMapToEntitlements() {
        #expect(Permissions.default.entitlements == [
            "com.apple.security.app-sandbox": true,
            "com.apple.security.device.usb": true,
        ])
        var all = Permissions(network: true, controllers: true, files: true)
        #expect(all.entitlements.count == 4)
        all[.controllers] = false
        #expect(all.entitlements["com.apple.security.device.usb"] == nil)
        #expect(all[.network])
    }

    @Test func duplicateCodeSigningExceptionsDoNotCrash() {
        #expect(CodeSigning(exceptions: ["allow-jit", "allow-jit"]).entitlements == ["com.apple.security.cs.allow-jit": true])
    }

    @Test func wellFormedPortIDs() {
        for id in ["shipwright", "2ship", "zelda64recomp", "a-b-1"] { #expect(PortID(id).isWellFormed, "\(id)") }
        for id in ["", "..", "../x", "-x", "Ship", "a_b", "a.b", "a/b", "a b", "é"] { #expect(!PortID(id).isWellFormed, "\(id)") }
    }

    /// One order everywhere: creation date first, then publication date, then version number.
    @Test func releaseOrder() {
        func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }
        let early = Release(port: "x", version: "0.9.9", published: at(30), created: at(10))
        let late = Release(port: "x", version: "0.9.9.1", published: at(20), created: at(11))
        #expect(late.isNewer(than: early) && !early.isNewer(than: late))
        let published = Release(port: "x", version: "1.0", published: at(40))
        #expect(published.isNewer(than: late))
        let undated = [Release(port: "x", version: "1.10"), Release(port: "x", version: "1.9")]
        #expect(undated[0].isNewer(than: undated[1]) && !undated[0].isNewer(than: undated[0]))
    }

    @Test func emptyPermissionsObjectUsesDefaults() throws {
        let permissions = try JSON.decode(Permissions.self, from: Data(#"{ "network": true }"#.utf8))
        #expect(permissions == Permissions(network: true, controllers: true, files: false))
    }

    @Test func roundTripsInstallationRecord() throws {
        let release = Release(
            port: "shipwright", version: "9.3.0", title: "Dewey Alfa",
            published: Date(timeIntervalSince1970: 1_759_795_200), notesURL: URL(string: "https://example.org/notes"),
            asset: ReleaseAsset(
                name: "SoH-Dewey-Alfa-Mac.zip", url: URL(string: "https://example.org/soh.zip")!, size: 47_000_000,
                sha256: "abc"))
        let installation = Installation(
            port: "shipwright", release: release, channel: .stable,
            installedAt: Date(timeIntervalSince1970: 1_759_800_000), appName: "soh.app",
            previous: Release(port: "shipwright", version: "9.2.3"),
            permissions: Permissions(network: true), buildAssets: BuildAssetsRecord(roms: [Self.oot10], format: "1"))
        let decoded = try JSON.decode(Installation.self, from: JSON.encode(installation))
        #expect(decoded == installation)
        #expect(decoded.id == "shipwright")
        #expect(!decoded.disabled)
    }

    @Test func runOutcome() {
        let log = URL(filePath: "/tmp/x.log")
        let start = Date(timeIntervalSince1970: 0)
        #expect(Run(id: "a", port: "x", release: "1", started: start, log: log).isRunning)
        let quit = Run(id: "a", port: "x", release: "1", started: start, ended: start + 60, exitStatus: 0, log: log)
        #expect(!quit.crashed && quit.duration == 60)
        #expect(Run(id: "a", port: "x", release: "1", started: start, ended: start, exitStatus: 11, signaled: true, log: log).crashed)
    }
}
