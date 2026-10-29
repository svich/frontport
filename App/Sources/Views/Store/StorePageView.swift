import FrontportCore
import SwiftUI

/// A Catalog entry's store page, under its Game: a note when the Game has other Ports, then screenshots, summary, the
/// action its state calls for, and details.
struct StorePageView: View {
    @Environment(AppModel.self) private var model
    let port: PortID

    var body: some View {
        Group {
            if let entry = model.survey.entry(port), model.survey.isListed(port) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Breadcrumb(entry: entry)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.survey.game(for: entry)?.name ?? entry.name)
                                .font(.system(size: 28, weight: .heavy))
                                .tracking(-0.5)
                            HStack(spacing: 0) {
                                Button(entry.name) {
                                    if let project = model.survey.lineup.project(for: entry) { model.open(.project(project.id)) }
                                }
                                .buttonStyle(.link)
                                .fontWeight(.semibold)
                                .help("Show the \(entry.name) Project")
                                .accessibilityIdentifier("store.project")
                                Text(" · by \(entry.developer) · \(entry.kind.name)")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.title3)
                        }
                        OtherPortsNotice(entry: entry)
                        HStack(alignment: .top, spacing: 24) {
                            ScreenshotViewer(entry: entry)
                                .frame(maxWidth: .infinity)
                            SummaryColumn(entry: entry)
                                .frame(width: 290)
                        }
                        ActionBar(entry: entry)
                        HStack(alignment: .top, spacing: 32) {
                            VStack(alignment: .leading, spacing: 26) {
                                About(entry: entry)
                                SystemRequirements(entry: entry)
                                StoreROMs(entry: entry)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            VStack(alignment: .leading, spacing: 22) {
                                StorePermissions(entry: entry)
                                if model.survey.installation(port) == nil {
                                    StorageSection(entry: entry)
                                }
                            }
                            .frame(width: 320)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 36)
                }
                .testContainer("screen.store.\(port.rawValue)")
            } else {
                ContentUnavailableView("Not in the Catalog", systemImage: "questionmark.square.dashed")
            }
        }
        .navigationTitle(model.survey.entry(port).map { model.gameName(for: $0) } ?? port.rawValue)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back", systemImage: "chevron.left") { model.back() }
                    .disabled(!model.canGoBack)
                    .help("Back")
            }
        }
    }
}

/// "Catalog › Nintendo 64 › Super Mario 64 › Ghostship", with the Game's page in the path when it has more than one
/// Port; "Catalog › PlayStation 2 › Jak and Daxter" otherwise.
private struct Breadcrumb: View {
    @Environment(AppModel.self) private var model
    let entry: CatalogEntry

    var body: some View {
        HStack(spacing: 6) {
            crumb("Catalog", .catalog)
            if let platform = model.survey.platform(for: entry) {
                crumb(platform.name, .platform(platform.id))
            }
            if model.survey.lineup.ports(of: entry.game).count > 1 {
                crumb(model.gameName(for: entry), .game(entry.game))
                Text(entry.name).fontWeight(.semibold)
            } else {
                Text(model.gameName(for: entry)).fontWeight(.semibold)
            }
        }
    }

