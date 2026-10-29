import Foundation
import FrontportCore

/// The Xcode Command Line Tools (or Xcode), looked up without ever triggering the install prompt.
public struct DeveloperTools: Sendable {
    /// The active developer directory, or nil when none is installed.
    public var directory: @Sendable () async -> URL?
    /// Shows the system's Command Line Tools installer and returns without waiting for it.
    public var requestInstall: @Sendable () async -> Void
    /// The macOS SDK of a developer directory, if it has one.
    public var sdk: @Sendable (_ developerDirectory: URL) async -> URL?
    /// The `Metal.xctoolchain` folder of a developer directory, if Xcode has one. Xcode 26 and later download it
    /// as a separate component, mounted inside the user's home folder, where xcrun in the build sandbox can't find it.
    public var metalToolchain: @Sendable (_ developerDirectory: URL) async -> URL?

    public init(
        directory: @escaping @Sendable () async -> URL?,
        requestInstall: @escaping @Sendable () async -> Void,
        sdk: @escaping @Sendable (URL) async -> URL?,
        metalToolchain: @escaping @Sendable (URL) async -> URL? = { _ in nil }
    ) {
        self.directory = directory
        self.requestInstall = requestInstall
        self.sdk = sdk
        self.metalToolchain = metalToolchain
    }

    private static let xcodeSelect = URL(fileURLWithPath: "/usr/bin/xcode-select")
    private static let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")

    public static let system = DeveloperTools(
        directory: {
            // Only `xcode-select -p` is safe here: xcrun and the /usr/bin shims prompt to install when nothing is.
            guard let result = try? await ProcessRunner().run(xcodeSelect, arguments: ["-p"]), result.succeeded else {
                return nil
            }
            let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            var isDirectory: ObjCBool = false
            guard !path.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        },
        requestInstall: {
            _ = try? await withTimeout(seconds: 15) {
                try await ProcessRunner().run(xcodeSelect, arguments: ["--install"], stdout: .discard, stderr: .discard)
            }
        },
        sdk: { developer in
            var environment = ProcessInfo.processInfo.environment
            environment["DEVELOPER_DIR"] = developer.path(percentEncoded: false)
            guard
                let result = try? await ProcessRunner().run(
                    xcrun, arguments: ["--sdk", "macosx", "--show-sdk-path"], environment: environment, stderr: .discard),
                result.succeeded
            else { return nil }
            let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
        },
        metalToolchain: { developer in
            var environment = ProcessInfo.processInfo.environment
            environment["DEVELOPER_DIR"] = developer.path(percentEncoded: false)
            guard
                let result = try? await ProcessRunner().run(
                    xcrun, arguments: ["--find", "metal"], environment: environment, stderr: .discard),
                result.succeeded
            else { return nil }
            return metalToolchain(containing: result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    )

    /// The `Metal.xctoolchain` folder that holds a `metal` command, with links resolved, or nil for any other `metal`,
    /// such as the stub in `XcodeDefault.xctoolchain` that only says the toolchain is missing. The build sandbox
    /// grants the folder it returns, so it must still be a Metal toolchain once resolved, not a link to elsewhere.
    static func metalToolchain(containing metal: String) -> URL? {
        guard let range = metal.range(of: "/Metal.xctoolchain/", options: .backwards),
            metal.hasSuffix("/usr/bin/metal"),
            let resolved = try? BuildSandbox.canonical(URL(fileURLWithPath: String(metal[..<range.lowerBound]) + "/Metal.xctoolchain"))
        else { return nil }
        let folder = URL(fileURLWithPath: resolved, isDirectory: true)
        guard folder.lastPathComponent == "Metal.xctoolchain", FileOperations.isDirectory(folder) else { return nil }
        return folder
    }

    /// The folder the build sandbox must be able to read for a developer directory: the whole Xcode.app for
    /// Xcode's `Contents/Developer`, else the directory itself.
    static func sandboxRoot(of developer: URL) -> URL {
        let path = developer.standardizedFileURL.path(percentEncoded: false)
        if let range = path.range(of: ".app/Contents/Developer") {
            return URL(fileURLWithPath: String(path[..<range.lowerBound]) + ".app", isDirectory: true)
        }
        return developer
    }

    /// Folders holding the compilers and developer commands, searched before the system's /usr/bin shims,
    /// which would otherwise call xcrun (and write its cache outside the sandbox) on every invocation.
    static func binaryFolders(in developer: URL) -> [URL] {
        let toolchain = developer.appending(path: "Toolchains/XcodeDefault.xctoolchain/usr/bin", directoryHint: .isDirectory)
        let own = developer.appending(path: "usr/bin", directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: toolchain.path(percentEncoded: false)) ? [toolchain, own] : [own]
    }
}

/// Runs `body`, cancelling it after `seconds`.
func withTimeout<T: Sendable>(seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw CancellationError()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
