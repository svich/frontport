import Foundation

/// Failures shown to the user. Services throw these for anything the user can understand or act on;
/// `CancellationError` is thrown as is.
public enum FrontportError: Error, Hashable, Sendable {
    // Catalog
    /// The signature didn't verify or the document is malformed or too new.
    case catalogInvalid(String)
    /// No cached or bundled Catalog could be loaded.
    case catalogUnavailable(String)
    /// A link didn't name a Catalog the user can add, or adding it failed.
    case catalogNotAdded(String)
    case unknownPort(PortID)
    case unsupported(PortID, reason: String)

    // Releases and Fetcher
    case noRelease(PortID, Channel)
    case blocked(PortID, release: String, reason: String)
    case assetNotFound(PortID, pattern: String)
    case digestMissing(asset: String)
    case digestMismatch(asset: String, expected: String, actual: String)
    case extractionFailed(String)
    /// The download or archive held no .app.
    case appNotFound(String)
    case network(String)

    // ROMs
    case romRejected(sha1: String?, reason: String)
    /// A Requirement has no ROM in ROMs.
    case romMissing(PortID, requirement: String)

    // Builder
    /// The Command Line Tools or the pinned toolchain aren't installed.
    case toolchainMissing(String)
    case buildFailed(PortID, status: Int32, log: URL?)

    // Packager
    case signingFailed(String)

    // Library and Launcher
    case notInstalled(PortID)
    case alreadyInstalled(PortID)
    /// The change needs the Port to quit first.
    case running(PortID)
    case noPreviousRelease(PortID)
    /// A stop Block moved the app aside.
    case disabled(PortID, reason: String)

    // System
    case processFailed(command: String, status: Int32, output: String)
    case fileOperation(String)
}

extension FrontportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .catalogInvalid(let detail): "The Catalog couldn’t be verified. \(detail)"
        case .catalogUnavailable(let detail): "The Catalog isn’t available. \(detail)"
        case .catalogNotAdded(let detail): "The Catalog couldn’t be added. \(detail)"
        case .unknownPort(let port): "“\(port)” isn’t in the Catalog."
        case .unsupported(_, let reason): "This Port can’t run in the sandbox. \(reason)"
        case .noRelease(let port, let channel): "\(port) has no installable Release on the \(channel) Channel."
        case .blocked(_, let release, let reason): "Release \(release) is Blocked. \(reason)"
        case .assetNotFound(_, let pattern): "The Release has no macOS download matching \(pattern)."
        case .digestMissing(let asset): "\(asset) has no checksum from GitHub, so it can’t be verified."
        case .digestMismatch(let asset, _, _): "\(asset) doesn’t match its checksum. It may be damaged or tampered with."
        case .extractionFailed(let detail): "The download couldn’t be unpacked. \(detail)"
        case .appNotFound(let detail): "The download contains no app. \(detail)"
        case .network(let detail): "A network request failed. \(detail)"
        case .romRejected(let sha1, let reason):
            sha1.map { "This ROM isn’t accepted (SHA-1 \($0)). \(reason)" } ?? "This ROM isn’t accepted. \(reason)"
        case .romMissing(_, let requirement): "Add a \(requirement) ROM first."
        case .toolchainMissing(let detail): "Building from source needs developer tools. \(detail)"
        case .buildFailed(let port, let status, _): "Building \(port) failed (exit status \(status))."
        case .signingFailed(let detail): "The Port couldn’t be signed. \(detail)"
        case .notInstalled(let port): "\(port) isn’t installed."
        case .alreadyInstalled(let port): "\(port) is already installed."
        case .running(let port): "Quit \(port) first."
        case .noPreviousRelease(let port): "\(port) has no previous Release to roll back to."
        case .disabled(_, let reason): "This Release was disabled by the Catalog. \(reason)"
        case .processFailed(let command, let status, _): "\(command) failed (exit status \(status))."
        case .fileOperation(let detail): detail
        }
    }
}
