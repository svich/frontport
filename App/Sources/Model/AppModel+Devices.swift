import Foundation
import FrontportCore

/// The Apple Team chosen in Settings › Devices and whether Frontport Renews on its own, kept in UserDefaults.
final class DefaultsDevicePreferences: DevicePreferences {
    private static let teamKey = "appleTeam"
    private static let renewKey = "renewOnItsOwn"

    var team: AppleTeamID? {
        get { UserDefaults.standard.string(forKey: Self.teamKey).flatMap { AppleTeamID(rawValue: $0) } }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: Self.teamKey) }
    }

    var renewsOnItsOwn: Bool {
        get { UserDefaults.standard.object(forKey: Self.renewKey) == nil || UserDefaults.standard.bool(forKey: Self.renewKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.renewKey) }
    }
}

extension AppModel {
    /// Every Device the user has, by name (`DeviceUpkeep.knownDevices`).
    var knownDevices: [DeviceReading] { deviceUpkeep.knownDevices }

    func deviceReading(_ device: DeviceID) -> DeviceReading? { deviceUpkeep.reading(device) }

    /// The name the user gave the Device, or "the Device" for one Frontport no longer knows.
    /// The Port's page to open: on this Mac while it's here or being installed here, else on the first Device it's on.
    func page(for port: PortID) -> Screen {
        let onMac = survey.installation(port) != nil || activities[port].map {
            if case .device = $0.kind { false } else { $0.kind != .prepareForDevices }
        } == true
        guard !onMac, let first = survey.deviceInstallations(of: port).first else { return .port(port) }
        return .portOnDevice(port, first.device)
    }

    func deviceName(_ device: DeviceID) -> String { deviceReading(device)?.device.name ?? "the Device" }

    /// What the Port has on the Device and can do there now.
    func deviceStatus(of port: PortID, on reading: DeviceReading) -> DeviceStatus {
        deviceUpkeep.status(of: port, on: reading)
    }

    /// Where an Installation's ROMs stand on its Device, from the latest plan read there while it's reachable.
    func deviceMatching(of installation: DeviceInstallation, isReachable: Bool) -> DeviceMatching? {
        deviceUpkeep.matching(of: installation, isReachable: isReachable)
    }

    /// Install on iPhone or iPad…: whether the Port's button can be clicked now, and which Devices it names. Nil
    /// without its entry.
    func deviceInstallStatus(of port: PortID) -> DeviceInstallStatus? { deviceUpkeep.installStatus(of: port) }

    // MARK: Asking which Devices

    /// The sheet asking which Devices to install a Port's prepared iOS version on.
    struct DevicePicker: Identifiable {
        let id = UUID()
        var port: PortID
        var app: PreparedDeviceApp
    }

    /// Install on iPhone or iPad…: has the Port's iOS version prepared (`DeviceUpkeep.prepare`), then asks which
    /// Devices to install it on.
    func installOnDevices(_ port: PortID) {
        deviceUpkeep.prepare(port) { [weak self] app in
            // Shown over whatever screen shows now, as the intake sheet is.
            self?.ask(DevicePicker(port: port, app: app))
        }
    }

    /// Shows the sheet, or with one showing, has it wait its turn, so a sheet is never swapped from under the user. One
    /// for the Port of the sheet showing is dropped, as a second click's is; one for a Port already waiting replaces it.
    private func ask(_ picker: DevicePicker) {
        guard let showing = devicePicker else {
            devicePicker = picker
            return
        }
        guard showing.port != picker.port else { return }
        waitingDevicePickers.removeAll { $0.port == picker.port }
        waitingDevicePickers.append(picker)
    }

    /// Once a sheet is closed, shows the next one waiting.
    func devicePickerClosed() {
        guard devicePicker == nil, !waitingDevicePickers.isEmpty else { return }
        devicePicker = waitingDevicePickers.removeFirst()
    }

    #if DEBUG
    /// Shows the sheet for the Port's prepared iOS version in the preview data, or closes it: for the snapshot driver.
    func previewDevicePicker(_ port: PortID?) {
        devicePicker = port.flatMap { port in previewPreparedApps[port].map { DevicePicker(port: port, app: $0) } }
    }
    #endif

