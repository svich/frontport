import Foundation
import FrontportCore

/// Apple Teams from the keychain and Provisioning Profiles from Xcode's folder (DESIGN › Provisioning Profiles): one is
/// taken when Xcode has it; otherwise Xcode is asked to make it, and it's taken then. Without a way to make one, or
/// when Xcode made none that fits, that's a `provisioningFailed`.
public struct DeviceProvisioning: Provisioning {
    /// Has Xcode make a Provisioning Profile for the bundle ID, Apple Team and Device, as `ProfileMaker.make` does.
    /// Tests inject their own.
    public typealias Make = @Sendable (_ bundleId: String, _ team: AppleTeamID, _ device: DeviceID) async throws -> Void

    private let readTeams: @Sendable () async -> [AppleTeam]
    private let readProfiles: @Sendable () async -> [ProvisioningProfile]
    private let make: Make?
    private let now: @Sendable () -> Date

    public init(
        teams: @escaping @Sendable () async -> [AppleTeam],
        profiles: @escaping @Sendable () async -> [ProvisioningProfile],
        make: Make? = nil,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        readTeams = teams
        readProfiles = profiles
        self.make = make
        self.now = now
    }

    /// The keychain's Apple Teams and Xcode's Provisioning Profiles; `maker` makes one Xcode doesn't have, and without
    /// it none is made.
    public init(
        keychain: KeychainAppleTeams = KeychainAppleTeams(), profiles: ProvisioningProfiles = ProvisioningProfiles(),
        maker: ProfileMaker? = nil
    ) {
        var make: Make?
        if let maker {
            make = { bundleId, team, device in try await maker.make(for: bundleId, team: team, device: device) }
        }
        self.init(teams: { keychain.teams() }, profiles: { await profiles.all() }, make: make)
    }

    public func teams() async -> [AppleTeam] {
        await readTeams()
    }

    /// Takes a Provisioning Profile, else has Xcode make one and takes it then: Xcode may make one only for an explicit
    /// App ID, register the Device, or download one it has online. An error making one is thrown as it is, since it says
    /// more than finding none.
    public func signing(for bundleId: String, team: AppleTeamID, device: DeviceID, outlasting: Date?) async throws -> DeviceSigning {
        guard !(await certificates(of: team)).isEmpty else { throw FrontportError.noAppleTeam }
        if let signing = await take(bundleId, team: team, device: device, outlasting: outlasting) { return signing }
        guard let make else {
            throw FrontportError.provisioningFailed(
                "Xcode has none for \(bundleId) on Apple Team \(team) that lists this Device and lasts long enough.")
        }
        try await make(bundleId, team, device)
        if let signing = await take(bundleId, team: team, device: device, outlasting: outlasting) { return signing }
        throw FrontportError.provisioningFailed(
            "Xcode made none for \(bundleId) on Apple Team \(team) that lists this Device and lasts long enough"
                + (outlasting.map { ": none lasts past \($0.formatted(date: .abbreviated, time: .omitted))." } ?? "."))
    }

    /// The Provisioning Profile `ProvisioningProfiles.choose` takes from Xcode's folder as it is now, with the
    /// certificate to sign with; nil when there's none.
    private func take(_ bundleId: String, team: AppleTeamID, device: DeviceID, outlasting: Date?) async -> DeviceSigning? {
        ProvisioningProfiles.choose(
            await readProfiles(), bundleId: bundleId, team: team, device: device,
            certificates: await certificates(of: team), now: now(), outlasting: outlasting)
    }

    private func certificates(of team: AppleTeamID) async -> [SigningCertificate] {
        await readTeams().first { $0.id == team }?.certificates ?? []
    }
}
