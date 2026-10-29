import FrontportCore
import SwiftUI

/// What happened to each file of an Add ROMs…: added, already there, not in the Catalog, or rejected with its hash. A
/// file the Catalog doesn't list but could be offers the ROMs it can be kept as, Unverified.
struct IntakeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(ViewState.self) private var viewState
    @Environment(\.dismiss) private var dismiss
    let report: ViewState.IntakeReport

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.bold())
                    .accessibilityIdentifier("intake.title")
                Text(summary).foregroundStyle(.secondary)
            }
            ScrollView {
                GroupedSection {
                    ForEach(Array(results.enumerated()), id: \.offset) { index, result in
                        IntakeRow(result: result) { sha1 in
                            await viewState.keep(index, of: report.id, as: sha1, in: model)
                        }
                    }
                }
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
            if unknown > 0 {
                Text("A file the Catalog doesn’t list, such as an NSZ, can be kept as the ROM you choose. It stays Unverified: if it isn’t that ROM, the Port fails to build or run.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if rejected > 0 {
                Text("Frontport accepts a ROM only when the Catalog lists its hash.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier("intake.done")
            }
        }
        .padding(24)
        .frame(width: 520)
        .testContainer("intake.sheet")
    }

    /// The report as it is now: keeping a file replaces its result.
    private var results: [ROMIntake] {
        viewState.intakeReport?.id == report.id ? viewState.intakeReport?.results ?? report.results : report.results
    }

    private var added: Int { results.count { if case .added = $0 { true } else { false } } }
    private var rejected: Int { results.count { if case .rejected = $0 { true } else { false } } }
    private var unknown: Int { results.count { if case .unknown = $0 { true } else { false } } }

    private var title: String {
        if added > 0 { return "Added \(Format.count(added, "ROM"))" }
        if unknown > 0 { return "Not in the Catalog" }
        return rejected > 0 ? "No ROMs Added" : "Already in ROMs"
    }

    private var summary: String {
        var parts: [String] = []
        if added > 0 { parts.append("\(added) added") }
        let duplicates = results.count - added - rejected - unknown
        if duplicates > 0 { parts.append("\(duplicates) already in ROMs") }
        if unknown > 0 { parts.append("\(unknown) not in the Catalog") }
        if rejected > 0 { parts.append("\(rejected) not accepted") }
        return parts.joined(separator: " · ")
    }
}

private struct IntakeRow: View {
    @Environment(AppModel.self) private var model
    let result: ROMIntake
    /// Keeps the row's file as the ROM with this SHA-1, Unverified.
    let keep: (String) async -> Void
    @State private var choice: String?
    @State private var isKeeping = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon
                .font(.title3)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                switch result {
                case .added(let record):
                    Text(name(of: record)).fontWeight(.semibold)
                    Text("\(record.isUnverified ? "Added as Unverified" : "Added") · \(record.originalFilename)")
                        .font(.callout).foregroundStyle(.secondary)
                    let ports = model.ports(using: record.sha1)
                    if !ports.isEmpty {
                        Text("For \(ports.map(\.name).formatted(.list(type: .and)))")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                case .duplicate(let record):
                    Text(name(of: record)).fontWeight(.semibold)
                    Text("Already in ROMs · \(record.originalFilename)").font(.callout).foregroundStyle(.secondary)
                case .unknown(let file, let sha1, let format, let reason):
                    Text(file.lastPathComponent).fontWeight(.semibold)
                    Text(reason).font(.callout).foregroundStyle(.secondary)
                    hash(sha1)
                    choose(among: model.assignable(format: format))
                        .padding(.top, 4)
                case .rejected(let file, let sha1, let reason):
                    Text(file.lastPathComponent).fontWeight(.semibold)
                    Text(reason).font(.callout).foregroundStyle(.secondary)
                    if let sha1 { hash(sha1) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .testContainer("intake.\(outcome)")
    }

    private func hash(_ sha1: String) -> some View {
        Text("SHA-1 \(sha1)")
            .font(.callout.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .accessibilityIdentifier("intake.sha1")
    }

    /// A menu of the ROMs the file can be kept as, and the button that keeps it.
    private func choose(among roms: [KnownROM]) -> some View {
        HStack(spacing: 8) {
            Picker("Keep as", selection: $choice) {
                Text("Choose a ROM").tag(String?.none)
                ForEach(roms) { rom in
                    Text("\(model.owner(of: rom)) · \(rom.name)").tag(Optional(rom.sha1))
                }
            }
            .labelsHidden()
            .accessibilityIdentifier("intake.choice")
            Button("Keep Unverified") {
                guard let choice else { return }
                isKeeping = true
                Task {
                    await keep(choice)
                    isKeeping = false
                }
            }
            .buttonStyle(.glass)
            .disabled(choice == nil || isKeeping)
            .accessibilityIdentifier("intake.keep")
            if isKeeping { ProgressView().controlSize(.small) }
        }
    }

    /// "added", "duplicate", "unknown" or "rejected".
    private var outcome: String {
        switch result {
        case .added: "added"
        case .duplicate: "duplicate"
        case .unknown: "unknown"
        case .rejected: "rejected"
        }
    }

    @ViewBuilder private var icon: some View {
        switch result {
        case .added(let record) where record.isUnverified:
            Image(systemName: "checkmark.circle.trianglebadge.exclamationmark").foregroundStyle(.orange)
        case .added: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .duplicate: Image(systemName: "equal.circle.fill").foregroundStyle(.secondary)
        case .unknown: Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
        case .rejected: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private func name(of record: ROMRecord) -> String {
        "\(model.owner(of: record)) · \(record.name)"
    }
}

#if DEBUG
#Preview("Intake") {
    let data = PreviewData.standard()
    IntakeSheet(report: .sample(data.roms))
        .previewEnvironment(data)
}
#endif
