import Darwin
import FrontportCore
import Foundation

/// The code inside an app that is signed before the app itself.
struct CodeLayout: Sendable {
    /// How the app is laid out.
    enum Layout: Hashable, Sendable {
        /// A Mac app: its code under `Contents/`, in the code locations.
        case mac
        /// An iPhone and iPad app: flat, with its main executable and `Info.plist` at the top, frameworks in
        /// `Frameworks/`, and no program but its own executable that Frontport signs.
        case flat
    }

    struct Item: Hashable, Sendable {
        enum Kind: Hashable, Sendable {
            /// A loose Mach-O file.
            case file
            /// A framework, nested app, XPC service or plug-in, signed as a bundle.
            case bundle
        }

        var url: URL
        var kind: Kind
        /// A program (a helper, or a nested app's or XPC service's executable) rather than a library.
        var isExecutable: Bool
    }

    /// Where nested code lives in a bundle, relative to its `Contents/`, where none of the Packager's links may be.
    /// Programs are signed wherever they are, so none keeps an upstream signature that would let it run unsandboxed.
    static let codeLocations = PortLinks.codeLocations

    /// Directory extensions signed as bundles when they hold a Mach-O executable.
    static let bundleExtensions: Set<String> = ["app", "framework", "xpc", "appex", "bundle", "plugin"]

    /// Nested code, deepest first, so every item is signed before whatever contains it.
    var nested: [Item]
    /// True when a library (dylib, framework or loadable bundle) is anywhere in the app.
    var hasLibraries: Bool
    /// In a flat app, by path, code iOS wouldn't run from it or Frontport doesn't sign: programs other than the main
    /// executable, app extensions, nested apps and XPC services (each listed, not what's inside), and `Watch/`. Always
    /// empty for a Mac app.
    var refused: [URL] = []

    init(app: URL, layout: Layout = .mac) throws {
        let app = app.resolvingSymlinksInPath()
        guard let paths = FileManager.default.enumerator(atPath: app.path(percentEncoded: false)) else {
            throw FrontportError.signingFailed("Couldn’t read \(app.lastPathComponent)")
        }

        var files: [String: MachO.FileType] = [:]
        var directories: [String] = []
        for case let relative as String in paths {
            let url = app.appending(path: relative)
            var info = stat()
            guard lstat(url.path(percentEncoded: false), &info) == 0 else { continue }
            switch info.st_mode & S_IFMT {
            case S_IFREG:
                if let type = MachO.fileType(of: url) { files[relative] = type }
            case S_IFDIR:
                directories.append(relative)
            default:
                break
            }
        }

        hasLibraries = files.values.contains(.library)
        if layout == .flat {
            (nested, refused) = Self.flat(app: app, files: files, directories: directories)
            return
        }

        let nestedApps = directories.filter { $0.hasSuffix(".app") }
        let roots = ([""] + nestedApps).flatMap { bundle in
            Self.codeLocations.map { (bundle.isEmpty ? "" : bundle + "/") + "Contents/\($0)/" }
        }
        func inCodeLocation(_ relative: String) -> Bool {
            roots.contains { relative.hasPrefix($0) }
        }

        var items: [String: Item] = [:]
        var bundleExecutables: Set<String> = []
        if let main = Self.mainExecutable(of: app, relativeTo: app) { bundleExecutables.insert(main) }
        for directory in directories
        where Self.bundleExtensions.contains((directory as NSString).pathExtension)
            && (inCodeLocation(directory) || directory.hasSuffix(".app"))
        {
            guard let executable = Self.mainExecutable(of: app.appending(path: directory), relativeTo: app),
                let type = files[executable]
            else { continue }
            bundleExecutables.insert(executable)
            items[directory] = Item(
                url: app.appending(path: directory, directoryHint: .isDirectory), kind: .bundle,
                isExecutable: type == .executable)
        }
        for (relative, type) in files
        where (inCodeLocation(relative) || type == .executable) && !bundleExecutables.contains(relative) {
            items[relative] = Item(url: app.appending(path: relative), kind: .file, isExecutable: type == .executable)
        }

        nested = Self.deepestFirst(items)
    }

    /// A flat app's: each framework as a bundle and every other library, anywhere, as a file. Code inside what's
    /// refused isn't listed, since the app is refused anyway.
    private static func flat(
        app: URL, files: [String: MachO.FileType], directories: [String]
    ) -> (nested: [Item], refused: [URL]) {
        let refusedBundles = directories.filter { directory in
            directory.split(separator: "/").first == "Watch"
                || ["app", "appex", "xpc"].contains((directory as NSString).pathExtension)
        }
        func inside(_ relative: String, _ folders: [String]) -> Bool {
            folders.contains { relative.hasPrefix($0 + "/") }
        }
        let outermost = refusedBundles.filter { !inside($0, refusedBundles) }

        var items: [String: Item] = [:]
        var bundleExecutables: Set<String> = []
        if let main = mainExecutable(of: app, relativeTo: app, layout: .flat) { bundleExecutables.insert(main) }
        for directory in directories
        where (directory as NSString).pathExtension == "framework" && !inside(directory, outermost) {
            guard let executable = mainExecutable(of: app.appending(path: directory), relativeTo: app, layout: .flat),
                files[executable] == .library
            else { continue }
            bundleExecutables.insert(executable)
            items[directory] = Item(
                url: app.appending(path: directory, directoryHint: .isDirectory), kind: .bundle, isExecutable: false)
        }
        var refused = outermost
        for (relative, type) in files where !bundleExecutables.contains(relative) && !inside(relative, outermost) {
            switch type {
            case .library: items[relative] = Item(url: app.appending(path: relative), kind: .file, isExecutable: false)
            case .executable: refused.append(relative)
            case .other: break
            }
        }
        return (deepestFirst(items), refused.sorted().map { app.appending(path: $0) })
    }

    private static func deepestFirst(_ items: [String: Item]) -> [Item] {
        items.sorted { a, b in
            let depthA = a.key.split(separator: "/").count
            let depthB = b.key.split(separator: "/").count
            return depthA != depthB ? depthA > depthB : a.key < b.key
        }.map(\.value)
    }

    /// The bundle's main executable as a path relative to `base` with symlinks resolved, when it exists. In a flat
    /// layout every bundle is shallow, with its `Info.plist` at the top.
    static func mainExecutable(of bundle: URL, relativeTo base: URL, layout: Layout = .mac) -> String? {
        let candidates: [(plist: String, executableFolder: String)] = switch layout {
        case .mac: [
            ("Contents/Info.plist", "Contents/MacOS"),
            ("Resources/Info.plist", ""),  // versioned framework, through Versions/Current
            ("Info.plist", ""),  // shallow bundle
        ]
        case .flat: [("Info.plist", "")]
        }
        for candidate in candidates {
            let plist = bundle.appending(path: candidate.plist)
            guard let data = try? Data(contentsOf: plist),
                let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                let name = info["CFBundleExecutable"] as? String, !name.isEmpty
            else { continue }
            var executable = bundle
            if !candidate.executableFolder.isEmpty {
                executable = executable.appending(path: candidate.executableFolder, directoryHint: .isDirectory)
            }
            executable = executable.appending(path: name).resolvingSymlinksInPath()
            let basePath = base.resolvingSymlinksInPath().path(percentEncoded: false)
            let path = executable.path(percentEncoded: false)
            let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
            guard path.hasPrefix(prefix), FileManager.default.fileExists(atPath: path) else { return nil }
            return String(path.dropFirst(prefix.count))
        }
        return nil
    }
}
