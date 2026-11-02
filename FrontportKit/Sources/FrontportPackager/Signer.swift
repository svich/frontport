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

/// Signs code in place for Devices with an Apple Team's Apple Development certificate, and checks the signature, for
/// the Device Packager: `Codesign` on this Mac, or in tests one that records what it's asked.
public protocol DeviceSigner: Sendable {
    /// Signs one item with the certificate whose SHA-1 is `certificate`, replacing any signature, with these
    /// entitlements or none. It may wait as long as macOS takes to ask whether codesign may use the key.
    func sign(_ item: URL, certificate: String, entitlements: [String: PortEntitlements.Value]?) async throws
    /// Checks the app's signature as strictly as its links allow; an app for Devices has none, so `.strict`.
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
/// limit is generous, since an app without Build Assets can be large. Signing has no limit, since macOS may be asking
/// whether codesign may use an Apple Team's key.
public struct Codesign: Signer, DeviceSigner {
    private let codesign: URL
    private let verifyLimit: Duration
    private let runner = ProcessRunner()

    public init(codesign: URL = URL(filePath: "/usr/bin/codesign"), verifyLimit: Duration = .seconds(600)) {
        self.codesign = codesign
        self.verifyLimit = verifyLimit
    }

    public func sign(_ item: URL, entitlements: [String: PortEntitlements.Value]?) async throws {
        let file = try entitlements.map(EntitlementsFile.init)
        let arguments = Self.signArguments(item, signature: .adHoc, entitlements: file?.url)
        try Self.check(try await runner.run(codesign, arguments: arguments))
    }

    public func sign(_ item: URL, certificate: String, entitlements: [String: PortEntitlements.Value]?) async throws {
        // Anything but a SHA-1 could name another identity, or "-" none.
        guard certificate.count == 40, certificate.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw FrontportError.signingFailed("“\(certificate)” isn’t an Apple Development certificate’s SHA-1.")
        }
        let file = try entitlements.map(EntitlementsFile.init)
        let arguments = Self.signArguments(item, signature: .certificate(certificate), entitlements: file?.url)
        let result = try await runner.run(codesign, arguments: arguments)
        guard result.succeeded else { throw Self.certificateFailure(Self.output(of: result)) }
    }

    /// What a signature is made with.
    enum Signature: Hashable, Sendable {
        /// Ad hoc under the hardened runtime, for the Mac.
        case adHoc
        /// An Apple Development certificate, by its SHA-1, for Devices: without the hardened runtime, which iOS
        /// doesn't use, or a secure timestamp, which a development signature doesn't need and would wait on Apple for.
        /// codesign adds the DER entitlements iOS reads by itself.
        case certificate(String)
    }

    /// codesign's arguments to sign `item`, with the entitlements plist at `entitlements` or none.
    static func signArguments(_ item: URL, signature: Signature, entitlements: URL?) -> [String] {
        var arguments = switch signature {
        case .adHoc: ["--force", "--sign", "-", "--options", "runtime"]
        case .certificate(let sha1): ["--force", "--sign", sha1, "--timestamp=none"]
        }
        if let entitlements { arguments += ["--entitlements", entitlements.path(percentEncoded: false)] }
        return arguments + [item.path(percentEncoded: false)]
    }

    /// codesign's words when signing with a certificate fails, saying what to do about the keychain when that's why.
    static func certificateFailure(_ output: String) -> FrontportError {
        if output.contains("errSecInternalComponent") {
            return .signingFailed(
                "macOS didn’t let codesign use your Apple Team’s key in the keychain. Try again, and when macOS asks, "
                    + "enter your login password and click Always Allow.")
        }
        if output.contains("no identity found") || output.contains("could not be found in the keychain") {
            return .signingFailed(
                "Your Apple Team’s Apple Development certificate isn’t in the keychain. Check Xcode › Settings › "
                    + "Accounts, then try again.")
        }
        return .signingFailed(output)
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
        guard result.succeeded else { throw FrontportError.signingFailed(output(of: result)) }
    }

    private static func output(of result: ProcessResult) -> String {
        (result.errorOutput.isEmpty ? result.output : result.errorOutput).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// An entitlements plist in a private temporary folder, removed when released.
final class EntitlementsFile {
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
