import Foundation
import FrontportCore

/// Has Xcode make a Provisioning Profile for a Port's bundle ID and a Device (DESIGN › Provisioning Profiles): writes a
/// stub iOS app project with that bundle ID and Apple Team into `Provisioning/<bundle-id>/`, then builds it with
/// `xcodebuild -allowProvisioningUpdates -allowProvisioningDeviceRegistration` for the Device. Xcode, with the Apple
/// Account the user added in its Settings › Accounts, registers the App ID and the Device on the Apple Team and puts the
/// Provisioning Profile in its folder, where `ProvisioningProfiles` takes it. Frontport never signs in to Apple.
///
/// The stub is written afresh each time and stays, so it can be opened in Xcode should making one fail; what Xcode
/// built from it goes, whether it succeeded or not. What `xcodebuild` says goes to `Logs/<port>.ios/provisioning.log`,
/// and its errors become a `FrontportError` that says what to do.
public struct ProfileMaker: Sendable {
    /// Runs `xcodebuild` with `arguments` and `environment`, its output going to `log`, and returns how it exited.
    /// Tests inject one that writes a log of their own.
    public typealias Runner = @Sendable (_ xcodebuild: URL, _ arguments: [String], _ environment: [String: String], _ log: URL)
        async throws -> ProcessResult

    /// How long Xcode may take: 5 minutes. It took 4 s with a Provisioning Profile already there.
    public static let limit = Duration.seconds(5 * 60)

    private let paths: AppPaths
    private let locator: Xcode.Locator
    private let limit: Duration
    private let temporary: URL
    private let runner: Runner

    /// `temporary` is where each build's DerivedData goes, in a folder of its own that goes afterwards.
    public init(
        paths: AppPaths, locator: Xcode.Locator = .system, limit: Duration = ProfileMaker.limit,
        temporary: URL = FileManager.default.temporaryDirectory, runner: Runner? = nil
    ) {
        self.paths = paths
        self.locator = locator
        self.limit = limit
        self.temporary = temporary
        self.runner = runner ?? { xcodebuild, arguments, environment, log in
            try await ProcessRunner().run(
                xcodebuild, arguments: arguments, environment: environment, stdout: .file(log), stderr: .file(log),
                killAfter: .seconds(10))
        }
    }

    /// Has Xcode make a Provisioning Profile that lets `team` sign `bundleId` for `device`, or bring the one it has up
    /// to date. `bundleId` must be a Port's for `team` (`PortID.deviceBundleID(team:)`), so the stub's folder and log
    /// are the Port's own. Throws `provisioningFailed` saying what Xcode said, `xcodeMissing` or `noIOSPlatform`.
    public func make(for bundleId: String, team: AppleTeamID, device: DeviceID) async throws {
        guard let port = PortID(deviceBundleID: bundleId, team: team) else {
            throw FrontportError.provisioningFailed("\(bundleId) isn’t a Port’s bundle ID for Apple Team \(team).")
        }
        guard device.isWellFormed else { throw FrontportError.fileOperation("“\(device)” isn’t a Device’s UDID.") }
        let xcode = try await Xcode.find(locator)

        // A link or file in place of a folder goes, never followed.
        let project = paths.provisioningProject(for: port, team: team)
        let log = paths.provisioningLog(for: port)
        for folder in [paths.provisioning, log.deletingLastPathComponent()]
        where FileOperations.exists(folder) && !FileOperations.isDirectory(folder) {
            try FileOperations.removeUntrusted(folder)
        }
        try FileOperations.removeUntrusted(project)
        for (path, contents) in Self.files(bundleId: bundleId, team: team) {
            let file = project.appending(path: path)
            try FileOperations.createDirectory(file.deletingLastPathComponent(), mode: 0o755)
            try Data(contents.utf8).write(to: file)
        }
        try FileOperations.createDirectory(log.deletingLastPathComponent(), mode: 0o755)
        try FileOperations.removeUntrusted(log)
        let derivedData = temporary.appending(path: "frontport-provisioning-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileOperations.removeUntrusted(derivedData)
            try? FileOperations.removeUntrusted(project.appending(path: "build", directoryHint: .isDirectory))
        }

        let arguments = Self.arguments(
            project: project.appending(path: "\(Self.name).xcodeproj", directoryHint: .isDirectory), device: device,
            derivedData: derivedData, team: team, bundleId: bundleId)
        var inherited = ProcessInfo.processInfo.environment
        inherited["DEVELOPER_DIR"] = xcode.developer.path(percentEncoded: false)
        let result: ProcessResult
        do {
            let (runner, xcodebuild, environment) = (runner, xcode.xcodebuild, inherited)
            result = try await withDeadline(limit) { try await runner(xcodebuild, arguments, environment, log) }
        } catch is CancellationError where !Task.isCancelled {
            throw FrontportError.provisioningFailed(
                "Xcode didn’t make one within \(Self.describe(limit)). What it said is in \(log.path(percentEncoded: false)).")
        }
        guard !result.succeeded else { return }
        let said = (try? FileOperations.readRegularFile(log)).map { String(decoding: $0.suffix(262_144), as: UTF8.self) } ?? ""
        throw Self.failure(fromLog: said, status: result.status, bundleId: bundleId, team: team)
    }

