import Foundation
import Testing
@testable import FrontportCore

/// Install on iPhone or iPad…: when the Port's button can be clicked, what it names, and which Devices its sheet lets
/// the prepared app go on.
@Suite struct DeviceInstallStatusTests {
    static let iPhone = DeviceStatusTests.iPhone
    static let iPad = Device(id: "00008112-0000000000000000", name: "Test iPad", model: "iPad Air", osVersion: "27.0", families: [1, 2])
    static let oldIPhone = Device(id: "00008030-0000000000000000", name: "Old iPhone", model: "iPhone 11", osVersion: "16.4", families: [1])
    static let entry = DeviceStatusTests.installed.entry

    static func ready(_ device: Device, connection: DeviceReading.Connection = .wired) -> DeviceReading {
        DeviceReading(device: device, connection: connection, isLocked: false, developerMode: true)
    }

    /// The Port's button as the App sees it: one iPhone, everything ready, unless a test says otherwise.
    struct Scenario {
        var hasIOSVersion = true
        var unsupported: String?
        var readings = [DeviceInstallStatusTests.ready(DeviceInstallStatusTests.iPhone)]
        var hasXcode = true
        var team: AppleTeamID? = DeviceInstallationTests.team
        var activity: Activity.Kind?
        var isListed = true

        var status: DeviceInstallStatus {
            var entry = DeviceInstallStatusTests.entry
            if !hasIOSVersion { entry.ios = nil }
            entry.unsupported = unsupported
            return DeviceInstallStatus(
                entry: entry, readings: readings, hasXcode: hasXcode, team: team, activity: activity.map { Activity($0) },
                isListed: isListed)
        }
    }

    // MARK: The button

    /// Each reason outranks the next: with every one standing, the first shows, and fixing it shows the next.
    @Test func reasonsComeInTheOrderTheUserFixesThem() {
        var scenario = Scenario(readings: [], hasXcode: false, team: nil, activity: .update, isListed: false)
        let expected: [DeviceInstallStatus.Reason] = [.needsXcode, .noAppleTeam, .noDevice, .activity(.update), .unknownEntry]
        var found: [DeviceInstallStatus.Reason] = []
        for _ in expected {
            guard case .disabled(let reason) = scenario.status.availability else { break }
            found.append(reason)
            switch reason {
            case .needsXcode: scenario.hasXcode = true
            case .noAppleTeam: scenario.team = DeviceInstallationTests.team
            case .noDevice: scenario.readings = [DeviceReading(device: Self.iPhone, connection: .away)]
            case .activity: scenario.activity = nil
            case .unknownEntry: scenario.isListed = true
            default: Issue.record("\(reason) isn't one the button gives")
            }
        }
        #expect(found == expected)
        #expect(scenario.status.isAllowed, "a Device that's away doesn't hold it back")
    }

    /// Without one chosen, other Apple Teams in the keychain make choosing one the fix, not adding an Apple account.
    @Test func otherAppleTeamsMakeChoosingTheFix() {
        let entry = Self.entry
        let status = DeviceInstallStatus(
            entry: entry, readings: [Self.ready(Self.iPhone)], hasXcode: true, team: nil, hasAppleTeams: true)
        #expect(status.availability == .disabled(.noAppleTeamChosen))
    }

    /// Neither Developer Mode nor a lock holds the button back: the sheet says which Devices can take the app.
    @Test func noDeviceNeedsToBeReadyForTheButton() {
        let off = DeviceReading(device: Self.iPhone, connection: .wired, isLocked: true, developerMode: false)
        #expect(Scenario(readings: [off]).status.isAllowed)
    }

    /// One change at a time: any of the Port's, on this Mac or a Device, preparing included.
    @Test func anyChangeOfThePortHoldsItBack() {
        for kind: Activity.Kind in [.applyROMs, .device(.uninstall, Self.iPad.id), .prepareForDevices] {
            #expect(Scenario(activity: kind).status.availability == .disabled(.activity(kind)))
        }
    }

    /// No button without an iOS version or on an Unsupported entry; with a Mac Installation or without, the same one.
    @Test func noButtonWithNothingToInstall() {
        #expect(Scenario(hasIOSVersion: false).status.availability == .unavailable)
        #expect(Scenario(unsupported: "Needs JIT.").status.availability == .unavailable)
        #expect(Scenario(hasXcode: false, team: nil).status.availability == .disabled(.needsXcode))
        #expect(Scenario(hasIOSVersion: false, hasXcode: false).status.availability == .unavailable)
    }

