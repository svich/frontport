import FrontportCore
import SwiftUI

/// A Catalog entry's store page, laid out like an app's page in the Mac App Store: its icon, name and the action its
/// state calls for, a strip of facts, screenshots (or its hero art), the description and what's new, the ROMs it needs,
/// its Permissions and Information, and its Game's other Ports.
struct StorePageView: View {
    @Environment(AppModel.self) private var model
    let port: PortID

    var body: some View {
        Group {
            if let entry = model.survey.entry(port), model.survey.isListed(port) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        Breadcrumb(entry: entry)
                        StoreHeader(entry: entry)
                        VStack(spacing: 0) {
                            Divider()
                            FactStrip(entry: entry).padding(.vertical, 14)
                            Divider()
                        }
                        ScreenshotShelf(entry: entry)
                        Description(entry: entry)
                        WhatsNew(entry: entry)
                        StoreROMs(entry: entry)
                        StorePermissions(entry: entry)
                        Information(entry: entry)
                        // Leftovers of a Port that isn't installed have no Port page to be removed from.
                        if model.survey.installation(port) == nil {
                            StorageSection(entry: entry)
                        }
                        OtherPorts(entry: entry)
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
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
        .font(.callout)
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

/// A row of facts under the header, as the App Store shows ratings, age and size: the latest Release, Platform, Genre,
/// size, ROMs, developer and, when it has one, its iOS version.
private struct FactStrip: View {
    @Environment(AppModel.self) private var model
    let entry: CatalogEntry

    var body: some View {
        FactRow(facts: facts)
    }

    private var facts: [Fact] {
        var facts: [Fact] = []
        if let release = model.survey.latestRelease(for: entry.id) {
            facts.append(Fact(
                caption: "Release", value: .text(release.version),
                detail: release.published.map(Format.date) ?? entry.name))
        }
        if let platform = model.survey.platform(for: entry) {
            facts.append(Fact(
                caption: "Platform", value: .image("PlatformIcons/\(platform.id.rawValue)"), detail: platform.name,
                screen: .platform(platform.id)))
        }
        if let game = model.survey.game(for: entry), let id = game.genres.first,
           let genre = model.survey.catalog?.genre(id) {
            facts.append(Fact(caption: "Genre", value: .genre(id), detail: genre.name, screen: .genre(id)))
        }
        if entry.isSourceBuilt {
            facts.append(Fact(caption: "Size", value: .symbol("hammer"), detail: "Built on this Mac"))
        } else if let size = model.survey.latestRelease(for: entry.id)?.asset?.size, size > 0 {
            let parts = Format.bytes(size).split(separator: " ", maxSplits: 1).map(String.init)
            facts.append(Fact(caption: "Size", value: .text(parts.first ?? ""), detail: parts.dropFirst().first ?? ""))
        }
        let matching = model.survey.matching(for: entry.id)
        let missing = matching.missing()
        if entry.requirements.isEmpty {
            facts.append(Fact(caption: "ROM", value: .symbol("checkmark.circle"), detail: "None needed"))
        } else if missing.isEmpty {
            // A Build ROM the Port was made from counts even once it's left ROMs, as the ROMs section says.
            let builtIn = matching.requirements.filter { $0.state == .builtIn }.count
            let detail = builtIn == 0 ? "In your ROMs" : builtIn == matching.requirements.count ? "Built in" : "Built in and in ROMs"
            facts.append(Fact(caption: "ROM", value: .symbol("checkmark.circle.fill"), detail: detail, tint: .green))
        } else {
            facts.append(Fact(
                caption: missing.count == 1 ? "ROM" : "ROMs", value: .text("\(missing.count)"),
                detail: "Needed", tint: .orange))
        }
        facts.append(Fact(caption: "Developer", value: .symbol("person.crop.square"), detail: entry.developer))
        if entry.ios != nil {
            facts.append(Fact(
                caption: "iPhone and iPad", value: .symbol("iphone"),
                detail: model.survey.latestIOSRelease(for: entry.id)?.version ?? "Available"))
        }
        return facts
    }
}

/// The project's screenshots in a row that scrolls sideways, or, when it has none, its hero art across the page at its
/// own shape, so none of it is cut off.
private struct ScreenshotShelf: View {
    let entry: CatalogEntry

    var body: some View {
        let shots = entry.screenshots
        if shots.isEmpty {
            ArtworkImage(.hero, port: entry.id)
                .aspectRatio(1920 / 620, contentMode: .fit)
                .overlay(alignment: .bottomLeading) {
                    ArtworkImage(.logo, port: entry.id)
                        .frame(maxWidth: 300, maxHeight: 110, alignment: .bottomLeading)
                        .padding(22)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .frame(maxWidth: .infinity)
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: 14) {
                    ForEach(Array(shots.enumerated()), id: \.offset) { offset, url in
                        Screenshot(url: url)
                            .frame(width: 480, height: 270)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(.separator, lineWidth: 0.5)
                            }
                            .accessibilityLabel("Screenshot \(offset + 1) of \(shots.count)")
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.never)
        }
    }
}

private struct Screenshot: View {
    let url: URL
    @Environment(AppModel.self) private var model
    @State private var loaded: (url: URL, image: NSImage?)?

    var body: some View {
        let loaded = loaded?.url == url ? loaded : ScreenshotCache.shared.cached(url).map { (url, $0) }
        Rectangle()
            .fill(.black)
            .overlay {
                switch loaded?.image {
                case let image?: Image(nsImage: image).resizable().scaledToFill()
                case nil where loaded != nil: Image(systemName: "photo").foregroundStyle(.secondary)
                case nil: ProgressView().controlSize(.small)
                }
            }
            .clipped()
            .task(id: url) {
                let image = await ScreenshotCache.shared.image(at: url, cache: model.paths.imageCache)
                if !Task.isCancelled { self.loaded = (url, image) }
            }
    }
}

/// The Game's other Ports, as the App Store shows "You Might Also Like", each opening its store page; nothing when the
/// Game has one Port.
private struct OtherPorts: View {
    @Environment(AppModel.self) private var model
    let entry: CatalogEntry

    var body: some View {
        let others = model.survey.lineup.ports(of: entry.game).filter { $0.id != entry.id }
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    SectionHeader(title: "Other Ports of \(model.gameName(for: entry))")
                    Button("See All") { model.open(.game(entry.game)) }
                        .buttonStyle(.link)
                        .help("Compare \(model.gameName(for: entry))’s Ports side by side")
                        .accessibilityIdentifier("store.allPorts")
                }
                FlowGrid(columns: 3, spacing: 14, rowSpacing: 14) {
                    ForEach(others) { other in
                        Button {
                            model.open(.store(other.id))
                        } label: {
                            HStack(spacing: 12) {
                                ArtworkImage(.icon, port: other.id)
                                    .frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(other.name).fontWeight(.semibold)
                                    Text("\(other.kind.name) · by \(other.developer)")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// The icon, Game, summary and Project, and the action the Port's Status calls for with a line on where it stands. Once
/// the Port is in the Library, Open, which leads to its Port page, beside only the Mac's action; Install on iPhone or
/// iPad… until then.
private struct StoreHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(ViewState.self) private var viewState
    let entry: CatalogEntry

    var body: some View {
        let status = model.status(of: entry.id)
        HStack(alignment: .top, spacing: 26) {
            ArtworkImage(.icon, port: entry.id)
                .frame(width: 140, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 31, style: .continuous))
                .shadow(color: .black.opacity(0.16), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.survey.game(for: entry)?.name ?? entry.name)
                    .font(.system(size: 28, weight: .bold))
                    .tracking(-0.4)
                    .fixedSize(horizontal: false, vertical: true)
                Text(entry.summary)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .catalogContent("summary")
                    .padding(.top, 3)
                HStack(spacing: 0) {
                    Button(entry.name) {
                        if let project = model.survey.lineup.project(for: entry) { model.open(.project(project.id)) }
                    }
                    .buttonStyle(.link)
                    .help("Show the \(entry.name) Project")
                    .accessibilityIdentifier("store.project")
                    Text(" · \(entry.kind.name) · by \(entry.developer)")
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 6)
                HStack(spacing: 10) {
                    // Once it's in the Library, the Port page manages it: the header opens it, and offers only the
                    // Mac's action. While a change is under way, the header is about it alone.
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
                    if isInLibrary(status) {
                        if status.main != .cancel { open }
                    } else {
                        InstallOnDevicesButton(port: entry.id, identifier: "store.installOnDevices")
                    }
                }
                .controlSize(.large)
                .padding(.top, 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(status.state))
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("store.status")
                    Text(detail(status.state))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .modifier(DetailIdentifier(state: status.state))
                    if case .working(let activity) = status.state {
                        ProgressView(value: activity.progress.fraction)
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                            .frame(maxWidth: 280)
                            .padding(.top, 4)
                    }
                }
                .font(.callout)
                .padding(.top, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func button(_ action: Status.Action, _ status: Status, _ identifier: String) -> some View {
        Button(model.title(action, for: entry.id)) { viewState.run(action, for: entry.id, in: model) }
            .disabled(!status.allows(action))
            .help(model.help(action, for: entry.id) ?? "")
            .accessibilityIdentifier(identifier)
    }

    private var open: some View {
        Button("Open") { model.open(.port(entry.id)) }
            .buttonStyle(.glass)
            .help("Open its Port page")
            .accessibilityIdentifier("store.open")
    }

    /// On this Mac, being installed here, or on an iPhone or iPad.
    private func isInLibrary(_ status: Status) -> Bool {
        status.isInLibrary || !model.survey.deviceInstallations(of: entry.id).isEmpty
    }

    /// "iPhone 13 and iPad Air", the Devices it's on.
    private var devices: String {
        model.survey.deviceInstallations(of: entry.id).map { model.deviceName($0.device) }.formatted(.list(type: .and))
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
        case .available where isInLibrary(model.status(of: entry.id)):
            return "\(game) · \(entry.name) is in your Library"
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
        case .available where isInLibrary(model.status(of: entry.id)):
            return "On \(devices), not on this Mac"
        case .available:
            var parts: [String] = []
            if entry.isSourceBuilt {
                parts.append("Frontport builds it on your Mac in a sandbox, with no network.")
            } else if let size = model.survey.latestRelease(for: entry.id)?.asset?.size, size > 0 {
                parts.append("\(Format.bytes(size)) download.")
            }
            if let roms = romsText(verb: entry.isSourceBuilt ? "build" : "play") { parts.append(roms) }
            return parts.joined(separator: " ")
        case .working(let activity):
            return activity.progress.message ?? "This can take a few minutes."
        case .needsBuildROM(let missing) where missing.count > 1:
            return "Frontport builds \(entry.name) with them, so it needs them before installing: \(labels(missing))."
        case .needsBuildROM:
            return "Frontport builds \(entry.name) with a supported \(game) ROM, so it needs one before installing."
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

/// The description, with the Project's links beside it, as the App Store puts the developer's beside an app's.
private struct Description: View {
    @Environment(AppModel.self) private var model
    let entry: CatalogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 10) {
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
            }
            .frame(maxWidth: 680, alignment: .leading)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 10) {
                if let project = model.survey.lineup.project(for: entry) {
                    link(project.name, "square.stack.3d.up") { model.open(.project(project.id)) }
                        .fontWeight(.semibold)
                }
                if let website = entry.website {
                    Link(destination: website) { Label("Website", systemImage: "safari") }
                }
                Link(destination: entry.source) { Label("Code", systemImage: "chevron.left.forwardslash.chevron.right") }
            }
            .frame(width: 200, alignment: .leading)
        }
    }

    private func link(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol) }
            .buttonStyle(.link)
    }
}

/// The latest Release: its version and date and a short summary of its notes, with All Releases opening the Project.
private struct WhatsNew: View {
    @Environment(AppModel.self) private var model
    let entry: CatalogEntry

    var body: some View {
        if let release = model.survey.latestRelease(for: entry.id) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    SectionHeader(title: "What’s New")
                    if let project = model.survey.lineup.project(for: entry) {
                        Button("All Releases") { model.open(.project(project.id)) }
                            .buttonStyle(.link)
                    }
                }
                HStack {
                    Text("\(entry.name) \(release.version)")
                    Spacer()
                    if let published = release.published {
                        Text(Format.date(published))
                    }
                }
                .foregroundStyle(.secondary)
                if let summary = model.notesSummary(release) {
                    Text(summary)
                        .lineSpacing(3)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 680, alignment: .leading)
                        .catalogContent("notes.\(release.id)")
                }
                if let url = release.notesURL {
                    Link("Release Notes", destination: url)
                }
            }
        }
    }
}

