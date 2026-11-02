import Foundation
import FrontportBuilder
import FrontportCatalog
import FrontportCore
import FrontportDevices
import FrontportLibrary
import FrontportPackager
import FrontportReleases
import FrontportROMs
import Testing

/// A Port's iOS version installed on a real Device through every real module: a stand-in iOS app built here with clang
/// against Xcode's iOS SDK, published as an `.ipa` in a GitHub-style release a `LocalServer` serves, then fetched,
/// packaged, signed with the user's Apple Team and a Provisioning Profile Xcode has, installed with `devicectl`, and
/// uninstalled. Opt-in and attended, as macOS may ask whether codesign may use the key, with the UDID of a Device paired
/// with this Mac and the ID of an Apple Team whose certificate, and a Provisioning Profile listing that Device, are here:
///
///     FRONTPORT_DEVICE_TESTS=<udid> FRONTPORT_DEVICE_TEAM=<team ID> swift test --filter DeviceEndToEndTests
///
/// It launches the app too when the Device is unlocked. Its Frontport folder is a temporary one, and it leaves nothing on
/// the Device: the app goes again whether the test passes or not.
@Suite(
    .enabled(if: DeviceHost.udid != nil && DeviceHost.team != nil, "Set FRONTPORT_DEVICE_TESTS=<udid> and FRONTPORT_DEVICE_TEAM=<team ID>"),
    .serialized, .timeLimit(.minutes(10)))
struct DeviceEndToEndTests {
    static let port: PortID = "synthetic-ios"
    static let repo = "frontport-test/synthetic-ios"

