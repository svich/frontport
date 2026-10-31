import Darwin
import Foundation
import FrontportCore

/// The user's Steam libraries, read from the files Steam keeps there, so Steam needn't be running: its library list,
/// an app manifest (`appmanifest_<app>.acf`) per installed app, and the depot manifests in `depotcache` that list each
/// depot's files with their SHA-1s. Frontport only reads them, and never signs in to Steam.
public struct SteamLibrary: Sendable {
    /// Steam's own folder, which holds `depotcache` and the first library.
    public var root: URL

    public init(root: URL) {
        self.root = root
    }

    public static let `default` = SteamLibrary(
        root: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Steam", directoryHint: .isDirectory))

    /// An app Steam has installed.
    struct App: Hashable, Sendable {
        var id: Int
        var name: String
        var buildID: String?
        /// The install folder, `steamapps/common/<installdir>` in its library.
        var folder: URL
        /// The library's own folder, whose `steamapps/depotcache` may hold its manifests.
        var library: URL
        var depots: [Depot]
    }

    struct Depot: Hashable, Sendable {
        var id: Int
        var manifest: String
    }

    /// The libraries Steam lists, its own folder first.
    func libraries() -> [URL] {
        var libraries = [root]
        let list = root.appending(path: "steamapps/libraryfolders.vdf")
        if let text = try? String(contentsOf: list, encoding: .utf8), let folders = try? KeyValues.parse(text)["libraryfolders"] {
            for (_, folder) in folders.children {
                guard let path = folder["path"]?.string, !path.isEmpty else { continue }
                let url = URL(filePath: path, directoryHint: .isDirectory)
                if !libraries.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) { libraries.append(url) }
            }
        }
        return libraries
    }

    /// Every app fully installed in any library. An app Steam is still downloading or updating isn't.
    func apps() -> [App] {
        var apps: [App] = []
        for library in libraries() {
            let steamapps = library.appending(path: "steamapps", directoryHint: .isDirectory)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: steamapps.path(percentEncoded: false))) ?? []
            for name in names.sorted() where name.hasPrefix("appmanifest_") && name.hasSuffix(".acf") {
                guard let text = try? String(contentsOf: steamapps.appending(path: name), encoding: .utf8),
                    let state = try? KeyValues.parse(text)["AppState"],
                    let id = state["appid"]?.string.flatMap({ Int($0) }),
                    let installdir = state["installdir"]?.string, !installdir.isEmpty, !installdir.contains("/"),
                    installdir != ".", installdir != "..",
                    // StateFlags 4 is fully installed; any other flag is an update, a download or a validation underway.
                    state["StateFlags"]?.string == "4"
                else { continue }
                let depots = (state["InstalledDepots"]?.children ?? []).compactMap { key, depot -> Depot? in
                    guard let id = Int(key), let manifest = depot["manifest"]?.string, UInt64(manifest) != nil else { return nil }
                    return Depot(id: id, manifest: manifest)
                }
                apps.append(App(
                    id: id, name: state["name"]?.string ?? "App \(id)", buildID: state["buildid"]?.string,
                    folder: steamapps.appending(path: "common/\(installdir)", directoryHint: .isDirectory),
                    library: library, depots: depots))
            }
        }
        return apps
    }

    /// The depot manifest Steam keeps for an installed depot: in its own `depotcache`, or in the library's.
    func manifest(of depot: Depot, in app: App) -> URL? {
        let name = "\(depot.id)_\(depot.manifest).manifest"
        return [root.appending(path: "depotcache/\(name)"), app.library.appending(path: "steamapps/depotcache/\(name)")]
            .first { FileOperations.exists($0) }
    }

    /// What a folder ROM in the app holds by Steam's manifests: the files under `folder` (the install folder when nil),
    /// with the SHA-1 each should have, leaving out `configs` and, as `FolderContents` does, hidden files.
    func contents(of app: App, folder: String?, leaving configs: Set<String>) throws -> SteamContents {
        // An added Catalog isn't linted, so its folder mustn't lead out of the install folder.
        if let folder, folder.isEmpty || folder.hasPrefix("/")
            || folder.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        {
            throw rejected("The Catalog names a Steam folder outside \(app.name)’s install folder.")
        }
        let prefix = folder.map { $0 + "/" } ?? ""
        var hashes: [String: (sha1: String, size: Int64)] = [:]
        for depot in app.depots {
            guard let url = manifest(of: depot, in: app) else {
                throw rejected("Steam’s list of the files of \(app.name) is missing. Verify its files in Steam, then try again.")
            }
            for entry in try DepotManifest.entries(of: url) where entry.path.hasPrefix(prefix) && !entry.isDirectory {
                let path = String(entry.path.dropFirst(prefix.count))
                guard !path.split(separator: "/").contains(where: { $0.hasPrefix(".") }), !configs.contains(path) else { continue }
                guard !entry.isLink else { throw rejected("\(entry.path) in \(app.name) is a symbolic link, which a ROM can’t hold.") }
                hashes[path] = (entry.sha1, entry.size)
            }
        }
        guard !hashes.isEmpty else { throw rejected("Steam lists no files for \(app.name) in \(folder ?? "its folder").") }
        let files = hashes.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.map {
            SteamContents.File(file: FolderContents.File(path: $0, size: hashes[$0]!.size), sha1: hashes[$0]!.sha1)
        }
        let location = folder.map { app.folder.appending(path: $0, directoryHint: .isDirectory) } ?? app.folder
        return SteamContents(folder: location, files: files)
    }

    private func rejected(_ reason: String) -> FrontportError {
        .romRejected(sha1: nil, reason: reason)
    }
}

