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