    @Test func installsAPrebuiltIOSVersionOnTheDeviceAndUninstallsIt() async throws {
        let udid = try #require(DeviceHost.udid)
        let team = try #require(DeviceHost.team)
        let folder = try Scratch()
        let server = try await LocalServer()
        let paths = AppPaths(
            root: folder.url.appending(path: "Frontport", directoryHint: .isDirectory),
            containers: folder.url.appending(path: "Containers", directoryHint: .isDirectory))
        try FileOperations.createDirectory(paths.root)
        let xcode = try await Xcode.find()
        let control = DeviceCtl(xcode: xcode)
        let library = DeviceLibrary(
            paths: paths, catalog: CatalogStore(paths: paths, bundled: Integration.bundledCatalog),
            releases: GitHubReleases(cache: paths.catalog.appending(path: "releases", directoryHint: .isDirectory), api: server.url("api/")),
            fetcher: AssetFetcher(paths: paths), builder: RecipeBuilder(paths: paths), packager: DevicePackager(), control: control,
            provisioning: DeviceProvisioning(), roms: ROMStore(paths: paths))
        try Self.storeFolderROM(in: paths)

        let reading = try #require(try await control.readings().first { $0.device.id == udid }, "\(udid) isn’t paired with this Mac")
        try #require(reading.isReachable, "\(reading.device.name) isn’t reachable")
        let bundleId = Self.port.deviceBundleID(team: team)
        try #require(!(try await control.apps(on: udid).contains(bundleId)), "\(bundleId) is on the Device already; uninstall it first")

        let ipa = try await SyntheticIOSApp.ipa(version: "1.0", in: folder.url)
        Self.publish(ipa, version: "1.0", on: server)
        let entry = Self.entry
        let progress: ProgressHandler = { update in
            if update.fraction == nil || update.fraction == 1 { print("  [\(update.phase.rawValue)] \(update.message ?? "")") }
        }

        do {
            let started = Date()
            let version = try IOSVersion(of: entry)
            _ = try await library.prepare(version, channel: .stable, progress: progress)
            let installed = try await library.installPrepared(version, on: reading, team: team, progress: progress)
            print("[\(Self.port)] installed on \(reading.device.name) (\(reading.connection.rawValue)) in \(Int(Date().timeIntervalSince(started))) s")

            #expect(installed.bundleId == bundleId && installed.team == team && installed.device == udid)
            #expect(installed.release.tag == "v1.0" && installed.release.asset?.sha256 == Hashing.sha256(ipa))
            #expect(installed.expires > Date() && installed.entry == entry)
            #expect(try JSON.read(DeviceInstallation.self, from: paths.deviceInstallRecord(for: Self.port, on: udid)) == installed)
            let kept = paths.deviceApp(for: installed)
            try await tool("/usr/bin/codesign", ["--verify", "--strict", path(kept)])
            #expect(!exists(paths.downloads(for: Self.port.deviceWorkspace)), "the download goes once it's installed")
            #expect(!exists(paths.library) && !exists(paths.containers), "nothing of the Mac's")
            #expect(try await control.apps(on: udid).contains(bundleId), "devicectl lists it")

            // Seeding fills the folder ROM into Documents, around a file the app wrote and one it rewrote there.
            if let current = try await control.readings().first(where: { $0.device.id == udid }), current.isLocked == false {
                let wrote = folder.url.appending(path: "wrote", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: wrote, withIntermediateDirectories: true)
                try Data("save".utf8).write(to: wrote.appending(path: "SAVE.SAV"))
                try Data("rewritten by the app".utf8).write(to: wrote.appending(path: "A.TXT"))
                try await control.copy(wrote, to: "Documents", of: bundleId, on: udid)

                let plan = try #require(try await library.seed(IOSVersion(of: entry), on: current, progress: progress))
                #expect(plan.items.map(\.step) == [.seeded], "the Device holds the folder ROM afterwards")
                let listed = Set(try await control.files(of: bundleId, on: udid, in: "Documents").map(\.path))
                #expect(listed.isSuperset(of: ["Documents/SAVE.SAV", "Documents/DATA/B.TXT", "Documents/.frontport-rom"]))
                #expect(try await control.read("Documents/A.TXT", of: bundleId, on: udid) == Data("rewritten by the app".utf8))
                #expect(try await control.read("Documents/.frontport-rom", of: bundleId, on: udid) == Data("\(Self.folderROM)\n".utf8))
                #expect(await library.installation(for: Self.port, on: udid)?.seeded == ["Synthetic Game": [Self.folderROM]])
                #expect(try await library.seed(IOSVersion(of: entry), on: current, progress: progress)?.copiesNothing == true, "nothing again")
                #expect(!exists(paths.containers), "nothing of the Mac's")
            } else {
                print("[\(Self.port)] \(reading.device.name) is locked, so the Seeding check is skipped")
            }

            // A scene-delegate app keeps running once launched, which needs the Device unlocked.
            if try await control.readings().first(where: { $0.device.id == udid })?.isLocked == false {
                try await Self.launch(bundleId, on: udid, with: xcode)
                #expect(try await Self.isRunning(SyntheticIOSApp.executable, on: udid, control: control), "it keeps running")
            } else {
                print("[\(Self.port)] \(reading.device.name) is locked, so the launch check is skipped")
            }

            try await library.uninstall(Self.port, from: udid)
            #expect(!(try await control.apps(on: udid).contains(bundleId)), "devicectl no longer lists it")
            #expect(await library.installations().isEmpty)
            #expect(!exists(paths.deviceInstallation(for: Self.port, on: udid)))
            #expect(await library.devices().map(\.id) == [udid])
        } catch {
            try? await control.uninstall(bundleId, from: udid)
            throw error
        }
    }

    // MARK: Fixtures

    /// A folder ROM, by a made-up SHA-1, that the iOS version takes as `Documents`.
    static let folderROM = String(repeating: "5e", count: 20)

    static let entry = CatalogEntry(
        id: port, name: "Synthetic iOS", kind: .decomp, game: "synthetic-ios", developer: "Frontport tests",
        summary: "A stand-in for a Port with an iOS version.", description: "",
        source: URL(string: "https://github.com/\(repo)")!, bundleId: port.conventionalBundleID,
        releases: .githubRelease(GitHubReleaseSource(repo: repo, asset: "Synthetic-*-mac.zip")),
        requirements: [Requirement(label: "Synthetic Game", stage: .runtime, oneOf: [folderROM], seedPath: "game")],
        ios: IOSSpec(releases: .githubRelease(GitHubReleaseSource(repo: repo, asset: "Synthetic-*.ipa")), seedPaths: ["Documents"]))

