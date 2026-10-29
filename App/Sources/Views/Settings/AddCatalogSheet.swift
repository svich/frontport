import FrontportCore
import SwiftUI

/// Adds a Catalog from the link or URL its own page gives: checks it first and shows its name, key and Ports, then adds
/// it once the user confirms (ADR 0012). A `frontport://add-catalog` link opens it already filled in.
struct AddCatalogSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var summary: CatalogSummary?
    @State private var problem: String?
    @State private var isWorking = false
    private let checksAtOnce: Bool

    init(link: URL? = nil) {
        _text = State(initialValue: link?.absoluteString ?? "")
        checksAtOnce = link != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add a Catalog").font(.title2.bold())
                Text("Paste the link or URL a Catalog’s page gives. Frontport checks the Catalog’s signature before adding it.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                TextField("Link", text: $text, prompt: Text("https://…"))
                    .labelsHidden()
                    .onSubmit(check)
                    .accessibilityIdentifier("addCatalog.link")
                Button("Check", action: check)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
                    .accessibilityIdentifier("addCatalog.check")
            }
            .onChange(of: text) {
                summary = nil
                problem = nil
            }
            if isWorking {
                ProgressView().controlSize(.small)
            } else if let summary {
                details(summary)
            } else if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("addCatalog.problem")
            }
            Text("Frontport doesn’t review the Catalogs you add. Their Ports run in the sandbox with the Permissions you see before installing, and their Recipes in the build sandbox. Add only Catalogs from people you trust.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Catalog", action: add)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(summary == nil || isWorking)
                    .accessibilityIdentifier("addCatalog.add")
            }
        }
        .padding(24)
        .frame(width: 520)
        .task {
            if checksAtOnce { check() }
        }
    }

    private func details(_ summary: CatalogSummary) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("Name").foregroundStyle(.secondary)
                Text(summary.name).fontWeight(.semibold)
                    .accessibilityIdentifier("addCatalog.name")
            }
            GridRow {
                Text("URL").foregroundStyle(.secondary)
                Text(summary.catalog.url.absoluteString)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            GridRow {
                Text("Key").foregroundStyle(.secondary)
                Text(summary.catalog.fingerprint)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .help("The fingerprint of the key the Catalog is signed with. Frontport checks every later version against it.")
            }
            GridRow {
                Text("Ports").foregroundStyle(.secondary)
                Text(summary.ports.isEmpty ? "None" : summary.ports.formatted(.list(type: .and)))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func check() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let link = URL(string: trimmed), !trimmed.isEmpty else {
            problem = "That isn’t a link."
            return
        }
        isWorking = true
        summary = nil
        problem = nil
        Task {
            do {
                summary = try await model.previewCatalog(link)
            } catch {
                problem = Self.describe(error)
            }
            isWorking = false
        }
    }

    private func add() {
        guard let summary else { return }
        isWorking = true
        Task {
            do {
                try await model.addCatalog(summary.catalog)
                dismiss()
            } catch {
                self.summary = nil
                problem = Self.describe(error)
            }
            isWorking = false
        }
    }

    private static func describe(_ error: any Error) -> String {
        (error as? FrontportError)?.errorDescription ?? error.localizedDescription
    }
}

#if DEBUG
#Preview("Add Catalog") {
    AddCatalogSheet()
        .previewEnvironment(PreviewData.standard())
}
#endif
