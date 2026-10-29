import FrontportCore
import Foundation

/// The entitlements Frontport signs a Port with.
public enum PortEntitlements {
    public static let sandbox = "com.apple.security.app-sandbox"
    public static let inherit = "com.apple.security.inherit"
    public static let disableLibraryValidation = "com.apple.security.cs.disable-library-validation"
    public static let homeRelativeReadOnly = "com.apple.security.temporary-exception.files.home-relative-path.read-only"
    public static let absoluteReadOnly = "com.apple.security.temporary-exception.files.absolute-path.read-only"

    /// An entitlement's value: on or off, or the paths a file exception names.
    public enum Value: Hashable, Sendable, ExpressibleByBooleanLiteral {
        case flag(Bool)
        case paths([String])

        public init(booleanLiteral value: Bool) { self = .flag(value) }

        var plist: Any {
            switch self {
            case .flag(let on): on
            case .paths(let paths): paths
            }
        }
    }

    /// The app's: its Permissions plus the Catalog's code-signing exceptions. Under the hardened runtime an
    /// ad-hoc signed process can't map another ad-hoc signed library (dyld: "different Team IDs"), so an app
    /// with nested libraries also gets `disable-library-validation`.
    ///
    /// `readOnly` is the canonical location of the Build Assets the app links to, outside its container, which it
    /// may then read but not change. Nested programs never get it: they inherit the app's sandbox.
    public static func app(
        permissions: Permissions, codeSigning: CodeSigning, hasLibraries: Bool, readOnly: URL? = nil,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String: Value] {
        var result = permissions.entitlements.merging(codeSigning.entitlements) { a, _ in a }.mapValues(Value.flag)
        if hasLibraries { result[disableLibraryValidation] = true }
        if let readOnly {
            let exception = exception(readOnly, home: home)
            result[exception.key] = .paths([exception.path])
        }
        return result
    }

    /// A nested program's: it inherits the app's sandbox when the app spawns it, and crashes when started any
    /// other way, so it can never run unsandboxed.
    public static func helper(codeSigning: CodeSigning, hasLibraries: Bool) -> [String: Value] {
        var result = codeSigning.entitlements.mapValues(Value.flag)
        result[sandbox] = true
        result[inherit] = true
        if hasLibraries { result[disableLibraryValidation] = true }
        return result
    }

    /// The read-only exception for one file or folder: relative to the home folder when it's inside it, so it names
    /// no user, otherwise absolute. A folder (a URL with a directory path) ends in "/", which covers everything in it.
    static func exception(_ url: URL, home: URL) -> (key: String, path: String) {
        let path = url.path(percentEncoded: false)
        var home = home.path(percentEncoded: false)
        if !home.hasSuffix("/") { home += "/" }
        guard path.hasPrefix(home) else { return (absoluteReadOnly, path) }
        return (homeRelativeReadOnly, "/" + path.dropFirst(home.count))
    }

    static func plist(_ entitlements: [String: Value]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: entitlements.mapValues(\.plist), format: .xml, options: 0)
    }
}
