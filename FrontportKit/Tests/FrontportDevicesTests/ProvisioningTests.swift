import Foundation
import FrontportCore
import Testing
@testable import FrontportDevices

/// Sanitized stand-ins for the Provisioning Profiles a Mac with a paid Apple Team has: Xcode's wildcard one, explicit
/// ones Xcode made, App Store ones and expired ones from years ago.
enum Profiles {
    static let team = AppleTeamID("ABCDE12345")!
    static let other = AppleTeamID("ZZZZZ99999")!
    static let device: DeviceID = "00008110-000000000000001E"
    static let now = date("2026-10-31T12:00:00Z")

    static let certificate = SigningCertificate(
        sha1: String(repeating: "A6", count: 20), name: "Apple Development: Test User (QWERTY1234)", team: team,
        expires: date("2027-05-06T00:00:00Z"))

    static func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    static func profile(
        _ name: String, appID: String, team: AppleTeamID = team, development: Bool = true, devices: [DeviceID] = [device],
        allDevices: Bool = false, certificates: [String] = [certificate.sha1], created: String = "2026-05-06T00:00:00Z",
        expires: String
    ) -> ProvisioningProfile {
        ProvisioningProfile(
            uuid: UUID().uuidString, name: name, team: team, applicationIdentifier: "\(team).\(appID)",
            isDevelopment: development, devices: devices, provisionsAllDevices: allDevices, certificates: certificates,
            created: date(created), expires: date(expires), file: URL(filePath: "/tmp/\(name).mobileprovision"))
    }

    static let wildcard = profile("iOS Team Provisioning Profile: *", appID: "*", expires: "2027-05-06T00:00:00Z")
    static let explicit = profile(
        "iOS Team Provisioning Profile: com.example.game", appID: "com.example.game", expires: "2027-03-01T00:00:00Z")
    static let store = profile(
        "iOS Team Store Provisioning Profile: com.example.game", appID: "com.example.game", development: false, devices: [],
        expires: "2027-09-01T00:00:00Z")
    static let expired = profile(
        "Old Wildcard", appID: "com.example.old.*", created: "2018-10-01T00:00:00Z", expires: "2019-10-01T00:00:00Z")

    static let mac = [wildcard, explicit, store, expired]

    static func choose(
        _ profiles: [ProvisioningProfile], _ bundleId: String, certificates: [SigningCertificate] = [certificate],
        device: DeviceID = device, outlasting: Date? = nil, now: Date = now
    ) -> ProvisioningProfile? {
        ProvisioningProfiles.choose(
            profiles, bundleId: bundleId, team: team, device: device, certificates: certificates, now: now,
            outlasting: outlasting)?.profile
    }
}

