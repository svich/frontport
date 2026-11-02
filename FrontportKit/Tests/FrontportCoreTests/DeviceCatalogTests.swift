import Foundation
import Testing
@testable import FrontportCore

/// An entry's `ios`, and the identifiers Devices are named by.
@Suite struct DeviceCatalogTests {
    static let fallout = "9e5c554b962e30eaf2a71792c7ad36594a747fc3"
    static let sf64 = "09f0d105f476b00efa5303a3ebc42e60a7753b7a"

    static let entryJSON = """
        {
          "id": "fallout-ce",
          "name": "Fallout Community Edition",
          "kind": "recreation",
          "game": "fallout",
          "developer": "alexbatalov",
          "summary": "Fallout, recreated.",
          "source": "https://github.com/alexbatalov/fallout1-ce",
          "bundleId": "dev.frontport.port.fallout-ce",
          "releases": {
            "type": "git", "repo": "alexbatalov/fallout1-ce", "refs": { "stable": "0609bcf" },
            "recipe": "recipes/fallout-ce.sh", "recipeSHA256": "\(String(repeating: "a", count: 64))"
          },
          "requirements": [
            { "label": "Fallout", "stage": "runtime", "oneOf": ["\(fallout)"], "seedPath": "Library/Application Support/Fallout" }
          ],
          "redirects": [{ "path": "Contents/Resources/log", "to": "Library/Logs" }],
          "launch": { "arguments": ["--windowed"] },
          "strip": ["Contents/MacOS/updater"],
          "blocked": [{ "release": "1.0.0", "severity": "warn", "reason": "Mac only." }],
          "ios": {
            "releases": {
              "type": "git", "repo": "alexbatalov/fallout1-ce", "refs": { "stable": "0609bcf" },
              "recipe": "recipes/fallout-ce-ios.sh", "recipeSHA256": "\(String(repeating: "b", count: 64))"
            },
            "seedPaths": ["Documents"],
            "strip": ["Settings.bundle"],
            "blocked": [{ "release": "1.1.0", "severity": "stop", "reason": "Crashes on launch." }]
          }
        }
        """

    static func entry() throws -> CatalogEntry {
        try JSON.decode(CatalogEntry.self, from: Data(entryJSON.utf8))
    }

    @Test func decodesIOS() throws {
        let ios = try #require(try Self.entry().ios)
        guard case .git(let source) = ios.releases else {
            Issue.record("expected a git source")
            return
        }
        #expect(source.recipe == "recipes/fallout-ce-ios.sh")
        #expect(ios.seedPaths == ["Documents"])
        #expect(ios.buildAssets == nil)
        #expect(ios.strip == ["Settings.bundle"])
        #expect(ios.blocked == [Block(release: "1.1.0", severity: .stop, reason: "Crashes on launch.")])
    }

