import CryptoKit
import Foundation
import FrontportCore
import Security

/// The user's Apple Teams, read from the Apple Development certificates whose keys are in the keychain: Xcode puts
/// one there for each Apple Team of the Apple account added in its Settings › Accounts. Reads only certificates, never
/// a key, so the keychain doesn't prompt.
public struct KeychainAppleTeams: Sendable {
    public init() {}

    /// Every Apple Team with a certificate that hasn't expired, by name.
    public func teams(now: Date = .now) -> [AppleTeam] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassIdentity, kSecMatchLimit: kSecMatchLimitAll, kSecReturnRef: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let identities = result as? [SecIdentity]
        else { return [] }
        let certificates = identities.compactMap { identity -> SecCertificate? in
            var certificate: SecCertificate?
            return SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess ? certificate : nil
        }
        return Self.teams(certificates.compactMap(Self.read), now: now)
    }

    /// A certificate of an Apple Team as the keychain holds it, with the Apple Team's name.
    struct Read: Hashable {
        var certificate: SigningCertificate
        var organization: String
    }

    /// The Apple Teams the certificates show, by name: those that haven't expired, grouped by organizational unit, the
    /// one expiring last first, the Apple Team named as that one names it.
    static func teams(_ certificates: [Read], now: Date) -> [AppleTeam] {
        let valid = certificates.filter { $0.certificate.expires > now }
        return Dictionary(grouping: valid, by: \.certificate.team).map { team, reads in
            let sorted = reads.sorted { ($0.certificate.expires, $0.certificate.sha1) > ($1.certificate.expires, $1.certificate.sha1) }
            // The same certificate can be in more than one keychain.
            var seen = Set<String>()
            let certificates = sorted.map(\.certificate).filter { seen.insert($0.sha1).inserted }
            return AppleTeam(id: team, name: sorted[0].organization, certificates: certificates)
        }
        .sorted { a, b in
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
        }
    }

    /// An Apple Development certificate's details, or nil for any other certificate.
    static func read(_ certificate: SecCertificate) -> Read? {
        var commonName: CFString?
        guard SecCertificateCopyCommonName(certificate, &commonName) == errSecSuccess,
            let name = commonName as String?, name.hasPrefix("Apple Development:"),
            let expires = SecCertificateCopyNotValidAfterDate(certificate) as Date?
        else { return nil }
        let subject = subjectFields(of: certificate)
        guard let unit = subject["2.5.4.11"], let team = AppleTeamID(unit) else { return nil }
        let der = SecCertificateCopyData(certificate) as Data
        return Read(
            certificate: SigningCertificate(sha1: sha1(der), name: name, team: team, expires: expires),
            organization: subject["2.5.4.10"] ?? unit)
    }

    /// A DER certificate's SHA-1 in uppercase hex, as `codesign` and Provisioning Profiles name it.
    static func sha1(_ der: Data) -> String {
        Insecure.SHA1.hash(data: der).map { String(format: "%02X", $0) }.joined()
    }

    /// The subject's string fields by OID, such as "2.5.4.11" for the organizational unit.
    private static func subjectFields(of certificate: SecCertificate) -> [String: String] {
        let keys = [kSecOIDX509V1SubjectName] as CFArray
        guard let values = SecCertificateCopyValues(certificate, keys, nil) as? [CFString: Any],
            let subject = values[kSecOIDX509V1SubjectName] as? [CFString: Any],
            let fields = subject[kSecPropertyKeyValue] as? [[CFString: Any]]
        else { return [:] }
        var result: [String: String] = [:]
        for field in fields {
            guard let label = field[kSecPropertyKeyLabel] as? String, let value = field[kSecPropertyKeyValue] as? String,
                result[label] == nil
            else { continue }
            result[label] = value
        }
        return result
    }
}