@Suite struct ChooseTests {
    @Test func theWildcardForAPort() {
        let signing = ProvisioningProfiles.choose(
            Profiles.mac, bundleId: "dev.frontport.port.fallout-ce.abcde12345", team: Profiles.team, device: Profiles.device,
            certificates: [Profiles.certificate], now: Profiles.now)
        #expect(signing == DeviceSigning(
            team: Profiles.team, bundleId: "dev.frontport.port.fallout-ce.abcde12345", certificate: Profiles.certificate,
            profile: Profiles.wildcard))
    }

    @Test func explicitBeatsAWildcardThatLastsLonger() {
        #expect(Profiles.choose(Profiles.mac, "com.example.game") == Profiles.explicit)
    }

    @Test func thenTheOneExpiringLast() {
        let later = Profiles.profile("Later", appID: "*", expires: "2027-08-01T00:00:00Z")
        #expect(Profiles.choose(Profiles.mac + [later], "dev.frontport.port.x.abcde12345") == later)
        let laterExplicit = Profiles.profile("Later explicit", appID: "com.example.game", expires: "2027-04-01T00:00:00Z")
        #expect(Profiles.choose(Profiles.mac + [laterExplicit], "com.example.game") == laterExplicit)
    }

    @Test func storeAndExpiredOnesAreSkipped() {
        #expect(Profiles.choose([Profiles.store, Profiles.expired], "com.example.game") == nil)
        #expect(Profiles.choose([Profiles.store, Profiles.expired], "com.example.old.app") == nil)
        #expect(Profiles.choose(Profiles.mac, "com.example.old.app") == Profiles.wildcard)
    }

    @Test func notExpiringWithinADayNorBeforeWhatItReplaces() {
        let soon = Profiles.profile("Soon", appID: "*", expires: "2026-11-01T06:00:00Z")
        #expect(Profiles.choose([soon], "a.b") == nil)
        let week = Profiles.profile("Week", appID: "*", expires: "2026-11-07T00:00:00Z")
        #expect(Profiles.choose([week], "a.b") == week)
        #expect(Profiles.choose([week], "a.b", outlasting: Profiles.date("2026-11-07T00:00:00Z")) == nil)
        #expect(Profiles.choose([week, Profiles.wildcard], "a.b", outlasting: Profiles.date("2026-11-07T00:00:00Z")) == Profiles.wildcard)
    }

    @Test func itMustListTheDevice() {
        #expect(Profiles.choose(Profiles.mac, "a.b", device: "00008110-0000000000000002") == nil)
        let enterprise = Profiles.profile("All", appID: "*", devices: [], allDevices: true, expires: "2027-05-06T00:00:00Z")
        #expect(Profiles.choose([enterprise], "a.b") == nil)
    }

    @Test func itsCertificateMustBeInTheKeychainAndValid() {
        #expect(Profiles.choose(Profiles.mac, "a.b", certificates: []) == nil)
        var expired = Profiles.certificate
        expired.expires = Profiles.date("2026-10-01T00:00:00Z")
        #expect(Profiles.choose(Profiles.mac, "a.b", certificates: [expired]) == nil)
        var another = Profiles.certificate
        another.sha1 = String(repeating: "B7", count: 20)
        #expect(Profiles.choose(Profiles.mac, "a.b", certificates: [another]) == nil)
        var otherTeam = Profiles.certificate
        otherTeam.team = Profiles.other
        #expect(Profiles.choose(Profiles.mac, "a.b", certificates: [otherTeam]) == nil)
    }

    /// The certificate must last as long as the Provisioning Profile must, since the signature lasts only as long as
    /// the sooner of the two: past a day, and past what it replaces.
    @Test func itsCertificateMustLastAsLongToo() {
        let longer = Profiles.profile("Longer", appID: "*", expires: "2027-08-01T00:00:00Z")
        #expect(Profiles.choose([longer], "a.b", outlasting: Profiles.date("2027-05-05T00:00:00Z")) == longer)
        #expect(Profiles.choose([longer], "a.b", outlasting: Profiles.certificate.expires) == nil)
        var soon = Profiles.certificate
        soon.expires = Profiles.date("2026-11-01T06:00:00Z")
        #expect(Profiles.choose([longer], "a.b", certificates: [soon]) == nil)
    }

    @Test func theCertificateExpiringLastOfThoseItNames() throws {
        var older = Profiles.certificate
        older.sha1 = String(repeating: "C8", count: 20)
        older.expires = Profiles.date("2027-01-01T00:00:00Z")
        let both = Profiles.profile("Both", appID: "*", certificates: [older.sha1, Profiles.certificate.sha1], expires: "2027-05-06T00:00:00Z")
        let signing = try #require(ProvisioningProfiles.choose(
            [both], bundleId: "a.b", team: Profiles.team, device: Profiles.device, certificates: [older, Profiles.certificate],
            now: Profiles.now))
        #expect(signing.certificate == Profiles.certificate)
    }

    @Test func onlyTheApplesTeamsOwn() {
        let theirs = Profiles.profile("Theirs", appID: "*", team: Profiles.other, expires: "2027-05-06T00:00:00Z")
        #expect(Profiles.choose([theirs], "a.b") == nil)
    }
}

