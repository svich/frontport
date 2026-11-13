import AppKit
import FrontportCore
import SwiftUI

/// The Settings scene: where artwork comes from, the Catalogs, update checks, the Library location, and the Apple Team and
/// Devices that Ports are installed on iPhones and iPads with.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var isAddingCatalog = false

    private static let steamGridDB = URL(string: "https://www.steamgriddb.com")!

    var body: some View {
        Form {
            Section {
                LabeledContent("Source") {
                    Link("SteamGridDB", destination: Self.steamGridDB)
                }
            } header: {
                Text("Artwork")
            } footer: {
                Text("Covers, heroes, logos and icons come from SteamGridDB’s artists, through Frontport’s artwork server, with SteamGridDB’s permission. Frontport asks it only for the Games it shows.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                LabeledContent("Frontport") {
                    Text("Built in").foregroundStyle(.secondary)
                }
                ForEach(model.addedCatalogs) { summary in
                    AddedCatalogRow(summary: summary)
                }
                LabeledContent("") {
                    Button("Add Catalog…") { isAddingCatalog = true }
                        .accessibilityIdentifier("catalogs.add")
                }
            } header: {
                Text("Catalogs")
            } footer: {
                Text("Frontport’s own Catalog is always there. A Catalog you add is signed with its own key, which Frontport checks whenever it reads it. Removing one leaves the Ports you installed from it in your Library.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                LabeledContent("Checks", value: "At launch and every 6 hours while open")
                LabeledContent("Last Checked") {
                    Text(model.survey.lastChecked.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Not yet")
                }
                LabeledContent("") {
                    Button("Check Now") { Task { await model.refresh() } }
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("Frontport never updates a Port by itself. It takes a Snapshot of the Port’s Data before every update.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Location") {
                    Text(abbreviated(model.paths.library.path(percentEncoded: false)))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                LabeledContent("Port Data") {
                    Text(abbreviated(model.paths.containers.path(percentEncoded: false)))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                LabeledContent("") {
                    Button("Show in Finder") {
                        let url = model.paths.library
                        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } else {
                            NSWorkspace.shared.open(model.paths.root)
                        }
                    }
                }
            } header: {
                Text("Library")
            } footer: {
                Text("Each Port keeps its Data in a folder of its own that macOS manages. It survives uninstalling.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            DevicesSettings()
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle("Frontport Settings")
        .sheet(isPresented: $isAddingCatalog) {
            AddCatalogSheet()
                .environment(model)
        }
    }

    private func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

/// An added Catalog: its name, URL and Ports, why it couldn't be refreshed, and Remove.
private struct AddedCatalogRow: View {
    @Environment(AppModel.self) private var model
    let summary: CatalogSummary
    @State private var isConfirmingRemoval = false

    var body: some View {
        LabeledContent {
            Button("Remove…") { isConfirmingRemoval = true }
                .confirmationDialog(
                    "Remove “\(summary.name)”?", isPresented: $isConfirmingRemoval
                ) {
                    Button("Remove", role: .destructive) {
                        Task { await model.removeCatalog(summary.catalog.url) }
                    }
                } message: {
                    Text("Its Ports leave the Catalog. The ones you installed stay in your Library, without updates.")
                }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.name)
                Text(summary.catalog.url.absoluteString)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(Format.count(summary.ports.count, "Port"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let problem = summary.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityIdentifier("catalogs.row")
    }
}

/// The Apple Team that signs Ports for iPhones and iPads, whether Frontport Renews them on its own, and every Device
/// Frontport knows, with Forget… for one that's away. Reads the Devices every 10 seconds while it shows.
private struct DevicesSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let upkeep = model.deviceUpkeep
        Section {
            LabeledContent("Apple Team") {
                if upkeep.teams.isEmpty {
                    Text(upkeep.hasXcode == false ? "Needs Xcode" : "None on this Mac").foregroundStyle(.secondary)
                } else {
                    Picker("Apple Team", selection: Binding(
                        get: { upkeep.team?.id }, set: { upkeep.chosenTeam = $0 }
                    )) {
                        if upkeep.team == nil { Text("Choose…").tag(AppleTeamID?.none) }
                        ForEach(upkeep.teams) { team in
                            Text("\(team.name) (\(team.id.rawValue))").tag(Optional(team.id))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("devices.team")
                }
            }
            // On one row, so it runs once whatever the Form makes of the Section.
            .task { await upkeep.watch() }
            Toggle(isOn: Binding(get: { upkeep.renewsOnItsOwn }, set: { upkeep.renewsOnItsOwn = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Renew on its own")
                    Text("A Port on an iPhone or iPad stops launching when its signing expires. Frontport Renews it within 2 days of that, whenever the Device is connected and unlocked and Frontport is open.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityIdentifier("devices.renewOnItsOwn")
            if upkeep.hasXcode == false {
                Label("Installing on iPhone and iPad needs Xcode, with its iOS platform.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            ForEach(model.knownDevices, id: \.device.id) { reading in
                DeviceSettingsRow(reading: reading)
            }
        } header: {
            Text("Devices")
        } footer: {
            Text("Frontport signs the Ports it installs on iPhones and iPads with your Apple Team, which comes from the Apple Account you add in Xcode › Settings › Accounts. A Device you forget keeps its Ports and their Data.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A Device: its name, model and how it's connected, the Ports Frontport installed there, and Forget… while it's away.
private struct DeviceSettingsRow: View {
    @Environment(AppModel.self) private var model
    let reading: DeviceReading
    @State private var isConfirmingForget = false

    var body: some View {
        let device = reading.device
        let ports = model.survey.deviceInstallations(on: device.id)
        LabeledContent {
            if !reading.isReachable {
                Button("Forget…") { isConfirmingForget = true }
                    .accessibilityIdentifier("devices.forget.\(device.id.rawValue)")
                    .confirmationDialog("Forget “\(device.name)”?", isPresented: $isConfirmingForget) {
                        Button("Forget", role: .destructive) {
                            Task { await model.forget(device.id) }
                        }
                    } message: {
                        Text(ports.isEmpty
                            ? "Frontport finds it again once it’s connected."
                            : "Frontport forgets the Ports it installed there. They stay on \(device.name) with their Data, until you delete them there.")
                    }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                Text([device.model, device.osVersion.isEmpty ? nil : "iOS \(device.osVersion)", model.connectionText(reading)]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !ports.isEmpty {
                    Text(Format.count(ports.count, "Port"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .testContainer("devices.row.\(device.id.rawValue)")
    }
}

#if DEBUG
#Preview("Settings") {
    SettingsView()
        .previewEnvironment()
}
#endif
