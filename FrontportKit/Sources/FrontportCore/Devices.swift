import Foundation

// What Frontport knows of Devices, Apple Teams and Provisioning Profiles (DESIGN › Devices, ADR 0016). FrontportDevices
// reads them; the Device pipeline and the App use them.

/// An iPhone or iPad paired with this Mac, as `devicectl` lists it, remembered in `Devices/<udid>/device.json` so its
/// Installations still show while it's away.
public struct Device: Codable, Hashable, Sendable, Identifiable {
    /// Its UDID.
    public var id: DeviceID
    /// The name the user gave it, such as "Test User’s iPhone".
    public var name: String
    /// Its marketing name, such as "iPhone 13".
    public var model: String
    /// The iOS version it ran when last read, such as "27.0.1".
    public var osVersion: String
    /// The `UIDeviceFamily` values its apps may have: 1 for iPhone, 2 for iPad.
    public var families: [Int]

    public init(id: DeviceID, name: String, model: String, osVersion: String, families: [Int]) {
        self.id = id
        self.name = name
        self.model = model
        self.osVersion = osVersion
        self.families = families
    }

    /// True for an iPad: its apps may be iPad apps.
    public var isPad: Bool { families.contains(2) }
}

/// A Device as of one reading: whether Frontport can reach it now, and what it said when it could. Never stored.
public struct DeviceReading: Hashable, Sendable {
    public enum Connection: String, Codable, Hashable, Sendable {
        /// Over USB.
        case wired
        /// Over Wi-Fi.
        case network
        /// Paired but not reachable now.
        case away
    }

    public var device: Device
    public var connection: Connection
    /// True when it's locked with a passcode, so a Port can't be launched on it. Nil when it wasn't read.
    public var isLocked: Bool?
    /// Whether Developer Mode is on, which installing on it needs. Nil when it wasn't read.
    public var developerMode: Bool?

    public init(device: Device, connection: Connection, isLocked: Bool? = nil, developerMode: Bool? = nil) {
        self.device = device
        self.connection = connection
        self.isLocked = isLocked
        self.developerMode = developerMode
    }

    public var isReachable: Bool { connection != .away }
}

/// Why a Device couldn't do what was asked: from `devicectl`'s error, or from its reading (`DeviceReadiness`).
public enum DeviceProblem: Hashable, Sendable {
    /// It isn't connected, or `devicectl` gave up waiting for it.
    case away
    /// It's locked with its passcode, so a Port can't be launched on it.
    case locked
    /// Developer Mode is off on it, which installing, Renewing and Seeding need.
    case developerModeOff
    /// The Port's app isn't installed on it.
    case notInstalled
    /// Anything else.
    case failed
}

/// A file or folder in a Port's container on a Device, as `devicectl device info files` lists it.
public struct DeviceFile: Hashable, Sendable {
    /// Relative to the container, such as "Documents/master.dat".
    public var path: String
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Date?
    /// A symbolic link, such as one the Port made in place of a file: never a folder, and never the ROM.
    public var isLink: Bool

    public init(path: String, isDirectory: Bool, size: Int64, modified: Date? = nil, isLink: Bool = false) {
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.isLink = isLink
    }
}

/// An Apple Development certificate whose key is in the keychain, which signs Ports for Devices.
public struct SigningCertificate: Codable, Hashable, Sendable {
    /// Its SHA-1 in uppercase hex, which `codesign --sign` takes and Provisioning Profiles list.
    public var sha1: String
    /// Its common name, such as "Apple Development: Test User (AB12CD34EF)".
    public var name: String
    /// Its organizational unit.
    public var team: AppleTeamID
    public var expires: Date

    public init(sha1: String, name: String, team: AppleTeamID, expires: Date) {
        self.sha1 = sha1
        self.name = name
        self.team = team
        self.expires = expires
    }
}

/// The user's Apple Team, as its Apple Development certificates in the keychain show it.
public struct AppleTeam: Codable, Hashable, Sendable, Identifiable {
    public var id: AppleTeamID
    /// Its name, the certificates' organization, such as "Test User".
    public var name: String
    /// Its certificates that haven't expired, the one expiring last first.
    public var certificates: [SigningCertificate]

    public init(id: AppleTeamID, name: String, certificates: [SigningCertificate]) {
        self.id = id
        self.name = name
        self.certificates = certificates
    }
}

/// A development provisioning profile, a `.mobileprovision` file, as far as choosing one goes.
public struct ProvisioningProfile: Codable, Hashable, Sendable {
    public var uuid: String
    public var name: String
    /// Its `TeamIdentifier`.
    public var team: AppleTeamID
    /// The `application-identifier` it grants: `<team>.<bundle ID>`, or a wildcard such as `<team>.*`.
    public var applicationIdentifier: String
    /// True when it grants `get-task-allow`, as only a development one does.
    public var isDevelopment: Bool
    /// Its `ProvisionedDevices`.
    public var devices: [DeviceID]
    /// True for an enterprise one, which lists no Devices.
    public var provisionsAllDevices: Bool
    /// SHA-1s of its `DeveloperCertificates`, in uppercase hex.
    public var certificates: [String]
    public var created: Date
    public var expires: Date
    /// Where it is, to copy it into the app as `embedded.mobileprovision`.
    public var file: URL

