#if DEBUG
import Foundation
import FrontportCore

/// Stand-ins for `devicectl`, the keychain and the Device Packager, which `FRONTPORT_FAKE_DEVICE` (TestHooks) puts in
/// place of the real ones: one iPhone, connected and ready, that keeps what's installed on it, and what's copied into
/// each app's container, in memory, and one Apple Team with a Provisioning Profile for every bundle ID. The Device
/// Library itself, the Fetcher, ROMs and the records are real, so the UI tests install on the iPhone, Seed it and
/// uninstall from it as the user would, with nothing signed or sent.
enum FakeDevices {
    static let iPhone = Device(
        id: "00008110-0000000000000000", name: "Test iPhone", model: "iPhone 13", osVersion: "27.0.1", families: [1])
    static let teamID = AppleTeamID("A1B2C3D4E5")!
    static let certificate = SigningCertificate(
        sha1: String(repeating: "AB", count: 20), name: "Apple Development: Frontport Tests", team: teamID,
        expires: .now.addingTimeInterval(365 * 86_400))
    static let team = AppleTeam(id: teamID, name: "Frontport Tests", certificates: [certificate])

    /// The services that stand in for the real ones.
    static let control = Control()
    static let provisioning = Teams()
    static let packager = Packager()

    /// The iPhone, always reachable over USB, unlocked and in Developer Mode, with nothing running.
    actor Control: DeviceControlling {
        private var installed: Set<String> = []
        /// Each app's container, each file by its path relative to it.
        private var containers: [String: [String: Data]] = [:]

        func readings() -> [DeviceReading] {
            [DeviceReading(device: FakeDevices.iPhone, connection: .wired, isLocked: false, developerMode: true)]
        }

        func apps(on device: DeviceID) throws -> Set<String> {
            try check(device)
            return installed
        }

        func install(_ app: URL, on device: DeviceID) throws {
            try check(device)
            installed.insert(Packager.bundleId(of: app) ?? app.lastPathComponent)
        }

        func uninstall(_ bundleId: String, from device: DeviceID) throws {
            try check(device)
            installed.remove(bundleId)
            containers[bundleId] = nil
        }

        func list(_ seeds: [StagedSeed], markers: [String], of bundleId: String, on device: DeviceID) throws -> DeviceListing {
            try check(device, bundleId)
            let files = containers[bundleId] ?? [:]
            var listed: [String: DeviceFile] = [:]
            for (path, data) in files {
                listed[path] = DeviceFile(path: path, isDirectory: false, size: Int64(data.count))
                var folder = (path as NSString).deletingLastPathComponent
                while !folder.isEmpty {
                    listed[folder] = DeviceFile(path: folder, isDirectory: true, size: 0)
                    folder = (folder as NSString).deletingLastPathComponent
                }
            }
            var listing = DeviceListing(files: Array(listed.values))
            for marker in markers where listing.isFile(marker) {
                listing.markers[marker] = files[marker].map(DeviceListing.named(by:))
            }
            return listing
        }

        func put(
            _ root: URL, markers: [String], over listing: DeviceListing, of bundleId: String, on device: DeviceID
        ) throws {
            try check(device, bundleId)
            let names = FileManager.default.enumerator(atPath: root.path(percentEncoded: false))?.allObjects as? [String] ?? []
            let files = names.filter { !FileOperations.isDirectory(root.appending(path: $0)) && !markers.contains($0) }
            for path in files + markers {
                containers[bundleId, default: [:]][path] = try Data(contentsOf: root.appending(path: path))
            }
        }

        func processes(on device: DeviceID) throws -> [Int32: URL] {
            try check(device)
            return [:]
        }

        /// Refuses another Device, and an app that isn't installed, as `devicectl` does.
        private func check(_ device: DeviceID, _ bundleId: String) throws {
            try check(device)
            guard installed.contains(bundleId) else {
                throw FrontportError.deviceUnavailable(.notInstalled, detail: "\(bundleId) isn’t installed.")
            }
        }

        private func check(_ device: DeviceID) throws {
            guard device == FakeDevices.iPhone.id else {
                throw FrontportError.deviceUnavailable(.away, detail: "Only \(FakeDevices.iPhone.name) is here.")
            }
        }
    }

