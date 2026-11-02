import Foundation
import Testing
@testable import FrontportCore

private let now = Date(timeIntervalSince1970: 1_850_000_000)
private let day: TimeInterval = 86_400
private let hour: TimeInterval = 60 * 60
private let iPhone = DeviceStatusTests.iPhone

private func reading(
    _ connection: DeviceReading.Connection = .wired, isLocked: Bool? = false, developerMode: Bool? = true
) -> DeviceReading {
    DeviceReading(device: iPhone, connection: connection, isLocked: isLocked, developerMode: developerMode)
}

/// Tiny on `device`, its app stopping `left` from now.
private func installation(_ left: TimeInterval, on device: DeviceID = iPhone.id) -> DeviceInstallation {
    var installation = DeviceInstallationTests.installation(profileExpires: now.addingTimeInterval(left), certificateExpires: .distantFuture)
    installation.device = device
    return installation
}

/// Where a Port's ROMs stand on a Device, as its row says: the first of held, waiting, failed, unseeded, missing and
/// Seeded that holds.
@Suite struct DeviceSeedingStateTests {
    static let held = Requirement(label: "Held", stage: .runtime, oneOf: ["h"], seedPath: "Documents/held")
    static let unseeded = DeviceMatchingTests.sm64
    static let missing = Requirement(label: "Missing", stage: .runtime, oneOf: ["m"], seedPath: "Documents/missing")
    static let seeded = Requirement(label: "Seeded", stage: .runtime, oneOf: ["s"], seedPath: "Documents/seeded")

    static func matching(_ states: [DeviceMatching.State], isLastKnown: Bool = false) -> DeviceMatching {
        let requirements: [DeviceMatching.State: Requirement] = [
            .held: held, .unseeded: unseeded, .missing: missing, .seeded: seeded,
        ]
        return DeviceMatching(
            requirements: states.map { .init(requirement: requirements[$0]!, state: $0) }, isLastKnown: isLastKnown)
    }

    typealias Seeding = DeviceStatus.Seeding

    @Test func precedence() {
        let all = Self.matching([.seeded, .missing, .unseeded, .held])
        let unseeded = Self.matching([.seeded, .missing, .unseeded])
        let cases: [(DeviceMatching?, Seeding.Wait?, Bool, Seeding?)] = [
            (nil, .running, true, nil),
            // A held folder first, whatever else holds.
            (all, .running, true, .held([Self.held])),
            // Then what isn't there yet: waiting for the Port to quit or for the Device…
            (unseeded, .running, true, .waiting([Self.unseeded], .running)),
            (unseeded, .running, false, .waiting([Self.unseeded], .running)),
            (unseeded, .away, true, .waiting([Self.unseeded], .away)),
            (unseeded, .locked, true, .waiting([Self.unseeded], .locked)),
            (unseeded, .developerModeOff, true, .waiting([Self.unseeded], .developerModeOff)),
            // …or, waiting for nothing, failed or not Seeded yet.
            (unseeded, nil, true, .failed([Self.unseeded])),
            (unseeded, nil, false, .unseeded([Self.unseeded])),
            // Then a ROM missing from ROMs, then what's Seeded.
            (Self.matching([.seeded, .missing]), .running, true, .missing([Self.missing])),
            (Self.matching([.seeded]), .running, true, .seeded([Self.seeded], isLastKnown: false)),
            (Self.matching([.seeded], isLastKnown: true), nil, false, .seeded([Self.seeded], isLastKnown: true)),
        ]
        for (index, (matching, wait, failed, expected)) in cases.enumerated() {
            #expect(Seeding(matching, wait: wait, failed: failed) == expected, "case \(index)")
        }
    }

    /// The row's status carries it, and whether Seeding failed there, for Try Again, only while the Port is there.
    @Test func theRowsStatusCarriesIt() {
        let status = DeviceStatus(
            reading: reading(), installation: DeviceStatusTests.installed, hasXcode: true,
            matching: Self.matching([.unseeded]), upkeep: .init(wait: .running, seedFailure: "It failed."))
        #expect(status.seeding == .waiting([Self.unseeded], .running))
        #expect(status.seedFailed && status.isRunning)

        let gone = DeviceStatus(
            reading: reading(), installation: nil, hasXcode: true, matching: Self.matching([.unseeded]),
            upkeep: .init(seedFailure: "It failed."))
        #expect(gone.seeding == nil && !gone.seedFailed)
    }
}

/// When a Port's app on a Device stops launching, once Renew is due, or why the last Renew failed.
@Suite struct DeviceRenewalTests {
    static func status(_ left: TimeInterval, failure: String? = nil) -> DeviceStatus {
        DeviceStatus(
            reading: reading(), installation: installation(left), hasXcode: true, team: DeviceInstallationTests.team,
            upkeep: .init(renewFailure: failure), now: now)
    }

    /// Whole days, rounded down: due from 2 days out, "less than a day" within the last, expired from the moment it
    /// stops.
    @Test func daysLeftBoundaries() {
        let cases: [(TimeInterval, DeviceStatus.Renewal?)] = [
            (2 * day + 1, nil),
            (2 * day, .due(daysLeft: 2)),
            (2 * day - 1, .due(daysLeft: 1)),
            (36 * hour, .due(daysLeft: 1)),
            (day, .due(daysLeft: 1)),
            (day - 1, .due(daysLeft: 0)),
            (1, .due(daysLeft: 0)),
            (0, .expired),
            (-day, .expired),
        ]
        for (left, expected) in cases {
            #expect(DeviceStatus.Renewal(installation(left), now: now) == expected, "\(left / hour) hours left")
            let status = Self.status(left)
            #expect(status.renewal == expected && status.isRenewDue == (expected != nil))
            #expect(status.isExpired == (expected == .expired))
        }
    }

    /// A failed Renew says why once Renew is due, expired or not, and nothing before.
    @Test func aFailureShowsOnceDue() {
        #expect(Self.status(day, failure: "No Provisioning Profile.").renewal == .failed("No Provisioning Profile."))
        let expired = Self.status(-day, failure: "No Provisioning Profile.")
        #expect(expired.renewal == .failed("No Provisioning Profile.") && expired.isExpired)
        #expect(Self.status(3 * day, failure: "No Provisioning Profile.").renewal == nil)
    }

    @Test func nothingWithoutAnInstallation() {
        let status = DeviceStatus(
            reading: reading(), installation: nil, hasXcode: true, upkeep: .init(renewFailure: "It failed."), now: now)
        #expect(status.renewal == nil && !status.isExpired)
    }
}