    /// "5 minutes", or "30 seconds" under a minute.
    static func describe(_ limit: Duration) -> String {
        let seconds = Int(limit.components.seconds)
        return seconds >= 60 ? "\(seconds / 60) minute\(seconds >= 120 ? "s" : "")" : "\(seconds) second\(seconds == 1 ? "" : "s")"
    }

    // MARK: xcodebuild

    /// The stub's name: its project, scheme, target and app.
    static let name = "Stub"

    /// `xcodebuild`'s arguments: a Debug build of the stub's scheme for the Device, which may register the App ID and
    /// the Device and download the Provisioning Profile, with the Apple Team, bundle ID and automatic signing given
    /// again on the command line, and DerivedData in `derivedData`.
    static func arguments(project: URL, device: DeviceID, derivedData: URL, team: AppleTeamID, bundleId: String) -> [String] {
        [
            "-project", DeviceCtl.argument(project), "-scheme", name, "-configuration", "Debug",
            "-destination", "id=\(device.rawValue)", "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration",
            "-derivedDataPath", DeviceCtl.argument(derivedData),
            "DEVELOPMENT_TEAM=\(team.rawValue)", "PRODUCT_BUNDLE_IDENTIFIER=\(bundleId)", "CODE_SIGN_STYLE=Automatic",
            "build",
        ]
    }

    /// What Xcode's errors in `log` mean for the user, most telling first, else the errors as Xcode wrote them.
    static func failure(fromLog log: String, status: Int32, bundleId: String, team: AppleTeamID) -> FrontportError {
        var errors: [String] = []
        for line in log.split(whereSeparator: \.isNewline) {
            guard let range = line.range(of: "error: ") else { continue }
            var error = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            // Xcode names the target and project it was building, which are the stub's.
            if let target = error.range(of: " (in target '") { error = String(error[..<target.lowerBound]) }
            if !error.isEmpty, !errors.contains(error) { errors.append(error) }
        }
        func first(_ needles: String...) -> String? {
            errors.first { error in needles.contains { error.localizedCaseInsensitiveContains($0) } }
        }

        if first("No Account for Team", "No Accounts", "valid credentials", "sign in again", "session has expired") != nil {
            return .provisioningFailed(
                "Xcode isn’t signed in to Apple Team \(team). Add your Apple Account in Xcode › Settings › Accounts, then "
                    + "try again.")
        }
        if let error = first("App ID limit", "maximum number of App IDs") {
            return .provisioningFailed(
                "Apple Team \(team) can’t register another App ID now: a free Apple Team may register 10 a week. Try again "
                    + "in a few days, or choose a paid Apple Team. Xcode said: \(error)")
        }
        if first("cannot be registered to your development team", "is not available. Change your bundle identifier") != nil {
            return .provisioningFailed("\(bundleId) is registered to another Apple Team, so Apple Team \(team) can’t use it.")
        }
        if let error = first(
            "isn't registered", "is not registered", "has no devices", "register device", "register the device",
            "maximum number of devices", "device limit")
        {
            return .provisioningFailed("Xcode couldn’t register the Device on Apple Team \(team). Xcode said: \(error)")
        }
        if let error = first("Developer Mode") {
            return .deviceUnavailable(
                .developerModeOff,
                detail: "Developer Mode is off on the Device. Turn it on in its Settings › Privacy & Security, then try "
                    + "again. Xcode said: \(error)")
        }
        if let error = first("Unable to find a destination", "is not available for destination") {
            return .deviceUnavailable(.away, detail: "Xcode couldn’t reach the Device. Xcode said: \(error)")
        }
        if first("first download and install the platform", "platform is not installed") != nil {
            return .noIOSPlatform
        }
        let said = errors.isEmpty
            ? log.split(whereSeparator: \.isNewline).suffix(5).joined(separator: "\n")
            : errors.prefix(5).joined(separator: "\n")
        return .provisioningFailed(
            said.isEmpty ? "xcodebuild failed (exit status \(status))." : "Xcode couldn’t make one. Xcode said: \(said)")
    }

