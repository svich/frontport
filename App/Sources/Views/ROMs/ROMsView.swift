import FrontportCore
import SwiftUI

/// What Library Ports still need, what Steam has installed, what's been added, and Add ROMs….
struct ROMsView: View {
    @Environment(AppModel.self) private var model
    @Environment(ViewState.self) private var viewState
    @State private var removing: ROMRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            let needed = model.neededGames
            if !needed.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Needed").font(.title3.bold())
                    ForEach(needed) { NeededCard(needed: $0) }
                }
            }
            if !model.steamOffers.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("In Steam").font(.title3.bold())
                    ForEach(model.steamOffers) { SteamCard(offer: $0) }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Added").font(.title3.bold())
                if model.survey.roms.isEmpty {
                    ContentUnavailableView {
                        Label("No ROMs Yet", systemImage: "sdcard")
                    } description: {
                        Text("Add a ROM for a Port you want to install.")
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    ROMTable(removing: $removing)
                }
            }
            DropZone()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 24)
        .testContainer("screen.roms")
        .navigationTitle("ROMs")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewState.isImportingROMs = true
                } label: {
                    Label("Add ROMs…", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.glassProminent)
                .disabled(viewState.isAddingROMs)
                .help("Add ROM files to Frontport")
                .accessibilityIdentifier("roms.add")
            }
        }
        .confirmationDialog(
            removing.map { "Remove \(name(of: $0))?" } ?? "",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { rom in
            Button("Remove", role: .destructive) { model.removeROM(rom.sha1) }
            Button("Cancel", role: .cancel) {}
        } message: { rom in
            Text(removalMessage(rom))
        }
    }

    private var subtitle: String {
        var parts = [Format.count(model.survey.roms.count, "ROM")]
        if model.portsUsingROMs > 0 { parts.append("used by \(Format.count(model.portsUsingROMs, "Port"))") }
        return parts.joined(separator: " · ")
    }

    private func name(of rom: ROMRecord) -> String {
        "\(model.owner(of: rom)) \(rom.name)"
    }

    private func removalMessage(_ rom: ROMRecord) -> String {
        let affected = model.portsAffected(byRemoving: rom.sha1).map(\.name)
        let keep = "Installed Ports keep working."
        guard !affected.isEmpty else { return "No installed Port will ask for it again. \(keep)" }
        let verb = affected.count == 1 ? "asks" : "ask"
        return "\(affected.formatted(.list(type: .and))) \(verb) for it again on an update that rebuilds its Assets. \(keep)"
    }
}