    /// Puts `folderROM` in ROMs as intake leaves a folder ROM, before the store first reads its index.
    static func storeFolderROM(in paths: AppPaths) throws {
        let folder = paths.rom(folderROM, format: ROMRecord.folderFormat)
        let files = ["A.TXT": "first file\n", "DATA/B.TXT": "second file\n"]
        for (path, text) in files {
            let url = folder.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let record = ROMRecord(
            sha1: folderROM, game: "synthetic-ios", name: "Synthetic", format: ROMRecord.folderFormat,
            size: Int64(files.values.reduce(0) { $0 + $1.utf8.count }), added: Date(), originalFilename: "SYNTHETIC")
        try JSON.write([record], to: paths.romIndex)
    }

    /// Serves GitHub's release list with one Release holding the `.ipa` and its digest, and the `.ipa` itself.
    static func publish(_ ipa: Data, version: String, on server: LocalServer) {
        let name = "Synthetic-\(version).ipa"
        let download = "download/v\(version)/\(name)"
        server.serve(download, .ok(ipa))
        let date = Date(timeIntervalSince1970: 1_790_000_000).formatted(.iso8601)
        let list: [[String: Any]] = [[
            "tag_name": "v\(version)", "name": "Synthetic iOS \(version)", "body": "", "draft": false, "prerelease": false,
            "created_at": date, "published_at": date, "html_url": server.url("releases/v\(version)").absoluteString,
            "assets": [[
                "name": name, "size": ipa.count, "browser_download_url": server.url(download).absoluteString,
                "digest": "sha256:\(Hashing.sha256(ipa))",
            ]],
        ]]
        server.serve("api/repos/\(repo)/releases", .json(try! JSONSerialization.data(withJSONObject: list)))
    }

    /// Launches the app on the Device with Xcode's `devicectl`, which Frontport itself does only later.
    static func launch(_ bundleId: String, on device: DeviceID, with xcode: Xcode) async throws {
        try await tool(
            path(xcode.devicectl),
            ["device", "process", "launch", "--device", device.rawValue, "--timeout", "60", "--terminate-existing", bundleId])
    }

    /// Whether a process running `executable` is still there a few seconds after the launch.
    static func isRunning(_ executable: String, on device: DeviceID, control: DeviceCtl) async throws -> Bool {
        try await Task.sleep(for: .seconds(3))
        return try await control.processes(on: device).values.contains {
            $0.lastPathComponent == executable && $0.deletingLastPathComponent().lastPathComponent == "\(executable).app"
        }
    }
}

enum DeviceHost {
    static let environment = ProcessInfo.processInfo.environment
    static var udid: DeviceID? { environment["FRONTPORT_DEVICE_TESTS"].map { DeviceID($0) }.flatMap { $0.isWellFormed ? $0 : nil } }
    static var team: AppleTeamID? { environment["FRONTPORT_DEVICE_TEAM"].flatMap { AppleTeamID($0) } }
}

/// A stand-in iOS app, as an upstream `.ipa` holds it: a UIKit program with a scene delegate, which an app built with
/// the iOS 27 SDK needs or it exits at once, linking `Frameworks/Kit.framework` and `Frameworks/libloose.dylib`, so the
/// Device Packager signs nested code. Upstream leaves it unsigned.
enum SyntheticIOSApp {
    static let executable = "Synthetic"

    static let main = """
        #import <UIKit/UIKit.h>
        const char *kit_hello(void);
        int loose_value(void);

        @interface AppDelegate : UIResponder <UIApplicationDelegate>
        @end
        @implementation AppDelegate
        - (UISceneConfiguration *)application:(UIApplication *)application
            configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
            UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:session.role];
            configuration.delegateClass = NSClassFromString(@"SceneDelegate");
            return configuration;
        }
        @end

        @interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
        @property (strong, nonatomic) UIWindow *window;
        @end
        @implementation SceneDelegate
        - (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
            self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
            UIViewController *controller = [UIViewController new];
            controller.view.backgroundColor = UIColor.systemBackgroundColor;
            UILabel *label = [[UILabel alloc] initWithFrame:controller.view.bounds];
            label.textAlignment = NSTextAlignmentCenter;
            label.numberOfLines = 0;
            label.text = [NSString stringWithFormat:@"Frontport synthetic iOS Port\\n%s %d", kit_hello(), loose_value()];
            [controller.view addSubview:label];
            self.window.rootViewController = controller;
            [self.window makeKeyAndVisible];
        }
        @end

        int main(int argc, char *argv[]) {
            @autoreleasepool { return UIApplicationMain(argc, argv, nil, @"AppDelegate"); }
        }
        """

