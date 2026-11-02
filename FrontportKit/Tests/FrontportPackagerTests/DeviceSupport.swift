import Foundation
import FrontportCore
import Synchronization
@testable import FrontportPackager

/// Mach-O files made by hand: little-endian, as arm64 is, with the load commands a test names.
enum MachOBytes {
    static let arm64: UInt32 = 0x0100_000C
    static let x86_64: UInt32 = 0x0100_0007
    static let execute: UInt32 = 0x2
    static let dylib: UInt32 = 0x6
    static let bundle: UInt32 = 0x8
    static let object: UInt32 = 0x1

    static func version(_ major: UInt32, _ minor: UInt32, _ patch: UInt32 = 0) -> UInt32 {
        major << 16 | minor << 8 | patch
    }

    /// `LC_BUILD_VERSION` with no tools.
    static func buildVersion(platform: UInt32, minimumOS: UInt32, sdk: UInt32) -> Data {
        words([0x32, 24, platform, minimumOS, sdk, 0])
    }

    /// `LC_VERSION_MIN_IPHONEOS` by default.
    static func versionMin(_ command: UInt32 = 0x25, minimumOS: UInt32, sdk: UInt32) -> Data {
        words([command, 16, minimumOS, sdk])
    }

    /// `LC_ENCRYPTION_INFO_64`.
    static func encryption(cryptid: UInt32) -> Data {
        words([0x2C, 24, 0x4000, 0x1000, cryptid, 0])
    }

    /// `LC_UUID`, a command the walk passes over.
    static let uuid = words([0x1B, 24, 1, 2, 3, 4])

    static func thin(cpu: UInt32 = arm64, fileType: UInt32 = execute, commands: [Data]) -> Data {
        let body = commands.reduce(Data(), +)
        return Data([0xCF, 0xFA, 0xED, 0xFE])
            + words([cpu, 0, fileType, UInt32(commands.count), UInt32(body.count), 0, 0]) + body + Data(count: 64)
    }

    /// A universal binary, its slices at page offsets.
    static func fat(_ slices: [(cpu: UInt32, data: Data)], is64: Bool = false) -> Data {
        var header = Data(is64 ? [0xCA, 0xFE, 0xBA, 0xBF] : [0xCA, 0xFE, 0xBA, 0xBE]) + bigWords([UInt32(slices.count)])
        var body = Data()
        for slice in slices {
            let (offset, size) = (UInt32(0x1000 + body.count), UInt32(slice.data.count))
            header += bigWords([slice.cpu, 0]) + (is64 ? bigWords([0, offset, 0, size, 12, 0]) : bigWords([offset, size, 12]))
            body += slice.data + Data(count: (0x1000 - slice.data.count % 0x1000) % 0x1000)
        }
        return header + Data(count: 0x1000 - header.count) + body
    }

    /// An iOS program, as a Recipe's clang makes one.
    static func iOS(minimumOS: UInt32 = version(15, 0), sdk: UInt32 = version(18, 0), fileType: UInt32 = execute) -> Data {
        thin(fileType: fileType, commands: [uuid, buildVersion(platform: 2, minimumOS: minimumOS, sdk: sdk)])
    }