    private func crumb(_ title: String, _ screen: Screen) -> some View {
        HStack(spacing: 6) {
            Button(title) { model.open(screen) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }
}

/// The project's screenshots with thumbnails, or the hero art when there are none.
private struct ScreenshotViewer: View {
    let entry: CatalogEntry
    @State private var index = 0

    var body: some View {
        let shots = entry.screenshots
        VStack(spacing: 10) {
            if shots.isEmpty {
                ArtworkImage(.hero, port: entry.id)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay(alignment: .bottomLeading) {
                        ArtworkImage(.logo, port: entry.id)
                            .frame(maxWidth: 320, maxHeight: 130, alignment: .bottomLeading)
                            .padding(24)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                let current = min(index, shots.count - 1)
                Screenshot(url: shots[current])
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        if shots.count > 1 {
                            HStack {
                                arrow("chevron.left", label: "Previous Screenshot") {
                                    index = (current - 1 + shots.count) % shots.count
                                }
                                Spacer()
                                arrow("chevron.right", label: "Next Screenshot") {
                                    index = (current + 1) % shots.count
                                }
                            }
                            .padding(12)
                        }
                    }
                    .accessibilityLabel("Screenshot \(current + 1) of \(shots.count)")
                if shots.count > 1 {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                        ForEach(Array(shots.enumerated()), id: \.offset) { offset, url in
                            Button {
                                index = offset
                            } label: {
                                Screenshot(url: url)
                                    .aspectRatio(16 / 9, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .opacity(offset == current ? 1 : 0.6)
                                    .overlay {
                                        if offset == current {
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .strokeBorder(.tint, lineWidth: 2)
                                                .padding(-3)
                                        }
                                    }
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Screenshot \(offset + 1)")
                        }
                    }
                    .padding(.horizontal, 3)
                }
            }
        }
    }

    private func arrow(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .fontWeight(.semibold)
                .frame(width: 18, height: 18)
                .accessibilityLabel(label)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
    }
}

private struct Screenshot: View {
    let url: URL

    var body: some View {
        Rectangle()
            .fill(.black)
            .overlay {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    case .failure: Image(systemName: "photo").foregroundStyle(.secondary)
                    case .empty: ProgressView().controlSize(.small)
                    @unknown default: EmptyView()
                    }
                }
            }
            .clipped()
    }
}

private struct SummaryColumn: View {
    @Environment(AppModel.self) private var model
    let entry: CatalogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ArtworkImage(.grid, port: entry.id)
                .aspectRatio(92 / 43, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(entry.summary)
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .catalogContent("summary")
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 7) {
                if let project = model.survey.lineup.project(for: entry) {
                    row("Project") {
                        Button(project.name) { model.open(.project(project.id)) }
                            .buttonStyle(.link)
                            .fontWeight(.semibold)
                    }
                }
                if let release = model.survey.latestRelease(for: entry.id) {
                    row("Latest Release") {
                        Text(["\(entry.name) \(release.version)", release.published.map(Format.date)].compactMap { $0 }
                            .joined(separator: " · "))
                    }
                }
                if let platform = model.survey.platform(for: entry) {
                    row("Platform") {
                        Button(platform.name) { model.open(.platform(platform.id)) }
                            .buttonStyle(.link)
                            .help("Show \(platform.name) Ports in the Catalog")
                    }
                }
                if let catalog = model.catalogName(for: entry) {
                    row("Catalog") {
                        Text(catalog)
                            .help("Listed by a Catalog you added in Settings, which Frontport doesn’t review")
                            .accessibilityIdentifier("store.catalog")
                    }
                }
                row("Developer") { Text(entry.developer) }
                row("Source") {
                    Link(entry.source.shortDisplay, destination: entry.source)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let website = entry.website {
                    row("Website") { Link(website.shortDisplay, destination: website) }
                }
            }
        }
    }

    private func row(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            value()
        }
    }
}

/// "Super Mario 64 also has another Port: sm64coopdx. See All Ports", opening the Game page; nothing when the Game
/// has one Port.
private struct OtherPortsNotice: View {
    @Environment(AppModel.self) private var model
    let entry: CatalogEntry

    var body: some View {
        let others = model.survey.lineup.ports(of: entry.game).filter { $0.id != entry.id }
        if !others.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "square.stack")
                    .foregroundStyle(.secondary)
                Text(text(others))
                    .foregroundStyle(.secondary)
                Button("See All Ports") { model.open(.game(entry.game)) }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("store.allPorts")
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func text(_ others: [CatalogEntry]) -> String {
        let game = model.gameName(for: entry)
        let names = others.map(\.name).formatted(.list(type: .and))
        return others.count == 1
            ? "\(game) also has another Port: \(names)."
            : "\(game) also has \(others.count) other Ports: \(names)."
    }
}

/// The action the Port's Status calls for, with "In Library" once it's there.
private struct ActionBar: View {
    @Environment(AppModel.self) private var model
    @Environment(ViewState.self) private var viewState
    let entry: CatalogEntry

