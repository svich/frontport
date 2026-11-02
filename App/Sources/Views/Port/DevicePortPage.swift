import FrontportCore
import SwiftUI

/// A Port's page on one Device, apart from its page on this Mac so neither's actions are taken for the other's: the hero,
/// what the Device needs first (Update, Renew or Seed) beside the Release there, a change under way there, a row of
/// facts about its Installation there and its ROMs there, each action disabled with why on hover. Installing on this Mac
/// or on another Device, and Uninstall…, are in its More menu. While it shows, Frontport reads the Devices every 10
/// seconds, and what Seeding would copy to the Device when it first shows and when it comes or goes.
struct DevicePortPage: View {
    @Environment(AppModel.self) private var model
    let port: PortID
    let device: DeviceID

    var body: some View {
        Group {
            if let entry = model.survey.entry(port), let reading = model.deviceReading(device),
               case let status = model.deviceStatus(of: port, on: reading), status.state != .available {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        PortHeader(entry: entry)
                        DeviceActionRow(entry: entry, status: status)
                        if case .working(let activity) = status.state {
                            PortActivityCard(entry: entry, activity: activity)
                        }
                        DeviceFacts(entry: entry, status: status)
                            .padding(.vertical, 6)
                        DeviceROMs(entry: entry, status: status)
                        Text(footer(entry))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .padding(.bottom, 36)
                }
                .testContainer("screen.device.\(device.rawValue).port.\(port.rawValue)")
                .task(id: port) { await model.deviceUpkeep.watch() }
                .task(id: Reachable(port: port, isReachable: reading.isReachable)) {
                    await model.deviceUpkeep.readSeeding(of: port)
                }
            } else {
                ContentUnavailableView("Not on \(model.deviceName(device))", systemImage: "iphone.slash")
            }
        }
        .navigationTitle(model.survey.entry(port)?.name ?? port.rawValue)
        .navigationSubtitle(model.deviceName(device))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back", systemImage: "chevron.left") { model.back() }
                    .disabled(!model.canGoBack)
                    .help("Back")
            }
            ToolbarItem(placement: .primaryAction) {
                DeviceMenu(port: port, device: device)
            }
        }
    }

    private func footer(_ entry: CatalogEntry) -> String {
        if model.deviceUpkeep.hasXcode == false {
            return "\(model.help(.needsXcode, .uninstall, for: entry.id)). Frontport finds it once it’s installed."
        }
        let renews = model.deviceUpkeep.renewsOnItsOwn ? ", and Renews it there before it stops launching" : ""
        return "Frontport installs \(entry.name)’s iOS version from this Mac\(renews). Uninstalling it removes its Data "
            + "there too."
    }

    /// Whether the Device can be reached: what Seeding is read again for when it changes.
    private struct Reachable: Hashable {
        var port: PortID
        var isReachable: Bool
    }
}

/// What the Device needs first and anything else it needs but Seed, which Device it is, and the store page.
private struct DeviceActionRow: View {
    @Environment(AppModel.self) private var model
    let entry: CatalogEntry
    let status: DeviceStatus

    var body: some View {
        HStack(spacing: 18) {
            if let action = status.primary {
                DeviceActionButton(entry: entry, status: status, action: action, isPrimary: true)
            }
            // Renew beside an Update; Seed waits beside its ROM, Uninstall… in the More menu.
            ForEach(status.actions.filter { $0 != status.primary && $0 != .seed && $0 != .uninstall }, id: \.self) { action in
                DeviceActionButton(entry: entry, status: status, action: action, isSecondary: true)
            }
            // Its Release is the first fact under the row.
            Text("On \(status.reading.device.name)").foregroundStyle(.secondary)
            Spacer()
            StorePageButton(entry: entry)
        }
    }
}

/// One of the Port's actions on the Device: large and prominent as the one it needs first, large beside it as another
/// it needs, small beside the ROM it's about.
private struct DeviceActionButton: View {
    @Environment(AppModel.self) private var model
    @Environment(ViewState.self) private var viewState
    let entry: CatalogEntry
    let status: DeviceStatus
    let action: DeviceStatus.Action
    var isPrimary = false
    /// Beside the one it needs first, as large but not prominent.
    var isSecondary = false

    var body: some View {
        let title = switch action {
        case .update: model.updateTitle(status)
        case .renew: "Renew"
        case .seed: model.seedTitle(status)
        case .uninstall: "Uninstall…"
        }
        let button = Button(title) { viewState.run(action, for: entry.id, on: status.reading.device.id, in: model) }
            .disabled(!status.allows(action))
            .help(model.help(action, status, for: entry.id) ?? "")
            .accessibilityIdentifier("device.\(action).\(status.reading.device.id.rawValue)")
        if isPrimary {
            button.buttonStyle(.glassProminent).controlSize(.extraLarge)
        } else if isSecondary {
            button.buttonStyle(.glass).controlSize(.extraLarge)
        } else {
            button.buttonStyle(.glass).controlSize(.small)
                .tint(action == .update || (action == .renew && status.isExpired) ? .accentColor : nil)
        }
    }
}

/// The Installation on the Device at a glance: its Release and when it was installed, how long it launches, how the
/// Device is connected, which it is, and its ROMs there.
private struct DeviceFacts: View {
    @Environment(AppModel.self) private var model
    let entry: CatalogEntry
    let status: DeviceStatus

    var body: some View {
        FactRow(facts: facts)
    }

