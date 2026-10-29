import CryptoKit
import SwiftUI

/// A stand-in Port for Frontport's UI tests, published to them by a local server as an upstream Port would be.
///
/// It reads the ROM Frontport Seeds at the path its first argument names, relative to its home (its container's
/// `Data` once sandboxed), counts its launches in its Data, and writes what it found to
/// `Library/Application Support/Testport/report.json` for the tests to read. It shows the same in its window and
/// quits cleanly when asked.
@main
struct TestportApp: App {
    private let report = Report.make()

    var body: some Scene {
        Window("Testport", id: "main") {
            ReportView(report: report)
        }
        .windowResizability(.contentSize)
    }
}

struct Report: Codable {
    struct ROM: Codable {
        var path: String
        var sha1: String
        var size: Int
    }

    var version: String
    var sandboxed: Bool
    var launches: Int
    /// The Seeded ROM, or nil when the path the Catalog gave holds none.
    var rom: ROM?

    static let folder = "Library/Application Support/Testport"

    /// Reads the ROM, counts this launch and writes the report.
    static func make() -> Report {
        let home = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
        let folder = home.appending(path: folder, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let counter = folder.appending(path: "launches")
        let launches = (try? String(contentsOf: counter, encoding: .utf8)).flatMap { Int($0) }.map { $0 + 1 } ?? 1
        try? String(launches).write(to: counter, atomically: true, encoding: .utf8)

        // Xcode and LaunchServices may add `-Key value` arguments; the Catalog's come first and don't start with "-".
        let seedPath = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("-") }
        let rom = seedPath.flatMap { relative -> ROM? in
            let url = home.appending(path: relative)
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
            let sha1 = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return ROM(path: relative, sha1: sha1, size: data.count)
        }

        let report = Report(
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            sandboxed: ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil,
            launches: launches, rom: rom)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report) {
            try? data.write(to: folder.appending(path: "report.json"), options: .atomic)
            print(String(decoding: data, as: UTF8.self))
        }
        return report
    }
}

struct ReportView: View {
    let report: Report

    var body: some View {
        Form {
            LabeledContent("Version", value: report.version)
            LabeledContent("Sandboxed", value: report.sandboxed ? "Yes" : "No")
            LabeledContent("Launches", value: String(report.launches))
            if let rom = report.rom {
                LabeledContent("ROM", value: rom.path)
                LabeledContent("SHA-1", value: rom.sha1)
                LabeledContent("Size", value: rom.size.formatted(.byteCount(style: .file)))
            } else {
                LabeledContent("ROM", value: "None")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize()
    }
}