    static func words(_ values: [UInt32]) -> Data {
        values.reduce(into: Data()) { data, value in withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    }

    static func bigWords(_ values: [UInt32]) -> Data {
        values.reduce(into: Data()) { data, value in withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    }
}

/// A flat iPhone and iPad app made by hand: its executable, `Frameworks/Kit.framework` with a library inside it, a
/// loose dylib, a file that only looks like one, and what upstream may leave: a signature, `SC_Info` and a profile.
enum DeviceApp {
    static let decoyContents = "not really a library"

    static func make(
        in directory: URL, name: String = "Tiny", executable: Data = MachOBytes.iOS(), families: [Int]? = [1, 2]
    ) throws -> URL {
        let app = directory.appending(path: "\(name).app", directoryHint: .isDirectory)
        var plist = """
            <key>CFBundleIdentifier</key><string>com.upstream.\(name.lowercased())</string>
            <key>CFBundleExecutable</key><string>\(name)</string>
            <key>CFBundlePackageType</key><string>APPL</string>
            <key>MinimumOSVersion</key><string>15.0</string>
            """
        if let families {
            plist += "<key>UIDeviceFamily</key><array>\(families.map { "<integer>\($0)</integer>" }.joined())</array>"
        }
        try write(dictionary(plist), to: app.appending(path: "Info.plist"))
        try executable.write(to: app.appending(path: name))

        let framework = app.appending(path: "Frameworks/Kit.framework", directoryHint: .isDirectory)
        try write(
            dictionary("""
                <key>CFBundleIdentifier</key><string>com.upstream.kit</string>
                <key>CFBundleExecutable</key><string>Kit</string>
                <key>CFBundlePackageType</key><string>FMWK</string>
                """), to: framework.appending(path: "Info.plist"))
        try MachOBytes.iOS(fileType: MachOBytes.dylib).write(to: framework.appending(path: "Kit"))
        try MachOBytes.iOS(fileType: MachOBytes.dylib).write(to: framework.appending(path: "libinner.dylib"))
        try MachOBytes.iOS(fileType: MachOBytes.dylib).write(to: app.appending(path: "Frameworks/libloose.dylib"))
        try write(decoyContents, to: app.appending(path: "Frameworks/decoy.dylib"))

        try write("upstream", to: app.appending(path: "_CodeSignature/CodeResources"))
        try write("store", to: app.appending(path: "SC_Info/\(name).sinf"))
        try write("old profile", to: app.appending(path: "embedded.mobileprovision"))
        try write("resource", to: app.appending(path: "Base.lproj/Main.strings"))
        return app
    }

    static func dictionary(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>\(body)</dict></plist>
        """
    }
}

/// The Port's iOS version, as Frontport reads it.
func deviceVersion(strip: [String] = [], buildAssets: BuildAssetsSpec? = nil) -> IOSVersion {
    var mac = entry()
    mac.ios = IOSSpec(
        releases: .githubRelease(GitHubReleaseSource(repo: "tests/tiny", asset: "*.ipa")), buildAssets: buildAssets,
        strip: strip)
    return IOSVersion(mac)!
}

let testTeam = AppleTeamID("A1B2C3D4E5")!
let testCertificate = String(repeating: "AB", count: 20)

/// How the tests sign: a wildcard development Provisioning Profile written at `profile`, holding `contents`.
func deviceSigning(
    profile: URL, contents: String = "profile", certificate: String = testCertificate, team: AppleTeamID = testTeam,
    profileTeam: AppleTeamID? = nil, appID: String = "*", profileCertificates: [String]? = nil
) throws -> DeviceSigning {
    try write(contents, to: profile)
    let profileTeam = profileTeam ?? team
    return DeviceSigning(
        team: team, bundleId: PortID("tiny").deviceBundleID(team: team),
        certificate: SigningCertificate(
            sha1: certificate, name: "Apple Development: Tests", team: team, expires: .distantFuture),
        profile: ProvisioningProfile(
            uuid: UUID().uuidString, name: "iOS Team Provisioning Profile: \(appID)", team: profileTeam,
            applicationIdentifier: "\(profileTeam.rawValue).\(appID)", isDevelopment: true, devices: ["UDID"],
            certificates: profileCertificates ?? [certificate], created: .distantPast, expires: .distantFuture,
            file: profile))
}

/// Signs nothing, so the Device Packager's checks run without codesign or a keychain: records each item it was asked
/// to sign, and, as codesign would, rewrites a bundle's `_CodeSignature` in place.
final class RecordingDeviceSigner: DeviceSigner {
    struct Signed: Sendable {
        var item: URL
        var certificate: String
        var entitlements: [String: PortEntitlements.Value]?
    }

    let signed = Mutex<[Signed]>([])
    let verified = Mutex<[URL]>([])
    let failsVerifying: Bool

    init(failsVerifying: Bool = false) {
        self.failsVerifying = failsVerifying
    }

    func sign(_ item: URL, certificate: String, entitlements: [String: PortEntitlements.Value]?) async throws {
        signed.withLock { $0.append(Signed(item: item, certificate: certificate, entitlements: entitlements)) }
        if FileOperations.isDirectory(item) {
            try write("signed with \(certificate)", to: item.appending(path: "_CodeSignature/CodeResources"))
        }
    }

    func verify(_ app: URL, strictness: Strictness) async throws {
        verified.withLock { $0.append(app) }
        if failsVerifying { throw FrontportError.signingFailed("verify failed") }
    }

    /// What was signed, relative to `app`, in order: "" for the app itself.
    func items(in app: URL) -> [String] {
        let root = app.resolvingSymlinksInPath().path(percentEncoded: false)
        return signed.withLock { $0 }.map {
            String($0.item.resolvingSymlinksInPath().path(percentEncoded: false).dropFirst(root.count))
                .trimmingCharacters(in: ["/"])
        }
    }
}

func write(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

func read(_ url: URL) throws -> String {
    String(decoding: try Data(contentsOf: url), as: UTF8.self)
}

func plist(_ url: URL) throws -> [String: Any] {
    try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any] ?? [:]
}