    // MARK: The stub

    /// The stub project's files, by path relative to its folder: a one-target iOS app for iPhone and iPad with a scene
    /// delegate, as apps built with the iOS 27 SDK need, signed automatically with `team` as `bundleId`.
    static func files(bundleId: String, team: AppleTeamID) -> [String: String] {
        [
            "\(name).xcodeproj/project.pbxproj": project(bundleId: bundleId, team: team),
            "\(name).xcodeproj/xcshareddata/xcschemes/\(name).xcscheme": scheme,
            "\(name)/App.swift": source,
            "\(name)/Info.plist": infoPlist,
        ]
    }

    private static func project(bundleId: String, team: AppleTeamID) -> String {
        """
        // !$*UTF8*$!
        {
        \tarchiveVersion = 1;
        \tclasses = {
        \t};
        \tobjectVersion = 56;
        \tobjects = {
        \t\tF0000000000000000000000B /* App.swift in Sources */ = {isa = PBXBuildFile; fileRef = F0000000000000000000000A /* App.swift */; };
        \t\tF0000000000000000000000A /* App.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = App.swift; sourceTree = "<group>"; };
        \t\tF0000000000000000000000C /* Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; };
        \t\tF0000000000000000000000D /* \(name).app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = \(name).app; sourceTree = BUILT_PRODUCTS_DIR; };
        \t\tF00000000000000000000001 = {isa = PBXGroup; children = (F00000000000000000000002 /* \(name) */, F00000000000000000000003 /* Products */, ); sourceTree = "<group>"; };
        \t\tF00000000000000000000002 /* \(name) */ = {isa = PBXGroup; children = (F0000000000000000000000A /* App.swift */, F0000000000000000000000C /* Info.plist */, ); path = \(name); sourceTree = "<group>"; };
        \t\tF00000000000000000000003 /* Products */ = {isa = PBXGroup; children = (F0000000000000000000000D /* \(name).app */, ); name = Products; sourceTree = "<group>"; };
        \t\tF00000000000000000000010 /* Sources */ = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (F0000000000000000000000B /* App.swift in Sources */, ); runOnlyForDeploymentPostprocessing = 0; };
        \t\tF00000000000000000000011 /* Frameworks */ = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ( ); runOnlyForDeploymentPostprocessing = 0; };
        \t\tF00000000000000000000020 /* \(name) */ = {isa = PBXNativeTarget; buildConfigurationList = F00000000000000000000031; buildPhases = (F00000000000000000000010 /* Sources */, F00000000000000000000011 /* Frameworks */, ); buildRules = ( ); dependencies = ( ); name = \(name); productName = \(name); productReference = F0000000000000000000000D /* \(name).app */; productType = "com.apple.product-type.application"; };
        \t\tF00000000000000000000030 /* Project object */ = {isa = PBXProject; attributes = {LastUpgradeCheck = 2700; TargetAttributes = {F00000000000000000000020 = {CreatedOnToolsVersion = 27.0; }; }; }; buildConfigurationList = F00000000000000000000032; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base, ); mainGroup = F00000000000000000000001; productRefGroup = F00000000000000000000003 /* Products */; projectDirPath = ""; projectRoot = ""; targets = (F00000000000000000000020 /* \(name) */, ); };
        \t\tF00000000000000000000040 /* Debug */ = {isa = XCBuildConfiguration; buildSettings = {
        \t\t\tCODE_SIGN_STYLE = Automatic;
        \t\t\tDEVELOPMENT_TEAM = \(team.rawValue);
        \t\t\tGENERATE_INFOPLIST_FILE = NO;
        \t\t\tINFOPLIST_FILE = \(name)/Info.plist;
        \t\t\tIPHONEOS_DEPLOYMENT_TARGET = 15.0;
        \t\t\tPRODUCT_BUNDLE_IDENTIFIER = "\(bundleId)";
        \t\t\tPRODUCT_NAME = \(name);
        \t\t\tSWIFT_VERSION = 5.0;
        \t\t\tTARGETED_DEVICE_FAMILY = "1,2";
        \t\t}; name = Debug; };
        \t\tF00000000000000000000041 /* Debug */ = {isa = XCBuildConfiguration; buildSettings = {
        \t\t\tALWAYS_SEARCH_USER_PATHS = NO;
        \t\t\tSDKROOT = iphoneos;
        \t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";
        \t\t}; name = Debug; };
        \t\tF00000000000000000000031 = {isa = XCConfigurationList; buildConfigurations = (F00000000000000000000040 /* Debug */, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
        \t\tF00000000000000000000032 = {isa = XCConfigurationList; buildConfigurations = (F00000000000000000000041 /* Debug */, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
        \t};
        \trootObject = F00000000000000000000030 /* Project object */;
        }

        """
    }

