import Foundation

/// Whether an operation can run on a Device now, and if not, the first reason, in the order the user fixes them: on this
/// Mac, Xcode then the Apple Team; then on the Device, reachable, unlocked, then Developer Mode (DESIGN › Devices). The
/// one rule for it: DeviceStatus, DeviceInstallStatus and DeviceUpkeepState ask it, the Device Library refuses by it
/// with the error `Reason.error(on:)` makes, and Seeding's wait reads that error back with `Reason(refusal:)`.
///
/// What the Port is doing there, such as running or a change under way, is the Port's, not the Device's: it isn't here.
public struct DeviceReadiness: Hashable, Sendable {
    /// What Frontport does on a Device, by what it needs there.
    public enum Operation: Hashable, Sendable {
        /// Installing the Port's app, first or over the one there as Update does: signed with the Apple Team, and in
        /// Developer Mode, though it needn't be unlocked.
        case install
        /// Signing the app there again and installing it over: as installing, and unlocked.
        case renew
        /// Copying ROMs into the app's container: unlocked and in Developer Mode, with no Apple Team.
        case seed
        /// Listing the app's container, for what Seeding would copy: in Developer Mode, though it may be locked.
        case list
        /// Removing the app: the Device reachable is all.
        case uninstall

        /// True when it signs the app, so it needs the Apple Team.
        var signs: Bool { self == .install || self == .renew }
        var needsUnlocked: Bool { self == .renew || self == .seed }
        var needsDeveloperMode: Bool { self != .uninstall }
    }

    /// Why an operation can't run on a Device now, in the order the user fixes them.
    public enum Reason: Hashable, Sendable {
        /// Xcode with its iOS platform isn't installed.
        case needsXcode
        /// No Apple Team is chosen, or its certificate is gone from the keychain.
        case noAppleTeam
        /// The Apple Team chosen isn't the one the app there is signed with: another one's bundle ID is an app of its
        /// own, so it would be an install of its own, with Data of its own.
        case otherAppleTeam(AppleTeamID)
        /// The Device isn't reachable now.
        case away
        /// The Device is locked with its passcode.
        case locked
        /// Developer Mode is off on the Device.
        case developerModeOff

        /// True for a reason on the Device, which a later reading of it can find gone.
        public var isOnDevice: Bool {
            switch self {
            case .away, .locked, .developerModeOff: true
            case .needsXcode, .noAppleTeam, .otherAppleTeam: false
            }
        }

        /// The error the Device Library refuses with for it.
        public func error(on device: Device) -> FrontportError {
            switch self {
            case .needsXcode: .xcodeMissing
            case .noAppleTeam: .noAppleTeam
            case .otherAppleTeam(let team): .otherAppleTeam(team)
            case .away: .deviceUnavailable(.away, detail: "\(device.name) isn’t connected to this Mac or its Wi-Fi network.")
            case .locked: .deviceUnavailable(.locked, detail: "Unlock \(device.name), then try again.")
            case .developerModeOff:
                .deviceUnavailable(
                    .developerModeOff,
                    detail: "Developer Mode is off on \(device.name). Turn it on in its Settings › Privacy & Security, then "
                        + "try again.")
            }
        }

        /// The reason an error means, the Device Library's refusal or `devicectl`'s or Xcode's own, or nil for one that
        /// isn't any.
        public init?(refusal error: any Error) {
            switch error {
            case FrontportError.xcodeMissing, FrontportError.noIOSPlatform: self = .needsXcode
            case FrontportError.noAppleTeam: self = .noAppleTeam
            case FrontportError.otherAppleTeam(let team): self = .otherAppleTeam(team)
            case FrontportError.deviceUnavailable(.away, _): self = .away
            case FrontportError.deviceUnavailable(.locked, _): self = .locked
            case FrontportError.deviceUnavailable(.developerModeOff, _): self = .developerModeOff
            default: return nil
            }
        }
    }

    /// Whether Xcode with its iOS platform is there.
    public var hasXcode: Bool
    /// The Apple Team chosen, while its certificate is in the keychain.
    public var team: AppleTeamID?

    public init(hasXcode: Bool, team: AppleTeamID?) {
        self.hasXcode = hasXcode
        self.team = team
    }

    /// The first reason `operation` can't run on the Device as `reading` found it, or nil when it can; without a
    /// reading, the first on this Mac. `signed` is the Apple Team the app there is signed with, for an operation that
    /// goes over it.
    public func reason(_ operation: Operation, on reading: DeviceReading?, signed: AppleTeamID? = nil) -> Reason? {
        if !hasXcode { return .needsXcode }
        if operation.signs {
            guard let team else { return .noAppleTeam }
            if let signed, signed != team { return .otherAppleTeam(signed) }
        }
        return reading.flatMap { Self.reason(operation, on: $0) }
    }

    /// Throws the error of the first reason `operation` can't run on the Device as `reading` found it, if any.
    public func check(_ operation: Operation, on reading: DeviceReading, signed: AppleTeamID? = nil) throws {
        if let reason = reason(operation, on: reading, signed: signed) { throw reason.error(on: reading.device) }
    }

    /// The first reason on the Device alone `operation` can't run there as `reading` found it, or nil when it can: what
    /// it didn't say isn't held against it.
    public static func reason(_ operation: Operation, on reading: DeviceReading) -> Reason? {
        if !reading.isReachable { return .away }
        if operation.needsUnlocked, reading.isLocked == true { return .locked }
        if operation.needsDeveloperMode, reading.developerMode == false { return .developerModeOff }
        return nil
    }
}