    var body: some View {
        let status = model.status(of: entry.id)
        HStack(spacing: 14) {
            ArtworkImage(.icon, port: entry.id)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title(status.state))
                    .font(.system(size: 16, weight: .bold))
                    .accessibilityIdentifier("store.status")
                Text(detail(status.state))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .modifier(DetailIdentifier(state: status.state))
                if case .working(let activity) = status.state {
                    ProgressView(value: activity.progress.fraction)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .frame(maxWidth: 260)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                // While a change is under way, the bar is about it alone.
                if status.isInLibrary, status.main != .cancel {
                    inLibrary
                }
                switch status.main {
                case .install?:
                    button(.install, status, "store.install").buttonStyle(.glassProminent)
                case .addROM(let stage)?:
                    button(.addROM(stage), status, "store.addROM").buttonStyle(.addROM)
                case .cancel?:
                    button(.cancel, status, "store.cancel").buttonStyle(.glass)
                case .seed?:
                    button(.seed, status, "store.seed").buttonStyle(.glassProminent)
                case .stop?:
                    Button {
                        viewState.run(.stop, for: entry.id, in: model)
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("store.stop")
                case nil:
                    EmptyView()
                default:
                    PortActionButton(port: entry.id, playsWhenUpdatable: true)
                }
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .calloutBackground(.accentColor)
    }

    private func button(_ action: Status.Action, _ status: Status, _ identifier: String) -> some View {
        Button(status.title(action)) { viewState.run(action, for: entry.id, in: model) }
            .disabled(!status.allows(action))
            .help(model.help(action, for: entry.id) ?? "")
            .accessibilityIdentifier(identifier)
    }

    private var inLibrary: some View {
        Button("In Library") { model.open(.port(entry.id)) }
            .buttonStyle(.glass)
            .accessibilityIdentifier("store.inLibrary")
    }

    /// The detail quotes an Unsupported entry's reason from the Catalog.
    private struct DetailIdentifier: ViewModifier {
        let state: Status.State

        func body(content: Content) -> some View {
            if case .unsupported = state {
                content.catalogContent("reason")
            } else {
                content.accessibilityIdentifier("store.detail")
            }
        }
    }

    private func title(_ state: Status.State) -> String {
        let game = model.gameName(for: entry)
        switch state {
        case .unsupported: return "Not available"
        case .available: return "Install \(entry.name)"
        case .working(let activity): return model.activityText(activity, for: entry.id)
        case .needsROM(let missing), .needsBuildROM(let missing):
            guard missing.count > 1 else { return "Add \(Self.article(game)) \(game) ROM" }
            return "Add \(missing.count) ROMs"
        case .running: return "\(game) · \(entry.name) is running"
        case .unseeded, .blocked, .updateAvailable, .ready: return "\(game) · \(entry.name) is in your Library"
        }
    }

    private func detail(_ state: Status.State) -> String {
        let game = model.gameName(for: entry)
        let installed = model.survey.installation(entry.id).map { "\(entry.name) \($0.release.version)" }
        switch state {
        case .unsupported(let reason):
            return "It can’t run inside the macOS sandbox. \(reason)"
        case .available:
            var parts: [String] = []
            if entry.isSourceBuilt {
                parts.append("Frontport builds it from source in a sandbox, with no network.")
            } else if let size = model.survey.latestRelease(for: entry.id)?.asset?.size, size > 0 {
                parts.append("\(Format.bytes(size)) download.")
            }
            if let roms = romsText(verb: entry.isSourceBuilt ? "build" : "play") { parts.append(roms) }
            return parts.joined(separator: " ")
        case .working(let activity):
            return activity.progress.message ?? "This can take a few minutes."
        case .needsBuildROM(let missing) where missing.count > 1:
            return "Frontport builds \(entry.name) from source with them, so it needs them before installing: \(labels(missing))."
        case .needsBuildROM:
            return "Frontport builds \(entry.name) from source with a supported \(game) ROM, so it needs one before installing."
        case .needsROM:
            return "\(entry.name) is installed, but needs a supported ROM to start."
        case .unseeded:
            return "Your \(game) ROM isn’t Seeded into its Data yet, so it can’t start with it."
        case .running:
            return ["Installed", installed].compactMap { $0 }.joined(separator: " · ")
        case .blocked, .updateAvailable, .ready:
            return ["Installed", installed, model.playedText(for: entry.id)].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// "You’ll need a Super Mario 64 ROM to play it.", or, for a Port that needs more than one, each ROM still
    /// missing; nil for a Port that needs none.
    private func romsText(verb: String) -> String? {
        let game = model.gameName(for: entry)
        let count = entry.requirements.count
        let missing = model.survey.matching(for: entry.id).missing()
        if count == 0 { return nil }
        if count == 1 {
            return missing.isEmpty
                ? "Your ROMs already have a supported \(game) ROM."
                : "You’ll need \(Self.article(game)) \(game) ROM to \(verb) it."
        }
        if missing.isEmpty { return "Your ROMs already have all \(count) it needs." }
        let needed = missing.count == count ? "\(count) ROMs" : Format.count(missing.count, "more ROM", "more ROMs")
        return "You’ll need \(needed) to \(verb) it: \(labels(missing))."
    }

    private func labels(_ requirements: [Requirement]) -> String {
        requirements.map(\.label).formatted(.list(type: .and))
    }

    static func article(_ word: String) -> String {
        guard let first = word.lowercased().first else { return "a" }
        return "aeiou".contains(first) ? "an" : "a"
    }
}

private struct About: View {
    @Environment(AppModel.self) private var model
    let entry: CatalogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "About \(entry.name)")
            let paragraphs = (entry.description.isEmpty ? entry.summary : entry.description)
                .components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .catalogContent("description")
            }
            if let project = model.survey.lineup.project(for: entry) {
                Button(project.ports.count > 1 ? "All Games and Releases from \(project.name)" : "Releases from \(project.name)") {
                    model.open(.project(project.id))
                }
                .buttonStyle(.link)
            }
        }
    }
}

