import FrontportCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct FrontportApp: App {
    @State private var model: AppModel
    @State private var viewState = ViewState()
    // Started only with an EdDSA key in Info.plist; the model checks with it along with the Ports' update checks.
    @State private var updater: AppUpdater

    init() {
        let paths = AppPaths.app
        let updater = AppUpdater()
        _updater = State(initialValue: updater)
        #if DEBUG
        if SnapshotDriver.isActive, !SnapshotDriver.isLive {
            _model = State(initialValue: AppModel(preview: SnapshotDriver.previewData(), paths: paths))
            return
        }
        #endif
        _model = State(initialValue: AppModel(services: .live(paths: paths), paths: paths, updater: updater))
    }

    var body: some Scene {
        // One main window: its navigation and ViewState are the app's.
        Window("Frontport", id: "main") {
            ContentView()
                .environment(model)
                .environment(viewState)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            CommandGroup(after: .newItem) {
                Button("Add ROMs…") { viewState.isImportingROMs = true }
                    .keyboardShortcut("o")
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(ViewState.self) private var viewState
    @Environment(\.openSettings) private var openSettings
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var model = model
        @Bindable var viewState = viewState
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            DetailView()
        }
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search")
        .task {
            #if DEBUG
            if SnapshotDriver.isActive {
                await SnapshotDriver.run(model: model, viewState: viewState, openSettings: openSettings)
                return
            }
            #endif
            await model.start()
        }
        .fileImporter(
            // A folder is a PC game's ROM.
            isPresented: isShowingImporter, allowedContentTypes: [.data, .folder], allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            Task { await viewState.addROMs(urls, to: model) }
        }
        #if DEBUG
        // UI tests add a file they wrote instead of driving the open panel.
        .onChange(of: viewState.isImportingROMs) { _, isImporting in
            guard isImporting, let files = TestHooks.importedROMs else { return }
            viewState.isImportingROMs = false
            Task { await viewState.addROMs(files, to: model) }
        }
        #endif
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            Task { await viewState.addROMs(files, to: model) }
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                DropOverlay()
            }
        }
        .sheet(item: $viewState.intakeReport) { report in
            IntakeSheet(report: report)
        }
        .onOpenURL { url in
            guard url.scheme?.lowercased() == "frontport" else { return }
            viewState.catalogLink = .init(url: url)
        }
        .sheet(item: $viewState.catalogLink) { request in
            AddCatalogSheet(link: request.url)
        }
        .portConfirmations()
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } }),
            presenting: model.failure
        ) { _ in
            Button("OK") {}
        } message: { failure in
            Text(failure.error.localizedDescription)
        }
    }
}

extension ContentView {
    /// Add ROMs… shows the open panel, except in a Debug build given files to add by the UI tests.
    private var isShowingImporter: Binding<Bool> {
        Binding(
            get: {
                #if DEBUG
                if TestHooks.importedROMs != nil { return false }
                #endif
                return viewState.isImportingROMs
            },
            set: { viewState.isImportingROMs = $0 })
    }
}

/// Shown while ROM files are dragged over the window.
private struct DropOverlay: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                .background(.tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            VStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 34, weight: .medium))
                Text("Add ROMs")
                    .font(.title2.bold())
                Text("Frontport checks each file against the Catalog and keeps it private.")
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .padding(10)
        .allowsHitTesting(false)
    }
}

struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.searchText.isEmpty {
            SearchResultsView()
        } else {
            switch model.selection {
            case .catalog, nil: CatalogView()
            case .library: LibraryView()
            case .releases: ReleasesView()
            case .roms: ROMsView()
            case .port(let id): PortPageView(port: id)
            case .platform(let id): PlatformPageView(platform: id)
            case .genre(let id): GenrePageView(genre: id)
            case .game(let id): GamePageView(game: id)
            case .store(let id): StorePageView(port: id)
            case .project(let id): ProjectPageView(project: id)
            }
        }
    }
}
