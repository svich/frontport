import Darwin
import Foundation
import FrontportCore
@testable import FrontportBuilder

/// A unique scratch folder, removed when the test drops it.
final class TemporaryDirectory: @unchecked Sendable {
    let url: URL

    init() throws {
        let base = URL(fileURLWithPath: try BuildSandbox.canonical(FileManager.default.temporaryDirectory), isDirectory: true)
        url = base.appending(path: "FrontportBuilderTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    // Folder ROMs and some tests leave read-only folders, which a plain removal stops at.
    deinit { try? FileOperations.removeUntrusted(url) }

    @discardableResult
    func folder(_ path: String) throws -> URL {
        let folder = url.appending(path: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @discardableResult
    func file(_ path: String, contents: String, executable: Bool = false) throws -> URL {
        let file = url.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path(percentEncoded: false))
        }
        return file
    }
}

func read(_ url: URL) throws -> String {
    try String(decoding: Data(contentsOf: url), as: UTF8.self)
}

func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
}

enum Host {
    /// The active developer directory, looked up once with `xcode-select -p`; nil without developer tools.
    static let developerDirectory: URL? = {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }()

    static var hasDeveloperTools: Bool { developerDirectory != nil }

    static var networkTests: Bool { ProcessInfo.processInfo.environment["FRONTPORT_NETWORK_TESTS"] == "1" }
}

/// A TCP listener on 127.0.0.1, so network rules can be tested without the internet.
final class LocalListener {
    let port: UInt16
    private let socket: Int32

    init() throws {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        self.socket = socket
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, length) }
        }
        guard bound == 0, listen(socket, 16) == 0 else {
            close(socket)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
        }
        port = UInt16(bigEndian: address.sin_port)
    }

    deinit { close(socket) }
}

/// A Unix-domain socket listening at a short path under /private/tmp, as a local agent's would.
final class UnixListener {
    let path: String
    private let socket: Int32

    init() throws {
        path = "/private/tmp/frontport-\(UUID().uuidString.prefix(8)).sock"
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        self.socket = socket
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in path.utf8.enumerated() { buffer[index] = byte }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(socket, 16) == 0 else {
            close(socket)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    deinit {
        close(socket)
        unlink(path)
    }
}

extension CatalogEntry {
    static func fixture(_ id: PortID = "testport") -> CatalogEntry {
        CatalogEntry(
            id: id, name: "Test Port", kind: .decomp, game: "test-game", developer: "Tests", summary: "A test Port.",
            description: "", source: URL(string: "https://example.com/test")!, bundleId: id.conventionalBundleID,
            releases: .git(GitSource(repo: "example/test", refs: [.stable: "v1"], recipe: "recipes/test.sh", recipeSHA256: "")))
    }
}

/// Collects progress updates from any thread.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ProgressUpdate] = []

    var updates: [ProgressUpdate] { lock.withLock { stored } }

    var handler: ProgressHandler {
        { update in self.lock.withLock { self.stored.append(update) } }
    }
}