    @Test func iosIsOptionalAndItsListsDefaultToEmpty() throws {
        var json = try #require(try JSONSerialization.jsonObject(with: Data(Self.entryJSON.utf8)) as? [String: Any])
        json["ios"] = nil
        let without = try JSON.decode(CatalogEntry.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(without.ios == nil)
        #expect(!String(decoding: try JSON.encode(without), as: UTF8.self).contains("\"ios\""))

        let bare = try JSON.decode(IOSSpec.self, from: Data(#"""
            { "releases": { "type": "github-release", "repo": "a/b", "asset": "b-*.ipa", "channels": ["stable"] } }
            """#.utf8))
        #expect(bare.seedPaths.isEmpty && bare.strip.isEmpty && bare.blocked.isEmpty && bare.buildAssets == nil)
    }

    /// A null seedPath, for a Requirement the iOS version doesn't use, survives encoding as null.
    @Test func roundTripsIOSWithNullSeedPaths() throws {
        var entry = try Self.entry()
        entry.requirements.append(Requirement(label: "Star Fox 64", stage: .build, oneOf: [Self.sf64]))
        entry.ios?.seedPaths = ["Documents", nil]
        entry.ios?.buildAssets = BuildAssetsSpec(path: "assets/sf64.o2r", format: "2")
        let data = try JSON.encode(entry)
        #expect(String(decoding: data, as: UTF8.self).contains("null"))
        #expect(try JSON.decode(CatalogEntry.self, from: data) == entry)
    }

    @Test func installationsKeepTheEntrysIOS() throws {
        let entry = try Self.entry()
        let installation = Installation(
            port: entry.id, release: Release(port: entry.id, version: "0609bcf"), channel: .stable,
            installedAt: Date(timeIntervalSince1970: 1_792_800_000), appName: "Fallout.app", entry: entry)
        let decoded = try JSON.decode(Installation.self, from: JSON.encode(installation))
        #expect(decoded.entry?.ios == entry.ios)
        #expect(decoded == installation)
    }

    @Test func pinsTheIOSRecipeToo() throws {
        var entry = try Self.entry()
        let document = CatalogDocument(
            issued: Date(timeIntervalSince1970: 0), platforms: [], games: [], roms: [], ports: [entry])
        #expect(document.pinnedRecipes == [
            PinnedRecipe(owner: "fallout-ce", path: "recipes/fallout-ce.sh", sha256: String(repeating: "a", count: 64)),
            PinnedRecipe(owner: "fallout-ce (iOS)", path: "recipes/fallout-ce-ios.sh", sha256: String(repeating: "b", count: 64)),
        ])

        entry.ios?.releases = .githubRelease(GitHubReleaseSource(repo: "alexbatalov/fallout1-ce", asset: "fallout-ce-ios.ipa"))
        let prebuilt = CatalogDocument(
            issued: Date(timeIntervalSince1970: 0), platforms: [], games: [], roms: [], ports: [entry])
        #expect(prebuilt.pinnedRecipes.map(\.owner) == ["fallout-ce"])
    }

    // MARK: Identifiers

    @Test func appleTeamIDsAreTenCapitalsOrDigits() throws {
        #expect(AppleTeamID("A1B2C3D4E5")?.rawValue == "A1B2C3D4E5")
        for bad in ["", "A1B2C3D4E", "A1B2C3D4E5Z", "a1b2c3d4e5", "A1B2C3D4E.", "A1B2C3D4E/", "A1B2C3D4EŸ"] {
            #expect(AppleTeamID(bad) == nil, "\(bad)")
        }
        #expect(try JSON.decode([AppleTeamID].self, from: Data(#"["A1B2C3D4E5"]"#.utf8)) == [AppleTeamID("A1B2C3D4E5")])
        #expect(throws: DecodingError.self) { try JSON.decode([AppleTeamID].self, from: Data(#"["../x"]"#.utf8)) }
    }

    @Test func deviceBundleIDsAndWorkspaces() throws {
        let team = try #require(AppleTeamID("A1B2C3D4E5"))
        let port: PortID = "fallout-ce"
        #expect(port.deviceBundleID(team: team) == "dev.frontport.port.fallout-ce.a1b2c3d4e5")
        #expect(port.deviceWorkspace == "fallout-ce.ios")
        // No Port's id has a ".", so neither can be another Port's.
        #expect(!port.deviceWorkspace.isWellFormed)
        #expect(PortID(deviceWorkspace: "fallout-ce.ios") == port)
        for name in ["fallout-ce", "fallout-ce.ios.ios", ".ios", "../x.ios"] {
            #expect(PortID(deviceWorkspace: name) == nil, "\(name)")
        }
    }

    @Test func wellFormedDeviceIDs() {
        #expect(DeviceID("00008110-0000000000000000").isWellFormed)
        #expect(DeviceID("5f3a0d2c41b9e8f7a6c5d4e3b2a1908172635445").isWellFormed)
        for bad in ["", "-x", "..", "a/b", "a.b", "a b"] {
            #expect(!DeviceID(rawValue: bad).isWellFormed, "\(bad)")
        }
    }

    // MARK: Links

    @Test func deviceAssetPathsStayClearOfTheFlatAppsCode() {
        for path in ["sf64.o2r", "assets/sf64.o2r", "Data/game", "Frameworks2/x", "Info.plist.bak"] {
            #expect(PortLinks.isClearOfDeviceCode(path), "\(path)")
        }
        for path in [
            "Frameworks", "frameworks/x.o2r", "PlugIns/x", "Extensions/x", "Watch", "SC_Info/x", "_CodeSignature",
            "_codesignature/CodeResources", "embedded.mobileprovision", "Info.plist", "info.PLIST", "CodeResources",
            "PkgInfo", "assets/Thing.framework/x", "Nested.app/x", "x.appex", "lib/libx.dylib", "Res.bundle/x",
            "", "/abs", "a/../b", "a//b", "Contentſ/x",
        ] {
            #expect(!PortLinks.isClearOfDeviceCode(path), "\(path)")
        }
    }
}
