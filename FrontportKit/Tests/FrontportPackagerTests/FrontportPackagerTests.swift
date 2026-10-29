import Foundation
import FrontportCore
import Testing
@testable import FrontportPackager

@Suite struct PortPackagerTests {
    @Test func packagesAnUpstreamAppToRunSandboxed() async throws {
        let tmp = try TemporaryDirectory()
        let app = try await TestApp.make(in: tmp.url)
        let entry = entry(exceptions: ["allow-jit"])
        // Upstream may ship a library read-only, as UZDoom does.
        #expect(chmod(app.appending(path: "Contents/Frameworks/libtiny.dylib").path(percentEncoded: false), 0o444) == 0)

        try await PortPackager(paths: .withoutData).package(app, entry: entry, permissions: .default, assets: nil, installedAssets: nil)

        let info = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: app.appending(path: "Contents/Info.plist")), format: nil) as? [String: Any]
        #expect(info?["CFBundleIdentifier"] as? String == entry.bundleId)
        #expect(!FileManager.default.fileExists(atPath: app.appending(path: "Contents/embedded.provisionprofile").path(percentEncoded: false)))
        #expect(FileOperations.extendedAttribute(FileOperations.quarantineAttribute, at: app) == nil)
        #expect(FileOperations.extendedAttribute(FileOperations.quarantineAttribute, at: app.appending(path: "Contents/MacOS/Tiny")) == nil)

        let appEntitlements = try await entitlements(of: app)
        #expect(appEntitlements["com.apple.security.app-sandbox"] as? Bool == true)
        #expect(appEntitlements["com.apple.security.device.usb"] as? Bool == true)
        #expect(appEntitlements["com.apple.security.cs.allow-jit"] as? Bool == true)
        #expect(appEntitlements["com.apple.security.cs.disable-library-validation"] as? Bool == true)
        #expect(appEntitlements["com.apple.security.network.client"] == nil)
        #expect(appEntitlements["com.apple.security.inherit"] == nil)
        #expect(appEntitlements[PortEntitlements.absoluteReadOnly] == nil && appEntitlements[PortEntitlements.homeRelativeReadOnly] == nil)

        let contents = app.appending(path: "Contents")
        for library in ["Frameworks/libtiny.dylib", "Frameworks/libnoext", "Frameworks/TinyKit.framework", "PlugIns/Thing.bundle"] {
            let url = contents.appending(path: library)
            #expect(try await signatureInfo(of: url).contains("(adhoc,runtime)"), "\(library)")
            #expect(try await entitlements(of: url).isEmpty, "\(library) must not carry the app's entitlements")
        }
        let helper = try await entitlements(of: contents.appending(path: "Helpers/tinyhelper"))
        #expect(helper["com.apple.security.app-sandbox"] as? Bool == true)
        #expect(helper["com.apple.security.inherit"] as? Bool == true)
        #expect(helper["com.apple.security.cs.allow-jit"] as? Bool == true)
        #expect(helper["com.apple.security.device.usb"] == nil)
        #expect(try String(decoding: Data(contentsOf: contents.appending(path: "Frameworks/decoy.dylib")), as: UTF8.self) == TestApp.decoyContents)
    }

    /// Under the hardened runtime an ad-hoc process loads its ad-hoc libraries only with library validation off.
    @Test func packagedAppLoadsItsLibrariesInsideItsSandbox() async throws {
        let tmp = try TemporaryDirectory()
        let app = try await TestApp.make(in: tmp.url)
        let entry = entry()

        try await PortPackager(paths: .withoutData).package(app, entry: entry, permissions: .default, assets: nil, installedAssets: nil)

        let output = try await tool(app.appending(path: "Contents/MacOS/Tiny").path(percentEncoded: false), [])
        #expect(output.contains("answer=42 framework=7"))
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Containers/\(entry.bundleId)/Data").path(percentEncoded: false)
        #expect(output.contains("HOME=\(container.hasSuffix("/") ? String(container.dropLast()) : container)\n"))
    }

    @Test func appWithoutLibrariesKeepsLibraryValidation() async throws {
        let tmp = try TemporaryDirectory()
        let app = try await TestApp.make(in: tmp.url, nested: false)

        try await PortPackager(paths: .withoutData).package(app, entry: entry(), permissions: .default, assets: nil, installedAssets: nil)

        let appEntitlements = try await entitlements(of: app)
        #expect(appEntitlements["com.apple.security.app-sandbox"] as? Bool == true)
        #expect(appEntitlements["com.apple.security.cs.disable-library-validation"] == nil)
        #expect(try await signatureInfo(of: app).contains("(adhoc,runtime)"))
    }

    @Test func resignAppliesNewPermissions() async throws {
        let tmp = try TemporaryDirectory()
        let app = try await TestApp.make(in: tmp.url)
        let entry = entry()
        let packager = PortPackager(paths: .withoutData)
        try await packager.package(app, entry: entry, permissions: .default, assets: nil, installedAssets: nil)

        try await packager.resign(
            app, entry: entry, permissions: Permissions(network: true, controllers: false, files: true), installedAssets: nil)

        let appEntitlements = try await entitlements(of: app)
        #expect(appEntitlements["com.apple.security.network.client"] as? Bool == true)
        #expect(appEntitlements["com.apple.security.files.user-selected.read-only"] as? Bool == true)
        #expect(appEntitlements["com.apple.security.device.usb"] == nil)
        #expect(appEntitlements["com.apple.security.cs.disable-library-validation"] as? Bool == true)
        try await tool("/usr/bin/codesign", ["--verify", "--strict", app.path(percentEncoded: false)])
    }

    @Test func stripsCatalogPathsBeforeSigning() async throws {
        let tmp = try TemporaryDirectory()
        let app = try await TestApp.make(in: tmp.url)
        var entry = entry()
        entry.strip = ["Contents/Helpers/tinyhelper", "Contents/Resources/absent"]

        try await PortPackager(paths: .withoutData).package(app, entry: entry, permissions: .default, assets: nil, installedAssets: nil)

        #expect(!FileManager.default.fileExists(atPath: app.appending(path: "Contents/Helpers/tinyhelper").path(percentEncoded: false)))
        try await tool("/usr/bin/codesign", ["--verify", "--strict", app.path(percentEncoded: false)])
    }

    @Test func neverStripsOutsideTheApp() async throws {
        let tmp = try TemporaryDirectory()
        let app = try await TestApp.make(in: tmp.url, nested: false)
        let outside = tmp.url.appending(path: "outside", directoryHint: .isDirectory)
        try write("keep", to: outside.appending(path: "victim"))
        try FileManager.default.createSymbolicLink(
            at: app.appending(path: "Contents/Escape"), withDestinationURL: outside)

        for path in ["Contents/Escape/victim", "../outside/victim", "/etc/hosts"] {
            var entry = entry()
            entry.strip = [path]
            await #expect(throws: FrontportError.self, "\(path)") {
                try await PortPackager(paths: .withoutData).package(app, entry: entry, permissions: .default, assets: nil, installedAssets: nil)
            }
        }
        #expect(FileManager.default.fileExists(atPath: outside.appending(path: "victim").path(percentEncoded: false)))
    }

    /// An untrusted app whose `Contents` is a link to another app's must not lead Frontport to rewrite that app.
    @Test func neverWritesThroughALinkOutOfTheApp() async throws {
        let tmp = try TemporaryDirectory()
        let victim = try await TestApp.make(in: tmp.url.appending(path: "victim"), name: "Victim", nested: false)
        let plist = try Data(contentsOf: victim.appending(path: "Contents/Info.plist"))
        let evil = tmp.url.appending(path: "Evil.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: evil, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: evil.appending(path: "Contents"), withDestinationURL: victim.appending(path: "Contents"))

        await #expect(throws: FrontportError.self) {
            try await PortPackager(paths: .withoutData).package(evil, entry: entry(), permissions: .default, assets: nil, installedAssets: nil)
        }
        await #expect(throws: FrontportError.self) {
            try await PortPackager(paths: .withoutData).resign(evil, entry: entry(), permissions: .default, installedAssets: nil)
        }
        #expect(try Data(contentsOf: victim.appending(path: "Contents/Info.plist")) == plist)
        #expect(FileManager.default.fileExists(atPath: victim.appending(path: "Contents/_CodeSignature").path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: victim.appending(path: "Contents/embedded.provisionprofile").path(percentEncoded: false)))
    }

    @Test func refusesBuildAssetsThatAreALink() async throws {
        let tmp = try TemporaryDirectory()
        let app = try await TestApp.make(in: tmp.url, nested: false)
        let secret = tmp.url.appending(path: "secret.txt")
        try write("secret", to: secret)
        let assets = tmp.url.appending(path: "assets.o2r")
        try FileManager.default.createSymbolicLink(at: assets, withDestinationURL: secret)
        let entry = entry(buildAssets: BuildAssetsSpec(path: "Contents/Resources/tiny.o2r", format: "1"))

        await #expect(throws: FrontportError.self) {
            try await PortPackager(paths: .withoutData).package(
                app, entry: entry, permissions: .default, assets: assets, installedAssets: tmp.url.appending(path: "kept"))
        }
    }

    /// A program anywhere in the app runs only inside the Port's sandbox, wherever upstream put it.
    @Test func signsProgramsOutsideTheCodeFolders() async throws {
        let tmp = try TemporaryDirectory()
        let app = try await TestApp.make(in: tmp.url, nested: false)
        let source = tmp.url.appending(path: "tool.c")
        try write("int main(void) { return 0; }\n", to: source)
        let program = app.appending(path: "Contents/Resources/bin/tool")
        try FileManager.default.createDirectory(at: program.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await clang(["-o", program.path(percentEncoded: false), source.path(percentEncoded: false)])

        try await PortPackager(paths: .withoutData).package(app, entry: entry(exceptions: ["allow-jit"]), permissions: .default, assets: nil, installedAssets: nil)

        let signed = try await entitlements(of: program)
        #expect(signed["com.apple.security.app-sandbox"] as? Bool == true)
        #expect(signed["com.apple.security.inherit"] as? Bool == true)
        #expect(signed["com.apple.security.cs.allow-jit"] as? Bool == true)
        try await tool("/usr/bin/codesign", ["--verify", "--strict", app.path(percentEncoded: false)])
    }

    @Test func buildAssetsNeedADeclaredPathAndAPlaceToBeKept() async throws {
        let tmp = try TemporaryDirectory()
        let app = try await TestApp.make(in: tmp.url, nested: false)
        let assets = tmp.url.appending(path: "assets.o2r")
        try Data("assets".utf8).write(to: assets)
        let kept = tmp.url.appending(path: "Library/tiny/assets")
        // Inside the app, Contents/Res leads to Contents/Resources.
        try FileManager.default.createDirectory(at: app.appending(path: "Contents/Resources"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: app.appending(path: "Contents/Res").path(percentEncoded: false), withDestinationPath: "Resources")

        await #expect(throws: FrontportError.self) {
            try await PortPackager(paths: .withoutData).package(app, entry: entry(), permissions: .default, assets: assets, installedAssets: kept)
        }
        await #expect(throws: FrontportError.self, "nowhere to keep them") {
            try await PortPackager(paths: .withoutData).package(
                app, entry: entry(buildAssets: BuildAssetsSpec(path: "Contents/Resources/tiny.o2r", format: "1")),
                permissions: .default, assets: assets, installedAssets: nil)
        }
        // A path leading out, one the relative link would miscount, through "." or through a link, or one where the
        // app's code or its signature is.
        for path in ["../escape.o2r", "Contents/./Resources/tiny.o2r", "Contents/Res/tiny.o2r", "Contents/MacOS/tiny.o2r",
            "Contents/Info.plist"]
        {
            await #expect(throws: FrontportError.self, "\(path)") {
                try await PortPackager(paths: .withoutData).package(
                    app, entry: entry(buildAssets: BuildAssetsSpec(path: path, format: "1")), permissions: .default,
                    assets: assets, installedAssets: kept)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: app.appending(path: "Contents/Resources/tiny.o2r").path(percentEncoded: false)))
    }
}

