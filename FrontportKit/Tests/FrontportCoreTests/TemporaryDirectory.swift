import Foundation
import FrontportCore

/// A unique scratch folder, removed when the test drops it.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "FrontportCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    // Folder ROMs and some tests leave read-only folders, which a plain removal stops at.
    deinit { try? FileOperations.removeUntrusted(url) }

    func file(_ name: String, contents: String) throws -> URL {
        let file = url.appending(path: name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
        return file
    }
}

func read(_ url: URL) throws -> String {
    try String(decoding: Data(contentsOf: url), as: UTF8.self)
}

func mode(of url: URL) throws -> Int {
    try (FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.posixPermissions] as? Int) ?? -1
}
