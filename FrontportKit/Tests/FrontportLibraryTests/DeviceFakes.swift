import Foundation
import FrontportCore
import FrontportLibrary
import FrontportPackager

// Fakes for the Device Library: `devicectl`, Provisioning and the Fetcher. The Packager is the real Device Packager
// over a signer that records what it's asked, so its checks run without codesign or a keychain.

let testTeam = AppleTeamID("A1B2C3D4E5")!
let testCertificate = SigningCertificate(
    sha1: String(repeating: "AB", count: 20), name: "Apple Development: Tests", team: testTeam,
    expires: Date(timeIntervalSince1970: 1_900_000_000))
let iPhone = Device(id: "00008110-0000000000000000", name: "Test iPhone", model: "iPhone 13", osVersion: "27.0.1", families: [1])
let iPad = Device(id: "00008112-0000000000000000", name: "Test iPad", model: "iPad Air", osVersion: "27.0", families: [1, 2])

/// The Device as a reading finds it when it can install: reachable, unlocked, Developer Mode on.
func ready(_ device: Device, connection: DeviceReading.Connection = .network) -> DeviceReading {
    DeviceReading(device: device, connection: connection, isLocked: false, developerMode: true)
}

extension DeviceLibrary {
    /// `prepare` on the Channel, then `installPrepared`, as the app installs: preparing runs first, for no Device.
    func prepareAndInstall(
        _ version: IOSVersion, on reading: DeviceReading, team: AppleTeamID, channel: Channel,
        progress: @escaping ProgressHandler
    ) async throws -> DeviceInstallation {
        _ = try await prepare(version, channel: channel, progress: progress)
        return try await installPrepared(version, on: reading, team: team, progress: progress)
    }
}

/// Hand-made iOS apps: little-endian Mach-O, as arm64 is, with the load commands the Device Packager reads.
enum DeviceFixtures {
    static func version(_ major: UInt32, _ minor: UInt32, _ patch: UInt32 = 0) -> UInt32 {
        major << 16 | minor << 8 | patch
    }

    /// An arm64 Mach-O with `LC_UUID` and `LC_BUILD_VERSION`: platform 2 is iOS, 7 the iOS Simulator, 1 macOS.
    static func executable(
        platform: UInt32 = 2, minimumOS: UInt32 = version(15, 0), sdk: UInt32 = version(18, 0), fileType: UInt32 = 0x2
    ) -> Data {
        let commands = words([0x1B, 24, 1, 2, 3, 4]) + words([0x32, 24, platform, minimumOS, sdk, 0])
        return Data([0xCF, 0xFA, 0xED, 0xFE]) + words([0x0100_000C, 0, fileType, 2, UInt32(commands.count), 0, 0])
            + commands + Data(count: 64)
    }

    /// A flat app as upstream ships it in an `.ipa`: its executable, a loose dylib in `Frameworks/`, an upstream
    /// signature, and the Release's version in `version.txt`.
    static func app(
        named name: String, version: String, in directory: URL, minimumOS: UInt32 = version(15, 0),
        families: [Int] = [1, 2], platform: UInt32 = 2
    ) throws -> URL {
        let app = directory.appending(path: "\(name).app", directoryHint: .isDirectory)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.upstream.\(name.lowercased())", "CFBundleExecutable": name,
            "CFBundlePackageType": "APPL", "MinimumOSVersion": "15.0", "UIDeviceFamily": families,
        ]
        try write(PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0), to: app.appending(path: "Info.plist"))
        try write(executable(platform: platform, minimumOS: minimumOS), to: app.appending(path: name))
        try write(executable(fileType: 0x6), to: app.appending(path: "Frameworks/libkit.dylib"))
        try write(Data("upstream".utf8), to: app.appending(path: "_CodeSignature/CodeResources"))
        try write(Data(version.utf8), to: app.appending(path: "version.txt"))
        return app
    }

    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    static func words(_ values: [UInt32]) -> Data {
        values.reduce(into: Data()) { data, value in withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    }

    /// An app's `CFBundleIdentifier`.
    static func bundleId(of app: URL) -> String? {
        guard let data = try? Data(contentsOf: app.appending(path: "Info.plist")) else { return nil }
        let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        return info?["CFBundleIdentifier"] as? String
    }

    static func version(of app: URL) throws -> String {
        try String(decoding: Data(contentsOf: app.appending(path: "version.txt")), as: UTF8.self)
    }
}

/// Makes the Release's app as the real Fetcher leaves it in `directory`, keeping a stand-in download in
/// `Downloads/<downloads>/` as it would, and counts the fetches in flight.
struct FakeDeviceFetcher: AssetFetching {
    let paths: AppPaths
    /// Each fetch's version and the Downloads folder it used.
    let fetched = Box<[(version: String, downloads: PortID)]>([])
    let inFlight = Box((now: 0, most: 0))
    let minimumOS = Box(DeviceFixtures.version(15, 0))
    let families = Box([1, 2])
    let platform = Box<UInt32>(2)