    /// "Install on iPhone…" when every Device known is an iPhone, "Install on iPad…" when every one is an iPad, and
    /// "Install on iPhone or iPad…" otherwise, none known included.
    @Test func namesTheDevicesKnown() {
        let iPadOnly = Device(id: "00008103-0000000000000000", name: "iPad", model: "iPad Air", osVersion: "27.0", families: [2])
        let unread = Device(id: "00008120-0000000000000000", name: "Unread", model: "", osVersion: "", families: [])
        #expect(Scenario().status.devices == .iPhone)
        #expect(Scenario(readings: [Self.ready(Self.iPhone), Self.ready(Self.oldIPhone)]).status.devices == .iPhone)
        #expect(Scenario(readings: [Self.ready(Self.iPad), Self.ready(iPadOnly)]).status.devices == .iPad)
        #expect(Scenario(readings: [Self.ready(Self.iPhone), Self.ready(Self.iPad)]).status.devices == .iPhoneOrIPad)
        #expect(Scenario(readings: [Self.ready(unread)]).status.devices == .iPhoneOrIPad)
        #expect(Scenario(readings: []).status.devices == .iPhoneOrIPad)
    }

    // MARK: The Devices it can go on

    static let app = PreparedDeviceApp(
        port: "tiny", release: DeviceStatusTests.installed.release, channel: .stable, appName: "Tiny.app",
        minimumOS: "17.0", families: [1, 2])