/// Build Assets beside the app, linked from `buildAssets.path`, which the app may read where the Library keeps them.
@Suite struct BuildAssetsLinkTests {
    static let file = BuildAssetsSpec(path: "Contents/Resources/tiny.o2r", format: "1")
    static let folder = BuildAssetsSpec(path: "Contents/Resources/data/out/tiny", format: "1")

    @Test func linksAFileBesideTheApp() async throws {
        let tmp = try TemporaryDirectory()
        let app = try await TestApp.make(in: tmp.url)
        let assets = tmp.url.appending(path: "made.o2r")
        try write("assets", to: assets)
        let kept = tmp.url.appending(path: "Library/tiny/assets")

        try await PortPackager(paths: .withoutData).package(
            app, entry: entry(buildAssets: Self.file), permissions: .default, assets: assets, installedAssets: kept)

        let link = app.appending(path: Self.file.path)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path(percentEncoded: false)) == "../../../assets")
        #expect(try String(contentsOf: tmp.url.appending(path: "assets"), encoding: .utf8) == "assets")
        #expect(try String(contentsOf: link, encoding: .utf8) == "assets", "the link leads beside the app")
        // Outside the home folder, as the test folder is: an absolute exception for the file, canonical.
        let appEntitlements = try await entitlements(of: app)
        #expect(appEntitlements[PortEntitlements.absoluteReadOnly] as? [String] == [canonicalPath(tmp.url) + "/Library/tiny/assets"])
        #expect(appEntitlements[PortEntitlements.homeRelativeReadOnly] == nil)
        let helper = try await entitlements(of: app.appending(path: "Contents/Helpers/tinyhelper"))
        #expect(helper[PortEntitlements.absoluteReadOnly] == nil, "nested programs inherit the app's sandbox")
        // Strict verification rejects any link out of the bundle; every other strict check passes.
        await #expect(throws: FrontportError.self) {
            try await tool("/usr/bin/codesign", ["--verify", "--strict", app.path(percentEncoded: false)])
        }
        try await tool("/usr/bin/codesign", ["--verify", "--strict=sideband", "--deep", app.path(percentEncoded: false)])
    }

    /// Whatever upstream or the Recipe left at the path, a folder here, gives way to the link.
    @Test func linksAFolderBesideTheApp() async throws {
        let tmp = try TemporaryDirectory()
        let app = try await TestApp.make(in: tmp.url, nested: false)
        try write("upstream's", to: app.appending(path: "\(Self.folder.path)/old"))
        let assets = tmp.url.appending(path: "made", directoryHint: .isDirectory)
        try write("iso", to: assets.appending(path: "iso/GAME.CGO"))
        try FileManager.default.createSymbolicLink(
            atPath: assets.appending(path: "current").path(percentEncoded: false), withDestinationPath: "iso")
        let kept = tmp.url.appending(path: "Library/tiny/assets")
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)

        try await PortPackager(paths: .withoutData).package(
            app, entry: entry(buildAssets: Self.folder), permissions: .default, assets: assets, installedAssets: kept)

        let link = app.appending(path: Self.folder.path)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path(percentEncoded: false)) == "../../../../../assets")
        #expect(try String(contentsOf: link.appending(path: "current/GAME.CGO"), encoding: .utf8) == "iso")
        #expect(!FileManager.default.fileExists(atPath: link.appending(path: "old").path(percentEncoded: false)))
        let appEntitlements = try await entitlements(of: app)
        #expect(appEntitlements[PortEntitlements.absoluteReadOnly] as? [String] == [canonicalPath(kept) + "/"], "a folder ends in /")
        try await tool("/usr/bin/codesign", ["--verify", "--strict=sideband", "--deep", app.path(percentEncoded: false)])
    }

    /// In the home folder, where the Library is, the exception is home-relative, so it names no user.
    @Test func namesBuildAssetsInTheHomeFolderRelativeToIt() async throws {
        let tmp = try TemporaryDirectory()
        let app = try await TestApp.make(in: tmp.url, nested: false)
        let assets = tmp.url.appending(path: "made.o2r")
        try write("assets", to: assets)
        let library = "Library/Application Support/FrontportPackagerTests-\(UUID().uuidString)/Library/tiny/assets"
        let kept = FileManager.default.homeDirectoryForCurrentUser.appending(path: library)

        try await PortPackager(paths: .withoutData).package(
            app, entry: entry(buildAssets: Self.file), permissions: .default, assets: assets, installedAssets: kept)

        let appEntitlements = try await entitlements(of: app)
        #expect(appEntitlements[PortEntitlements.homeRelativeReadOnly] as? [String] == ["/" + library])
        #expect(appEntitlements[PortEntitlements.absoluteReadOnly] == nil)
    }

    @Test func exceptionIsHomeRelativeOnlyInsideTheHomeFolder() {
        let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
        let file = URL(filePath: "/Users/someone/Library/Frontport/tiny/assets")
        let folder = URL(filePath: "/Users/someone/Library/Frontport/tiny/assets", directoryHint: .isDirectory)

        #expect(PortEntitlements.exception(file, home: home) == (PortEntitlements.homeRelativeReadOnly, "/Library/Frontport/tiny/assets"))
        #expect(PortEntitlements.exception(folder, home: home) == (PortEntitlements.homeRelativeReadOnly, "/Library/Frontport/tiny/assets/"))
        let neighbour = URL(filePath: "/Users/someone-else/assets", directoryHint: .isDirectory)
        #expect(PortEntitlements.exception(neighbour, home: home) == (PortEntitlements.absoluteReadOnly, "/Users/someone-else/assets/"))
        #expect(PortEntitlements.exception(URL(filePath: "/Volumes/Games/assets"), home: home) == (PortEntitlements.absoluteReadOnly, "/Volumes/Games/assets"))
    }

    @Test func resignKeepsTheLinkAndItsException() async throws {
        let tmp = try TemporaryDirectory()
        let app = try await TestApp.make(in: tmp.url)
        let assets = tmp.url.appending(path: "made.o2r")
        try write("assets", to: assets)
        let kept = tmp.url.appending(path: "Library/tiny/assets")
        let entry = entry(buildAssets: Self.file)
        let packager = PortPackager(paths: .withoutData)
        try await packager.package(app, entry: entry, permissions: .default, assets: assets, installedAssets: kept)

        try await packager.resign(app, entry: entry, permissions: Permissions(network: true), installedAssets: kept)

        let appEntitlements = try await entitlements(of: app)
        #expect(appEntitlements["com.apple.security.network.client"] as? Bool == true)
        #expect(appEntitlements[PortEntitlements.absoluteReadOnly] as? [String] == [canonicalPath(tmp.url) + "/Library/tiny/assets"])
        try await tool("/usr/bin/codesign", ["--verify", "--strict=sideband", app.path(percentEncoded: false)])
        // Without the Build Assets' place, the link is one more link leading out.
        await #expect(throws: FrontportError.self) {
            try await packager.resign(app, entry: entry, permissions: .default, installedAssets: nil)
        }
    }

    /// The link is found in the app, so a Catalog that has since moved or dropped `buildAssets.path` doesn't matter, and
    /// a link planted where the Build Assets are kept can't steer the exception.
    @Test func resignFindsTheLinkInTheAppItself() async throws {
        let tmp = try TemporaryDirectory()
        let app = try await TestApp.make(in: tmp.url, nested: false)
        let assets = tmp.url.appending(path: "made.o2r")
        try write("assets", to: assets)
        let kept = tmp.url.appending(path: "Library/tiny/assets")
        try FileManager.default.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: kept, withDestinationURL: URL(filePath: "/private/etc", directoryHint: .isDirectory))
        let packager = PortPackager(paths: .withoutData)
        try await packager.package(app, entry: entry(buildAssets: Self.file), permissions: .default, assets: assets, installedAssets: kept)

        for later in [entry(buildAssets: BuildAssetsSpec(path: "Contents/Resources/moved/tiny.o2r", format: "1")), entry()] {
            try await packager.resign(app, entry: later, permissions: Permissions(network: true), installedAssets: kept)
            let appEntitlements = try await entitlements(of: app)
            #expect(appEntitlements[PortEntitlements.absoluteReadOnly] as? [String] == [canonicalPath(tmp.url) + "/Library/tiny/assets"])
        }
    }

    /// While a stop Block has the app aside, its link leads nowhere: the exception still names the installed folder.
    @Test func resignsWhileTheLinkLeadsNowhere() async throws {
        let tmp = try TemporaryDirectory()
        let library = tmp.url.appending(path: "Library", directoryHint: .isDirectory)
        let app = try await TestApp.make(in: library, nested: false)
        let assets = tmp.url.appending(path: "made", directoryHint: .isDirectory)
        try write("iso", to: assets.appending(path: "GAME.CGO"))
        let kept = library.appending(path: "assets")
        let entry = entry(buildAssets: Self.folder)
        try await PortPackager(paths: .withoutData).package(app, entry: entry, permissions: .default, assets: assets, installedAssets: kept)
        let blocked = library.appending(path: "blocked/Tiny.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: blocked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: app, to: blocked)

        try await PortPackager(paths: .withoutData).resign(blocked, entry: entry, permissions: Permissions(network: true), installedAssets: kept)

        let appEntitlements = try await entitlements(of: blocked)
        #expect(appEntitlements["com.apple.security.network.client"] as? Bool == true)
        #expect(appEntitlements[PortEntitlements.absoluteReadOnly] as? [String] == [canonicalPath(kept) + "/"])
    }

    /// Only the Packager's own link passes: any other link out, a link at the path that leads elsewhere, and the same
    /// link made by upstream or a Recipe are refused.
    @Test func allowsOnlyThePackagersOwnLink() async throws {
        let tmp = try TemporaryDirectory()
        let app = try await TestApp.make(in: tmp.url, nested: false)
        let assets = tmp.url.appending(path: "made.o2r")
        try write("assets", to: assets)
        let kept = tmp.url.appending(path: "Library/tiny/assets")
        let entry = entry(buildAssets: Self.file)
        let packager = PortPackager(paths: .withoutData)
        try await packager.package(app, entry: entry, permissions: .default, assets: assets, installedAssets: kept)
        let fm = FileManager.default
        func link(_ path: String, _ destination: String) throws {
            let url = app.appending(path: path)
            try? fm.removeItem(at: url)
            try fm.createSymbolicLink(atPath: url.path(percentEncoded: false), withDestinationPath: destination)
        }

        try link("Contents/Resources/other.o2r", "../../../assets")
        await #expect(throws: FrontportError.self, "another link out") {
            try await packager.resign(app, entry: entry, permissions: .default, installedAssets: kept)
        }
        try fm.removeItem(at: app.appending(path: "Contents/Resources/other.o2r"))
        for destination in ["../../../../assets", "../../../made.o2r", canonicalPath(tmp.url) + "/assets"] {
            try link(Self.file.path, destination)
            await #expect(throws: FrontportError.self, "\(destination)") {
                try await packager.resign(app, entry: entry, permissions: .default, installedAssets: kept)
            }
        }

        // Upstream's app, or a Recipe's, arriving with the Packager's link already in it.
        let planted = try await TestApp.make(in: tmp.url.appending(path: "planted"), nested: false)
        try write("not the Build Assets", to: tmp.url.appending(path: "planted/assets"))
        try fm.createDirectory(at: planted.appending(path: "Contents/Resources"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            atPath: planted.appending(path: Self.file.path).path(percentEncoded: false), withDestinationPath: "../../../assets")
        for given in [nil, assets] {
            await #expect(throws: FrontportError.self) {
                try await packager.package(planted, entry: entry, permissions: .default, assets: given, installedAssets: kept)
            }
        }
    }
}