private struct SystemRequirements: View {
    @Environment(AppModel.self) private var model
    let entry: CatalogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "System Requirements")
            GroupedSection {
                row("macOS", "26 or later")
                row("Processor", "Apple silicon")
                row("Storage", storage)
                row("Input", entry.permissions.controllers ? "Keyboard, or a controller" : "Keyboard")
            }
        }
    }

    private var storage: String {
        let assets = entry.requirements.isEmpty ? "" : ", plus Assets made from your ROM"
        if entry.isSourceBuilt { return "Built on this Mac\(assets)" }
        guard let size = model.survey.latestRelease(for: entry.id)?.asset?.size, size > 0 else { return "Varies" }
        return "\(Format.bytes(size)) download\(assets)"
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

private struct StorePermissions: View {
    let entry: CatalogEntry

    var body: some View {
        GroupedSection("Permissions", footer: "Set by the Catalog. You can change them after installing.") {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.shield")
                    .font(.title3)
                    .foregroundStyle(.tint)
                Text("Runs in its own sandbox").fontWeight(.semibold)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            ForEach(Permission.allCases, id: \.self) { permission in
                GroupedRow(permission.name) {
                    Text(entry.permissions[permission] ? "Allowed" : "Not allowed")
                        .foregroundStyle(entry.permissions[permission] ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                }
            }
            if !entry.codeSigning.exceptions.isEmpty {
                GroupedRow("Code-signing exceptions") {
                    Text(entry.codeSigning.exceptions.joined(separator: ", "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                .help("Mirrored from upstream by the Catalog")
            }
        }
    }
}

/// What files the Port needs: a row for each Requirement and extra, with its Type, the files it's added from and the
/// versions accepted, opening to each accepted ROM's SHA-1.
private struct StoreROMs: View {
    @Environment(AppModel.self) private var model
    let entry: CatalogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "ROMs")
            if entry.requirements.isEmpty {
                GroupedSection {
                    GroupedRow("Needs no ROM", value: "")
                }
            } else {
                GroupedSection(footer: footer) {
                    ForEach(model.survey.matching(for: entry.id).requirements) { state in
                        let requirement = state.requirement
                        RequirementRow(
                            label: requirement.label, roms: model.knownROMs(requirement.oneOf),
                            status: .init(state.accepted, needed: requirement.stage))
                        ForEach(model.knownROMs(requirement.extras)) { extra in
                            RequirementRow(
                                label: extra.name, roms: [extra], status: .init(state.extras[extra.sha1] ?? .missing))
                        }
                    }
                }
            }
        }
    }

    private var footer: String {
        let stages = Set(entry.requirements.map(\.stage))
        let use =
            if stages == [.build] { "Used while building; the Port never sees them." }
            else if stages == [.runtime] { "Placed in the Port’s own Data." }
            else { "Those needed to build are used while building, and the Port never sees them; the rest are placed in its own Data." }
        return "\(use) Any version listed will do; open a ROM to check yours by its SHA-1."
    }
}

/// One Requirement or extra: its Type, the files it's added from and the versions accepted, opening to each accepted
/// ROM and each installer that holds one, with its SHA-1 to copy.
private struct RequirementRow: View {
    enum Status {
        case present, builtIn, needed(Stage), optional

        /// A Requirement's accepted ROM, needed at `needed` when missing; or, without one, an extra.
        init(_ state: ROMState, needed stage: Stage? = nil) {
            switch state {
            case .missing: self = stage.map { .needed($0) } ?? .optional
            case .builtIn: self = .builtIn
            case .inROMs, .seeded, .unseeded: self = .present
            }
        }
    }

    @Environment(AppModel.self) private var model
    let label: String
    let roms: [KnownROM]
    let status: Status
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                summary.contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide the versions accepted" : "Show the versions accepted and their SHA-1s")
            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(roms) { rom in
                        AcceptedROM(name: rom.name, sha1: rom.sha1, isPresent: model.survey.matching.contains(rom.sha1))
                    }
                    let installers = roms.flatMap { model.installers(holding: $0.sha1) }
                    if !installers.isEmpty {
                        Text("Or an installer that holds it:")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        ForEach(installers) { installer in
                            AcceptedROM(name: installer.name, sha1: installer.sha1, isPresent: false)
                        }
                    }
                }
                .padding(.leading, 50)
                .padding(.trailing, 14)
                .padding(.bottom, 12)
            }
        }
    }

    private var summary: some View {
        HStack(spacing: 10) {
            Group {
                if let game = roms.first?.game {
                    ArtworkImage(.icon, game: game)
                } else {
                    Image(systemName: type?.symbol ?? "sdcard")
                        .font(.body)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.quaternary)
                }
            }
            .frame(width: 26, height: 26)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .opacity(isOptional ? 0.55 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            switch status {
            case .present:
                Label("In your ROMs", systemImage: "checkmark")
                    .font(.callout)
                    .foregroundStyle(.green)
            case .builtIn:
                Label("Built in", systemImage: "checkmark")
                    .font(.callout)
                    .foregroundStyle(.green)
            case .needed(let stage):
                Text(stage == .build ? "Needed to build" : "Needed")
                    .font(.callout)
                    .foregroundStyle(.orange)
            case .optional:
                Text("Optional")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var type: ROMType? { roms.first.map(model.type(of:)) }

    /// "Cartridge · .nsp, .xci, .nsz or .xcz · 1.0.0 (game card) or 1.0.0 (eShop)", leaving out the version when it's
    /// the label itself, as an extra's is, and counting more than two, which the row lists when open.
    private var detail: String {
        let names = roms.map(\.name)
        let versions =
            names == [label] ? nil
            : names.count > 2 ? Format.count(names.count, "version")
            : names.formatted(.list(type: .or))
        return [type?.name, model.filesText(for: roms), versions].compactMap { $0 }.joined(separator: " · ")
    }

    private var isOptional: Bool {
        if case .optional = status { true } else { false }
    }
}

/// One version a Requirement accepts, or an installer holding it: its name, whether it's in ROMs, and its SHA-1 to
/// check a dump against.
private struct AcceptedROM: View {
    let name: String
    let sha1: String
    let isPresent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(name)
                if isPresent {
                    Label("In your ROMs", systemImage: "checkmark")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.green)
                        .help("In your ROMs")
                }
            }
            HStack(spacing: 6) {
                Text("SHA-1 \(sha1)")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("Copy SHA-1", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sha1, forType: .string)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Copy SHA-1")
            }
        }
    }
}

#if DEBUG
#Preview("Store · Installed, Update") {
    ScreenPreview(.store("shipwright"), data: .standard().withStandInScreenshots())
}

#Preview("Store · Available") {
    ScreenPreview(.store("banjorecomp"))
}

#Preview("Store · Needs Build ROM") {
    ScreenPreview(.store("zelda3"))
}

#Preview("Store · Data Left") {
    ScreenPreview(.store("ghostship"))
}

#Preview("Store · Unsupported") {
    ScreenPreview(.store("opengoal-jak3"), data: .standard().withOpenGOALUnsupported())
}
#endif