    /// Each Device the sheet lists with why it can't take the app, most telling first: the Port there already, then
    /// what the user fixes on the Device, then what no fix brings back.
    @Test func saysWhyEachDeviceCantTakeTheApp() {
        let away = DeviceReading(device: Self.iPad, connection: .away)
        let off = DeviceReading(device: Self.iPad, connection: .network, isLocked: false, developerMode: false)
        let iPadOnly = PreparedDeviceApp(
            port: "tiny", release: Self.app.release, channel: .stable, appName: "Tiny.app", minimumOS: "15.0", families: [2])
        let installedAway = DeviceReading(device: Self.iPhone, connection: .away)
        let installed = [DeviceStatusTests.installed]

        let reasons = { (app: PreparedDeviceApp, readings: [DeviceReading]) in
            DeviceInstallStatus.choices(for: app, readings: readings, installations: installed).map(\.reason)
        }
        #expect(reasons(Self.app, [installedAway]) == [.installed(version: "1.0")])
        #expect(reasons(Self.app, [away]) == [.away])
        #expect(reasons(Self.app, [off]) == [.developerModeOff])
        #expect(reasons(Self.app, [Self.ready(Self.oldIPhone)]) == [.needsNewerIOS(minimumOS: "17.0")])
        #expect(reasons(iPadOnly, [Self.ready(Self.oldIPhone)]) == [.otherDevices(families: [2])])
        #expect(reasons(Self.app, [Self.ready(Self.iPad)]) == [nil])
        #expect(reasons(iPadOnly, [Self.ready(Self.iPad)]) == [nil], "an iPad runs it")
        // Locked takes an install, and what a Device didn't say isn't held against it.
        let locked = DeviceReading(device: Self.iPad, connection: .wired, isLocked: true, developerMode: nil)
        let unread = Device(id: "00008120-0000000000000000", name: "Unread", model: "", osVersion: "", families: [])
        #expect(reasons(Self.app, [locked, Self.ready(unread)]) == [nil, nil])
        // Another Port's Installation doesn't count.
        var other = DeviceStatusTests.installed
        other.port = "other"
        #expect(DeviceInstallStatus.choices(for: Self.app, readings: [Self.ready(Self.iPhone)], installations: [other])
            .map(\.reason) == [nil])
    }

    /// The only Device that can take the app is chosen to start with; with two, neither is.
    @Test func choosesTheOnlyDeviceThatCanTakeIt() {
        let iPhoneHasIt = DeviceInstallStatus.choices(
            for: Self.app, readings: [Self.ready(Self.iPhone), Self.ready(Self.iPad, connection: .network)],
            installations: [DeviceStatusTests.installed])
        #expect(DeviceInstallStatus.chosen([], among: iPhoneHasIt) == [Self.iPad.id])

        let both = DeviceInstallStatus.choices(
            for: Self.app, readings: [Self.ready(Self.iPhone), Self.ready(Self.iPad)], installations: [])
        #expect(DeviceInstallStatus.chosen([], among: both).isEmpty)
        #expect(DeviceInstallStatus.chosen([Self.iPhone.id], among: both) == [Self.iPhone.id])
    }

    /// As the Devices are read again: one that went away is unchosen, and one plugged in is chosen when it's the only
    /// one that can take the app and nothing is chosen.
    @Test func keepsTheChoiceInStepWithTheReadings() {
        let away = DeviceInstallStatus.choices(
            for: Self.app, readings: [DeviceReading(device: Self.iPad, connection: .away)], installations: [])
        #expect(DeviceInstallStatus.chosen([], among: away).isEmpty)
        #expect(DeviceInstallStatus.chosen([Self.iPad.id], among: away).isEmpty)

        let pluggedIn = DeviceInstallStatus.choices(for: Self.app, readings: [Self.ready(Self.iPad)], installations: [])
        #expect(DeviceInstallStatus.chosen([], among: pluggedIn) == [Self.iPad.id])

        let two = DeviceInstallStatus.choices(
            for: Self.app, readings: [Self.ready(Self.iPhone), Self.ready(Self.iPad)], installations: [])
        #expect(DeviceInstallStatus.chosen([Self.iPad.id], among: two) == [Self.iPad.id], "a second doesn't join")
    }

    @Test func comparesIOSVersionsNumberByNumber() {
        #expect(DeviceInstallStatus.isAtLeast("27.0.1", "27.0"))
        #expect(DeviceInstallStatus.isAtLeast("27", "27.0"))
        #expect(DeviceInstallStatus.isAtLeast("27.0", "27"))
        #expect(DeviceInstallStatus.isAtLeast("27.10", "27.9"))
        #expect(!DeviceInstallStatus.isAtLeast("26.4", "27.0"))
        #expect(!DeviceInstallStatus.isAtLeast("27.0", "27.0.1"))
    }

    /// A prepared app is reused for its own Release on its own Channel only: the same tag and asset digest, whatever
    /// else upstream changed since, such as its notes.
    @Test func aPreparedAppIsForItsOwnRelease() {
        var release = Self.app.release
        release.notes = "Edited since."
        #expect(Self.app.isFor(release, on: .stable, recipeSHA256: nil))
        #expect(!Self.app.isFor(release, on: .nightly, recipeSHA256: nil))
        var rebuilt = release
        rebuilt.asset?.sha256 = "def"
        #expect(!Self.app.isFor(rebuilt, on: .stable, recipeSHA256: nil))
        var newer = release
        newer.tag = "v1.1"
        #expect(!Self.app.isFor(newer, on: .stable, recipeSHA256: nil))
    }

    /// The button skips straight to the sheet only for an app prepared from the newest iOS Release on the default
    /// Channel that the iOS version still offers, even when the newest Release known is one it Blocks now.
    @Test func aPreparedAppIsOfferedAsItIsOnlyWhileTheIOSVersionOffersIt() throws {
        let latest = Self.app.release
        let version = try IOSVersion(of: Self.entry)
        #expect(Self.app.isCurrent(for: version, latest: latest))
        #expect(!Self.app.isCurrent(for: version, latest: nil), "not looked up yet")
        var newer = latest
        newer.tag = "v1.1"
        #expect(!Self.app.isCurrent(for: version, latest: newer))

        var blocked = Self.entry
        blocked.ios?.blocked = [Block(release: latest.version, severity: .warn, reason: "Crashes on load.")]
        #expect(!Self.app.isCurrent(for: try IOSVersion(of: blocked), latest: latest))

        var nightly = Self.entry
        nightly.ios?.releases = .githubRelease(GitHubReleaseSource(repo: "tests/tiny", asset: "Tiny-*.ipa", channels: [.nightly]))
        #expect(!Self.app.isCurrent(for: try IOSVersion(of: nightly), latest: latest))
    }
}