    /// The one Apple Team, with a wildcard Provisioning Profile that lists the iPhone and lasts as long as its
    /// certificate. With `FRONTPORT_FAKE_DEVICE_RENEW` in the environment, the one an install takes lasts a day and a
    /// half, so its Renew is due at once, and the one a Renew asks for lasts as long as the certificate.
    struct Teams: Provisioning {
        static let shortLived = ProcessInfo.processInfo.environment["FRONTPORT_FAKE_DEVICE_RENEW"] != nil

        func teams() -> [AppleTeam] { [FakeDevices.team] }

        func signing(for bundleId: String, team: AppleTeamID, device: DeviceID, outlasting: Date?) throws -> DeviceSigning {
            guard team == FakeDevices.teamID else { throw FrontportError.noAppleTeam }
            let expires = Self.shortLived && outlasting == nil
                ? Date.now.addingTimeInterval(36 * 60 * 60) : FakeDevices.certificate.expires
            if let outlasting, expires <= outlasting {
                throw FrontportError.provisioningFailed("None lasts longer than the one it has.")
            }
            let profile = ProvisioningProfile(
                uuid: outlasting == nil ? "00000000-0000-0000-0000-000000000000" : "00000000-0000-0000-0000-000000000001",
                name: "iOS Team Provisioning Profile: *", team: team,
                applicationIdentifier: "\(team.rawValue).*", isDevelopment: true, devices: [FakeDevices.iPhone.id],
                certificates: [FakeDevices.certificate.sha1], created: .now, expires: expires,
                file: URL(filePath: "/dev/null"))
            return DeviceSigning(team: team, bundleId: bundleId, certificate: FakeDevices.certificate, profile: profile)
        }
    }

    /// Reads any app, a Mac one included, as one for iPhone and iPad from iOS 15, sets the bundle ID as the real one
    /// does, and signs nothing.
    struct Packager: DevicePackaging {
        func inspect(_ app: URL, version: IOSVersion) throws -> DeviceAppInfo {
            let info = (try? PropertyListSerialization.propertyList(from: Data(contentsOf: Self.plist(of: app)), format: nil))
                as? [String: Any] ?? [:]
            return DeviceAppInfo(
                bundleId: info["CFBundleIdentifier"] as? String ?? "", executable: info["CFBundleExecutable"] as? String ?? "",
                minimumOS: "15.0", sdk: nil, families: [1, 2])
        }

        func package(_ app: URL, version: IOSVersion, signing: DeviceSigning) throws -> DeviceAppInfo {
            try resign(app, signing: signing)
        }

        func resign(_ app: URL, signing: DeviceSigning) throws -> DeviceAppInfo {
            let plist = Self.plist(of: app)
            var info = (try? PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil))
                as? [String: Any] ?? [:]
            info["CFBundleIdentifier"] = signing.bundleId
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)
            return DeviceAppInfo(
                bundleId: signing.bundleId, executable: info["CFBundleExecutable"] as? String ?? "",
                minimumOS: "15.0", sdk: nil, families: [1, 2])
        }

        /// A Mac app's `Contents/Info.plist`, or a flat one's.
        static func plist(of app: URL) -> URL {
            let mac = app.appending(path: "Contents/Info.plist")
            return FileManager.default.fileExists(atPath: mac.path(percentEncoded: false)) ? mac : app.appending(path: "Info.plist")
        }

        static func bundleId(of app: URL) -> String? {
            let info = (try? PropertyListSerialization.propertyList(from: Data(contentsOf: plist(of: app)), format: nil))
                as? [String: Any]
            return info?["CFBundleIdentifier"] as? String
        }
    }
}
#endif