@Suite struct ProvisioningProfileFileTests {
    static func plist(certificate: Data) -> [String: Any] {
        [
            "UUID": "11111111-2222-3333-4444-555555555555",
            "Name": "iOS Team Provisioning Profile: *",
            "TeamIdentifier": ["ABCDE12345"],
            "ApplicationIdentifierPrefix": ["ABCDE12345"],
            "Entitlements": [
                "application-identifier": "ABCDE12345.*", "get-task-allow": true,
                "com.apple.developer.team-identifier": "ABCDE12345",
            ],
            "ProvisionedDevices": ["00008110-000000000000001E"],
            "DeveloperCertificates": [certificate],
            "CreationDate": Profiles.date("2026-05-06T00:00:00Z"),
            "ExpirationDate": Profiles.date("2027-05-06T00:00:00Z"),
        ]
    }

    @Test func readsAPropertyList() throws {
        let certificate = Data("not really DER".utf8)
        let data = try PropertyListSerialization.data(fromPropertyList: Self.plist(certificate: certificate), format: .xml, options: 0)
        let profile = try ProvisioningProfiles.profile(fromPlist: data, file: URL(filePath: "/tmp/x.mobileprovision"))
        #expect(profile.uuid == "11111111-2222-3333-4444-555555555555")
        #expect(profile.team == Profiles.team)
        #expect(profile.applicationIdentifier == "ABCDE12345.*")
        #expect(profile.isWildcard)
        #expect(profile.isDevelopment)
        #expect(profile.devices == [Profiles.device])
        #expect(!profile.provisionsAllDevices)
        #expect(profile.certificates == [KeychainAppleTeams.sha1(certificate)])
        #expect(profile.expires == Profiles.date("2027-05-06T00:00:00Z"))
    }

    @Test func aStoreOneIsntForDevelopment() throws {
        var plist = Self.plist(certificate: Data())
        plist["Entitlements"] = ["application-identifier": "ABCDE12345.com.example.game", "get-task-allow": false]
        plist["ProvisionedDevices"] = nil
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let profile = try ProvisioningProfiles.profile(fromPlist: data, file: URL(filePath: "/tmp/x.mobileprovision"))
        #expect(!profile.isDevelopment)
        #expect(profile.devices.isEmpty)
        #expect(!profile.isWildcard)
    }

    @Test func refusesWhatIsntOne() {
        #expect(throws: FrontportError.self) {
            try ProvisioningProfiles.profile(fromPlist: Data("nope".utf8), file: URL(filePath: "/tmp/x.mobileprovision"))
        }
        var plist = Self.plist(certificate: Data())
        plist["TeamIdentifier"] = ["not a team"]
        #expect(throws: FrontportError.self) {
            try ProvisioningProfiles.profile(
                fromPlist: try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
                file: URL(filePath: "/tmp/x.mobileprovision"))
        }
    }

    /// A CMS SignedData message with `content` and no signers, the way a `.mobileprovision` file holds its property
    /// list, signed.
    static func cms(_ content: Data) -> Data {
        func der(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] {
            var size = body.count
            var length: [UInt8] = []
            while size > 0 {
                length.insert(UInt8(size & 0xFF), at: 0)
                size >>= 8
            }
            return [tag] + (body.count < 0x80 ? [UInt8(body.count)] : [0x80 | UInt8(length.count)] + length) + body
        }
        let signedData: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02]
        let data: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01]
        let encapsulated = der(0x30, data + der(0xA0, der(0x04, Array(content))))
        let body = der(0x30, der(0x02, [1]) + der(0x31, []) + encapsulated + der(0x31, []))
        return Data(der(0x30, signedData + der(0xA0, body)))
    }

    @Test func readsTheFolder() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "frontport-profiles-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let plist = try PropertyListSerialization.data(fromPropertyList: Self.plist(certificate: Data("c".utf8)), format: .xml, options: 0)
        try Self.cms(plist).write(to: folder.appending(path: "a.mobileprovision"))
        try Data("garbage".utf8).write(to: folder.appending(path: "b.mobileprovision"))
        try plist.write(to: folder.appending(path: "c.plist"))

        let profiles = await ProvisioningProfiles(folder: folder).all()
        #expect(profiles.map(\.uuid) == ["11111111-2222-3333-4444-555555555555"])
        #expect(profiles.first?.file.lastPathComponent == "a.mobileprovision")
    }
}

