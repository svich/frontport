import FrontportCore
import Foundation

/// Signs code in place and checks the signature, for the Packager: `Codesign` on this Mac, or in tests one that
/// records what it's asked, so the Packager's checks and links run without codesign.
public protocol Signer: Sendable {
    /// Signs one item ad-hoc under the hardened runtime, replacing any signature, with these entitlements or none.
    func sign(_ item: URL, entitlements: [String: PortEntitlements.Value]?) async throws
    /// Checks the app's signature as strictly as its links allow.
    func verify(_ app: URL, strictness: Strictness) async throws
}

/// How strictly an app's signature is checked. `--strict` also checks that every link leads inside the app, which
/// rejects the Packager's own links; the Packager polices links itself instead.
public enum Strictness: Sendable {
    /// Every check, for an app without the Packager's links.
    case strict
    /// Every check but that links lead inside the app.
    case sideband
    /// Only the signature, for an app whose link to its Build Assets leads nowhere while a stop Block has it aside,
    /// where even the sideband checks would follow it.
    case lenient
}

/// Signs with `codesign`, stopping a check that takes longer than `verifyLimit` while the Mac is awake: codesign opens
/// what each Redirect leads to, in Data the Port controls, so something the Port left there could hold it up. The
/// limit is generous, since an app without Build Assets can be large.
public struct Codesign: Signer {
    private let codesign: URL
    private let verifyLimit: Duration
    private let runner = ProcessRunner()

    public init(codesign: URL = URL(filePath: "/usr/bin/codesign"), verifyLimit: Duration = .seconds(600)) {
        self.codesign = codesign
        self.verifyLimit = verifyLimit
    }

    public func sign(_ item: URL, entitlements: [String: PortEntitlements.Value]?) async throws {
        let file = try entitlements.map(EntitlementsFile.init)
        var arguments = ["--force", "--sign", "-", "--options", "runtime"]
        if let file { arguments += ["--entitlements", file.url.path(percentEncoded: false)] }
        try Self.check(try await runner.run(codesign, arguments: arguments + [item.path(percentEncoded: false)]))
    }

    public func verify(_ app: URL, strictness: Strictness) async throws {
        let strict = switch strictness {
        case .strict: ["--strict"]
        case .sideband: ["--strict=sideband"]
        case .lenient: [String]()
        }
        let arguments = ["--verify"] + strict + [app.path(percentEncoded: false)]
        let (runner, codesign, limit) = (runner, codesign, verifyLimit)
        let result = try await withThrowingTaskGroup(of: ProcessResult?.self) { group in
            // Cancelled, codesign is sent SIGTERM, which ends it even while it waits on a FIFO, and SIGKILL should it
            // ignore that, so the group never waits on it for long.
            group.addTask { try await runner.run(codesign, arguments: arguments, killAfter: .seconds(5)) }
            group.addTask {
                try await Task.sleep(for: limit, clock: SuspendingClock())
                return nil
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
        guard let result else {
            let time = limit.formatted(.units(allowed: [.minutes, .seconds], width: .wide))
            throw FrontportError.signingFailed(
                "Verifying \(app.lastPathComponent) took longer than \(time), so it was stopped. Try again.")
        }
        try Self.check(result)
    }

    private static func check(_ result: ProcessResult) throws {
        guard result.succeeded else {
            let output = (result.errorOutput.isEmpty ? result.output : result.errorOutput)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw FrontportError.signingFailed(output)
        }
    }
}

/// An entitlements plist in a private temporary folder, removed when released.
private final class EntitlementsFile {
    let url: URL
    private let folder: URL

    init(_ entitlements: [String: PortEntitlements.Value]) throws {
        folder = FileManager.default.temporaryDirectory
            .appending(path: "frontport-entitlements-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileOperations.createDirectory(folder)
        url = folder.appending(path: "port.entitlements")
        do {
            try PortEntitlements.plist(entitlements).write(to: url)
        } catch {
            throw FrontportError.signingFailed("Couldn’t write entitlements: \(error.localizedDescription)")
        }
    }

    deinit { try? FileManager.default.removeItem(at: folder) }
}
