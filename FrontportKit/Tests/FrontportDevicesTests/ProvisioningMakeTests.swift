import Foundation
import FrontportCore
import Testing
@testable import FrontportDevices

/// Taking a Provisioning Profile Xcode has, else having Xcode make one and taking that.
@Suite struct ProvisioningMakeTests {
    static let bundleId = "dev.frontport.port.x.abcde12345"
    static let team = AppleTeam(id: Profiles.team, name: "Test User", certificates: [Profiles.certificate])
    static let made = Profiles.profile("iOS Team Provisioning Profile: \(bundleId)", appID: bundleId, expires: "2027-04-01T00:00:00Z")

    /// Xcode's folder, which the stand-in for Xcode adds to.
    final class Folder: @unchecked Sendable {
        private let lock = NSLock()
        private var profiles: [ProvisioningProfile]
        private(set) var makes: [(bundleId: String, team: AppleTeamID, device: DeviceID)] = []

        init(_ profiles: [ProvisioningProfile]) { self.profiles = profiles }

        var all: [ProvisioningProfile] { lock.withLock { profiles } }
        var made: Int { lock.withLock { makes.count } }

        /// Xcode making `profile`, or nothing, as when it signs with one there that doesn't last long enough.
        func make(_ profile: ProvisioningProfile?) -> DeviceProvisioning.Make {
            { bundleId, team, device in
                self.lock.withLock {
                    self.makes.append((bundleId, team, device))
                    if let profile { self.profiles.append(profile) }
                }
            }
        }
    }

    static func provisioning(_ folder: Folder, make: DeviceProvisioning.Make?) -> DeviceProvisioning {
        DeviceProvisioning(teams: { [team] }, profiles: { folder.all }, make: make, now: { Profiles.now })
    }

    /// One Xcode has is taken, and Xcode isn't asked.
    @Test func takesOneXcodeHasWithoutMakingOne() async throws {
        let folder = Folder([Profiles.wildcard])
        let signing = try await Self.provisioning(folder, make: folder.make(Self.made))
            .signing(for: Self.bundleId, team: Profiles.team, device: Profiles.device, outlasting: nil)
        #expect(signing.profile == Profiles.wildcard)
        #expect(folder.made == 0)
    }

    /// Without one, Xcode makes one for the bundle ID, Apple Team and Device, and that's taken.
    @Test func makesOneThenTakesIt() async throws {
        let folder = Folder([Profiles.store, Profiles.expired])
        let signing = try await Self.provisioning(folder, make: folder.make(Self.made))
            .signing(for: Self.bundleId, team: Profiles.team, device: Profiles.device, outlasting: nil)
        #expect(signing.profile == Self.made && signing.certificate == Profiles.certificate)
        #expect(folder.makes.map(\.bundleId) == [Self.bundleId])
        #expect(folder.makes.map(\.team) == [Profiles.team] && folder.makes.map(\.device) == [Profiles.device])
    }

    /// For Renew: one that doesn't outlast the signature the app has is made again, and when Xcode makes none that
    /// does, that's a `provisioningFailed`.
    @Test func whatXcodeMakesMustLastLongEnoughToo() async throws {
        let folder = Folder([Profiles.wildcard])
        let outlasting = Profiles.date("2027-05-06T00:00:00Z")
        await #expect {
            try await Self.provisioning(folder, make: folder.make(nil))
                .signing(for: Self.bundleId, team: Profiles.team, device: Profiles.device, outlasting: outlasting)
        } throws: { error in
            guard case FrontportError.provisioningFailed(let detail) = error else { return false }
            return detail.contains("Xcode made none") && detail.contains(Self.bundleId)
        }
        #expect(folder.made == 1)
    }

    /// For Renew: when the certificate is what doesn't outlast the signature the app has, though the Provisioning
    /// Profile does, Xcode is asked too, and the one it makes with a newer certificate is taken.
    @Test func aCertificateThatDoesntLastLongEnoughHasXcodeMakeOne() async throws {
        let longer = Profiles.profile("Longer", appID: "*", expires: "2027-08-01T00:00:00Z")
        var newer = Profiles.certificate
        newer.sha1 = String(repeating: "C8", count: 20)
        newer.expires = Profiles.date("2027-10-01T00:00:00Z")
        let remade = Profiles.profile(
            "iOS Team Provisioning Profile: *", appID: "*", certificates: [Profiles.certificate.sha1, newer.sha1],
            expires: "2027-10-01T00:00:00Z")
        let folder = Folder([longer])
        let certificates = Certificates([Profiles.certificate])
        let (make, added) = (folder.make(remade), newer)
        let provisioning = DeviceProvisioning(
            teams: { [AppleTeam(id: Profiles.team, name: "Test User", certificates: certificates.all)] },
            profiles: { folder.all },
            make: { bundleId, team, device in
                certificates.add(added)
                try await make(bundleId, team, device)
            },
            now: { Profiles.now })

        let signing = try await provisioning.signing(
            for: Self.bundleId, team: Profiles.team, device: Profiles.device, outlasting: Profiles.certificate.expires)
        #expect(folder.made == 1)
        #expect(signing.certificate == newer && signing.profile == remade)
    }

    /// The keychain's certificates, which the stand-in for Xcode adds to.
    final class Certificates: @unchecked Sendable {
        private let lock = NSLock()
        private var certificates: [SigningCertificate]

        init(_ certificates: [SigningCertificate]) { self.certificates = certificates }

        var all: [SigningCertificate] { lock.withLock { certificates } }
        func add(_ certificate: SigningCertificate) { lock.withLock { certificates.append(certificate) } }
    }

    /// What went wrong making one says more than finding none, so it's thrown as it is.
    @Test func anErrorMakingOneIsThrownAsItIs() async {
        let failure = FrontportError.provisioningFailed("Xcode isn’t signed in to Apple Team ABCDE12345.")
        let provisioning = DeviceProvisioning(
            teams: { [Self.team] }, profiles: { [] }, make: { _, _, _ in throw failure }, now: { Profiles.now })
        await #expect(throws: failure) {
            try await provisioning.signing(for: Self.bundleId, team: Profiles.team, device: Profiles.device, outlasting: nil)
        }
    }

    /// Without the Apple Team's certificate nothing is made: Xcode would sign with nothing Frontport can use.
    @Test func noCertificateNoMaking() async {
        let folder = Folder([])
        let provisioning = DeviceProvisioning(
            teams: { [] }, profiles: { folder.all }, make: folder.make(Self.made), now: { Profiles.now })
        await #expect(throws: FrontportError.noAppleTeam) {
            try await provisioning.signing(for: Self.bundleId, team: Profiles.team, device: Profiles.device, outlasting: nil)
        }
        #expect(folder.made == 0)
    }
}
