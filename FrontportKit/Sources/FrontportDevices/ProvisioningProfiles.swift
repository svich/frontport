import Foundation
import FrontportCore
import Security

/// The Provisioning Profiles in Xcode's folder, where Xcode keeps the ones it makes and downloads. Frontport only reads
/// them, and chooses one per DESIGN › Provisioning Profiles.
public struct ProvisioningProfiles: Sendable {
    public let folder: URL

    public init(folder: URL = ProvisioningProfiles.xcodeFolder) {
        self.folder = folder
    }

    /// `~/Library/Developer/Xcode/UserData/Provisioning Profiles`.
    public static var xcodeFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Developer/Xcode/UserData/Provisioning Profiles", directoryHint: .isDirectory)
    }

    /// Every `.mobileprovision` in the folder that could be read, the unreadable ones left out.
    public func all() async -> [ProvisioningProfile] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var profiles: [ProvisioningProfile] = []
        for file in files where file.pathExtension == "mobileprovision" {
            if let profile = try? await Self.read(file) { profiles.append(profile) }
        }
        return profiles
    }

    /// Reads a `.mobileprovision`: a signed CMS message whose content is a property list. Decoded with CMSDecoder, or
    /// with `security cms -D` should that fail.
    public static func read(_ file: URL) async throws -> ProvisioningProfile {
        let data = try FileOperations.readRegularFile(file)
        let plist: Data
        if let content = content(ofCMS: data) {
            plist = content
        } else {
            let result = try await ProcessRunner().run(
                URL(filePath: "/usr/bin/security"), arguments: ["cms", "-D", "-i", file.path(percentEncoded: false)])
            plist = try result.check("security cms").stdout
        }
        return try profile(fromPlist: plist, file: file)
    }

    /// The content of a CMS message, or nil when it isn't one.
    static func content(ofCMS data: Data) -> Data? {
        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder else { return nil }
        let updated = data.withUnsafeBytes { bytes in
            CMSDecoderUpdateMessage(decoder, bytes.baseAddress!, bytes.count)
        }
        guard updated == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess else { return nil }
        var content: CFData?
        guard CMSDecoderCopyContent(decoder, &content) == errSecSuccess, let content else { return nil }
        return content as Data
    }

    /// A Provisioning Profile from its property list.
    static func profile(fromPlist data: Data, file: URL) throws -> ProvisioningProfile {
        func malformed(_ detail: String) -> FrontportError {
            .provisioningFailed("\(file.lastPathComponent) can’t be read: \(detail).")
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw malformed("it isn’t a property list")
        }
        let entitlements = plist["Entitlements"] as? [String: Any] ?? [:]
        guard let uuid = plist["UUID"] as? String else { throw malformed("it has no UUID") }
        guard let team = (plist["TeamIdentifier"] as? [String])?.first.flatMap({ AppleTeamID(rawValue: $0) }) else {
            throw malformed("it names no Apple Team")
        }
        guard let applicationIdentifier = entitlements["application-identifier"] as? String else {
            throw malformed("it grants no application identifier")
        }
        guard let created = plist["CreationDate"] as? Date, let expires = plist["ExpirationDate"] as? Date else {
            throw malformed("it has no dates")
        }
        return ProvisioningProfile(
            uuid: uuid, name: plist["Name"] as? String ?? uuid, team: team, applicationIdentifier: applicationIdentifier,
            isDevelopment: entitlements["get-task-allow"] as? Bool ?? false,
            devices: (plist["ProvisionedDevices"] as? [String] ?? []).map { DeviceID(rawValue: $0) },
            provisionsAllDevices: plist["ProvisionsAllDevices"] as? Bool ?? false,
            certificates: (plist["DeveloperCertificates"] as? [Data] ?? []).map(KeychainAppleTeams.sha1),
            created: created, expires: expires, file: file)
    }

    /// How long a Provisioning Profile must still last to be taken.
    public static let margin: TimeInterval = 24 * 60 * 60

    /// The Provisioning Profile to sign `bundleId` for `device` with, and the certificate to sign with: a development one
    /// of `team` whose App ID is `bundleId` or a wildcard covering it, that lists `device` and names a certificate of
    /// `certificates`, both lasting past a day from `now` and past `outlasting`, since a signature lasts only as long as
    /// the sooner of them. An explicit App ID wins over a wildcard, then the one expiring last. Nil when there's none,
    /// so Xcode is asked to make one.
    public static func choose(
        _ profiles: [ProvisioningProfile], bundleId: String, team: AppleTeamID, device: DeviceID,
        certificates: [SigningCertificate], now: Date, outlasting: Date? = nil
    ) -> DeviceSigning? {
        let deadline = max(now.addingTimeInterval(margin), outlasting ?? .distantPast)
        let usable = certificates.filter { $0.team == team && $0.expires > deadline }
        let candidates = profiles.compactMap { profile -> (ProvisioningProfile, SigningCertificate)? in
            guard profile.team == team, profile.isDevelopment, !profile.provisionsAllDevices, profile.expires > deadline,
                profile.covers(bundleId), profile.devices.contains(device)
            else { return nil }
            let named = usable.filter { profile.certificates.contains($0.sha1.uppercased()) }
            guard let certificate = named.max(by: { $0.expires < $1.expires }) else { return nil }
            return (profile, certificate)
        }
        let best = candidates.max { a, b in
            (a.0.isWildcard ? 0 : 1, a.0.expires, a.0.created, a.0.uuid) < (b.0.isWildcard ? 0 : 1, b.0.expires, b.0.created, b.0.uuid)
        }
        return best.map { DeviceSigning(team: team, bundleId: bundleId, certificate: $0.1, profile: $0.0) }
    }
}