/// A folder ROM as Steam's manifests list it.
struct SteamContents: Hashable, Sendable {
    struct File: Hashable, Sendable {
        var file: FolderContents.File
        /// What Steam says its SHA-1 is.
        var sha1: String
    }

    /// Where it is on disk.
    var folder: URL
    /// Sorted by path, as `FolderContents.files` sorts them.
    var files: [File]

    /// The identity the folder has if its files are as Steam installed them, worked out without reading them.
    var sha1: String {
        FolderContents.identity(of: files.map { ($0.file.path, $0.sha1) })
    }
}

/// A Steam depot manifest: the sections Steam writes, each a little-endian magic number and length followed by a
/// protobuf message. Only the payload is read: its file mappings, each a file's name, size, flags and SHA-1.
enum DepotManifest {
    struct Entry: Hashable, Sendable {
        /// Relative to the install folder, `/` between components, though Steam writes `\`.
        var path: String
        var size: Int64
        var flags: UInt64
        /// Lowercase hex. Steam writes all zeros for an empty file; this is the SHA-1 of nothing instead.
        var sha1: String

        var isDirectory: Bool { flags & 64 != 0 }
        var isLink: Bool { flags & 512 != 0 }
    }

    private static let payload: UInt32 = 0x71F6_17D0
    private static let metadata: UInt32 = 0x1F48_12BE
    private static let end: UInt32 = 0x32C4_15AB
    private static let emptySHA1 = "da39a3ee5e6b4b0d3255bfef95601890afd80709"

    static func entries(of url: URL) throws -> [Entry] {
        let data = try Data(contentsOf: url)
        var offset = 0
        var entries: [Entry]?
        func uint32() throws -> UInt32 {
            guard offset + 4 <= data.count else { throw malformed(url) }
            let value = data[data.startIndex + offset..<data.startIndex + offset + 4].enumerated()
                .reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
            offset += 4
            return value
        }
        while offset < data.count {
            let magic = try uint32()
            if magic == end { break }
            let length = Int(try uint32())
            guard offset + length <= data.count else { throw malformed(url) }
            let section = data.subdata(in: data.startIndex + offset..<data.startIndex + offset + length)
            offset += length
            switch magic {
            case payload: entries = try mappings(in: section, of: url)
            case metadata:
                // Field 4 is `filenames_encrypted`: names only Steam's depot key can read.
                if try Protobuf.fields(section).contains(where: { $0.number == 4 && $0.varint == 1 }) {
                    throw FrontportError.romRejected(sha1: nil, reason: "Steam’s list of these files hides their names.")
                }
            default: continue
            }
        }
        guard let entries else { throw malformed(url) }
        return entries
    }

    private static func mappings(in payload: Data, of url: URL) throws -> [Entry] {
        try Protobuf.fields(payload).filter { $0.number == 1 }.map { mapping in
            guard let message = mapping.bytes else { throw malformed(url) }
            var name: String?
            var size: UInt64 = 0
            var flags: UInt64 = 0
            var sha1: Data?
            for field in try Protobuf.fields(message) {
                switch field.number {
                case 1: name = field.bytes.flatMap { String(data: $0, encoding: .utf8) }
                case 2: size = field.varint ?? 0
                case 3: flags = field.varint ?? 0
                case 5: sha1 = field.bytes
                default: continue
                }
            }
            guard let name, !name.isEmpty, size <= UInt64(Int64.max) else { throw malformed(url) }
            let path = name.replacingOccurrences(of: "\\", with: "/")
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else {
                throw malformed(url)
            }
            let hex = (sha1 ?? Data()).map { String(format: "%02x", $0) }.joined()
            let isEmpty = hex.isEmpty || hex.allSatisfy { $0 == "0" }
            guard isEmpty || hex.count == 40 else { throw malformed(url) }
            return Entry(path: path, size: Int64(size), flags: flags, sha1: isEmpty ? emptySHA1 : hex)
        }
    }

