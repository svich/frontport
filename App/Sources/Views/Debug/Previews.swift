#if DEBUG
import AppKit
import FrontportCore
import SwiftUI

/// The main window over `PreviewData` with one screen showing, for Xcode previews. As in the snapshot driver, its
/// intents do nothing.
///
///     #Preview("Port · Runs") {
///         ScreenPreview(.port("shipwright")) { _, viewState in viewState.portTab = .runs }
///     }
struct ScreenPreview: View {
    @State private var model: AppModel
    @State private var viewState: ViewState

    init(
        _ screen: Screen, data: PreviewData = .standard(),
        configure: (AppModel, ViewState) -> Void = { _, _ in }
    ) {
        let model = AppModel(preview: data)
        let viewState = ViewState()
        model.selection = screen
        configure(model, viewState)
        _model = State(initialValue: model)
        _viewState = State(initialValue: viewState)
    }

    var body: some View {
        ContentView()
            .environment(model)
            .environment(viewState)
            .frame(width: SnapshotDriver.size.width, height: SnapshotDriver.size.height)
    }
}

extension View {
    /// What the screens read from the environment, over `PreviewData`: for a view previewed outside the main
    /// window, such as a sheet or Settings.
    func previewEnvironment(_ data: PreviewData = .standard()) -> some View {
        environment(AppModel(preview: data)).environment(ViewState())
    }
}

extension PreviewData {
    /// With one Catalog entry changed, such as to Block its installed Release or mark it Unsupported.
    func changing(_ port: PortID, _ change: (inout CatalogEntry) -> Void) -> PreviewData {
        var data = self
        if let index = data.catalog.ports.firstIndex(where: { $0.id == port }) {
            change(&data.catalog.ports[index])
        }
        return data
    }

    /// With stand-in screenshots for Ship of Harkinian, so its store page shows the viewer. They're drawn
    /// locally into `folder`: never upstream screenshots.
    @MainActor func withStandInScreenshots(
        in folder: URL = FileManager.default.temporaryDirectory.appending(
            path: "frontport-previews/screenshots", directoryHint: .isDirectory)
    ) -> PreviewData {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let symbols = ["mountain.2.fill", "tree.fill", "flame.fill", "water.waves", "sparkles"]
        let screenshots = symbols.enumerated().compactMap { offset, symbol -> URL? in
            let url = folder.appending(path: "shot-\(offset + 1).png")
            let renderer = ImageRenderer(content: StandInScreenshot(number: offset + 1, symbol: symbol))
            renderer.scale = 1
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
                (try? png.write(to: url)) != nil
            else { return nil }
            return url
        }
        return changing("shipwright") { $0.screenshots = screenshots }
    }
}

extension ViewState.IntakeReport {
    /// One of each outcome over the first two ROMs; the unknown and rejected hashes are made up.
    static func sample(_ roms: [ROMRecord]) -> Self {
        var results = roms.prefix(2).enumerated().map { offset, rom in
            offset == 0 ? ROMIntake.added(rom) : .duplicate(rom)
        }
        results.append(.unknown(
            file: URL(filePath: "/Users/Shared/Zelda (Europe).z64"),
            sha1: "8d1c5b8f1a2e3a67d9986f54eb282e8d5bc1ee8b", format: "z64",
            reason: "No ROM in the Catalog has this hash."))
        results.append(.rejected(
            file: URL(filePath: "/Users/Shared/Mario Kart 64 (Hack).z64"),
            sha1: "3a67d9986f54eb282e8d5bc1ee8b2d1c5b8f1a2e",
            reason: "No Port in the Catalog accepts this ROM. It may be damaged, or a ROM hack."))
        return Self(results: results)
    }
}

extension PreviewData {
    /// With OpenGOAL's Jak 3 Unsupported, for the reason the Catalog once gave.
    func withOpenGOALUnsupported() -> PreviewData {
        changing("opengoal-jak3") {
            $0.unsupported = """
                The macOS Release is a set of command-line tools rather than an app, the game can’t run until a \
                second tool has built it from your disc image, and the OpenGOAL Launcher downloads and runs those \
                tools itself. None of that fits one sandboxed app.
                """
        }
    }
}

private struct StandInScreenshot: View {
    let number: Int
    let symbol: String

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hue: Double(number) / 6, saturation: 0.5, brightness: 0.55), .black],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 120))
                Text("Stand-in screenshot \(number)").font(.system(size: 36, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.85))
        }
        .frame(width: 1280, height: 720)
    }
}
#endif
