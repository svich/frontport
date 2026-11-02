import Foundation

/// A Port's Catalog id, such as `shipwright`. Stable forever: it names the Port's folders and bundle ID.
public struct PortID: RawRepresentable, Hashable, Comparable, Sendable, Codable, CodingKeyRepresentable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// A Game's Catalog id, such as `ocarina-of-time`.
public struct GameID: RawRepresentable, Hashable, Comparable, Sendable, Codable, CodingKeyRepresentable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// A Platform's Catalog id, such as `n64`.
public struct PlatformID: RawRepresentable, Hashable, Comparable, Sendable, Codable, CodingKeyRepresentable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// A Genre's Catalog id, such as `platformer`.
public struct GenreID: RawRepresentable, Hashable, Comparable, Sendable, Codable, CodingKeyRepresentable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// The stream of Releases an Installation follows. The first Channel an entry lists is its default.
public struct Channel: RawRepresentable, Hashable, Sendable, Codable, CodingKeyRepresentable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    public static let stable: Channel = "stable"
    public static let nightly: Channel = "nightly"
}

/// An Apple Team's ID, such as `A1B2C3D4E5`: 10 characters of A–Z and 0–9, as its Apple Development certificate's
/// organizational unit says. Anything else isn't one, so it can't put anything but itself into a bundle ID.
public struct AppleTeamID: RawRepresentable, Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init?(rawValue: String) {
        guard rawValue.unicodeScalars.count == 10,
            rawValue.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) || ("0"..."9").contains($0) })
        else { return nil }
        self.rawValue = rawValue
    }
    public init?(_ rawValue: String) { self.init(rawValue: rawValue) }
    public var description: String { rawValue }
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// A Device's UDID, such as `00008110-0000000000000000`, as `devicectl` reports it. It names the Device's folder.
public struct DeviceID: RawRepresentable, Hashable, Comparable, Sendable, Codable, CodingKeyRepresentable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// True when it's letters, digits and hyphens, starting with a letter or digit, so it names only the Device's
    /// own folder.
    public var isWellFormed: Bool {
        func allowed(_ c: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(c) || ("A"..."Z").contains(c) || ("0"..."9").contains(c)
        }
        guard let first = rawValue.unicodeScalars.first, allowed(first) else { return false }
        return rawValue.unicodeScalars.allSatisfy { allowed($0) || $0 == "-" }
    }
}

extension PortID {
    /// The name of the Port's iOS version's folders in Downloads, Builds and Logs: `<id>.ios`. No Port's id has a
    /// ".", so it can't be another Port's, and sweeping the Mac's leftovers never takes it.
    public var deviceWorkspace: PortID { PortID("\(rawValue)\(Self.deviceWorkspaceSuffix)") }

    /// The Port whose `deviceWorkspace` is `name`; nil for any other name.
    public init?(deviceWorkspace name: String) {
        guard name.hasSuffix(Self.deviceWorkspaceSuffix) else { return nil }
        let port = PortID(String(name.dropLast(Self.deviceWorkspaceSuffix.count)))
        guard port.isWellFormed, port.deviceWorkspace.rawValue == name else { return nil }
        self = port
    }

    private static let deviceWorkspaceSuffix = ".ios"

    /// The bundle ID the Port's iOS version has when `team` signs it: `dev.frontport.port.<id>.<team>`, the Apple
    /// Team's ID in lowercase, since an explicit App ID belongs to the one Apple Team that registered it.
    public func deviceBundleID(team: AppleTeamID) -> String {
        "\(conventionalBundleID).\(team.rawValue.lowercased())"
    }

    /// The Port whose bundle ID for `team` `bundleId` is, `dev.frontport.port.<id>.<team>`; nil for any other bundle ID,
    /// one whose id isn't well formed included.
    public init?(deviceBundleID bundleId: String, team: AppleTeamID) {
        let prefix = PortID("").conventionalBundleID
        let suffix = ".\(team.rawValue.lowercased())"
        guard bundleId.hasPrefix(prefix), bundleId.hasSuffix(suffix), bundleId.count > prefix.count + suffix.count else {
            return nil
        }
        let port = PortID(String(bundleId.dropFirst(prefix.count).dropLast(suffix.count)))
        guard port.isWellFormed, port.deviceBundleID(team: team) == bundleId else { return nil }
        self = port
    }
}
