import FrontportCore
import SwiftUI

/// "Install Ghostship on…": once a Port's iOS version is downloaded, every Device Frontport knows with a checkbox, and
/// why one that can't take it can't: away, Developer Mode off, too old an iOS, the other kind of Device, or the Port
/// there already. The only Device that can is chosen to start with. The Devices are read again every 10 seconds while
/// it shows, so one plugged in meanwhile can be chosen. Install installs on each chosen one, one after another; Cancel
/// keeps the download for next time.
struct DevicePickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let picker: AppModel.DevicePicker
    @State private var chosen: Set<DeviceID> = []

    var body: some View {
        let choices = DeviceInstallStatus.choices(
            for: picker.app, readings: model.knownDevices, installations: model.survey.deviceInstallations(of: picker.port))
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Install \(name) on…").font(.title2.bold())
                    .accessibilityIdentifier("devicePicker.title")
                Text(summary).foregroundStyle(.secondary)
            }
            GroupedSection {
                ForEach(choices) { choice in
                    ChoiceRow(choice: choice, app: picker.app, isChosen: binding(for: choice))
                }
            }
            // Why Install can't be taken, when a reading since it opened says so, such as Xcode gone.
            Text(model.installHelp(picker.port) ?? "Frontport signs it for each Device you choose and installs it on them one after another. Connect another, and it shows here within seconds.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("devicePicker.footer")
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("devicePicker.cancel")
                Button("Install") {
                    // Kept open when nothing was installed, so the line above says why.
                    if model.deviceUpkeep.install(picker.port, prepared: picker.app, on: chosen) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(chosen.isEmpty || !model.canInstall(picker.port))
                .accessibilityIdentifier("devicePicker.install")
            }
        }
        .padding(24)
        .frame(width: 480)
        .onChange(of: choices.filter(\.isEligible).map(\.id), initial: true) {
            chosen = DeviceInstallStatus.chosen(chosen, among: choices)
        }
        // Only while it shows.
        .task { await model.deviceUpkeep.watch() }
        .testContainer("devicePicker.sheet")
    }

    private var name: String { model.survey.entry(picker.port)?.name ?? picker.port.rawValue }

    /// "3.0.0 · For iPhone and iPad with iOS 16 or later".
    private var summary: String {
        let devices = switch Set(picker.app.families) {
        case [1]: "iPhone"
        case [2]: "iPad"
        default: "iPhone and iPad"
        }
        return "\(picker.app.release.version) · For \(devices) with iOS \(AppModel.shortVersion(picker.app.minimumOS)) or later"
    }

    /// Chosen or not; one that can't take the app is never chosen.
    private func binding(for choice: DeviceInstallStatus.Choice) -> Binding<Bool> {
        Binding(
            get: { choice.isEligible && chosen.contains(choice.id) },
            set: { isOn in
                if isOn, choice.isEligible { chosen.insert(choice.id) } else { chosen.remove(choice.id) }
            })
    }
}

/// One Device: a checkbox with its name and model, and how it's connected or why it can't take the app. Clicking the
/// name chooses it too.
private struct ChoiceRow: View {
    @Environment(AppModel.self) private var model
    let choice: DeviceInstallStatus.Choice
    let app: PreparedDeviceApp
    @Binding var isChosen: Bool

    var body: some View {
        let device = choice.reading.device
        GroupedRow {
            HStack(spacing: 10) {
                // Its own element, apart from the text beside it, so each can be read on its own.
                Toggle(device.name, isOn: $isChosen)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(!choice.isEligible)
                    .accessibilityIdentifier("devicePicker.device.\(device.id.rawValue)")
                Image(systemName: device.isPad ? "ipad" : "iphone")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 0) {
                        Text(device.name)
                        if !device.model.isEmpty {
                            Text(" · \(device.model)").foregroundStyle(.secondary)
                        }
                    }
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("devicePicker.detail.\(device.id.rawValue)")
                }
                .opacity(choice.isEligible ? 1 : 0.6)
            }
            .contentShape(Rectangle())
            .onTapGesture { if choice.isEligible { isChosen.toggle() } }
        } trailing: {
            EmptyView()
        }
    }

    /// "Connected over Wi-Fi", or why it can't take the app: "Installed · Connected over USB", "Not connected".
    private var detail: String {
        let connection = model.connectionText(choice.reading)
        guard let reason = choice.reason else { return connection }
        switch reason {
        // The connection says so already.
        case .away, .developerModeOff: return connection
        default: return "\(model.choiceText(reason, for: app)) · \(connection)"
        }
    }
}
