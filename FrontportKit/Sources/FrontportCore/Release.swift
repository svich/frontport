import Foundation

/// One version of a Port as published by its upstream project.
public struct Release: Codable, Hashable, Sendable, Identifiable {
    public var port: PortID
    /// Display version, such as "9.3.1" (the tag without a leading "v").
    public var version: String
    /// Upstream tag. For a source-built Release, the git ref to build.
    public var tag: String
    /// Upstream release name, such as "Dewey Bravo".
    public var title: String?
    public var channel: Channel
    public var published: Date?
    /// When upstream created it: on GitHub, the date of the Release's commit, which orders Releases.
    public var created: Date?
    /// Upstream release notes, Markdown.
    public var notes: String?
    public var notesURL: URL?
    /// The prebuilt asset to download; nil for a source-built Release.
    public var asset: ReleaseAsset?

    public var id: String { "\(port)@\(tag)" }
    public var isSourceBuilt: Bool { asset == nil }

    public init(
        port: PortID, version: String, tag: String? = nil, title: String? = nil, channel: Channel = .stable,
        published: Date? = nil, created: Date? = nil, notes: String? = nil, notesURL: URL? = nil,
        asset: ReleaseAsset? = nil
    ) {
        self.port = port
        self.version = version
        self.tag = tag ?? version
        self.title = title
        self.channel = channel
        self.published = published
        self.created = created
        self.notes = notes
        self.notesURL = notesURL
        self.asset = asset
    }
}

extension Release {
    /// Release order, the one rule discovery, updates and Rollback all use: by creation date when both have
    /// one (as GitHub orders them, so publishing an old draft later doesn't make it the newest), else by
    /// publication date, else by version number.
    public func isNewer(than other: Release) -> Bool {
        if let date = created ?? published, let otherDate = other.created ?? other.published, date != otherDate {
            return date > otherDate
        }
        return version.compare(other.version, options: .numeric) == .orderedDescending
    }
}

/// A Release's downloadable macOS asset.
public struct ReleaseAsset: Codable, Hashable, Sendable {
    public var name: String
    public var url: URL
    /// Bytes.
    public var size: Int64
    /// Lowercase hex SHA-256 from GitHub's asset digest; nil when upstream has none.
    public var sha256: String?

    public init(name: String, url: URL, size: Int64, sha256: String?) {
        self.name = name
        self.url = url
        self.size = size
        self.sha256 = sha256
    }
}