    func fetch(_ release: Release, into directory: URL, downloads: PortID, progress: @escaping ProgressHandler) async throws -> URL {
        inFlight.update { $0.now += 1; $0.most = max($0.most, $0.now) }
        defer { inFlight.update { $0.now -= 1 } }
        try await Task.sleep(for: .milliseconds(20))
        fetched.update { $0.append((release.version, downloads)) }
        progress(ProgressUpdate(.downloading, fraction: 1))
        try DeviceFixtures.write(
            Data("ipa".utf8), to: paths.downloads(for: downloads).appending(path: release.asset?.name ?? "asset.ipa"))
        return try DeviceFixtures.app(
            named: "Tiny", version: release.version, in: directory, minimumOS: minimumOS.get, families: families.get,
            platform: platform.get)
    }
}

/// `devicectl` over Devices that hold what it installed: each install records the app's bundle ID and version, as
/// signed at that moment. Each app's container is a plain dictionary of its files' contents by path.
struct FakeDeviceControl: DeviceControlling {
    struct Install: Sendable {
        var device: DeviceID
        var bundleId: String
        var version: String
        /// True when the app held the Device Packager's signature and Provisioning Profile.
        var signed: Bool
    }

    /// Each Device's containers by bundle ID, each file's contents by its path relative to the container.
    let containers = Box<[DeviceID: [String: [String: Data]]]>([:])
    /// Each put: the files it wrote, in order.
    let puts = Box<[[String]]>([])
    /// Each marker read while listing.
    let reads = Box<[String]>([])
    /// Thrown by a put once `writesBeforeFailure` more files have been written.
    let putFailure = Box<FrontportError?>(nil)
    let writesBeforeFailure = Box(0)
    /// When true, the file a put fails on is left cut off at half its size, as one stopped part way might.
    let truncatesOnFailure = Box(false)
    /// What runs on each Device, by process ID.
    let processes = Box<[DeviceID: [Int32: URL]]>([:])

    /// Each Device's apps, bundle ID to version.
    let apps = Box<[DeviceID: [String: String]]>([:])
    let installs = Box<[Install]>([])
    let uninstalls = Box<[(bundleId: String, device: DeviceID)]>([])
    let installFailure = Box<FrontportError?>(nil)
    let uninstallFailure = Box<FrontportError?>(nil)
    /// Runs as each install starts, so a test can look at the world as `devicectl` sees it.
    let onInstall = Box<(@Sendable (URL) throws -> Void)?>(nil)

    func readings() async throws -> [DeviceReading] { [] }

    func apps(on device: DeviceID) async throws -> Set<String> { Set(apps.get[device].map { Array($0.keys) } ?? []) }

    func install(_ app: URL, on device: DeviceID) async throws {
        try onInstall.get?(app)
        if let failure = installFailure.get { throw failure }
        let bundleId = DeviceFixtures.bundleId(of: app) ?? ""
        let version = (try? DeviceFixtures.version(of: app)) ?? ""
        let signed = (try? String(decoding: Data(contentsOf: app.appending(path: "_CodeSignature/CodeResources")), as: UTF8.self))
            == "signed with \(testCertificate.sha1)" && FileManager.default.fileExists(
                atPath: app.appending(path: "embedded.mobileprovision").path(percentEncoded: false))
        installs.update { $0.append(Install(device: device, bundleId: bundleId, version: version, signed: signed)) }
        apps.update { $0[device, default: [:]][bundleId] = version }
    }

    func uninstall(_ bundleId: String, from device: DeviceID) async throws {
        uninstalls.update { $0.append((bundleId, device)) }
        if let failure = uninstallFailure.get { throw failure }
        apps.update { $0[device]?[bundleId] = nil }
        containers.update { $0[device]?[bundleId] = nil }
    }

