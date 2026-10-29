import Darwin
import FrontportCore
import Foundation

/// The code inside an app that is signed before the app itself.
struct CodeLayout: Sendable {
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

    init(app: URL) throws {
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

        nested = items.sorted { a, b in
            let depthA = a.key.split(separator: "/").count
            let depthB = b.key.split(separator: "/").count
            return depthA != depthB ? depthA > depthB : a.key < b.key
        }.map(\.value)
        hasLibraries = files.values.contains(.library)
    }

    /// The bundle's main executable as a path relative to `base` with symlinks resolved, when it exists.
    static func mainExecutable(of bundle: URL, relativeTo base: URL) -> String? {
        let candidates: [(plist: String, executableFolder: String)] = [
            ("Contents/Info.plist", "Contents/MacOS"),
            ("Resources/Info.plist", ""),  // versioned framework, through Versions/Current
            ("Info.plist", ""),  // shallow bundle
        ]
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