    private var facts: [Fact] {
        let udid = status.reading.device.id.rawValue
        var facts: [Fact] = []
        if let installation = status.installation {
            facts.append(Fact(
                caption: "Release", value: .text(installation.release.version),
                detail: "Installed \(Format.shortDate(installation.installedAt))", valueID: "device.release.\(udid)"))
            let renew = model.renewText(status)
            facts.append(Fact(
                caption: "Signed until", value: .text(Format.shortDate(installation.expires)),
                detail: renew ?? (model.deviceUpkeep.renewsOnItsOwn ? "Renewed on its own" : "Then Renew it"),
                tint: renew == nil ? nil : .orange, help: renew,
                valueID: "device.signed.\(udid)", detailID: renew == nil ? nil : "device.renewal.\(udid)"))
        }
        let reading = status.reading
        let connection = switch reading.connection {
        case .wired: ("cable.connector", "USB")
        case .network: ("wifi", "Wi-Fi")
        case .away: ("wifi.slash", "Not connected")
        }
        facts.append(Fact(
            caption: "Connection", value: .symbol(connection.0), detail: connection.1,
            tint: reading.isReachable ? nil : .orange, help: model.connectionText(reading)))
        facts.append(Fact(
            caption: reading.device.isPad ? "iPad" : "iPhone", value: .symbol(reading.device.isPad ? "ipad" : "iphone"),
            detail: reading.device.model.isEmpty ? reading.device.name : reading.device.model))
        let items = status.matching?.requirements ?? []
        let notThere = items.filter { $0.state != .seeded }.count
        if items.isEmpty {
            facts.append(Fact(caption: "ROM", value: .symbol("checkmark.circle"), detail: "None needed"))
        } else if notThere == 0 {
            facts.append(Fact(caption: items.count == 1 ? "ROM" : "ROMs", value: .symbol("checkmark.circle.fill"), detail: "Seeded", tint: .green))
        } else {
            facts.append(Fact(
                caption: items.count == 1 ? "ROM" : "ROMs", value: .text("\(notThere)"), detail: "Not there yet", tint: .orange))
        }
        return facts
    }
}

/// Where each ROM the iOS version Seeds stands on the Device, with Add… for one not in ROMs and Seed or Try Again for
/// one not there yet, then where Seeding there stands while anything isn't there.
private struct DeviceROMs: View {
    @Environment(AppModel.self) private var model
    let entry: CatalogEntry
    let status: DeviceStatus

    var body: some View {
        let items = status.matching?.requirements ?? []
        let firstUnseeded = items.first { $0.state == .unseeded }?.id
        VStack(alignment: .leading, spacing: 8) {
            GroupedSection("ROMs") {
                if items.isEmpty {
                    GroupedRow("Needs no ROM", value: "")
                }
                ForEach(items) { item in
                    GroupedRow(item.requirement.label) {
                        switch item.state {
                        case .seeded:
                            Label("Seeded", systemImage: "checkmark")
                                .foregroundStyle(.green)
                                .accessibilityIdentifier("device.seeded.\(status.reading.device.id.rawValue)")
                        case .missing:
                            Button("Add…") { model.open(.roms) }
                                .buttonStyle(.glass)
                                .controlSize(.small)
                        case .unseeded:
                            HStack(spacing: 10) {
                                Label("Not Seeded", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                                if item.id == firstUnseeded, status.actions.contains(.seed), status.primary != .seed {
                                    DeviceActionButton(entry: entry, status: status, action: .seed)
                                }
                            }
                        case .held:
                            Label("Holds another ROM", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                    }
                }
            }
            if let seeding = model.seedingText(status, for: entry.id), !isAllSeeded {
                Text(seeding)
                    .font(.callout)
                    .foregroundStyle(status.matching?.hasUnseeded == true ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .accessibilityIdentifier("device.seeding.\(status.reading.device.id.rawValue)")
            }
        }
    }

    /// Every ROM is there, as the rows say, and not only as last known.
    private var isAllSeeded: Bool {
        if case .seeded(_, isLastKnown: false)? = status.seeding { true } else { false }
    }
}

/// Installing elsewhere, Uninstall… from the Device, the Port's page on this Mac while it's here, and the store page.
private struct DeviceMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(ViewState.self) private var viewState
    let port: PortID
    let device: DeviceID

    var body: some View {
        Menu {
            InstallItems(port: port)
            Divider()
            if let reading = model.deviceReading(device), case let status = model.deviceStatus(of: port, on: reading),
               status.actions.contains(.uninstall) {
                Button("Uninstall from \(reading.device.name)…") { viewState.run(.uninstall, for: port, on: device, in: model) }
                    .disabled(!status.allows(.uninstall))
                    .accessibilityIdentifier("device.uninstall.\(device.rawValue)")
                Divider()
            }
            if model.survey.installation(port) != nil {
                Button("Open on This Mac") { model.open(.port(port)) }
            }
            if model.survey.isListed(port) {
                Button("Store Page") { model.open(.store(port)) }
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .menuIndicator(.hidden)
        .help("More")
        .accessibilityIdentifier("port.more")
    }
}

extension DeviceStatus {
    /// The Port's Installation on the Device, while no change is under way there.
    var installation: DeviceInstallation? {
        if case .installed(let installation) = state { installation } else { nil }
    }

    /// What the Device needs first, which its page leads with: Update, Renew or Seed. Nil while it needs nothing.
    var primary: Action? { actions.first { $0 != .uninstall } }
}

#if DEBUG
#Preview("Port on iPhone") {
    ScreenPreview(.port("ghostship"))
}

#Preview("Port on iPad · Update, Renew and Seed due") {
    let data = PreviewData.standard()
    ScreenPreview(.portOnDevice("ghostship", data.deviceInstallations[1].device), data: data)
}
#endif