/// Redirects lead from paths inside the app to folders in the Port's own Data, by absolute path.
@Suite struct RedirectLinkTests {
    static let log = Redirect(path: "Contents/Resources/data/log", to: "Library/Application Support/Tiny/log")

    /// A packager over a temporary containers folder, with the folder `log` leads to made in the Port's Data.
    static func packager(in tmp: TemporaryDirectory) throws -> (packager: PortPackager, data: String) {
        let paths = AppPaths(root: tmp.url.appending(path: "root"), containers: tmp.url.appending(path: "Containers"))
        try FileManager.default.createDirectory(
            at: paths.data(for: entry().bundleId).appending(path: log.to), withIntermediateDirectories: true)
        return (PortPackager(paths: paths), canonicalPath(tmp.url) + "/Containers/\(entry().bundleId)/Data")
    }

    static func redirected(_ redirects: [Redirect] = [log], buildAssets: BuildAssetsSpec? = nil) -> CatalogEntry {
        var redirected = entry(buildAssets: buildAssets)
        redirected.redirects = redirects
        return redirected
    }

    @Test func linksIntoThePortsData() async throws {
        let tmp = try TemporaryDirectory()
        let app = try await TestApp.make(in: tmp.url, nested: false)
        try write("upstream's", to: app.appending(path: "\(Self.log.path)/old.log"))
        let (packager, data) = try Self.packager(in: tmp)
        let assets = tmp.url.appending(path: "made.o2r")
        try write("assets", to: assets)

        try await packager.package(
            app, entry: Self.redirected(buildAssets: BuildAssetsLinkTests.file), permissions: .default, assets: assets,
            installedAssets: tmp.url.appending(path: "Library/tiny/assets"))

        let link = app.appending(path: Self.log.path)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path(percentEncoded: false)) == data + "/" + Self.log.to)
        try write("written", to: link.appending(path: "run.log"))
        #expect(try String(contentsOf: URL(filePath: data + "/" + Self.log.to + "/run.log"), encoding: .utf8) == "written")
        let appEntitlements = try await entitlements(of: app)
        #expect(appEntitlements[PortEntitlements.absoluteReadOnly] as? [String] == [canonicalPath(tmp.url) + "/Library/tiny/assets"],
            "the container needs no exception")
        await #expect(throws: FrontportError.self) {
            try await tool("/usr/bin/codesign", ["--verify", "--strict", app.path(percentEncoded: false)])
        }
        try await tool("/usr/bin/codesign", ["--verify", "--strict=sideband", "--deep", app.path(percentEncoded: false)])
    }

    /// Redirects are found in the app, so an entry that no longer lists them doesn't matter; a link into another
    /// Port's Data, or one that climbs out of this one's, is refused.
    @Test func resignAllowsOnlyLinksIntoThisPortsData() async throws {
        let tmp = try TemporaryDirectory()
        let app = try await TestApp.make(in: tmp.url, nested: false)
        let (packager, data) = try Self.packager(in: tmp)
        try await packager.package(app, entry: Self.redirected(), permissions: .default, assets: nil, installedAssets: nil)

        try await packager.resign(app, entry: entry(), permissions: Permissions(network: true), installedAssets: nil)
        #expect(try await entitlements(of: app)["com.apple.security.network.client"] as? Bool == true)

        let other = canonicalPath(tmp.url) + "/Containers/dev.frontport.tests.other/Data/" + Self.log.to
        try FileManager.default.createDirectory(at: URL(filePath: other), withIntermediateDirectories: true)
        let link = app.appending(path: Self.log.path).path(percentEncoded: false)
        for destination in [other, data + "/Library/../../../dev.frontport.tests.other/Data", data, "../../../../Containers"] {
            try FileManager.default.removeItem(atPath: link)
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: destination)
            await #expect(throws: FrontportError.self, "\(destination)") {
                try await packager.resign(app, entry: Self.redirected(), permissions: .default, installedAssets: nil)
            }
        }

        // A link of the Redirect's shape where no Redirect may be: where the app's code is.
        try FileManager.default.removeItem(atPath: link)
        let code = app.appending(path: "Contents/MacOS/log").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(atPath: code, withDestinationPath: data + "/" + Self.log.to)
        await #expect(throws: FrontportError.self) {
            try await packager.resign(app, entry: Self.redirected(), permissions: .default, installedAssets: nil)
        }
    }

    /// A copy of `pristine` at `tmp/<name>/Tiny.app`, with a decoy folder in its Resources, and a link at `p` in the
    /// Port's Data, as the previous Release could leave there running sandboxed, back into the app being packaged.
    static func probe(_ name: String, of pristine: URL, in tmp: TemporaryDirectory, data: String) throws -> URL {
        let fm = FileManager.default
        let app = tmp.url.appending(path: "\(name)/Tiny.app", directoryHint: .isDirectory)
        try fm.createDirectory(at: app.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: pristine, to: app)
        let resources = app.appending(path: "Contents/Resources", directoryHint: .isDirectory)
        try write("decoy", to: resources.appending(path: "decoy/file"))
        try? fm.removeItem(atPath: data + "/p")
        try fm.createSymbolicLink(atPath: data + "/p", withDestinationPath: canonicalPath(resources))
        return app
    }

    /// Upstream's app, or a Recipe's, arriving with a link shaped like a Redirect is refused, absolute or relative,
    /// whether it leads into the Port's Data or, through the link the Port left there, back into the app, and whether
    /// or not the entry has Redirects of its own. Otherwise it would pass as one of the Packager's, and verifying
    /// would drop to sideband.
    @Test func refusesALinkShapedLikeARedirect() async throws {
        let tmp = try TemporaryDirectory()
        let pristine = try await TestApp.make(in: tmp.url.appending(path: "pristine"), nested: false)
        let (packager, data) = try Self.packager(in: tmp)
        // From Contents/Resources in tmp/<case>/Tiny.app, out to tmp.
        let relative = "../../../../Containers/\(entry().bundleId)/Data"
        let destinations = [data + "/" + Self.log.to, data + "/p", relative + "/" + Self.log.to, relative + "/p"]
        for (index, (entry, destination)) in [Self.redirected(), entry()].flatMap({ e in destinations.map { (e, $0) } })
            .enumerated()
        {
            let app = try Self.probe("case-\(index)", of: pristine, in: tmp, data: data)
            try FileManager.default.createSymbolicLink(
                atPath: app.appending(path: "Contents/Resources/evil").path(percentEncoded: false),
                withDestinationPath: destination)

            await #expect(throws: FrontportError.self, "\(destination), Redirects: \(entry.redirects)") {
                try await packager.package(app, entry: entry, permissions: .default, assets: nil, installedAssets: nil)
            }
            #expect(!FileOperations.exists(app.appending(path: Self.log.path)), "refused before anything is placed")
        }
    }

    /// A relative link that, followed, passes through one of the Packager's links is refused, though its text stays
    /// inside the app and it lands back inside it, through the link the Port left in Data: the Port could retarget
    /// that link later. So is one at a code location. Without the Redirect, or with only the Build Assets link, the
    /// same link leads nowhere outside the app.
    @Test func refusesALinkThroughAPackagersLink() async throws {
        let tmp = try TemporaryDirectory()
        let pristine = try await TestApp.make(in: tmp.url.appending(path: "pristine"), nested: false)
        let (packager, data) = try Self.packager(in: tmp)
        let assets = tmp.url.appending(path: "made.o2r")
        try write("assets", to: assets)
        let x = data + "/" + Self.log.to + "/x"
        let links = [
            ("Contents/Resources/sneak", "data/log/x/decoy"),
            ("Contents/Library/LoginItems/Evil.app", "../../Resources/data/log/x/decoy"),
        ]
        let entries = [Self.redirected(), Self.redirected(buildAssets: BuildAssetsLinkTests.file), entry(),
            entry(buildAssets: BuildAssetsLinkTests.file)]
        for (index, (entry, (path, destination))) in entries.flatMap({ e in links.map { (e, $0) } }).enumerated() {
            let app = try Self.probe("case-\(index)", of: pristine, in: tmp, data: data)
            // Also left by the previous Release, where the Redirect leads.
            try? FileManager.default.removeItem(atPath: x)
            try FileManager.default.createSymbolicLink(
                atPath: x, withDestinationPath: canonicalPath(app.appending(path: "Contents/Resources")))
            let link = app.appending(path: path)
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: link.path(percentEncoded: false), withDestinationPath: destination)
            let packaging = await Result(catching: {
                try await packager.package(
                    app, entry: entry, permissions: .default, assets: entry.buildAssets == nil ? nil : assets,
                    installedAssets: tmp.url.appending(path: "Library/tiny/assets"))
            })

            if entry.redirects.isEmpty {
                // Then it leads nowhere, whether or not codesign takes it.
                #expect(!FileOperations.exists(link.appending(path: "file")), "\(path), \(entry.buildAssets as Any)")
            } else {
                #expect(throws: FrontportError.self, "\(path), \(entry.buildAssets as Any)") { try packaging.get() }
            }
        }
    }

    /// A chain of relative links whose text stays inside the app but that, followed, climbs out of it, here to come back
    /// in through the link the Port left in its Data, is refused for every Port: one with only the Build Assets link is
    /// verified with sideband, and one with no link of the Packager's at all is refused before codesign sees it.
    @Test func refusesAChainOfLinksThatClimbsOut() async throws {
        let tmp = try TemporaryDirectory()
        let pristine = try await TestApp.make(in: tmp.url.appending(path: "pristine"), nested: false)
        let (packager, data) = try Self.packager(in: tmp)
        let assets = tmp.url.appending(path: "made.o2r")
        try write("assets", to: assets)
        for (index, entry) in [entry(), Self.redirected(), entry(buildAssets: BuildAssetsLinkTests.file)].enumerated() {
            let app = try Self.probe("case-\(index)", of: pristine, in: tmp, data: data)
            let deep = app.appending(path: "Contents/Resources/d1/d2/d3", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
            // `b` leads to the app itself; through it, `a` climbs to tmp and on into the Port's Data.
            try FileManager.default.createSymbolicLink(
                atPath: deep.appending(path: "b").path(percentEncoded: false), withDestinationPath: "../../../../../.")
            try FileManager.default.createSymbolicLink(
                atPath: deep.appending(path: "a").path(percentEncoded: false),
                withDestinationPath: "b/../../Containers/\(entry.bundleId)/Data/p/decoy")
            #expect(try String(contentsOf: deep.appending(path: "a/file"), encoding: .utf8) == "decoy", "lands inside")

            await #expect(throws: FrontportError.self, "\(entry.redirects), \(entry.buildAssets as Any)") {
                try await packager.package(
                    app, entry: entry, permissions: .default, assets: entry.buildAssets == nil ? nil : assets,
                    installedAssets: tmp.url.appending(path: "Library/tiny/assets"))
            }
        }
    }

    /// The volume folds "ſ" into "s" and composes accents, so a path that isn't plain ASCII could name another: here
    /// the nested app's own Contents, which placing the link would have deleted.
    @Test func refusesPathsThatArentPlainASCII() async throws {
        let tmp = try TemporaryDirectory()
        let app = try await TestApp.make(in: tmp.url, nested: false)
        let helper = try await TestApp.make(in: tmp.url.appending(path: "h"), name: "Helper", nested: false)
        try FileManager.default.createDirectory(at: app.appending(path: "Contents/Resources"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: helper, to: app.appending(path: "Contents/Resources/Helper.app"))
        let (packager, _) = try Self.packager(in: tmp)

        for redirect in [
            Redirect(path: "Contents/Resources/Helper.app/Content\u{017F}", to: Self.log.to),
            Redirect(path: "Contents/Resources/Helper.app/Conte\u{0301}nts", to: Self.log.to),
            Redirect(path: Self.log.path, to: "Library/Application Support/Tiny/lo\u{0301}g"),
        ] {
            await #expect(throws: FrontportError.self, "\(redirect)") {
                try await packager.package(
                    app, entry: Self.redirected([redirect]), permissions: .default, assets: nil, installedAssets: nil)
            }
        }
        #expect(FileOperations.isDirectory(app.appending(path: "Contents/Resources/Helper.app/Contents")))
        await #expect(throws: FrontportError.self) {
            try await packager.package(
                app, entry: entry(buildAssets: BuildAssetsSpec(path: "Contents/Re\u{017F}ources/tiny.o2r", format: "1")),
                permissions: .default, assets: tmp.url.appending(path: "h"), installedAssets: tmp.url.appending(path: "kept"))
        }
    }

    /// codesign opens what each Redirect leads to, so the folders are walked to right before it verifies: one the Port
    /// removed comes back, and anything else in its place is refused rather than followed or opened.
    @Test func resignWalksToTheFoldersFirst() async throws {
        let tmp = try TemporaryDirectory()
        let app = try await TestApp.make(in: tmp.url, nested: false)
        let (packager, data) = try Self.packager(in: tmp)
        try await packager.package(app, entry: Self.redirected(), permissions: .default, assets: nil, installedAssets: nil)
        let target = URL(filePath: data + "/" + Self.log.to)
        let fm = FileManager.default

        try fm.removeItem(at: target)
        try await packager.resign(app, entry: Self.redirected(), permissions: Permissions(network: true), installedAssets: nil)
        #expect(FileOperations.isDirectory(target))

        try fm.removeItem(at: target)
        #expect(mkfifo(target.path(percentEncoded: false), 0o644) == 0)
        let started = Date()
        await #expect(throws: FrontportError.fileOperation(
            "Couldn’t use \(Self.log.to) in Data: it’s a symbolic link or not a folder. Delete Data to start over."))
        {
            try await packager.resign(app, entry: Self.redirected(), permissions: .default, installedAssets: nil)
        }
        #expect(Date().timeIntervalSince(started) < 30, "the FIFO is never opened")

        try fm.removeItem(at: target)
        try write("not a folder", to: target)
        await #expect(throws: FrontportError.self) {
            try await packager.resign(app, entry: Self.redirected(), permissions: .default, installedAssets: nil)
        }
    }

    /// Verifying gets a time limit, as something the Port left could hold codesign up; it's stopped when it passes,
    /// even when it ignores SIGTERM.
    @Test func verifyingStopsAtItsTimeLimit() async throws {
        let tmp = try TemporaryDirectory()
        let app = try await TestApp.make(in: tmp.url, nested: false)
        let codesign = tmp.url.appending(path: "codesign")
        try write(
            "#!/bin/sh\nif [ \"$1\" = --verify ]; then trap '' TERM; exec sleep 60; fi\nexec /usr/bin/codesign \"$@\"\n",
            to: codesign)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codesign.path(percentEncoded: false))
        let packager = PortPackager(paths: .withoutData, signer: Codesign(codesign: codesign, verifyLimit: .seconds(1)))

        let started = Date()
        await #expect(throws: FrontportError.signingFailed(
            "Verifying Tiny.app took longer than 1 second, so it was stopped. Try again."))
        {
            try await packager.package(app, entry: entry(), permissions: .default, assets: nil, installedAssets: nil)
        }
        #expect(Date().timeIntervalSince(started) < 30)
    }

    @Test func refusesRedirectsThatCollideOrLeadAstray() async throws {
        let tmp = try TemporaryDirectory()
        let pristine = try await TestApp.make(in: tmp.url.appending(path: "pristine"), nested: false)
        let (packager, _) = try Self.packager(in: tmp)
        let assets = tmp.url.appending(path: "made.o2r")
        try write("assets", to: assets)
        try FileManager.default.createDirectory(at: pristine.appending(path: "Contents/Resources"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: pristine.appending(path: "Contents/Res").path(percentEncoded: false), withDestinationPath: "Resources")
        let to = Self.log.to
        // A file where a folder of `to` would be.
        try write("not a folder", to: tmp.url.appending(path: "Containers/\(entry().bundleId)/Data/Library/file"))
        let cases: [[Redirect]] = [
            [Redirect(path: BuildAssetsLinkTests.file.path, to: to)],
            [Redirect(path: BuildAssetsLinkTests.file.path + "/log", to: to)],
            [Redirect(path: "Contents/Resources", to: to)],
            [Self.log, Redirect(path: Self.log.path + "/inner", to: to)],
            [Self.log, Self.log],
            [Redirect(path: "Resources/log", to: to)],
            [Redirect(path: "Contents/./Resources/log", to: to)],
            [Redirect(path: "Contents/../log", to: to)],
            [Redirect(path: "Contents/Res/log", to: to)],
            [Redirect(path: "Contents/MacOS", to: to)],
            [Redirect(path: "Contents/Resources/Helper.app/Contents/MacOS", to: to)],
            [Redirect(path: Self.log.path, to: "Library/../../escape")],
            [Redirect(path: Self.log.path, to: "/etc")],
            [Redirect(path: Self.log.path, to: "Library/file")],
            [Redirect(path: Self.log.path, to: "Library/file/log")],
        ]
        for (index, redirects) in cases.enumerated() {
            let app = tmp.url.appending(path: "case-\(index)/Tiny.app", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: app.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: pristine, to: app)
            await #expect(throws: FrontportError.self, "\(redirects)") {
                try await packager.package(
                    app, entry: Self.redirected(redirects, buildAssets: BuildAssetsLinkTests.file), permissions: .default,
                    assets: assets, installedAssets: tmp.url.appending(path: "Library/tiny/assets"))
            }
        }
    }
}