    /// Whether the sheet's Install can be taken now (`DeviceInstallStatus.isInstallAllowed`).
    func canInstall(_ port: PortID) -> Bool {
        deviceInstallStatus(of: port)?.isInstallAllowed == true
    }

    /// Why the sheet's Install can't be taken now, as the line above its buttons says. Nil when it can.
    func installHelp(_ port: PortID) -> String? {
        guard !canInstall(port) else { return nil }
        guard let status = deviceInstallStatus(of: port), let help = installOnDevicesHelp(status, for: port) else {
            return "The Catalog no longer offers \(portName(port)) for iPhone and iPad"
        }
        return help
    }

    /// Forgets a Device that's away, with the records of the Ports Frontport installed there; they stay on it, with
    /// their Data.
    func forget(_ device: DeviceID) async {
        do {
            try await deviceUpkeep.forget(device)
        } catch {
            present(error)
        }
    }

    // MARK: Wording

    /// What `action` does for the Port on the Device, or why it's disabled, as help: "Connect Test iPhone to this
    /// Mac…". Nil when there's nothing to say.
    func help(_ action: DeviceStatus.Action, _ status: DeviceStatus, for port: PortID) -> String? {
        let name = status.reading.device.name
        guard case .disabled(let reason) = status.check(action) else {
            switch action {
            case .update: return status.update.map { "Installs \($0.version) over it on \(name), keeping its Data there" }
            case .renew: return "Installs it on \(name) again with a Provisioning Profile that lasts longer, keeping its Data there"
            case .seed, .uninstall: return nil
            }
        }
        return help(reason, action.change, for: port, on: name)
    }

    /// Why `change` can't be made for the Port now, on the Device named `device` when it's one in particular: the one
    /// wording of each reason.
    func help(_ reason: DeviceStatus.Reason, _ change: DeviceChange, for port: PortID, on device: String? = nil) -> String {
        let name = device ?? "the Device"
        switch reason {
        case .needsXcode:
            let doing = switch change {
            case .install: "Installing on"
            case .update: "Updating on"
            case .renew: "Renewing on"
            case .seed: "Seeding on"
            case .uninstall: "Uninstalling from"
            }
            return "\(doing) iPhone and iPad needs Xcode, with its iOS platform"
        case .noAppleTeam: return "Add your Apple Account in Xcode › Settings › Accounts, so Frontport has an Apple Team to sign with"
        case .noAppleTeamChosen: return "Choose an Apple Team in Frontport › Settings › Devices"
        case .otherAppleTeam(let team):
            return "It’s signed with Apple Team \(team) on \(name): choose that one in Frontport › Settings › Devices"
        case .away: return "Connect \(name) to this Mac, or to its Wi-Fi network"
        case .locked: return "Unlock \(name)"
        case .developerModeOff: return "Turn on Developer Mode in \(name)’s Settings › Privacy & Security"
        case .running: return "Quit \(portName(port)) on \(name) first"
        case .noDevice: return "Connect an iPhone or iPad to this Mac with a cable, and trust this Mac on it."
        case .activity(let kind): return waiting(for: kind, of: port)
        case .unknownEntry: return "The Catalog no longer lists \(portName(port))"
        }
    }

    /// The Port's name in the Catalog, or its ID once the Catalog no longer has it.
    private func portName(_ port: PortID) -> String { survey.entry(port)?.name ?? port.rawValue }

    /// The Port's Update button on the Device's row: "Update to 3.0.0".
    func updateTitle(_ status: DeviceStatus) -> String {
        status.update.map { "Update to \($0.version)" } ?? "Update"
    }

    /// The Port's Seed button on the Device's row: Try Again once Seeding failed there.
    func seedTitle(_ status: DeviceStatus) -> String {
        status.seedFailed ? "Try Again" : "Seed"
    }

    /// When the Port's app on the Device stops launching, in a short line, once Renew is due: "1 day left to Renew", or
    /// why it wasn't Renewed last time. Nil before it's due.
    func renewText(_ status: DeviceStatus) -> String? {
        switch status.renewal {
        case nil: nil
        case .failed(let message)?: "Not Renewed: \(message)"
        case .expired?: "Stopped launching there: Renew it to play again"
        case .due(let days)?: "\(Self.left(days)) to Renew"
        }
    }

