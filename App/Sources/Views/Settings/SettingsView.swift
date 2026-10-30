import AppKit
import FrontportCore
import SwiftUI

/// The Settings scene: SteamGridDB artwork, the Catalogs, update checks and the Library location.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var key = ""
    @State private var isSaving = false
    @State private var isAddingCatalog = false

    private static let apiKeyPage = URL(string: "https://www.steamgriddb.com/profile/preferences/api")!

    var body: some View {
        Form {
            Section {
                LabeledContent("API Key") {
                    HStack(spacing: 8) {
                        SecureField("API Key", text: $key, prompt: Text(model.steamGridDBKey == .user ? "Saved in your Keychain" : "Paste your key"))
                            .labelsHidden()
                            .onSubmit(save)
                        Button("Save", action: save)
                            .disabled(key.isEmpty || isSaving)
                    }
                }
                switch model.steamGridDBKey {
                case .user:
                    LabeledContent("Status") {
                        HStack(spacing: 10) {
                            Label("Saved in your Keychain", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Button("Remove") {
                                Task { await model.setSteamGridDBKey(nil) }
                            }
                        }
                    }
                case .builtIn:
                    LabeledContent("Status") {
                        Label("Using Frontport’s key", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                case nil:
                    EmptyView()
                }
                Link(destination: Self.apiKeyPage) {
                    Label("Get an API key on steamgriddb.com", systemImage: "arrow.up.forward.square")
                }
            } header: {
                Text("Artwork")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Covers, heroes, logos and icons come from SteamGridDB. Frontport fetches artwork only for this Mac, and never shares your key.")
                    if model.steamGridDBKey == .builtIn {
                        Text("This copy of Frontport comes with a key of its own. Save yours to use it instead.")
                    } else {
                        Text("Without a key, Ports show a flat color with the Game’s name.")
                    }
                    Text("SteamGridDB allows personal, non-commercial use only.")
                }
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

    private func save() {
        guard !key.isEmpty else { return }
        isSaving = true
        Task {
            await model.setSteamGridDBKey(key)
            key = ""
            isSaving = false
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

#if DEBUG
#Preview("Settings") {
    SettingsView()
        .previewEnvironment()
}
#endif