    /// `Payload/Synthetic.app` at `version`, zipped as upstream publishes an `.ipa`.
    static func ipa(version: String, in folder: URL) async throws -> Data {
        let work = folder.appending(path: "ios-\(version)", directoryHint: .isDirectory)
        let sources = work.appending(path: "src", directoryHint: .isDirectory)
        let payload = work.appending(path: "Payload", directoryHint: .isDirectory)
        let app = payload.appending(path: "\(executable).app", directoryHint: .isDirectory)
        let frameworks = app.appending(path: "Frameworks", directoryHint: .isDirectory)
        let framework = frameworks.appending(path: "Kit.framework", directoryHint: .isDirectory)
        for folder in [sources, framework] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }

        try plist([
            "CFBundleIdentifier": "org.example.synthetic-ios", "CFBundleExecutable": executable,
            "CFBundleName": "Synthetic", "CFBundleDisplayName": "Synthetic", "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version, "CFBundleVersion": version,
            "CFBundleSupportedPlatforms": ["iPhoneOS"], "LSRequiresIPhoneOS": true, "MinimumOSVersion": "15.0",
            "UIDeviceFamily": [1, 2], "UILaunchScreen": [String: Any](),
            "UIApplicationSceneManifest": ["UIApplicationSupportsMultipleScenes": false],
        ], to: app.appending(path: "Info.plist"))
        try plist([
            "CFBundleIdentifier": "org.example.synthetic-ios.kit", "CFBundleExecutable": "Kit", "CFBundleName": "Kit",
            "CFBundlePackageType": "FMWK", "CFBundleShortVersionString": version, "CFBundleVersion": version,
            "CFBundleSupportedPlatforms": ["iPhoneOS"], "MinimumOSVersion": "15.0",
        ], to: framework.appending(path: "Info.plist"))
        try Data("const char *kit_hello(void) { return \"hello from Kit\"; }\n".utf8).write(to: sources.appending(path: "kit.c"))
        try Data("int loose_value(void) { return 42; }\n".utf8).write(to: sources.appending(path: "loose.c"))
        try Data(main.utf8).write(to: sources.appending(path: "main.m"))

        let clang = ["--sdk", "iphoneos", "clang", "-target", "arm64-apple-ios15.0"]
        try await tool("/usr/bin/xcrun", clang + [
            "-dynamiclib", "-install_name", "@rpath/Kit.framework/Kit", "-o", path(framework.appending(path: "Kit")),
            path(sources.appending(path: "kit.c")),
        ])
        try await tool("/usr/bin/xcrun", clang + [
            "-dynamiclib", "-install_name", "@rpath/libloose.dylib", "-o", path(frameworks.appending(path: "libloose.dylib")),
            path(sources.appending(path: "loose.c")),
        ])
        try await tool("/usr/bin/xcrun", clang + [
            "-fobjc-arc", "-framework", "UIKit", "-framework", "Foundation", "-F", path(frameworks), "-framework", "Kit",
            "-L", path(frameworks), "-lloose", "-Wl,-rpath,@executable_path/Frameworks",
            "-o", path(app.appending(path: executable)), path(sources.appending(path: "main.m")),
        ])
        let archive = folder.appending(path: "Synthetic-\(version).ipa")
        try await tool("/usr/bin/ditto", ["-c", "-k", "--keepParent", path(payload), path(archive)])
        return try Data(contentsOf: archive)
    }

    private static func plist(_ values: [String: Any], to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: url)
    }
}