    /// How long an app on a Device launches, once Renew is due: "Less than a day left", "2 days left".
    private static func left(_ days: Int) -> String {
        days == 0 ? "Less than a day left" : "\(Format.count(days, "day")) left"
    }

    /// Where the Port's ROMs stand on the Device, in a short line: "Super Mario 64 Seeded", "Seeding Super Mario 64
    /// failed". Nil when its iOS version Seeds nothing there.
    func seedingText(_ status: DeviceStatus, for port: PortID) -> String? {
        func names(_ requirements: [Requirement]) -> String { requirements.map(\.label).formatted(.list(type: .and)) }
        return switch status.seeding {
        case nil: nil
        case .held(let held)?: "\(names(held)) left alone: its folder there holds another ROM. Uninstall to start over."
        case .waiting(let unseeded, .running)?: "\(names(unseeded)) Seeded once \(portName(port)) quits there"
        case .waiting(let unseeded, .away)?: "\(names(unseeded)) Seeded once it’s connected"
        case .waiting(let unseeded, .locked)?: "\(names(unseeded)) Seeded once it’s unlocked"
        case .waiting(let unseeded, .developerModeOff)?: "\(names(unseeded)) Seeded once Developer Mode is on"
        case .failed(let unseeded)?: "Seeding \(names(unseeded)) failed"
        case .unseeded(let unseeded)?: "\(names(unseeded)) not Seeded yet"
        case .missing(let missing)?: "Add a ROM for \(names(missing)) to Seed it here"
        case .seeded(let seeded, let isLastKnown)?: "\(names(seeded)) Seeded\(isLastKnown ? " when last connected" : "")"
        }
    }

    /// "Install on iPhone…", "Install on iPad…" or "Install on iPhone or iPad…", by the Devices Frontport knows.
    func installOnDevicesTitle(_ status: DeviceInstallStatus) -> String {
        switch status.devices {
        case .iPhone: "Install on iPhone…"
        case .iPad: "Install on iPad…"
        case .iPhoneOrIPad: "Install on iPhone or iPad…"
        }
    }

    /// Why Install on iPhone or iPad… is disabled for the Port, as help. Nil when it isn't.
    func installOnDevicesHelp(_ status: DeviceInstallStatus, for port: PortID) -> String? {
        guard case .disabled(let reason) = status.availability else { return nil }
        return help(reason, .install, for: port)
    }

    /// Why the Device can't take the prepared app, as its row in the sheet says: "Not connected", "Needs iOS 16 or
    /// later".
    func choiceText(_ reason: DeviceInstallStatus.Choice.Reason, for app: PreparedDeviceApp) -> String {
        switch reason {
        case .installed(let version): version == app.release.version ? "Installed" : "\(version) installed"
        case .away: "Not connected"
        case .developerModeOff: "Developer Mode is off"
        case .needsNewerIOS(let minimumOS): "Needs iOS \(Self.shortVersion(minimumOS)) or later"
        case .otherDevices(let families): families == [2] ? "iPad only" : families == [1] ? "iPhone only" : "Not for this Device"
        }
    }

    /// An iOS version as people say it: "16" for "16.0", and "16.4" as it is.
    static func shortVersion(_ version: String) -> String {
        let parts = version.split(separator: ".")
        return parts.dropFirst().allSatisfy { Int($0) == 0 } ? String(parts.first ?? "") : version
    }

    /// How the Device is reachable now: "Connected over USB", "Not connected".
    func connectionText(_ reading: DeviceReading) -> String {
        var parts: [String] = []
        switch reading.connection {
        case .wired: parts.append("Connected over USB")
        case .network: parts.append("Connected over Wi-Fi")
        case .away: parts.append("Not connected")
        }
        if reading.isReachable, reading.developerMode == false { parts.append("Developer Mode off") }
        if reading.isReachable, reading.isLocked == true { parts.append("Locked") }
        return parts.joined(separator: " · ")
    }
}