    public init(
        uuid: String, name: String, team: AppleTeamID, applicationIdentifier: String, isDevelopment: Bool,
        devices: [DeviceID], provisionsAllDevices: Bool = false, certificates: [String], created: Date, expires: Date,
        file: URL
    ) {
        self.uuid = uuid
        self.name = name
        self.team = team
        self.applicationIdentifier = applicationIdentifier
        self.isDevelopment = isDevelopment
        self.devices = devices
        self.provisionsAllDevices = provisionsAllDevices
        self.certificates = certificates
        self.created = created
        self.expires = expires
        self.file = file
    }

    /// The App ID it's for, without the team: a bundle ID, or a wildcard ending in `*`.
    public var appID: String? {
        let prefix = "\(team.rawValue)."
        return applicationIdentifier.hasPrefix(prefix) ? String(applicationIdentifier.dropFirst(prefix.count)) : nil
    }

    public var isWildcard: Bool { appID?.hasSuffix("*") == true }

    /// True when its App ID is `bundleId`, or a wildcard whose stem `bundleId` extends (`*` covers every bundle ID).
    public func covers(_ bundleId: String) -> Bool {
        guard let appID, !bundleId.isEmpty else { return false }
        guard appID.hasSuffix("*") else { return appID == bundleId }
        let stem = appID.dropLast()
        return bundleId.count > stem.count && bundleId.hasPrefix(stem)
    }
}

/// How the Packager signs a Port's app for a Device.
public struct DeviceSigning: Hashable, Sendable {
    public var team: AppleTeamID
    /// The bundle ID the app gets, `PortID.deviceBundleID(team:)`.
    public var bundleId: String
    public var certificate: SigningCertificate
    /// Copied into the app as `embedded.mobileprovision`.
    public var profile: ProvisioningProfile

    public init(team: AppleTeamID, bundleId: String, certificate: SigningCertificate, profile: ProvisioningProfile) {
        self.team = team
        self.bundleId = bundleId
        self.certificate = certificate
        self.profile = profile
    }
}

/// What the Packager read from an app it signed for a Device, to check it against a Device before installing.
public struct DeviceAppInfo: Codable, Hashable, Sendable {
    public var bundleId: String
    /// `CFBundleExecutable`.
    public var executable: String
    /// The oldest iOS it runs on, from its main executable, such as "11.0".
    public var minimumOS: String
    /// The iOS SDK its main executable was built with, such as "16.2". Nil when it doesn't say. An app built with the
    /// iOS 27 SDK or later that has no scene delegate exits at once.
    public var sdk: String?
    /// Its `UIDeviceFamily`: 1 for iPhone, 2 for iPad. iOS takes a missing one as iPhone only.
    public var families: [Int]

    public init(bundleId: String, executable: String, minimumOS: String, sdk: String?, families: [Int]) {
        self.bundleId = bundleId
        self.executable = executable
        self.minimumOS = minimumOS
        self.sdk = sdk
        self.families = families
    }
}

/// A Port's iOS version as fetched on this Mac, unpacked and not yet signed for any Device: `prepared.json` beside the
/// app in `Builds/<port>.ios/prepared/`. Each Device it's installed on gets a signed clone of it, so it's fetched once
/// for them all; it stays for the next Device while one has the Port, until a newer Release is prepared.
public struct PreparedDeviceApp: Codable, Hashable, Sendable {
    public var port: PortID
    /// The iOS Release, its asset's digest included.
    public var release: Release
    public var channel: Channel
    /// File name of the app in `prepared/`, such as "Ghostship.app".
    public var appName: String
    /// The oldest iOS it runs on, from its main executable, such as "15.0".
    public var minimumOS: String
    /// Its `UIDeviceFamily`: 1 for iPhone, 2 for iPad.
    public var families: [Int]
    /// The SHA-256 of the iOS Recipe a source-built one was built by (`ReleaseSource.recipeSHA256`); nil for one
    /// downloaded, and in a record from before Frontport kept it.
    public var recipeSHA256: String?

    public init(
        port: PortID, release: Release, channel: Channel, appName: String, minimumOS: String, families: [Int],
        recipeSHA256: String? = nil
    ) {
        self.port = port
        self.release = release
        self.channel = channel
        self.appName = appName
        self.minimumOS = minimumOS
        self.families = families
        self.recipeSHA256 = recipeSHA256
    }

    /// True when it was prepared from `release` for `channel` by the Recipe with `recipeSHA256`, the iOS version's now
    /// (nil for a prebuilt one): the same tag, the same asset by its digest, and the same Recipe, so a Recipe the Catalog
    /// changed at the same ref makes it stale.
    public func isFor(_ release: Release, on channel: Channel, recipeSHA256: String?) -> Bool {
        self.channel == channel && self.release.tag == release.tag && self.release.asset?.sha256 == release.asset?.sha256
            && self.release.asset?.name == release.asset?.name && self.recipeSHA256 == recipeSHA256
    }

    /// True when it can be offered as it is, without preparing again: prepared from `latest`, the newest iOS Release
    /// known, on the iOS version's default Channel, and still offered by it (`IOSVersion.offers`). A Block that came
    /// with a Catalog refresh counts, though the newest Release couldn't be looked up again since.
    public func isCurrent(for version: IOSVersion, latest: Release?) -> Bool {
        guard let latest else { return false }
        return isFor(latest, on: version.defaultChannel, recipeSHA256: version.recipeSHA256)
            && version.offers(release, on: channel)
    }
}
