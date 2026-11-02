import Foundation
import Testing
@testable import FrontportCore

private let now = Date(timeIntervalSince1970: 1_850_000_000)
private let day: TimeInterval = 86_400
private let team = DeviceInstallationTests.team
private let iPhone = DeviceStatusTests.iPhone

/// Tiny on the iPhone, its app signed until `expires`, on Release 1.0.
private func installation(expires: Date = now.addingTimeInterval(300 * day)) -> DeviceInstallation {
    DeviceInstallationTests.installation(profileExpires: expires, certificateExpires: now.addingTimeInterval(365 * day))
}

private func release(_ version: String, day offset: Double, channel: Channel = .stable) -> Release {
    Release(
        port: "tiny", version: version, tag: "v\(version)", channel: channel,
        published: Date(timeIntervalSince1970: 1_800_000_000 + offset * day),
        asset: ReleaseAsset(name: "Tiny-\(version).ipa", url: URL(string: "https://example.com/Tiny.ipa")!, size: 3, sha256: "0"))
}

/// Update and Renew on a Port's row for a Device: when they show, and why one is disabled, first reason first.
@Suite struct DeviceRenewStatusTests {
    struct Scenario {
        var expires = now.addingTimeInterval(300 * day)
        var hasXcode = true
        var team: AppleTeamID? = DeviceInstallationTests.team
        var connection = DeviceReading.Connection.wired
        var isLocked: Bool? = false
        var developerMode: Bool? = true
        var activity: Activity.Kind?
        var update: Release?
        var isRunning = false
        var isListed = true

        var status: DeviceStatus {
            DeviceStatus(
                reading: DeviceReading(device: iPhone, connection: connection, isLocked: isLocked, developerMode: developerMode),
                installation: installation(expires: expires), hasXcode: hasXcode, team: team,
                activity: activity.map { Activity($0) }, update: update, upkeep: .init(wait: isRunning ? .running : nil), isListed: isListed,
                now: now)
        }
    }

    // MARK: Renew

    /// Due within 2 days of its app stopping, or once it has; not before.
    @Test func renewIsDueWithinTwoDays() {
        let far = Scenario(expires: now.addingTimeInterval(2 * day + 60)).status
        #expect(!far.isRenewDue && far.check(.renew) == .unavailable && far.actions == [.uninstall])

        let due = Scenario(expires: now.addingTimeInterval(36 * 60 * 60)).status
        #expect(due.renewal == .due(daysLeft: 1) && !due.isExpired)
        #expect(due.actions == [.renew, .uninstall] && due.allows(.renew))

        let lastDay = Scenario(expires: now.addingTimeInterval(60 * 60)).status
        #expect(lastDay.renewal == .due(daysLeft: 0))

        let expired = Scenario(expires: now.addingTimeInterval(-day)).status
        #expect(expired.renewal == .expired && expired.isExpired)
        #expect(expired.actions == [.renew, .uninstall] && expired.allows(.renew))
    }

    /// The certificate expiring first makes it due as well.
    @Test func theCertificateCountsToo() {
        let soon = DeviceInstallationTests.installation(
            profileExpires: now.addingTimeInterval(300 * day), certificateExpires: now.addingTimeInterval(day))
        let status = DeviceStatus(
            reading: DeviceReading(device: iPhone, connection: .wired, isLocked: false, developerMode: true),
            installation: soon, hasXcode: true, team: team, now: now)
        #expect(status.isRenewDue && status.allows(.renew))
    }

    /// Xcode, then an Apple Team, the one it's signed with, then the Device reachable, unlocked and in Developer Mode,
    /// then the Port not running there, since installing over it would stop it, then the one change at a time.
    @Test func renewReasonsInOrder() {
        var s = Scenario(
            expires: now.addingTimeInterval(day), hasXcode: false, team: nil, connection: .away, isLocked: true,
            developerMode: false, activity: .update, isRunning: true)
        #expect(s.status.check(.renew) == .disabled(.needsXcode))
        s.hasXcode = true
        #expect(s.status.check(.renew) == .disabled(.noAppleTeam))
        s.team = AppleTeamID("ZZZZZ99999")
        #expect(s.status.check(.renew) == .disabled(.otherAppleTeam(team)))
        s.team = team
        #expect(s.status.check(.renew) == .disabled(.away))
        s.connection = .network
        #expect(s.status.check(.renew) == .disabled(.locked))
        s.isLocked = nil
        #expect(s.status.check(.renew) == .disabled(.developerModeOff))
        s.developerMode = nil
        #expect(s.status.check(.renew) == .disabled(.running))
        s.isRunning = false
        #expect(s.status.check(.renew) == .disabled(.activity(.update)))
        s.activity = nil
        #expect(s.status.check(.renew) == .allowed)
    }

    // MARK: Update

    /// Shown while its Channel offers a newer iOS Release; it doesn't need the Device unlocked, and the Catalog must
    /// still list the Port.
    @Test func updateReasonsInOrder() {
        #expect(Scenario().status.check(.update) == .unavailable)
        var s = Scenario(
            hasXcode: false, team: nil, connection: .away, isLocked: true, developerMode: false, activity: .applyROMs,
            update: release("2.0", day: 2), isListed: false)
        #expect(s.status.actions == [.update, .uninstall])
        #expect(s.status.check(.update) == .disabled(.needsXcode))
        s.hasXcode = true
        #expect(s.status.check(.update) == .disabled(.noAppleTeam))
        s.team = AppleTeamID("ZZZZZ99999")
        #expect(s.status.check(.update) == .disabled(.otherAppleTeam(team)))
        s.team = team
        #expect(s.status.check(.update) == .disabled(.away))
        s.connection = .wired
        #expect(s.status.check(.update) == .disabled(.developerModeOff), "locked is no reason")
        s.developerMode = true
        #expect(s.status.check(.update) == .disabled(.activity(.applyROMs)))
        s.activity = nil
        #expect(s.status.check(.update) == .disabled(.unknownEntry))
        s.isListed = true
        #expect(s.status.check(.update) == .allowed)
    }

    /// Update, Renew, then Uninstall; a Device without the Port offers neither.
    @Test func theRowsOrder() {
        let both = Scenario(expires: now.addingTimeInterval(day), update: release("2.0", day: 2)).status
        #expect(both.actions == [.update, .renew, .uninstall])
        let none = DeviceStatus(
            reading: DeviceReading(device: iPhone, connection: .wired), installation: nil, hasXcode: true, team: team,
            update: release("2.0", day: 2), now: now)
        #expect(none.actions.isEmpty && none.update == nil && !none.isRenewDue)
        #expect(none.check(.renew) == .unavailable && none.check(.update) == .unavailable)
    }
}