    private static let scheme = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Scheme LastUpgradeVersion = "2700" version = "1.7">
           <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
              <BuildActionEntries>
                 <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
                    <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "F00000000000000000000020" BuildableName = "\(name).app" BlueprintName = "\(name)" ReferencedContainer = "container:\(name).xcodeproj">
                    </BuildableReference>
                 </BuildActionEntry>
              </BuildActionEntries>
           </BuildAction>
           <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "" selectedLauncherIdentifier = "Xcode.IDEFoundation.Launcher.PosixSpawn" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
           </LaunchAction>
        </Scheme>

        """

    private static let source = """
        import UIKit

        // Frontport writes this stub only so Xcode makes a Provisioning Profile for its bundle ID. It's built, never
        // installed: the Port's own app is signed with the Provisioning Profile.

        @main
        final class AppDelegate: UIResponder, UIApplicationDelegate {
            func application(
                _ application: UIApplication, configurationForConnecting session: UISceneSession,
                options: UIScene.ConnectionOptions
            ) -> UISceneConfiguration {
                let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
                configuration.delegateClass = SceneDelegate.self
                return configuration
            }
        }

        final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
            var window: UIWindow?

            func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
                guard let scene = scene as? UIWindowScene else { return }
                let window = UIWindow(windowScene: scene)
                window.rootViewController = UIViewController()
                window.makeKeyAndVisible()
                self.window = window
            }
        }

        """

    private static let infoPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>CFBundleExecutable</key>
        \t<string>$(EXECUTABLE_NAME)</string>
        \t<key>CFBundleIdentifier</key>
        \t<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
        \t<key>CFBundleName</key>
        \t<string>$(PRODUCT_NAME)</string>
        \t<key>CFBundlePackageType</key>
        \t<string>APPL</string>
        \t<key>CFBundleShortVersionString</key>
        \t<string>1.0</string>
        \t<key>CFBundleVersion</key>
        \t<string>1</string>
        \t<key>UIApplicationSceneManifest</key>
        \t<dict>
        \t\t<key>UIApplicationSupportsMultipleScenes</key>
        \t\t<false/>
        \t</dict>
        \t<key>UILaunchScreen</key>
        \t<dict/>
        \t<key>UISupportedInterfaceOrientations</key>
        \t<array>
        \t\t<string>UIInterfaceOrientationPortrait</string>
        \t\t<string>UIInterfaceOrientationPortraitUpsideDown</string>
        \t\t<string>UIInterfaceOrientationLandscapeLeft</string>
        \t\t<string>UIInterfaceOrientationLandscapeRight</string>
        \t</array>
        </dict>
        </plist>

        """
}
