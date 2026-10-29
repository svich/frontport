import FrontportCore
import SwiftUI

/// The Port page's Overview: header art, Play, the update, About, ROMs, Permissions and Storage.
struct PortOverview: View {
    @Environment(AppModel.self) private var model
    let entry: CatalogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Header(entry: entry)
            ActionRow(entry: entry)
            if let activity = model.activities[entry.id] {
                ActivityCard(entry: entry, activity: activity)
            } else if let snapshot = model.switchSnapshots[entry.id] {
                SwitchCallout(entry: entry, snapshot: snapshot)
            } else if let update = model.survey.updates[entry.id] {
                UpdateCallout(entry: entry, release: update)
            }
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 22) {
                    AboutSection(entry: entry)
                    if model.survey.knowsEntry(entry.id) {
                        PortROMs(entry: entry)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 22) {
                    PermissionToggles(entry: entry)
                    StorageSection(entry: entry)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .testContainer("port.overview")
    }
}

/// Hero art with the logo as the title, and "Game · Kind · by Developer".
private struct Header: View {
    @Environment(AppModel.self) private var model
    let entry: CatalogEntry

    var body: some View {
        ArtworkImage(.hero, port: entry.id)
            .aspectRatio(1920 / 620, contentMode: .fit)
            .frame(minHeight: 220)
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 10) {
                    ArtworkImage(.logo, port: entry.id)
                        .frame(maxWidth: 440, maxHeight: 150, alignment: .bottomLeading)
                        .accessibilityLabel(entry.name)
                        .accessibilityAddTraits(.isHeader)
                    Text(model.bylineLine(for: entry))
                        .font(.body.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.55), in: Capsule())
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Play (or Stop, Add ROM…, Cancel), the installed Release and when it was last played, and the store page.
private struct ActionRow: View {
    @Environment(AppModel.self) private var model
    let entry: CatalogEntry

    var body: some View {
        HStack(spacing: 18) {
            PortActionButton(port: entry.id, controlSize: .extraLarge, playsWhenUpdatable: true)
            VStack(alignment: .leading, spacing: 1) {
                if let installation = model.survey.installation(entry.id) {
                    Text(installation.release.version)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                    if let played = model.playedText(for: entry.id) {
                        Text(played).font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("Not played yet").font(.callout).foregroundStyle(.secondary)
                    }
                } else if let release = model.survey.latestRelease(for: entry.id) {
                    Text(release.version).fontWeight(.semibold).monospacedDigit()
                    Text("Not installed yet").font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.survey.isListed(entry.id) {
                Button {
                    model.open(.store(entry.id))
                } label: {
                    Label("Store Page", systemImage: "book")
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("port.storePage")
            }
        }
    }
}

private struct ActivityCard: View {
    @Environment(AppModel.self) private var model
    let entry: CatalogEntry
    let activity: Activity

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(model.activityText(activity, for: entry.id))
                        .font(.headline)
                    Spacer()
                    if let fraction = activity.progress.fraction {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: activity.progress.fraction)
                    .progressViewStyle(.linear)
                if let message = activity.progress.message {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .calloutBackground(.accentColor)
    }

    private var symbol: String {
        if activity.isBuilding { return "hammer" }
        switch activity.kind {
        case .install, .update, .switchChannel: return "arrow.down.circle"
        case .rollback, .restore: return "clock.arrow.circlepath"
        case .permissions: return "lock.shield"
        case .applyROMs: return "sdcard"
        case .uninstall, .deleteData, .removeBuildFolder: return "trash"
        }
    }
}

/// After a Channel switch landed on an older Release: offers the Snapshot from before it, in case the Data doesn't
/// load.
private struct SwitchCallout: View {
    @Environment(AppModel.self) private var model
    @Environment(ViewState.self) private var viewState
    let entry: CatalogEntry
    let snapshot: Snapshot

    var body: some View {
        let installation = model.survey.installation(entry.id)
        HStack(spacing: 14) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 26))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(["Now on \(installation?.channel.name ?? "")", installation?.release.version]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.headline)
                Text("It’s older than the Release you had, so \(entry.name) may not load your Data. If it doesn’t, restore the Snapshot from before the switch.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                Button("Dismiss") { model.dismissSwitchSnapshot(for: entry.id) }
                    .buttonStyle(.glass)
                Button("Restore “\(snapshot.title)”…") {
                    viewState.confirm(.restore(snapshot), for: entry.id, in: model)
                }
                .buttonStyle(.glassProminent)
                .disabled(!model.status(of: entry.id).allows(.restore))
                .help(model.help(.restore, for: entry.id) ?? "")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .calloutBackground(.orange)
    }
}

private struct UpdateCallout: View {
    @Environment(AppModel.self) private var model
    @Environment(ViewState.self) private var viewState
    let entry: CatalogEntry
    let release: Release

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 26))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(release.displayName) is available")
                    .font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 14) {
                if let url = release.notesURL {
                    Link("Release Notes", destination: url)
                }
                let status = model.status(of: entry.id)
                Button(status.title(.update)) { viewState.run(.update, for: entry.id, in: model) }
                    .buttonStyle(.glassProminent)
                    .disabled(!status.allows(.update))
                    .help(model.help(.update, for: entry.id) ?? "")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .calloutBackground(.accentColor)
    }

    private var detail: String {
        let released = release.published.map { "Released \(Format.shortDate($0)). " } ?? ""
        return released + "Frontport takes a Snapshot of your Data first, so you can roll back."
    }
}

private struct AboutSection: View {
    @Environment(AppModel.self) private var model
    @Environment(ViewState.self) private var viewState
    let entry: CatalogEntry