    private static func malformed(_ url: URL) -> FrontportError {
        .romRejected(sha1: nil, reason: "Steam’s list of files \(url.lastPathComponent) couldn’t be read.")
    }
}

/// Just enough protobuf to read a depot manifest: each field's number, and its varint or length-delimited bytes.
enum Protobuf {
    struct Field {
        var number: UInt64
        var varint: UInt64?
        var bytes: Data?
    }

    struct Malformed: Error {}

    static func fields(_ data: Data) throws -> [Field] {
        let bytes = [UInt8](data)
        var index = 0
        func varint() throws -> UInt64 {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard index < bytes.count, shift < 64 else { throw Malformed() }
                let byte = bytes[index]
                index += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte < 0x80 { return value }
                shift += 7
            }
        }
        var fields: [Field] = []
        while index < bytes.count {
            let key = try varint()
            var field = Field(number: key >> 3)
            switch key & 7 {
            case 0: field.varint = try varint()
            case 1, 5:
                let width = key & 7 == 1 ? 8 : 4
                guard index + width <= bytes.count else { throw Malformed() }
                index += width
            case 2:
                let length = try varint()
                guard length <= UInt64(bytes.count - index) else { throw Malformed() }
                field.bytes = Data(bytes[index..<index + Int(length)])
                index += Int(length)
            default: throw Malformed()
            }
            fields.append(field)
        }
        return fields
    }
}

/// Valve's KeyValues text, as in `.acf` and `.vdf` files: quoted keys, each followed by a quoted value or a braced
/// block of more. Keys are matched case-insensitively, as Steam does.
indirect enum KeyValues {
    case string(String)
    case block([(String, KeyValues)])

    struct Malformed: Error {}

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var children: [(String, KeyValues)] {
        if case .block(let children) = self { return children }
        return []
    }

    subscript(_ key: String) -> KeyValues? {
        children.first { $0.0.caseInsensitiveCompare(key) == .orderedSame }?.1
    }

    static func parse(_ text: String) throws -> KeyValues {
        var tokens = try tokenize(text)[...]
        let parsed = try block(&tokens)
        guard tokens.isEmpty else { throw Malformed() }
        return parsed
    }

    private enum Token: Equatable {
        case text(String)
        case open
        case close
    }

    private static func block(_ tokens: inout ArraySlice<Token>) throws -> KeyValues {
        var children: [(String, KeyValues)] = []
        while let token = tokens.first {
            if token == .close { break }
            guard case .text(let key) = tokens.removeFirst(), let next = tokens.first else { throw Malformed() }
            switch next {
            case .text(let value):
                tokens.removeFirst()
                children.append((key, .string(value)))
            case .open:
                tokens.removeFirst()
                children.append((key, try block(&tokens)))
                guard tokens.first == .close else { throw Malformed() }
                tokens.removeFirst()
            case .close: throw Malformed()
            }
        }
        return .block(children)
    }

    private static func tokenize(_ text: String) throws -> [Token] {
        var tokens: [Token] = []
        var characters = text.unicodeScalars[...]
        while let character = characters.first {
            switch character {
            case "{": tokens.append(.open); characters.removeFirst()
            case "}": tokens.append(.close); characters.removeFirst()
            case "\"":
                characters.removeFirst()
                var value = ""
                while true {
                    guard let next = characters.popFirst() else { throw Malformed() }
                    if next == "\"" { break }
                    if next == "\\", let escaped = characters.popFirst() {
                        switch escaped {
                        case "n": value += "\n"
                        case "t": value += "\t"
                        default: value.unicodeScalars.append(escaped)
                        }
                    } else {
                        value.unicodeScalars.append(next)
                    }
                }
                tokens.append(.text(value))
            case "/" where characters.dropFirst().first == "/":
                while let next = characters.first, next != "\n" { characters.removeFirst() }
            case "[":
                // A platform condition such as `[$WIN32]`, which nothing Frontport reads uses.
                while let next = characters.popFirst(), next != "]" {}
            default:
                guard character.properties.isWhitespace else {
                    // An unquoted token.
                    var value = ""
                    while let next = characters.first, !next.properties.isWhitespace, !"{}\"".unicodeScalars.contains(next) {
                        value.unicodeScalars.append(next)
                        characters.removeFirst()
                    }
                    tokens.append(.text(value))
                    continue
                }
                characters.removeFirst()
            }
        }
        return tokens
    }
}