@Suite struct AppleTeamTests {
    static func read(_ sha1: String, team: AppleTeamID, organization: String, expires: String) -> KeychainAppleTeams.Read {
        KeychainAppleTeams.Read(
            certificate: SigningCertificate(
                sha1: sha1, name: "Apple Development: Test User (QWERTY1234)", team: team, expires: Profiles.date(expires)),
            organization: organization)
    }

    @Test func groupedByOrganizationalUnitExpiredOnesDropped() {
        let reads = [
            Self.read("01", team: Profiles.team, organization: "Test User (old name)", expires: "2027-01-01T00:00:00Z"),
            Self.read("02", team: Profiles.team, organization: "Test User", expires: "2027-05-06T00:00:00Z"),
            Self.read("03", team: Profiles.team, organization: "Test User", expires: "2025-05-06T00:00:00Z"),
            Self.read("02", team: Profiles.team, organization: "Test User", expires: "2027-05-06T00:00:00Z"),
            Self.read("04", team: Profiles.other, organization: "Another Team", expires: "2027-02-01T00:00:00Z"),
            Self.read("05", team: AppleTeamID("EXPIRED123")!, organization: "Gone", expires: "2019-02-01T00:00:00Z"),
        ]
        let teams = KeychainAppleTeams.teams(reads, now: Profiles.now)
        #expect(teams.map(\.id) == [Profiles.other, Profiles.team])
        #expect(teams.map(\.name) == ["Another Team", "Test User"])
        #expect(teams.last?.certificates.map(\.sha1) == ["02", "01"])
    }

    @Test func sha1InUppercaseHex() {
        #expect(KeychainAppleTeams.sha1(Data("abc".utf8)) == "A9993E364706816ABA3E25717850C26C9CD0D89D")
    }
}

@Suite struct DeviceProvisioningTests {
    static func provisioning(teams: [AppleTeam], profiles: [ProvisioningProfile] = Profiles.mac) -> DeviceProvisioning {
        DeviceProvisioning(teams: { teams }, profiles: { profiles }, now: { Profiles.now })
    }

    static let team = AppleTeam(id: Profiles.team, name: "Test User", certificates: [Profiles.certificate])

    @Test func takesAProfile() async throws {
        let signing = try await Self.provisioning(teams: [Self.team])
            .signing(for: "dev.frontport.port.x.abcde12345", team: Profiles.team, device: Profiles.device, outlasting: nil)
        #expect(signing.profile == Profiles.wildcard)
        #expect(signing.certificate == Profiles.certificate)
        #expect(signing.team == Profiles.team)
    }

    @Test func withoutTheApplesTeamsCertificate() async {
        await #expect(throws: FrontportError.noAppleTeam) {
            try await Self.provisioning(teams: [])
                .signing(for: "a.b", team: Profiles.team, device: Profiles.device, outlasting: nil)
        }
    }

    @Test func withoutAProfile() async {
        await #expect {
            try await Self.provisioning(teams: [Self.team], profiles: [Profiles.store])
                .signing(for: "a.b", team: Profiles.team, device: Profiles.device, outlasting: nil)
        } throws: { error in
            guard case FrontportError.provisioningFailed(let detail) = error else { return false }
            return detail.contains("a.b")
        }
    }
}