    var body: some View {
        GroupedSection("About", footer: footer) {
            if model.survey.isListed(entry.id) {
                GroupedRow("Kind", value: entry.kind.name)
                GroupedRow("Game", value: model.gameName(for: entry))
                if let platform = model.survey.platform(for: entry) {
                    GroupedRow("Platform", value: platform.name)
                }
                GroupedRow("Source") {
                    Link(entry.source.shortDisplay, destination: entry.source)
                }
            } else {
                GroupedRow("Catalog", value: "Not listed")
            }
            if let installation = model.survey.installation(entry.id) {
                GroupedRow("Channel") {
                    Picker("Channel", selection: Binding(
                        get: { installation.channel },
                        set: { viewState.confirmSwitch(entry.id, to: $0, in: model) }
                    )) {
                        ForEach(entry.channels, id: \.self) { Text($0.name).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .disabled(!model.status(of: entry.id).allows(.switchChannel))
                    .help(channelHelp)
                }
            }
        }
    }

    private var footer: String? {
        guard !model.survey.isListed(entry.id) else { return nil }
        let actions = model.survey.knowsEntry(entry.id)
            ? "play it, change its Permissions, roll it back, uninstall it or delete its Data"
            : "play it, uninstall it or delete its Data"
        return "The Catalog no longer lists \(entry.name), so it gets no updates. You can still \(actions)."
    }

    private var channelHelp: String {
        if entry.channels.count < 2 { return "This Port has one Channel" }
        return model.help(.switchChannel, for: entry.id) ?? "Releases this Port follows"
    }
}

/// Whether each Requirement and extra is satisfied and, once installed, Seeded, with Add… for what's missing and
/// Try Again for ROMs that aren't Seeded.
private struct PortROMs: View {
    @Environment(AppModel.self) private var model
    let entry: CatalogEntry

    var body: some View {
        let matching = model.survey.matching(for: entry.id)
        GroupedSection("ROMs", footer: footer(hasUnseeded: !matching.unseeded.isEmpty)) {
            if entry.requirements.isEmpty {
                GroupedRow("Needs no ROM", value: "")
            }
            ForEach(matching.requirements) { state in
                row(state.requirement.label, state.accepted)
                ForEach(model.knownROMs(state.requirement.extras)) { extra in
                    row(extra.name, state.extras[extra.sha1] ?? .missing, isOptional: true)
                }
            }
        }
    }

    /// Seeding waits for a running Port to quit.
    private var isWaiting: Bool { model.isWaitingToSeed(entry.id) }

    private func footer(hasUnseeded: Bool) -> String? {
        if hasUnseeded {
            if isWaiting { return "Frontport Seeds them into \(entry.name)’s Data once it quits." }
            return model.activities.seedingFailures[entry.id] ?? "Frontport couldn’t Seed them into \(entry.name)’s Data yet."
        }
        let stages = Set(entry.requirements.map(\.stage))
        if stages == [.build] { return "Built into the Port’s Assets. Frontport keeps the ROM for updates." }
        if stages.contains(.runtime) { return "The Port reads these from its own Data." }
        return nil
    }

    private func present(_ text: String) -> some View {
        Label(text, systemImage: "checkmark")
            .foregroundStyle(.green)
    }

    private func row(_ name: String, _ state: ROMState, isOptional: Bool = false) -> some View {
        GroupedRow {
            HStack(spacing: 0) {
                Text(name)
                if isOptional { Text(" · optional").foregroundStyle(.secondary) }
            }
        } trailing: {
            switch state {
            case .unseeded where isWaiting:
                Label("Seeded when it quits", systemImage: "clock")
                    .foregroundStyle(.secondary)
            case .unseeded:
                HStack(spacing: 10) {
                    Label("Not Seeded", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    if !isOptional {
                        Button("Try Again") { model.applyROMs(entry.id) }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                            .disabled(!model.status(of: entry.id).allows(.seed))
                    }
                }
            case .inROMs: present("In your ROMs")
            case .builtIn: present("Built in")
            case .seeded: present("Seeded")
            case .missing:
                Button("Add…") { model.open(.roms) }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
    }
}

/// Network, Controllers and Files; locked while the Port runs, applied on its next launch.
private struct PermissionToggles: View {
    @Environment(AppModel.self) private var model
    let entry: CatalogEntry

    var body: some View {
        let installation = model.survey.installation(entry.id)
        let permissions = installation?.permissions ?? entry.permissions
        let status = model.status(of: entry.id)
        GroupedSection("Permissions", footer: footer(status.check(.setPermissions))) {
            GroupedRow("Sandbox") {
                Label("Always on", systemImage: "lock")
                    .foregroundStyle(.secondary)
            }
            ForEach(Permission.allCases, id: \.self) { permission in
                GroupedRow(permission.name) {
                    Toggle(permission.name, isOn: Binding(
                        get: { permissions[permission] },
                        set: { isOn in
                            var changed = permissions
                            changed[permission] = isOn
                            model.setPermissions(changed, for: entry.id)
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .disabled(!status.allows(.setPermissions))
                    .accessibilityIdentifier("port.permission.\(permission.rawValue)")
                }
            }
        }
    }

    private func footer(_ availability: Status.Availability) -> String {
        switch availability {
        case .unavailable: "Set by the Catalog. You can change them once it’s installed."
        case .disabled(.unknownEntry): "Fixed: it was installed before Frontport kept its Catalog entry, which re-signing needs."
        case .disabled(.running): "Quit \(entry.name) to change them. Changes apply the next time it opens."
        default: "Changes apply the next time it opens."
        }
    }
}