@Suite struct CodeLayoutTests {
    @Test func listsNestedCodeDeepestFirst() async throws {
        let tmp = try TemporaryDirectory()
        let app = try await TestApp.make(in: tmp.url)
        // A nested app with its own framework.
        let nested = app.appending(path: "Contents/Helpers/Crash.app")
        _ = try await TestApp.make(in: app.appending(path: "Contents/Helpers"), name: "Crash")

        let layout = try CodeLayout(app: app)
        let root = app.resolvingSymlinksInPath().path(percentEncoded: false)
        let relative = layout.nested.map {
            String($0.url.resolvingSymlinksInPath().path(percentEncoded: false).dropFirst(root.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        #expect(root.hasSuffix(".app/"))

        #expect(layout.hasLibraries)
        #expect(Set(relative) == [
            "Contents/Frameworks/libtiny.dylib", "Contents/Frameworks/libnoext", "Contents/Frameworks/TinyKit.framework",
            "Contents/PlugIns/Thing.bundle", "Contents/Helpers/tinyhelper",
            "Contents/Helpers/Crash.app",
            "Contents/Helpers/Crash.app/Contents/Frameworks/libtiny.dylib",
            "Contents/Helpers/Crash.app/Contents/Frameworks/libnoext",
            "Contents/Helpers/Crash.app/Contents/Frameworks/TinyKit.framework",
            "Contents/Helpers/Crash.app/Contents/PlugIns/Thing.bundle",
            "Contents/Helpers/Crash.app/Contents/Helpers/tinyhelper",
        ])
        // Everything inside a bundle comes before the bundle.
        for (index, path) in relative.enumerated() {
            for container in relative[..<index] {
                #expect(!path.hasPrefix(container + "/"), "\(container) is signed before \(path) inside it")
            }
        }
        let crash = try #require(layout.nested.first { $0.url.lastPathComponent == "Crash.app" })
        #expect(crash.kind == .bundle && crash.isExecutable)
        #expect(nested.lastPathComponent == "Crash.app")
        let framework = try #require(layout.nested.first { $0.url.lastPathComponent == "TinyKit.framework" })
        #expect(framework.kind == .bundle && !framework.isExecutable)
    }

    @Test func recognizesMachOByMagic() async throws {
        let tmp = try TemporaryDirectory()
        let source = tmp.url.appending(path: "main.c")
        try write("int main(void) { return 0; }\n", to: source)
        let thin = tmp.url.appending(path: "thin.txt")
        let universal = tmp.url.appending(path: "universal")
        try await clang(["-o", thin.path(percentEncoded: false), source.path(percentEncoded: false)])
        try await clang(["-arch", "arm64", "-arch", "x86_64", "-o", universal.path(percentEncoded: false), source.path(percentEncoded: false)])
        let javaClass = tmp.url.appending(path: "Thing.class")
        try Data([0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x34] + [UInt8](repeating: 0, count: 32)).write(to: javaClass)
        let text = tmp.url.appending(path: "lib.dylib")
        try write("text", to: text)

        #expect(MachO.fileType(of: thin) == .executable)
        #expect(MachO.fileType(of: universal) == .executable)
        #expect(MachO.fileType(of: javaClass) == nil)
        #expect(MachO.fileType(of: text) == nil)
    }
}

/// Runs the primer on a real container: macOS lays out `Data/` again after Delete Data.
@Suite(.serialized) struct ContainerPrimerTests {
    @Test func recreatesDeletedDataWithItsLayout() async throws {
        let tmp = try TemporaryDirectory()
        let source = tmp.url.appending(path: "primer.c")
        try write("int main(void) { return 0; }\n", to: source)
        let executable = tmp.url.appending(path: "frontport-primer")
        try await clang(["-o", executable.path(percentEncoded: false), source.path(percentEncoded: false)])
        let paths = AppPaths(root: tmp.url.appending(path: "Frontport"), containers: AppPaths.default.containers)
        let entry = entry(id: "primer", bundleId: "dev.frontport.tests.primer")
        let primer = ContainerPrimer(executable: executable, paths: paths)
        let data = paths.data(for: entry.bundleId)
        defer { try? FileOperations.removeUntrusted(data) }

        try await primer.prime(entry)  // creates the container on first use
        try FileManager.default.removeItem(at: data)  // Delete Data
        try await primer.prime(entry)

        func exists(_ path: String) -> Bool {
            FileManager.default.fileExists(atPath: data.appending(path: path).path(percentEncoded: false))
        }
        #expect(exists("Library/Application Support") && exists("Library/Caches") && exists("tmp"))
        let desktop = try FileManager.default.destinationOfSymbolicLink(atPath: data.appending(path: "Desktop").path(percentEncoded: false))
        #expect(desktop.hasSuffix("/Desktop"), "the standard layout links the user's folders")
    }
}