/// One Game that installed Ports still need a ROM of, or whose ROM isn't Seeded into their Data yet.
private struct NeededCard: View {
    @Environment(AppModel.self) private var model
    @Environment(ViewState.self) private var viewState
    let needed: NeededGame

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let game = needed.game {
                    ArtworkImage(.icon, game: game)
                } else {
                    Image(systemName: "sdcard").font(.title2)
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(needed.label).fontWeight(.semibold)
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !needed.isUnseeded, !steamOffers.isEmpty {
                Button("Add from Steam") { Task { await viewState.addFromSteam(steamOffers, to: model) } }
                    .buttonStyle(.addROM)
                    .disabled(viewState.isAddingROMs)
            } else if !needed.isUnseeded {
                Button("Add ROM…") { viewState.isImportingROMs = true }
                    .buttonStyle(.addROM)
            } else if !isWaiting {
                Button("Try Again") {
                    for port in needed.ports { model.applyROMs(port.id) }
                }
                .buttonStyle(.glass)
                .disabled(!needed.ports.contains { model.status(of: $0.id).allows(.seed) })
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .calloutBackground(.orange, cornerRadius: 12)
        .testContainer("roms.needed.\(needed.id)")
    }

    /// What Steam installed that these Ports accept.
    private var steamOffers: [SteamOffer] {
        let ids = Set(needed.ports.flatMap { model.steamOffers(for: $0.id) }.map(\.sha1))
        return model.steamOffers.filter { ids.contains($0.sha1) }
    }

    /// Every Port waits for itself to quit before Seeding.
    private var isWaiting: Bool { needed.ports.allSatisfy { model.isWaitingToSeed($0.id) } }

    private var reason: String {
        // A Project's Ports can share its name, so a name used twice gets its Game: "OpenGOAL for Jak II".
        let all = needed.ports.map(\.name)
        let names = needed.ports.map { port in
            all.filter { $0 == port.name }.count > 1 ? "\(port.name) for \(model.gameName(for: port))" : port.name
        }.formatted(.list(type: .and))
        let single = needed.ports.count == 1
        if needed.isUnseeded {
            if isWaiting { return "In your ROMs. Frontport Seeds it once \(names) \(single ? "quits" : "quit")." }
            let data = single ? "\(names)’s Data" : "the Data of \(names)"
            let failed = needed.ports.contains { model.activities.seedingFailures[$0.id] != nil }
            return failed ? "Seeding it into \(data) failed." : "In your ROMs, but not Seeded into \(data) yet."
        }
        return "\(names) \(single ? "needs" : "need") it to \(needed.stages.contains(.runtime) ? "start" : "build")."
    }
}

/// A ROM Steam installed that a Port in the Catalog accepts, ready to add as Steam installed it.
private struct SteamCard: View {
    @Environment(AppModel.self) private var model
    @Environment(ViewState.self) private var viewState
    let offer: SteamOffer

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let game = known?.game {
                    ArtworkImage(.icon, game: game)
                } else {
                    Image(systemName: "folder").font(.title2)
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(known.map { model.owner(of: $0) } ?? offer.appName).fontWeight(.semibold)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if offer.matches {
                Button("Add") { Task { await viewState.addFromSteam([offer], to: model) } }
                    .buttonStyle(.glass)
                    .disabled(viewState.isAddingROMs)
                    .accessibilityIdentifier("roms.steam.add.\(offer.sha1)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .calloutBackground(.secondary, cornerRadius: 12)
        .help(offer.folder.path(percentEncoded: false))
        .testContainer("roms.steam.\(offer.sha1)")
    }

    private var known: KnownROM? { model.survey.catalog?.knownROM(offer.sha1) }

    private var detail: String {
        guard offer.matches else {
            return "Steam installed another build of \(offer.appName) than \(known?.name ?? "the one the Catalog lists")."
        }
        return [known?.name, "Adds Steam’s files, not your saves or settings."].compactMap(\.self).joined(separator: ". ")
    }
}

private struct ROMTable: View {
    @Environment(AppModel.self) private var model
    @Environment(ViewState.self) private var viewState
    @Binding var removing: ROMRecord?
    @State private var selection: ROMRecord.ID?

    var body: some View {
        Table(model.survey.roms, selection: $selection) {
            TableColumn("ROM") { rom in
                HStack(spacing: 12) {
                    Group {
                        if let game = rom.game {
                            ArtworkImage(.icon, game: game)
                        } else {
                            Image(systemName: model.type(of: rom).symbol).font(.title3)
                        }
                    }
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.owner(of: rom))
                            .fontWeight(.semibold)
                        HStack(spacing: 6) {
                            Text(rom.name)
                                .foregroundStyle(.secondary)
                            if rom.isUnverified {
                                Text("Unverified")
                                    .foregroundStyle(.orange)
                                    .accessibilityIdentifier("roms.unverified.\(rom.sha1)")
                            }
                        }
                        .font(.callout)
                    }
                }
                .padding(.vertical, 4)
                .help(help(for: rom))
                .cellEnvironment(model, viewState)
            }
            .width(min: 180, ideal: 220)
            TableColumn("Type") { rom in
                Text(model.type(of: rom).name)
                    .foregroundStyle(.secondary)
                    .help(rom.isFolder ? "" : ".\(rom.format)")
            }
            .width(min: 60, ideal: 70)
            TableColumn("Size") { rom in
                Text(Format.bytes(rom.size)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 70)
            TableColumn("SHA-1") { rom in
                Text(rom.fileSHA1)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(rom.fileSHA1)
                    .textSelection(.enabled)
            }
            .width(min: 90, ideal: 130)
            TableColumn("Used by") { rom in
                UsedBy(sha1: rom.sha1)
                    .cellEnvironment(model, viewState)
            }
            .width(min: 140, ideal: 220)
            TableColumn("Added") { rom in
                Text(Format.shortDate(rom.added)).foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)
            TableColumn("") { rom in
                Menu {
                    menuItems(rom)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More for \(rom.name)")
                .accessibilityIdentifier("roms.more.\(rom.sha1)")
            }
            .width(32)
        }
        .alternatingRowBackgrounds(.disabled)
        // As tall as its rows, up to the space there is.
        .frame(maxHeight: CGFloat(model.survey.roms.count) * 50 + 44)
        .contextMenu(forSelectionType: ROMRecord.ID.self) { ids in
            if let rom = model.survey.roms.first(where: { ids.contains($0.id) }) {
                menuItems(rom)
            }
        }
    }

    /// The file it was added from, and for an Unverified ROM what that means.
    private func help(for rom: ROMRecord) -> String {
        guard rom.isUnverified else { return rom.originalFilename }
        return "\(rom.originalFilename)\nUnverified: the Catalog doesn’t list this file’s hash, so Frontport can’t tell it’s this ROM. If it isn’t, the Port fails to build or run."
    }

    @ViewBuilder private func menuItems(_ rom: ROMRecord) -> some View {
        Button("Copy SHA-1") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(rom.fileSHA1, forType: .string)
        }
        Divider()
        Button("Remove…", role: .destructive) { removing = rom }
    }
}

/// The Library Ports using a ROM, each linking to its Port page.
private struct UsedBy: View {
    @Environment(AppModel.self) private var model
    let sha1: String

