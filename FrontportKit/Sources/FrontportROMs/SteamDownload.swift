import Foundation
import FrontportCore

/// Downloading a ROM's depots with Steam, for a Game Steam hasn't installed or has installed at another build (ADR
/// 0015). Frontport runs Steam's console command `download_depot` on Steam's command line, so Steam downloads with
/// the user's own sign-in, and follows it in Steam's console log. Steam leaves each depot in a folder of its own and
/// its manifest in `depotcache`, as an install does.
extension SteamLibrary {
    /// Where `download_depot` leaves a depot's files.
    func content(app: Int, depot: Int) -> URL {
        root.appending(path: "Steam.AppBundle/Steam/Contents/MacOS/steamapps/content/app_\(app)/depot_\(depot)", directoryHint: .isDirectory)
    }

    var consoleLog: URL { root.appending(path: "logs/console_log.txt") }

    /// How long Steam may take to start a download, signing in first if it wasn't running.
    static let startTimeout: Duration = .seconds(180)

    /// Has Steam download one depot at one manifest, and returns its folder once Steam says it's complete. `progress`
    /// gets the fraction downloaded, as the folder's size against the size Steam announces.
    func download(
        _ depot: KnownROM.Steam.Depot, of app: Int, name: String, poll: Duration = .seconds(1),
        progress: @Sendable (Double) -> Void
    ) async throws -> URL {
        guard let commandLine = client() else { throw rejected("Steam isn’t installed. Install Steam, sign in, then try again.") }
        let folder = content(app: app, depot: depot.depot)
        // Leftovers of an earlier download would be taken for this one's.
        if FileOperations.exists(folder) { try FileOperations.removeUntrusted(folder) }
        var offset = (try? FileManager.default.attributesOfItem(atPath: consoleLog.path(percentEncoded: false))[.size] as? Int) ?? 0
        try commandLine(["+download_depot", "\(app)", "\(depot.depot)", depot.manifest])

        let started = ContinuousClock.now
        var accepted = false
        var total: Int64?
        var pending = ""
        while true {
            try await Task.sleep(for: poll)
            let (text, next) = Self.read(consoleLog, from: offset)
            offset = next
            pending += text
            var lines = pending.components(separatedBy: "\n")
            pending = lines.removeLast()
            for line in lines {
                if line.contains("ExecCommandLine:"), line.contains("'+download_depot' '\(app)' '\(depot.depot)'") {
                    accepted = true
                } else if !accepted {
                    continue
                } else if let size = Self.announcedSize(in: line, depot: depot.depot) {
                    total = size
                } else if line.contains("Depot download complete"), line.contains("depot_\(depot.depot)\"") {
                    progress(1)
                    return folder
                } else if let range = line.range(of: "Depot download failed : ") {
                    let reason = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                    throw rejected("Steam couldn’t download \(name): \(reason).")
                }
            }
            if !accepted, ContinuousClock.now - started > Self.startTimeout {
                throw rejected("Steam didn’t start downloading \(name). Open Steam and sign in, then try again.")
            }
            if let total, total > 0, let size = try? FileOperations.size(of: folder) {
                progress(min(0.99, Double(size) / Double(total)))
            }
        }
    }

    /// What's been appended to `log` since `offset`, and the offset after it. Steam starts a new log when it starts,
    /// so a log shorter than `offset` is read from its start.
    private static func read(_ log: URL, from offset: Int) -> (String, Int) {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return ("", offset) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()).map(Int.init) ?? 0
        let start = size < offset ? 0 : offset
        try? handle.seek(toOffset: UInt64(start))
        let data = (try? handle.readToEnd()) ?? Data()
        return (String(decoding: data, as: UTF8.self), start + data.count)
    }

    /// The size in "Downloading depot 38405 (171 files, 82 MB) ...".
    private static func announcedSize(in line: String, depot: Int) -> Int64? {
        guard let range = line.range(of: "Downloading depot \(depot) ("), let mb = line[range.upperBound...]
            .split(separator: ",").dropFirst().first?.split(separator: " ").first.flatMap({ Int64($0) })
        else { return nil }
        return mb << 20
    }

    /// Clones the files of `folders` into one folder at `destination`, as Steam would install them into one install
    /// folder: a file in two is the later folder's.
    static func merge(_ folders: [URL], into destination: URL) throws {
        try FileOperations.createDirectory(destination)
        for folder in folders {
            try FileOperations.refuseEscapingLinks(in: folder)
            guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            let base = folder.standardizedFileURL.path(percentEncoded: false)
            for case let file as URL in walker where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                let path = String(file.standardizedFileURL.path(percentEncoded: false).dropFirst(base.count)).trimmingCharacters(in: ["/"])
                let target = destination.appending(path: path)
                try FileOperations.createDirectory(target.deletingLastPathComponent())
                if FileOperations.exists(target) { try FileManager.default.removeItem(at: target) }
                _ = try FileOperations.clone(file, to: target)
            }
        }
    }
}
