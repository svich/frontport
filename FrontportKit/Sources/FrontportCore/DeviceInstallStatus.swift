import Foundation

/// Install on iPhone or iPad…, the Port's way onto the user's Devices (DESIGN › Devices): whether it can be taken now,
/// and once the Port's iOS version is prepared, which Devices can take it. Built from the App's state alone, like
/// DeviceStatus, so the button, the sheet that asks which Devices, and the intents they start make one decision.
///
/// No Device needs to be reachable for the button: one can be plugged in while the iOS version is prepared, and the
/// sheet reads the Devices again while it shows.
public struct DeviceInstallStatus: Hashable, Sendable {
    /// Why the Port can't be installed on Devices now, in the order the user fixes them: the row's reasons, of which
    /// the button gives only those on this Mac (`needsXcode`, `noAppleTeam`, `noAppleTeamChosen`), then `noDevice`,
    /// `activity` and `unknownEntry`.
    public typealias Reason = DeviceStatus.Reason

    /// Whether the button can be clicked now.
    public enum Availability: Hashable, Sendable {
        case allowed
        case disabled(Reason)
        /// The Port has no iOS version, or is Unsupported: no button.
        case unavailable
    }

    /// The Devices the button names: "Install on iPhone…" when every known one is an iPhone.
    public enum Devices: Hashable, Sendable {
        case iPhone, iPad, iPhoneOrIPad
    }

    public let availability: Availability
    public let devices: Devices

    /// `readings` are every Device Frontport knows, away or not; `team` is the Apple Team chosen in Settings › Devices,
    /// `hasAppleTeams` whether any is in the keychain; `isListed` is whether the Catalog lists the entry, rather than
    /// only an Installation keeping it.
    public init(
        entry: CatalogEntry, readings: [DeviceReading], hasXcode: Bool, team: AppleTeamID?, hasAppleTeams: Bool = false,
        activity: Activity? = nil, isListed: Bool = true
    ) {
        if !readings.isEmpty, readings.allSatisfy({ $0.device.families == [1] }) {
            devices = .iPhone
        } else if !readings.isEmpty, readings.allSatisfy(\.device.isPad) {
            devices = .iPad
        } else {
            devices = .iPhoneOrIPad
        }
        // No Device in particular: only what's on this Mac.
        let unready = DeviceReadiness(hasXcode: hasXcode, team: team).reason(.install, on: nil)
            .map { Reason($0, hasAppleTeams: hasAppleTeams) }
        if entry.ios == nil || !entry.isInstallable {
            availability = .unavailable
        } else if let unready {
            availability = .disabled(unready)
        } else if readings.isEmpty {
            availability = .disabled(.noDevice)
        } else if let activity {
            availability = .disabled(.activity(activity.kind))
        } else {
            availability = isListed ? .allowed : .disabled(.unknownEntry)
        }
    }

    public var isAllowed: Bool { availability == .allowed }

    /// Whether the sheet's Install can be taken now: as the button allows, though a change under way on the Port, such
    /// as one Renewing, only means waiting, since the sheet comes after preparing.
    public var isInstallAllowed: Bool {
        switch availability {
        case .allowed, .disabled(.activity): true
        default: false
        }
    }

    // MARK: Choosing Devices

    /// A Device in the sheet that asks which ones to install the prepared app on, and why it can't take it, if it
    /// can't.
    public struct Choice: Hashable, Sendable, Identifiable {
        /// Why a Device can't take the prepared app now, most telling first.
        public enum Reason: Hashable, Sendable {
            /// It has the Port already, at this version.
            case installed(version: String)
            /// It isn't reachable now.
            case away
            /// Developer Mode is off on it.
            case developerModeOff
            /// It has an older iOS than the app's oldest.
            case needsNewerIOS(minimumOS: String)
            /// The app is made only for the other kind of Device: these are its `UIDeviceFamily` values.
            case otherDevices(families: [Int])
        }

        public var reading: DeviceReading
        /// Nil when it can take the app now.
        public var reason: Reason?

        public init(reading: DeviceReading, reason: Reason?) {
            self.reading = reading
            self.reason = reason
        }

        public var id: DeviceID { reading.device.id }
        public var isEligible: Bool { reason == nil }
    }

    /// Every Device in `readings`, in their order, with why it can't take `app` now. A Device that has the Port already
    /// can't, whichever Release it has: installing over it is an update. What's on this Mac holds the sheet's Install
    /// instead (`isInstallAllowed`), so only the Device's own readiness counts here.
    public static func choices(
        for app: PreparedDeviceApp, readings: [DeviceReading], installations: [DeviceInstallation]
    ) -> [Choice] {
        readings.map { reading in
            let device = reading.device
            let reason: Choice.Reason? =
                if let installed = installations.first(where: { $0.port == app.port && $0.device == device.id }) {
                    .installed(version: installed.release.version)
                } else {
                    switch DeviceReadiness.reason(.install, on: reading) {
                    case .away?: .away
                    case .developerModeOff?: .developerModeOff
                    // Installing needs no unlocking, and the rest are this Mac's.
                    case .locked?, .needsXcode?, .noAppleTeam?, .otherAppleTeam?, nil:
                        fit(minimumOS: app.minimumOS, families: app.families, on: device)
                    }
                }
            return Choice(reading: reading, reason: reason)
        }
    }

    /// What's chosen once the choices change, as when a Device is plugged in: only Devices that can take the app stay,
    /// and with none chosen, the one that can is when it's the only one. Starting from none, that's the sheet's first
    /// choice.
    public static func chosen(_ chosen: Set<DeviceID>, among choices: [Choice]) -> Set<DeviceID> {
        let eligible = choices.filter(\.isEligible).map(\.id)
        let kept = chosen.intersection(eligible)
        return kept.isEmpty && eligible.count == 1 ? [eligible[0]] : kept
    }

    /// Why an app with this oldest iOS and these `UIDeviceFamily` values can't run on the Device, or nil when it can:
    /// an older iOS first, which updating fixes, then the other kind of Device. What the Device didn't say isn't
    /// checked; an iPad also runs iPhone apps, as its families say.
    public static func fit(minimumOS: String, families: [Int], on device: Device) -> Choice.Reason? {
        if !device.osVersion.isEmpty, !isAtLeast(device.osVersion, minimumOS) {
            return .needsNewerIOS(minimumOS: minimumOS)
        }
        if !device.families.isEmpty, Set(families).isDisjoint(with: device.families) {
            return .otherDevices(families: families)
        }
        return nil
    }

    /// True when `version` is `minimum` or later, compared number by number, so "15" is "15.0".
    public static func isAtLeast(_ version: String, _ minimum: String) -> Bool {
        let numbers = { (text: String) in text.split(separator: ".").map { Int($0) ?? 0 } }
        let (a, b) = (numbers(version), numbers(minimum))
        for index in 0..<max(a.count, b.count) {
            let (x, y) = (index < a.count ? a[index] : 0, index < b.count ? b[index] : 0)
            if x != y { return x > y }
        }
        return true
    }
}
