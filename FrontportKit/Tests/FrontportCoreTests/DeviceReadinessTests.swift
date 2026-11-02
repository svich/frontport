import Foundation
import Testing
@testable import FrontportCore

/// Whether each operation can run on a Device as a reading found it, and the first reason it can't: the one rule every
/// Device screen, the Device Library and Seeding's wait go by.
@Suite struct DeviceReadinessTests {
    static let iPhone = DeviceStatusTests.iPhone
    static let team = DeviceInstallationTests.team
    static let other = AppleTeamID("ZZZZZ99999")!
    static let ready = DeviceReadiness(hasXcode: true, team: team)

    static func reading(
        _ connection: DeviceReading.Connection = .wired, isLocked: Bool? = false, developerMode: Bool? = true
    ) -> DeviceReading {
        DeviceReading(device: iPhone, connection: connection, isLocked: isLocked, developerMode: developerMode)
    }

    /// Operation by reading, with this Mac ready: installing needs no unlocking, listing works while locked, and
    /// uninstalling needs only the Device reachable. A lock comes before Developer Mode.
    @Test func eachOperationByWhatTheDeviceSaid() {
        typealias R = DeviceReadiness.Reason
        let readings: [(String, DeviceReading)] = [
            ("ready", Self.reading()),
            ("away", Self.reading(.away, isLocked: true, developerMode: false)),
            ("locked", Self.reading(isLocked: true)),
            ("Developer Mode off", Self.reading(developerMode: false)),
            ("locked, Developer Mode off", Self.reading(.network, isLocked: true, developerMode: false)),
            ("unsaid", Self.reading(isLocked: nil, developerMode: nil)),
        ]
        let table: [(DeviceReadiness.Operation, [R?])] = [
            (.install, [nil, .away, nil, .developerModeOff, .developerModeOff, nil]),
            (.renew, [nil, .away, .locked, .developerModeOff, .locked, nil]),
            (.seed, [nil, .away, .locked, .developerModeOff, .locked, nil]),
            (.list, [nil, .away, nil, .developerModeOff, .developerModeOff, nil]),
            (.uninstall, [nil, .away, nil, nil, nil, nil]),
        ]
        for (operation, expected) in table {
            for ((name, reading), reason) in zip(readings, expected) {
                #expect(Self.ready.reason(operation, on: reading) == reason, "\(operation) on \(name)")
                #expect(DeviceReadiness.reason(operation, on: reading) == reason, "\(operation) on \(name), the Device alone")
            }
        }
    }

    /// What's on this Mac comes before the Device: Xcode for everything, the Apple Team only for what signs.
    @Test func thisMacComesFirst() {
        let away = Self.reading(.away)
        let noXcode = DeviceReadiness(hasXcode: false, team: nil)
        let noTeam = DeviceReadiness(hasXcode: true, team: nil)
        let table: [(DeviceReadiness.Operation, noTeam: DeviceReadiness.Reason, otherTeam: DeviceReadiness.Reason)] = [
            (.install, .noAppleTeam, .otherAppleTeam(Self.other)),
            (.renew, .noAppleTeam, .otherAppleTeam(Self.other)),
            (.seed, .away, .away),
            (.list, .away, .away),
            (.uninstall, .away, .away),
        ]
        for (operation, noTeamReason, otherTeamReason) in table {
            #expect(noXcode.reason(operation, on: away, signed: Self.other) == .needsXcode, "\(operation)")
            #expect(noXcode.reason(operation, on: nil) == .needsXcode, "\(operation)")
            #expect(noTeam.reason(operation, on: away, signed: Self.other) == noTeamReason, "\(operation)")
            #expect(Self.ready.reason(operation, on: away, signed: Self.other) == otherTeamReason, "\(operation)")
            #expect(Self.ready.reason(operation, on: Self.reading(), signed: Self.team) == nil, "\(operation)")
        }
        // Without a Device in particular, only this Mac is asked.
        #expect(noTeam.reason(.install, on: nil) == .noAppleTeam)
        #expect(noTeam.reason(.seed, on: nil) == nil)
        #expect(Self.ready.reason(.install, on: nil) == nil)
    }

    /// The Device Library refuses with one error per reason, which reads back as that reason; Seeding waits for those
    /// on the Device and fails for those on this Mac.
    @Test func refusalsReadBackAsTheirReason() throws {
        let reasons: [DeviceReadiness.Reason] = [
            .needsXcode, .noAppleTeam, .otherAppleTeam(Self.other), .away, .locked, .developerModeOff,
        ]
        for reason in reasons {
            let error = reason.error(on: Self.iPhone)
            #expect(DeviceReadiness.Reason(refusal: error) == reason)
            #expect(DeviceUpkeepState.Wait(refusal: error) == (reason.isOnDevice ? .unready : nil), "\(reason)")
        }
        #expect(throws: FrontportError.deviceUnavailable(.locked, detail: "Unlock Test iPhone, then try again.")) {
            try Self.ready.check(.renew, on: Self.reading(isLocked: true))
        }
        try Self.ready.check(.install, on: Self.reading(isLocked: true))
        #expect(DeviceReadiness.Reason(refusal: FrontportError.deviceUnavailable(.failed, detail: "")) == nil)
        #expect(DeviceReadiness.Reason(refusal: CancellationError()) == nil)
    }

    /// What the user reads: the Device's name for Developer Mode, which only they can turn on, there.
    @Test func refusalsSayWhatToDo() {
        #expect(DeviceReadiness.Reason.away.error(on: Self.iPhone).localizedDescription
            == "The Device isn’t reachable. Connect it to this Mac or to the same Wi-Fi network, then try again.")
        #expect(DeviceReadiness.Reason.locked.error(on: Self.iPhone).localizedDescription == "Unlock the Device, then try again.")
        #expect(DeviceReadiness.Reason.developerModeOff.error(on: Self.iPhone).localizedDescription
            == "Developer Mode is off on Test iPhone. Turn it on in its Settings › Privacy & Security, then try again.")
    }

    /// Seeding waits for a Device that isn't ready to Seed on, as far as it said.
    @Test func seedingIsReadyAsTheDeviceAllows() {
        #expect(DeviceUpkeepState.isReady(Self.reading()))
        #expect(DeviceUpkeepState.isReady(Self.reading(isLocked: nil, developerMode: nil)))
        #expect(!DeviceUpkeepState.isReady(Self.reading(.away)))
        #expect(!DeviceUpkeepState.isReady(Self.reading(isLocked: true)))
        #expect(!DeviceUpkeepState.isReady(Self.reading(developerMode: false)))
    }
}