    var body: some View {
        let ports = model.ports(using: sha1)
        if ports.isEmpty {
            Text("No installed Port").foregroundStyle(.tertiary)
        } else {
            Text(links(ports))
                .lineLimit(2)
                .environment(\.openURL, OpenURLAction { url in
                    guard url.scheme == "frontport", let id = url.pathComponents.last else { return .discarded }
                    model.open(.port(PortID(id)))
                    return .handled
                })
        }
    }

    private func links(_ ports: [CatalogEntry]) -> AttributedString {
        var text = AttributedString()
        for (index, entry) in ports.enumerated() {
            if index > 0 { text.append(AttributedString(", ")) }
            var name = AttributedString(entry.name)
            name.link = URL(string: "frontport://port/\(entry.id.rawValue)")
            text.append(name)
            if case .working(let activity) = model.status(of: entry.id).state {
                var note = AttributedString(" · \(model.activityText(activity, for: entry.id))")
                note.foregroundColor = .secondary
                text.append(note)
            }
        }
        return text
    }
}

/// Click or drop to add ROMs; dropping anywhere on the window works too.
private struct DropZone: View {
    @Environment(ViewState.self) private var viewState

    var body: some View {
        Button {
            viewState.isImportingROMs = true
        } label: {
            VStack(spacing: 6) {
                if viewState.isAddingROMs {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(.secondary)
                }
                Text("Drop ROMs here").fontWeight(.semibold)
                Text("Frontport checks each one against the Catalog and keeps it private. ROMs are used to build and update Ports, never played directly.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            .frame(maxWidth: .infinity)
            .padding(20)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#if DEBUG
#Preview("ROMs") {
    ScreenPreview(.roms)
}

#Preview("ROMs · Empty") {
    ScreenPreview(.roms, data: .empty())
}
#endif