    func list(_ seeds: [StagedSeed], markers: [String], of bundleId: String, on device: DeviceID) async throws -> DeviceListing {
        try checkInstalled(bundleId, on: device)
        let files = containers.get[device]?[bundleId] ?? [:]
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
            reads.update { $0.append(marker) }
            listing.markers[marker] = files[marker].map(DeviceListing.named(by:))
        }
        return listing
    }

    func put(_ root: URL, markers: [String], over listing: DeviceListing, of bundleId: String, on device: DeviceID) async throws {
        try checkInstalled(bundleId, on: device)
        let names = FileManager.default.enumerator(atPath: root.path(percentEncoded: false))?.allObjects as? [String] ?? []
        let files = names.filter { !FileOperations.isDirectory(root.appending(path: $0)) && !markers.contains($0) }.sorted()
        puts.update { $0.append([]) }
        for path in files + markers {
            let data = try Data(contentsOf: root.appending(path: path))
            if let failure = putFailure.get {
                if writesBeforeFailure.get == 0 {
                    if truncatesOnFailure.get { store(data.prefix(data.count / 2), at: path, of: bundleId, on: device) }
                    throw failure
                }
                writesBeforeFailure.update { $0 -= 1 }
            }
            store(data, at: path, of: bundleId, on: device)
            puts.update { $0[$0.count - 1].append(path) }
        }
    }

    func processes(on device: DeviceID) async throws -> [Int32: URL] { processes.get[device] ?? [:] }

    /// Writes a file in the app's container on the Device, as the Port or the user would.
    func write(_ text: String, at path: String, of bundleId: String, on device: DeviceID) {
        store(Data(text.utf8), at: path, of: bundleId, on: device)
    }

    /// The file at `path` in the app's container on the Device, as text.
    func text(at path: String, of bundleId: String, on device: DeviceID) -> String? {
        containers.get[device]?[bundleId]?[path].map { String(decoding: $0, as: UTF8.self) }
    }

    /// Every file put, in order.
    var written: [String] { puts.get.flatMap { $0 } }

    private func store(_ data: Data, at path: String, of bundleId: String, on device: DeviceID) {
        containers.update { $0[device, default: [:]][bundleId, default: [:]][path] = data }
    }

    private func checkInstalled(_ bundleId: String, on device: DeviceID) throws {
        guard apps.get[device]?[bundleId] != nil else {
            throw FrontportError.deviceUnavailable(.notInstalled, detail: "The app isn’t installed.")
        }
    }
}

/// The Apple Team `testTeam` with a wildcard development Provisioning Profile for every Device, written at `profile`.
/// One that doesn't last past what a request asks it to outlast is refused, as `ProvisioningProfiles.choose` refuses it.
struct FakeProvisioning: Provisioning {
    let profile: URL
    let requests = Box<[(bundleId: String, team: AppleTeamID, device: DeviceID)]>([])
    /// What each request asked the Provisioning Profile to outlast.
    let outlasting = Box<[Date?]>([])
    let failure = Box<FrontportError?>(nil)
    /// How long each request takes, as when Xcode makes a Provisioning Profile.
    let delay = Box<Duration?>(nil)
    /// When the Provisioning Profile expires, and its UUID: a test sets later ones, as Xcode making one would.
    let profileExpires = Box(FakeProvisioning.expires)
    let profileUUID = Box("11111111-2222-3333-4444-555555555555")
    static let expires = Date(timeIntervalSince1970: 1_850_000_000)

    init(profile: URL) throws {
        self.profile = profile
        try DeviceFixtures.write(Data("wildcard profile".utf8), to: profile)
    }

    func teams() async -> [AppleTeam] { [AppleTeam(id: testTeam, name: "Tests", certificates: [testCertificate])] }

    func signing(for bundleId: String, team: AppleTeamID, device: DeviceID, outlasting: Date?) async throws -> DeviceSigning {
        requests.update { $0.append((bundleId, team, device)) }
        self.outlasting.update { $0.append(outlasting) }
        if let delay = delay.get { try await Task.sleep(for: delay) }
        if let failure = failure.get { throw failure }
        let expires = profileExpires.get
        if let outlasting, expires <= outlasting {
            throw FrontportError.provisioningFailed("Xcode has none for \(bundleId) that lasts long enough.")
        }
        return DeviceSigning(
            team: team, bundleId: bundleId, certificate: testCertificate,
            profile: ProvisioningProfile(
                uuid: profileUUID.get, name: "iOS Team Provisioning Profile: *", team: team,
                applicationIdentifier: "\(team.rawValue).*", isDevelopment: true, devices: [device],
                certificates: [testCertificate.sha1], created: Date(timeIntervalSince1970: 1_800_000_000),
                expires: expires, file: profile))
    }
}

/// Signs nothing, so the real Device Packager runs without codesign: records each item it was asked to sign, and, as
/// codesign would, rewrites a bundle's `_CodeSignature` in place.
struct RecordingDeviceSigner: DeviceSigner {
    let signed = Box<[(item: URL, certificate: String, entitlements: [String: PortEntitlements.Value]?)]>([])

    func sign(_ item: URL, certificate: String, entitlements: [String: PortEntitlements.Value]?) async throws {
        signed.update { $0.append((item, certificate, entitlements)) }
        if FileOperations.isDirectory(item) {
            try DeviceFixtures.write(
                Data("signed with \(certificate)".utf8), to: item.appending(path: "_CodeSignature/CodeResources"))
        }
    }

    func verify(_ app: URL, strictness: Strictness) async throws {}
}
