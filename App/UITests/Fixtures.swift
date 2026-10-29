import AppKit
import CryptoKit
import Foundation
import FrontportCore
import XCTest

/// The repository this test target was built from.
let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

/// The words GLOSSARY.md's Avoid lists name, checked against what the app shows.
enum Glossary {
    struct Violation: CustomStringConvertible {
        var word: String
        var term: String
        var text: String
        var description: String { "“\(word)” (say \(term)) in “\(text)”" }
    }

    /// Avoid lists name nouns; the UI uses these words only as verbs: Install, "Frontport builds it from source",
    /// Copy SHA-1, "Drop ROMs here".
    static let verbs: Set<String> = ["install", "installs", "build", "copy", "drop"]

    /// Names DESIGN.md gives to screens and sections, removed before checking.
    static let names = ["Store Page", "store page", "System Requirements"]

    /// The glossary's terms, such as "Port", in the order it defines them, each with its Avoid list.
    static let entries: [(term: String, avoid: [String])] = {
        let text = (try? String(contentsOf: repository.appending(path: "GLOSSARY.md"), encoding: .utf8)) ?? ""
        var entries: [(term: String, avoid: [String])] = []
        for line in text.split(separator: "\n").map(String.init) {
            if line.hasPrefix("**"), let end = line.dropFirst(2).firstIndex(of: "*") {
                entries.append((String(line[line.index(line.startIndex, offsetBy: 2)..<end]), []))
            } else if line.hasPrefix("_Avoid_:"), !entries.isEmpty {
                entries[entries.count - 1].avoid = line.dropFirst("_Avoid_:".count).split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            }
        }
        return entries
    }()

    static let terms = Set(entries.map(\.term))

    /// Each avoided word or phrase with the term to say instead.
    static let avoided = entries.flatMap { entry in entry.avoid.map { (word: $0, term: entry.term) } }

    static func violations(in strings: [String]) -> [Violation] {
        var result: [Violation] = []
        for original in strings {
            var text = original
            for name in names { text = text.replacingOccurrences(of: name, with: " ") }
            for (word, term) in avoided where !verbs.contains(word.lowercased()) {
                for form in forms(of: word) where contains(text, form) {
                    result.append(Violation(word: form, term: term, text: original))
                }
            }
        }
        return result
    }

    /// The word, its plural, and both capitalized unless that spelling is itself a term ("Game", "Port").
    private static func forms(of word: String) -> [String] {
        var forms = [word]
        if !word.contains(" "), !word.hasSuffix("s") { forms.append(word + "s") }
        let capitalized = forms.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        forms += capitalized.filter { !terms.contains($0) && !terms.contains(String($0.dropLast())) }
        return Array(Set(forms))
    }

    private static func contains(_ text: String, _ word: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: word)
        return text.range(of: "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])", options: .regularExpression) != nil
    }
}

/// The bundled Catalog, read from the app's resources, and what its screens show on an empty root: the Lineup's
/// rules are tested in FrontportKit, so these tests check only that the screens show its answers.
enum BundledCatalog {
    static let document: CatalogDocument = {
        let url = repository.appending(path: "App/Resources/catalog/catalog.json")
        // A Catalog that doesn't decode fails every test that reads it, here rather than as a missing screen.
        return try! JSON.decoder().decode(CatalogDocument.self, from: Data(contentsOf: url))
    }()

    static let lineup = Lineup(catalog: document)
}

/// A made-up file with an N64 header, which intake hashes as it is: nothing in the Catalog accepts it.
struct SyntheticROM {
    let bytes: Data

    init(marker: String) {
        var bytes = Data([0x80, 0x37, 0x12, 0x40])
        let filler = Data("Frontport UI test stand-in, \(marker). ".utf8)
        while bytes.count < 1 << 20 { bytes.append(filler) }
        self.bytes = bytes
    }

    var sha1: String { Insecure.SHA1.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

    func write(to url: URL) throws { try bytes.write(to: url, options: .atomic) }
}

/// A Port's files outside the app: its container in `~/Library/Containers` and what's running.
struct PortFiles {
    let port: String
    var bundleID: String { "dev.frontport.port.\(port)" }

    var container: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Containers/\(bundleID)", directoryHint: .isDirectory)
    }

    var data: URL { container.appending(path: "Data", directoryHint: .isDirectory) }

    var hasData: Bool { FileManager.default.fileExists(atPath: data.path(percentEncoded: false)) }

    /// What's left in the container besides `Data`: macOS keeps the folder and its metadata plist.
    var containerContents: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: container.path(percentEncoded: false))) ?? []
    }

    var running: [NSRunningApplication] { NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) }

    /// The installed app in a Frontport root.
    func app(in root: URL) -> URL? {
        let folder = root.appending(path: "Library/\(port)", directoryHint: .isDirectory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        return names.first { $0.hasSuffix(".app") }.map { folder.appending(path: $0, directoryHint: .isDirectory) }
    }

    /// The app's entitlements, as `codesign -d --entitlements - --xml` prints them.
    static func entitlements(of app: URL) -> [String: Any] {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/codesign")
        process.arguments = ["-d", "--entitlements", "-", "--xml", app.path(percentEncoded: false)]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [:] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] ?? [:]
    }

    /// Whether the process runs in a sandbox, by `sandbox_check(pid, NULL, SANDBOX_FILTER_NONE)`.
    static func isSandboxed(_ pid: pid_t) -> Bool {
        typealias Check = @convention(c) (pid_t, UnsafePointer<CChar>?, Int32) -> Int32
        // RTLD_DEFAULT, which Swift doesn't import.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_check") else { return false }
        return unsafeBitCast(symbol, to: Check.self)(pid, nil, 0) == 1
    }
}
