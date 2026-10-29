#if DEBUG
import AppKit
import FrontportCore
import ObjectiveC
import SwiftUI

/// `-FrontportSnapshots <dir>`: visits every screen in light and dark appearance, writes each window to a
/// PNG in `<dir>`, then quits. Draws through `cacheDisplay`, so it needs no Screen Recording permission.
///
/// It shows preview data unless `-FrontportSnapshotsLive` is also given: then the model runs on the real services
/// (over `FRONTPORT_ROOT`, if set), loads and checks for updates first, and the Port pages show the first Port in
/// the Library.
@MainActor
enum SnapshotDriver {
    static let directory: URL? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-FrontportSnapshots"), arguments.indices.contains(index + 1)
        else { return nil }
        return URL(filePath: arguments[index + 1], directoryHint: .isDirectory)
    }()

    static var isActive: Bool { directory != nil }

    static var isLive: Bool { ProcessInfo.processInfo.arguments.contains("-FrontportSnapshotsLive") }

    static let size = CGSize(width: 1280, height: 820)

    private struct Shot {
        var name: String
        /// Also captured at this height, to see the whole page.
        var fullHeight: CGFloat?
        /// Needs a state only the preview data has.
        var previewOnly = false
        var apply: @MainActor (AppModel, ViewState) -> Void
    }

    /// The Library Port the Port pages show.
    private static var port: PortID = "shipwright"

    private static let shots: [Shot] = [
        Shot(name: "catalog", fullHeight: 2450) { model, _ in
            model.selection = .catalog
        },
        Shot(name: "platform-n64", fullHeight: 1100) { model, _ in
            model.selection = .platform("n64")
        },
        Shot(name: "library-grid") { model, _ in
            model.libraryLayout = .grid
            model.selection = .library
        },
        Shot(name: "library-list") { model, _ in
            model.libraryLayout = .list
            model.selection = .library
        },
        Shot(name: "store-shipwright", fullHeight: 1400) { model, _ in
            model.selection = .store("shipwright")
        },
        Shot(name: "game-super-mario-64", fullHeight: 1000) { model, _ in
            model.selection = .game("super-mario-64")
        },
        Shot(name: "store-ghostship", fullHeight: 1400) { model, _ in
            model.selection = .store("ghostship")
        },
        Shot(name: "store-opengoal-jak1", fullHeight: 1400) { model, _ in
            model.selection = .store("opengoal-jak1")
        },
        Shot(name: "store-macnativegames-totk", fullHeight: 1600, previewOnly: true) { model, _ in
            model.selection = .store("macnativegames-totk")
        },
        Shot(name: "project-opengoal", fullHeight: 1500) { model, _ in
            model.selection = .project("open-goal/jak-project")
        },
        Shot(name: "project-nxnative", fullHeight: 1200, previewOnly: true) { model, _ in
            model.selection = .project("seedds/nxnative")
        },
        Shot(name: "platform-switch", fullHeight: 1100, previewOnly: true) { model, _ in
            model.selection = .platform("switch")
        },
        Shot(name: "releases", fullHeight: 1750) { model, _ in
            model.selection = .releases
        },
        Shot(name: "roms") { model, _ in
            model.selection = .roms
        },
        Shot(name: "port-overview", fullHeight: 1150) { model, state in
            model.selection = .port(port)
            state.portTab = .overview
        },
        Shot(name: "port-snapshots") { model, state in
            model.selection = .port(port)
            state.portTab = .snapshots
        },
        Shot(name: "port-runs") { model, state in
            model.selection = .port(port)
            state.portTab = .runs
        },
        Shot(name: "port-building", previewOnly: true) { model, state in
            model.selection = .port("starship")
            state.portTab = .overview
        },
        Shot(name: "port-unseeded", previewOnly: true) { model, state in
            model.selection = .port("zelda64recomp")
            state.portTab = .overview
        },
        Shot(name: "search") { model, _ in
            model.selection = .library
            model.searchText = "mario"
        },
    ]

    static func run(model: AppModel, viewState: ViewState, openSettings: OpenSettingsAction) async {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if isLive {
            await model.load()
            await model.refresh()
            if let first = model.survey.libraryPorts.first { port = first.id }
            model.selection = model.initialScreen
        }
        try? await Task.sleep(for: .seconds(1))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else {
            NSApp.terminate(nil)
            return
        }
        allowFramesTallerThanScreen(window)
        let layout = model.libraryLayout
        let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
        for (suffix, appearance) in appearances {
            NSApp.appearance = NSAppearance(named: appearance)
            for shot in shots where !(isLive && shot.previewOnly) {
                model.searchText = ""
                shot.apply(model, viewState)
                resize(window, height: size.height)
                await settle()
                capture(window, named: "\(shot.name)-\(suffix)", in: directory)
                if let fullHeight = shot.fullHeight {
                    resize(window, height: fullHeight)
                    await settle()
                    capture(window, named: "\(shot.name)-full-\(suffix)", in: directory)
                }
            }
            model.searchText = ""
            model.selection = .roms
            viewState.intakeReport = .sample(model.survey.roms)
            await settle()
            if let sheet = window.attachedSheet {
                capture(sheet, named: "intake-\(suffix)", in: directory)
            }
            viewState.intakeReport = nil
            await settle()
            openSettings()
            await settle()
            if let settings = NSApp.windows.first(where: { $0 !== window && $0.isVisible && $0.canBecomeKey }) {
                capture(settings, named: "settings-\(suffix)", in: directory)
                settings.close()
            }
        }
        model.libraryLayout = layout
        NSApp.terminate(nil)
    }

    private static func settle() async {
        try? await Task.sleep(for: .milliseconds(900))
    }

    private static func resize(_ window: NSWindow, height: CGFloat) {
        var frame = window.frame
        frame.origin.y += frame.height - height
        frame.size = CGSize(width: size.width, height: height)
        window.setFrame(frame, display: true)
    }

    /// AppKit keeps titled windows within the screen; lift that so pages render at full height on a small display.
    private static func allowFramesTallerThanScreen(_ window: NSWindow) {
        let selector = #selector(NSWindow.constrainFrameRect(_:to:))
        guard let method = class_getInstanceMethod(type(of: window), selector) else { return }
        let unconstrained: @convention(block) (NSWindow, NSRect, NSScreen?) -> NSRect = { _, rect, _ in rect }
        class_replaceMethod(
            type(of: window), selector, imp_implementationWithBlock(unconstrained), method_getTypeEncoding(method))
    }

    /// Writes `<name>.png` from the window's theme frame, so the toolbar is included.
    ///
    /// `cacheDisplay` skips what sits inside an `NSGlassEffectView`, such as the sidebar, so each glass view's
    /// content is drawn again on a flat stand-in for the glass; glass buttons in the content get one too.
    private static func capture(_ window: NSWindow, named name: String, in directory: URL) {
        guard let root = window.contentView?.superview ?? window.contentView,
            let output = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(root.bounds.width * window.backingScaleFactor),
                pixelsHigh: Int(root.bounds.height * window.backingScaleFactor), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                bitsPerPixel: 0)
        else { return }
        output.size = root.bounds.size
        root.layoutSubtreeIfNeeded()
        let isDark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: output)
        draw(root, in: root)
        for glass in descendants(of: root).compactMap({ $0 as? NSGlassEffectView }) {
            guard let content = glass.contentView else { continue }
            let frame = rect(of: glass, in: root)
            let isSidebar = frame.height > 200
            NSGraphicsContext.saveGraphicsState()
            if isSidebar {
                // Leave the toolbar area above the list as captured.
                let inset = descendants(of: content).compactMap { $0 as? NSScrollView }.first?.contentInsets.top ?? 0
                NSBezierPath(rect: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height - inset))
                    .addClip()
                (isDark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 1, alpha: 1)).setFill()
                frame.fill()
                (isDark ? NSColor(white: 0.19, alpha: 1) : NSColor(white: 0.955, alpha: 1)).setFill()
                NSBezierPath(roundedRect: frame.insetBy(dx: 8, dy: 8), xRadius: 18, yRadius: 18).fill()
            } else {
                (isDark ? NSColor(white: 0.24, alpha: 1) : NSColor(white: 1, alpha: 1)).setFill()
                let radius = min(frame.height, frame.width) / 2
                NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).fill()
            }
            draw(content, in: root)
            // List rows don't draw as part of their table; draw each one.
            for row in descendants(of: content).compactMap({ $0 as? NSTableRowView }) where !row.isHidden {
                draw(row, in: root)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        for view in [root] + descendants(of: root) {
            drawGlassButtons(of: view, in: root, isDark: isDark, scale: window.backingScaleFactor)
        }
        NSGraphicsContext.restoreGraphicsState()
        try? output.representation(using: .png, properties: [:])?.write(to: directory.appending(path: "\(name).png"))
    }

    /// Glass buttons are drawn by layers `cacheDisplay` skips: the glass by a backdrop, the label through a vibrancy
    /// filter that depends on what's behind it. Draws each of a view's on a flat capsule, its label and icon in the
    /// label color. A prominent button's tint isn't in any layer, so it shows as plain glass. The toolbar and the
    /// sidebar keep their own glass.
    private static func drawGlassButtons(of view: NSView, in root: NSView, isDark: Bool, scale: CGFloat) {
        let isApart = sequence(first: view, next: \.superview).contains {
            "\(type(of: $0))".contains("Toolbar") || ($0 is NSGlassEffectView && $0.frame.height > 200)
        }
        guard !isApart, let layer = view.layer, let context = NSGraphicsContext.current?.cgContext else { return }
        for button in sublayers(of: layer, ownLayersOf: view).filter({ "\(type(of: $0))" == "SDFLayer" })
        where button.bounds.height <= 40 {
            let labels = sublayers(of: button, ownLayersOf: view)
                .filter { ["CGDrawingLayer", "ImageLayer"].contains("\(type(of: $0))") }
            // A glass search field or menu: nothing to redraw it from.
            guard !labels.isEmpty else { continue }
            let frame = rect(of: button, in: view, root: root)
            let capsule = NSBezierPath(roundedRect: frame, xRadius: frame.height / 2, yRadius: frame.height / 2)
            (isDark ? NSColor(white: 0.3, alpha: 1) : .white).setFill()
            capsule.fill()
            if !isDark {
                NSColor(white: 0, alpha: 0.14).setStroke()
                capsule.lineWidth = 0.5
                capsule.stroke()
            }
            for label in labels {
                guard let mask = mask(of: label, scale: scale, isFlipped: view.isFlipped) else { continue }
                let frame = rect(of: label, in: view, root: root)
                context.saveGState()
                context.clip(to: frame, mask: mask)
                context.setFillColor((isDark ? NSColor.white : NSColor(white: 0.1, alpha: 1)).cgColor)
                context.fill(frame)
                context.restoreGState()
            }
        }
    }

    /// A layer's frame in `root`, in the bottom-left origin of the output image.
    private static func rect(of layer: CALayer, in view: NSView, root: NSView) -> CGRect {
        guard let viewLayer = view.layer else { return .zero }
        var frame = view.convert(viewLayer.convert(layer.bounds, from: layer), to: root)
        if root.isFlipped { frame.origin.y = root.bounds.height - frame.maxY }
        return frame
    }

    /// A layer's sublayers, deep, leaving out other views' layers and the glass's backdrop copies.
    private static func sublayers(of layer: CALayer, ownLayersOf view: NSView) -> [CALayer] {
        (layer.sublayers ?? []).flatMap { sublayer -> [CALayer] in
            if let owner = sublayer.delegate as? NSView, owner !== view { return [] }
            if ["Backdrop", "Portal"].contains(where: "\(type(of: sublayer))".contains) { return [] }
            return [sublayer] + sublayers(of: sublayer, ownLayersOf: view)
        }
    }

    /// What a label layer covers, drawn on its own.
    private static func mask(of label: CALayer, scale: CGFloat, isFlipped: Bool) -> CGImage? {
        let width = Int(label.bounds.width * scale), height = Int(label.bounds.height * scale)
        guard width > 0, height > 0,
            let bitmap = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        if isFlipped {
            bitmap.translateBy(x: 0, y: CGFloat(height))
            bitmap.scaleBy(x: scale, y: -scale)
        } else {
            bitmap.scaleBy(x: scale, y: scale)
        }
        label.render(in: bitmap)
        return bitmap.makeImage()
    }

    /// Draws a view's `cacheDisplay` image where it sits in `root`.
    private static func draw(_ view: NSView, in root: NSView) {
        guard view.bounds.width > 0, view.bounds.height > 0,
            let image = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: image)
        image.draw(in: rect(of: view, in: root), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
    }

    /// A view's frame in `root`, in the bottom-left origin of the output image.
    private static func rect(of view: NSView, in root: NSView) -> CGRect {
        var frame = view.convert(view.bounds, to: root)
        if root.isFlipped { frame.origin.y = root.bounds.height - frame.maxY }
        return frame
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// Standard preview data, with stand-in screenshots for Ship of Harkinian so the store page shows its viewer.
    static func previewData() -> PreviewData {
        guard let directory else { return .standard() }
        return .standard().withStandInScreenshots(in: directory.appending(path: "screenshots", directoryHint: .isDirectory))
    }
}
#endif
