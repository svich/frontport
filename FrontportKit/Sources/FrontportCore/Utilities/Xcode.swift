import CoreServices
import Foundation

/// Full Xcode with the iOS platform, which Devices need: its `devicectl` installs and Seeds, its `xcodebuild` makes
/// Provisioning Profiles and its iOS SDK builds iOS Recipes. The Command Line Tools have none of them.
public struct Xcode: Hashable, Sendable {
    /// Its `Contents/Developer` folder.
    public var developer: URL

    public init(developer: URL) {
        self.developer = developer
    }

    public var devicectl: URL { developer.appending(path: "usr/bin/devicectl") }
    public var xcodebuild: URL { developer.appending(path: "usr/bin/xcodebuild") }
    public var iosPlatform: URL { developer.appending(path: "Platforms/iPhoneOS.platform", directoryHint: .isDirectory) }
    public var iosSDK: URL { iosPlatform.appending(path: "Developer/SDKs/iPhoneOS.sdk", directoryHint: .isDirectory) }

    /// How Xcode is looked up. Tests inject their own.
    public struct Locator: Sendable {
        /// The active developer folder, `xcode-select -p`, or nil when none is set.
        public var selected: @Sendable () async -> URL?
        /// Every Xcode.app LaunchServices knows, best first.
        public var installed: @Sendable () async -> [URL]
        /// True when a folder exists.
        public var exists: @Sendable (URL) -> Bool

        public init(
            selected: @escaping @Sendable () async -> URL?,
            installed: @escaping @Sendable () async -> [URL],
            exists: @escaping @Sendable (URL) -> Bool = { FileOperations.isDirectory($0) }
        ) {
            self.selected = selected
            self.installed = installed
            self.exists = exists
        }

        private static let xcodeSelect = URL(fileURLWithPath: "/usr/bin/xcode-select")

        public static let system = Locator(
            selected: {
                // Only `xcode-select -p` is safe: xcrun and the /usr/bin shims prompt to install when nothing is.
                guard let result = try? await ProcessRunner().run(xcodeSelect, arguments: ["-p"], stderr: .discard),
                    result.succeeded
                else { return nil }
                let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
            },
            installed: {
                let urls = LSCopyApplicationURLsForBundleIdentifier("com.apple.dt.Xcode" as CFString, nil)?
                    .takeRetainedValue() as? [URL]
                return urls ?? []
            }
        )
    }

    /// The selected developer folder when it's inside an app, else the first Xcode LaunchServices knows that has the
    /// iOS platform. Throws `xcodeMissing` when there's no Xcode, `noIOSPlatform` when none has the iOS platform.
    public static func find(_ locator: Locator = .system) async throws -> Xcode {
        var candidates: [Xcode] = []
        if let selected = await locator.selected(), selected.standardizedFileURL.path(percentEncoded: false)
            .trimmingCharacters(in: ["/"]).hasSuffix(".app/Contents/Developer")
        {
            candidates.append(Xcode(developer: selected))
        }
        for app in await locator.installed() {
            let xcode = Xcode(developer: app.appending(path: "Contents/Developer", directoryHint: .isDirectory))
            if !candidates.contains(where: { $0.developer.standardizedFileURL == xcode.developer.standardizedFileURL }) {
                candidates.append(xcode)
            }
        }
        candidates = candidates.filter { locator.exists($0.developer) }
        guard !candidates.isEmpty else { throw FrontportError.xcodeMissing }
        guard let xcode = candidates.first(where: { locator.exists($0.iosPlatform) }) else {
            throw FrontportError.noIOSPlatform
        }
        return xcode
    }
}