/// What the sandbox lets the Port do, a card each, as the App Store shows App Privacy.
private struct StorePermissions: View {
    let entry: CatalogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Permissions", subtitle: subtitle)
            HStack(alignment: .top, spacing: 14) {
                ForEach(Permission.allCases, id: \.self) { permission in
                    let allowed = entry.permissions[permission]
                    card(
                        symbol: symbol(permission), title: permission.name,
                        detail: allowed ? "Allowed" : "Not allowed", isOn: allowed)
                }
                if !entry.codeSigning.exceptions.isEmpty {
                    card(
                        symbol: "signature", title: "Code-signing exceptions",
                        detail: entry.codeSigning.exceptions.joined(separator: ", "), isOn: true)
                        .help("Mirrored from upstream by the Catalog")
                }
            }
        }
    }

    /// On iPhone and iPad, iOS gives every app the network.
    private var subtitle: String {
        let set = "Runs in its own sandbox. Set by the Catalog; you can change them after installing."
        return entry.ios == nil ? set : set + " Network is always on on iPhone and iPad."
    }

    private func symbol(_ permission: Permission) -> String {
        switch permission {
        case .controllers: "gamecontroller"
        case .network: "network"
        case .files: "folder"
        }
    }

    private func card(symbol: String, title: String, detail: String, isOn: Bool) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .frame(height: 32)
            Text(title).fontWeight(.semibold)
            Text(detail)
                .font(.callout)
                .foregroundStyle(isOn ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Equal columns filled row by row, each row as tall as its tallest item.
private struct FlowGrid: Layout {
    var columns: Int
    var spacing: CGFloat
    var rowSpacing: CGFloat

    private func width(_ total: CGFloat) -> CGFloat {
        (total - spacing * CGFloat(columns - 1)) / CGFloat(columns)
    }

    /// The row heights last measured, and the column width they're for: a lazy stack asks again and again.
    struct Cache {
        var width: CGFloat?
        var heights: [CGFloat] = []
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }

    private func rows(_ subviews: Subviews, width: CGFloat, cache: inout Cache) -> [CGFloat] {
        if cache.width == width { return cache.heights }
        let heights = stride(from: 0, to: subviews.count, by: columns).map { start in
            subviews[start..<min(start + columns, subviews.count)]
                .map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }.max() ?? 0
        }
        cache = Cache(width: width, heights: heights)
        return heights
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let total = proposal.width ?? 900
        let heights = rows(subviews, width: width(total), cache: &cache)
        return CGSize(width: total, height: heights.reduce(0, +) + rowSpacing * CGFloat(max(0, heights.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let column = width(bounds.width)
        let heights = rows(subviews, width: column, cache: &cache)
        var y = bounds.minY
        for (row, height) in heights.enumerated() {
            for index in row * columns..<min((row + 1) * columns, subviews.count) {
                let x = bounds.minX + CGFloat(index - row * columns) * (column + spacing)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: column, height: height))
            }
            y += height + rowSpacing
        }
    }
}

/// The App Store's Information: a grid of labelled facts, each under a hairline.
private struct Information: View {
    @Environment(AppModel.self) private var model
    let entry: CatalogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Information")
            // Not lazy, so every fact is there to find before it's scrolled to.
            FlowGrid(columns: 3, spacing: 28, rowSpacing: 16) {
                item("Developer") { Text(entry.developer) }
                if let project = model.survey.lineup.project(for: entry) {
                    item("Project") {
                        Button(project.name) { model.open(.project(project.id)) }.buttonStyle(.link)
                    }
                }
                item("Kind") { Text(entry.kind.name) }
                if let platform = model.survey.platform(for: entry) {
                    item("Platform") {
                        Button(platform.name) { model.open(.platform(platform.id)) }
                            .buttonStyle(.link)
                            .help("Show \(platform.name) Ports in the Catalog")
                    }
                }
                item("Storage") { Text(storage) }
                item("Compatibility") { Text("macOS 26 or later on Apple silicon") }
                item("Input") { Text(entry.permissions.controllers ? "Keyboard, or a controller" : "Keyboard") }
                if entry.ios != nil {
                    item("iPhone and iPad") { Text(devices) }
                        .testContainer("store.requirements.devices")
                }
                if let first = entry.firstRelease {
                    item("First Release") { Text(Format.date(first)) }
                }
                if let catalog = model.catalogName(for: entry) {
                    item("Catalog") {
                        Text(catalog)
                            .help("Listed by a Catalog you added in Settings, which Frontport doesn’t review")
                            .accessibilityIdentifier("store.catalog")
                    }
                }
                item("Code") {
                    Link(entry.source.shortDisplay, destination: entry.source)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let website = entry.website {
                    item("Website") { Link(website.shortDisplay, destination: website) }
                }
            }
        }
    }

    /// Its latest iOS Release, which Frontport installs from this Mac, with Xcode.
    private var devices: String {
        let installed = "Installed from this Mac, with Xcode"
        guard let release = model.survey.latestIOSRelease(for: entry.id) else { return installed }
        return "\(release.version) · \(installed)"
    }

    private var storage: String {
        let assets = entry.requirements.isEmpty ? "" : ", plus Assets made from your ROM"
        if entry.isSourceBuilt { return "Built on this Mac\(assets)" }
        guard let size = model.survey.latestRelease(for: entry.id)?.asset?.size, size > 0 else { return "Varies" }
        return "\(Format.bytes(size)) download\(assets)"
    }

    private func item(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            value()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
