import FrontportCore
import SwiftUI

/// The Port page's Snapshots: one per change of Release, with Restore… and Roll Back.
struct SnapshotsList: View {
    @Environment(AppModel.self) private var model
    @Environment(ViewState.self) private var viewState
    let entry: CatalogEntry

    var body: some View {
        let snapshots = model.snapshots[entry.id] ?? []
        let installation = model.survey.installation(entry.id)
        let rollback = model.rollbackSnapshot(for: entry.id)
        let status = model.status(of: entry.id)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom, spacing: 12) {
                PageHeader(
                    title: "Snapshots",
                    subtitle: "Taken before every change of Release. Frontport keeps the last 3.")
                if status.check(.rollBack) != .unavailable {
                    Button(status.title(.rollBack)) { viewState.run(.rollBack, for: entry.id, in: model) }
                        .buttonStyle(.glass)
                        .disabled(!status.allows(.rollBack))
                        .help(model.help(.rollBack, for: entry.id) ?? "")
                }
            }
            if snapshots.isEmpty {
                ContentUnavailableView(
                    "No Snapshots Yet", systemImage: "clock.arrow.circlepath",
                    description: Text("Frontport takes one before \(entry.name) changes Release."))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else {
                GroupedSection {
                    ForEach(snapshots) { snapshot in
                        GroupedRow {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(snapshot.title).fontWeight(.semibold)
                                Text(detail(snapshot, isRollback: snapshot == rollback))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        } trailing: {
                            HStack(spacing: 8) {
                                Button(status.title(.restore)) { confirm(.restore(snapshot)) }
                                    .disabled(!status.allows(.restore))
                                    .help(model.help(.restore, for: entry.id) ?? "")
                                Button("Show in Finder") { model.revealSnapshot(snapshot) }
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            if let previous = installation?.previous, let current = installation?.release, let rollback,
                model.survey.knowsEntry(entry.id)
            {
                VStack(alignment: .leading, spacing: 8) {
                    Text("What Roll Back does").font(.headline)
                    VStack(alignment: .leading, spacing: 4) {
                        step(1, "Takes a Snapshot of your current Data, so nothing since \(current.version) is lost.")
                        step(2, "Restores “\(rollback.title)”.")
                        step(3, "Returns \(entry.name) to \(previous.version).")
                    }
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.separator.opacity(0.6), lineWidth: 1)
                }
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .testContainer("port.snapshots")
    }

    private func confirm(_ action: PortConfirmation.Action) {
        viewState.confirm(action, for: entry.id, in: model)
    }

    private func detail(_ snapshot: Snapshot, isRollback: Bool) -> String {
        var parts = [Format.date(snapshot.created)]
        if let size = snapshot.size { parts.append(Format.bytes(size)) }
        switch snapshot.reason {
        case .update: break
        case .rollback: parts.append("before a Roll Back")
        case .channelSwitch: parts.append("before a Channel switch")
        case .restore: parts.append("before a restore")
        }
        if isRollback { parts.append("used by Roll Back") }
        return parts.joined(separator: " · ")
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).").monospacedDigit()
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The Port page's Runs: the last 5 launches with how each ended and its log.
struct RunsList: View {
    @Environment(AppModel.self) private var model
    let entry: CatalogEntry

    var body: some View {
        let runs = model.runs[entry.id] ?? []
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom, spacing: 12) {
                PageHeader(title: "Runs", subtitle: "Output from each launch. Frontport keeps the last 5.")
                Button("Show Logs in Finder") { model.openLogs(for: entry.id) }
                    .buttonStyle(.glass)
            }
            if runs.isEmpty {
                ContentUnavailableView(
                    "No Runs Yet", systemImage: "play.square.stack",
                    description: Text("Each time \(entry.name) opens, its output is kept here."))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else {
                GroupedSection {
                    ForEach(runs) { run in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(Format.shortDate(run.started)).fontWeight(.semibold)
                                Text(run.started.formatted(date: .omitted, time: .shortened))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 90, alignment: .leading)
                            Text(run.release)
                                .monospacedDigit()
                                .frame(width: 70, alignment: .leading)
                            outcome(run)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Open Log") { model.openLog(run) }
                                .buttonStyle(.link)
                                .accessibilityIdentifier("run.openLog")
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                    }
                }
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .testContainer("port.runs")
    }

    @ViewBuilder private func outcome(_ run: Run) -> some View {
        if run.isRunning {
            HStack(spacing: 6) {
                Circle().fill(.green).frame(width: 7, height: 7)
                Text("Running")
            }
            .foregroundStyle(.green)
        } else {
            let duration = run.duration.map(Format.duration) ?? ""
            let ending: String =
                if run.signaled {
                    "Crashed (signal \(run.exitStatus ?? 0))"
                } else if let status = run.exitStatus, status != 0 {
                    "Exited with status \(status)"
                } else {
                    "Quit"
                }
            Text([duration, ending].filter { !$0.isEmpty }.joined(separator: " · "))
                .foregroundStyle(run.crashed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        }
    }
}

/// A large in-page title with a line under it.
struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 22, weight: .bold))
            Text(subtitle).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
