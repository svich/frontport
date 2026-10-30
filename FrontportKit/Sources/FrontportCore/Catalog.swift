import Foundation

/// How a Port was made.
public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
    case decomp, recomp, recreation, sourceport
}

/// The system a Game was originally released on.
public struct Platform: Codable, Hashable, Sendable, Identifiable {
    public var id: PlatformID
    /// "Nintendo 64".
    public var name: String
    /// "N64".
    public var shortName: String
    /// What its Games come on.
    public var medium: Medium

    public init(id: PlatformID, name: String, shortName: String, medium: Medium) {
        self.id = id
        self.name = name
        self.shortName = shortName
        self.medium = medium
    }
}

/// What a Platform's Games come on, and so the Type of a Game's ROM that is neither a folder nor an ISO.
public enum Medium: String, Codable, Hashable, Sendable {
    case cartridge, iso, file
}

/// A kind of Game, such as Platformer or Racing.
public struct Genre: Codable, Hashable, Sendable, Identifiable {
    public var id: GenreID
    /// "Platformer".
    public var name: String

    public init(id: GenreID, name: String) {
        self.id = id
        self.name = name
    }
}

/// The original title a Port is based on.
public struct Game: Codable, Hashable, Sendable, Identifiable {
    public var id: GameID
    /// "The Legend of Zelda: Ocarina of Time".
    public var name: String
    /// "Ocarina of Time", where the UI has little room.
    public var shortName: String?
    public var platform: PlatformID
    /// Its Genres, main one first.
    public var genres: [GenreID]
    /// SteamGridDB game id of the Game itself.
    public var steamgriddb: Int?
    /// The Game this one expands and plays on top of, such as Half-Life for Opposing Force. Its Ports take the base
    /// Game's ROMs too.
    public var base: GameID?

    public init(
        id: GameID, name: String, shortName: String? = nil, platform: PlatformID, genres: [GenreID] = [],
        steamgriddb: Int? = nil, base: GameID? = nil
    ) {
        self.id = id
        self.name = name
        self.shortName = shortName
        self.platform = platform
        self.genres = genres
        self.steamgriddb = steamgriddb
        self.base = base
    }

    enum CodingKeys: String, CodingKey { case id, name, shortName, platform, genres, steamgriddb, base }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(GameID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        shortName = try c.decodeIfPresent(String.self, forKey: .shortName)
        platform = try c.decode(PlatformID.self, forKey: .platform)
        genres = try c.decodeIfPresent([GenreID].self, forKey: .genres) ?? []
        steamgriddb = try c.decodeIfPresent(Int.self, forKey: .steamgriddb)
        base = try c.decodeIfPresent(GameID.self, forKey: .base)
    }

    public var displayName: String { shortName ?? name }
}

/// When a Requirement's ROM is used.
public enum Stage: String, Codable, Hashable, Sendable {
    /// Consumed by the Recipe while producing the Port, which never sees it.
    case build
    /// Seeded into the Port's Data; the Port uses it itself.
    case runtime
}

/// The ROMs a Port needs: one of a set of accepted ROMs, plus optional extras.
public struct Requirement: Codable, Hashable, Sendable, Identifiable {
    /// Human label, such as "Ocarina of Time". Unique within an entry, so it doubles as the id.
    public var label: String
    public var stage: Stage
    /// SHA-1s (lowercase hex, of the standard form) of the accepted ROMs, in order of preference.
    public var oneOf: [String]
    /// SHA-1s of optional extra ROMs, such as Master Quest.
    public var extras: [String]
    /// Runtime Stage only: where the Port looks, relative to its Data folder. A path ending in `/` is a
    /// folder, and each ROM is Seeded into it as `<sha1>.<format>`; otherwise it is the file path itself
    /// (used for the accepted ROM only, so extras need a folder).
    public var seedPath: String?

    public var id: String { label }

    public init(label: String, stage: Stage, oneOf: [String], extras: [String] = [], seedPath: String? = nil) {
        self.label = label
        self.stage = stage
        self.oneOf = oneOf
        self.extras = extras
        self.seedPath = seedPath
    }

    /// Where `seedPath` puts the ROMs, or nil without one. Seeding and the Catalog's lint both go by it.
    public func seedTarget() throws(SeedPathError) -> SeedTarget? {
        guard let seedPath else { return nil }
        let parts = seedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let components = seedPath.hasSuffix("/") ? Array(parts.dropLast()) : parts
        guard !seedPath.hasPrefix("/"), !components.isEmpty,
            !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else { throw .outsideData }
        if seedPath.hasSuffix("/") { return .folder(components) }
        guard extras.isEmpty else { throw .extrasNeedAFolder }
        return .file(folder: Array(components.dropLast()), name: components[components.count - 1])
    }

    enum CodingKeys: String, CodingKey { case label, stage, oneOf, extras, seedPath }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        stage = try c.decode(Stage.self, forKey: .stage)
        oneOf = try c.decode([String].self, forKey: .oneOf)
        extras = try c.decodeIfPresent([String].self, forKey: .extras) ?? []
        seedPath = try c.decodeIfPresent(String.self, forKey: .seedPath)
    }
}

/// Where a Runtime Requirement's ROMs go in the Port's Data, from its `seedPath`.
public enum SeedTarget: Hashable, Sendable {
    /// A file path: the accepted ROM goes there, under `name`, in the folders `folder` lead to from Data.
    case file(folder: [String], name: String)
    /// A folder path: the accepted ROM and the extras go into it, each as `<sha1>.<format>`.
    case folder([String])
}

/// Why a Requirement's `seedPath` can't be used.
public enum SeedPathError: Error, Hashable, Sendable {
    /// Absolute, empty, or with an empty, `.` or `..` component, so it could lead out of the Port's Data.
    case outsideData
    /// A file path for a Requirement with extras, which only a folder can take.
    case extrasNeedAFolder
}

/// How an installer becomes the ROMs it holds: a Recipe that unpacks it in the build sandbox, and the folder ROMs it
/// yields, each a `KnownROM` of its own. Frontport keeps those, never the installer.
public struct Unpack: Codable, Hashable, Sendable {
    /// Path of the Recipe relative to the Catalog root, such as "recipes/innoextract.sh".
    public var recipe: String
    /// Lowercase hex SHA-256 of the Recipe, so the Catalog's signature covers it.
    public var recipeSHA256: String
    /// SHA-1s of the folder ROMs the installer holds.
    public var yields: [String]

    public init(recipe: String, recipeSHA256: String, yields: [String]) {
        self.recipe = recipe
        self.recipeSHA256 = recipeSHA256
        self.yields = yields
    }
}

/// What a ROM is: as the Catalog says for an update or DLC, else told from its format and its Game's Platform.
public enum ROMType: String, Codable, Hashable, Sendable, CaseIterable {
    /// A dump of a Game on a cartridge Platform, in whatever container: a Switch NSP is one too.
    case cartridge
    /// A disc image.
    case iso
    /// A Game that comes as a folder of files, such as a PC Game.
    case folder
    /// A Game's single file on a Platform whose Games come as files, such as a Doom IWAD or an installer.
    case file
    /// A Platform's console keys.
    case key
    /// A Platform's own files other than its keys, such as a Switch firmware.
    case firmware
    /// A Game's update, such as a Switch game's 1.4.3. Only the Catalog says so.
    case update
    /// A Game's downloadable content. Only the Catalog says so.
    case dlc

    /// - Parameter medium: the Game's Platform's; nil when the Catalog doesn't list them, which makes it a File.
    public init(format: String, game: GameID?, medium: Medium?) {
        guard format != "keys" else { self = .key; return }
        guard game != nil else { self = .firmware; return }
        switch (format, medium) {
        case (ROMRecord.folderFormat, _): self = .folder
        case ("iso", _), (_, .iso): self = .iso
        case (_, .cartridge): self = .cartridge
        case (_, .file), (_, nil): self = .file
        }
    }
}

/// A ROM the Catalog accepts, identified by the SHA-1 of its standard form: a dump of a Game, or of a Platform's
/// own files that its Games need, such as a Switch's console keys.
public struct KnownROM: Codable, Hashable, Sendable, Identifiable {
    /// Lowercase hex SHA-1 of the standard form.
    public var sha1: String
    /// The Game it's a dump of; nil for a Platform's own files.
    public var game: GameID?
    /// The Platform whose own files it is, for a ROM of no Game.
    public var platform: PlatformID?
    /// The ROM’s version and region, such as "NTSC 1.0 (US)".
    public var name: String
    /// File extension of the standard form, such as "z64" or "sfc".
    public var format: String
    /// Present for an installer, which Frontport unpacks into the ROMs it holds instead of keeping it.
    public var unpack: Unpack?
    /// `update` or `dlc`, for a Game's update or DLC, which nothing else tells from the Game itself. Every other
    /// ROM's Type is told from its format and its Game's Platform.
    public var type: ROMType?
    /// The added Catalog that lists it, nil for Frontport's own. Set when Frontport reads the Catalogs as one, never
    /// taken from a document.
    public var catalog: URL?

    public var id: String { sha1 }

    public var isFolder: Bool { format == ROMRecord.folderFormat }

    public init(
        sha1: String, game: GameID?, platform: PlatformID? = nil, name: String, format: String, unpack: Unpack? = nil,
        type: ROMType? = nil, catalog: URL? = nil
    ) {
        self.sha1 = sha1
        self.game = game
        self.platform = platform
        self.name = name
        self.format = format
        self.unpack = unpack
        self.type = type
        self.catalog = catalog
    }
}

/// A Recipe the Catalog pins: a source-built Port's, or an installer's unpack Recipe.
public struct PinnedRecipe: Hashable, Sendable {
    /// The Port's id or the installer's SHA-1, for messages.
    public var owner: String
    /// Relative to the Catalog root.
    public var path: String
    public var sha256: String
}

/// What a Port may access beyond its own Data. Defaults: network off, controllers on, files off.
public struct Permissions: Codable, Hashable, Sendable {
    public var network: Bool
    public var controllers: Bool
    public var files: Bool

    public init(network: Bool = false, controllers: Bool = true, files: Bool = false) {
        self.network = network
        self.controllers = controllers
        self.files = files
    }

    public static let `default` = Permissions()

    public subscript(_ permission: Permission) -> Bool {
        get {
            switch permission {
            case .network: network
            case .controllers: controllers
            case .files: files
            }
        }
        set {
            switch permission {
            case .network: network = newValue
            case .controllers: controllers = newValue
            case .files: files = newValue
            }
        }
    }

    /// Entitlements for these Permissions, always including the App Sandbox. Code-signing exceptions are separate.
    public var entitlements: [String: Bool] {
        var result = ["com.apple.security.app-sandbox": true]
        for permission in Permission.allCases where self[permission] {
            result[permission.entitlement] = true
        }
        return result
    }

    enum CodingKeys: String, CodingKey { case network, controllers, files }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Permissions.default
        network = try c.decodeIfPresent(Bool.self, forKey: .network) ?? d.network
        controllers = try c.decodeIfPresent(Bool.self, forKey: .controllers) ?? d.controllers
        files = try c.decodeIfPresent(Bool.self, forKey: .files) ?? d.files
    }
}

/// One user-facing Permission, in the order the UI lists them.
public enum Permission: String, Codable, Hashable, Sendable, CaseIterable {
    case controllers, network, files

    public var entitlement: String {
        switch self {
        case .network: "com.apple.security.network.client"
        case .controllers: "com.apple.security.device.usb"
        case .files: "com.apple.security.files.user-selected.read-only"
        }
    }
}

/// A Release the Catalog forbids installing.
public struct Block: Codable, Hashable, Sendable {
    public enum Severity: String, Codable, Hashable, Sendable {
        /// Warn and offer an update or Rollback.
        case warn
        /// Disable the Installation by moving its app aside.
        case stop
    }

    /// The Release's version or tag, such as "9.3.0".
    public var release: String
    public var severity: Severity
    public var reason: String

    public init(release: String, severity: Severity, reason: String) {
        self.release = release
        self.severity = severity
        self.reason = reason
    }

    public func matches(_ release: Release) -> Bool {
        self.release == release.version || self.release == release.tag
    }
}

/// Upstream GitHub Releases with a prebuilt macOS asset.
public struct GitHubReleaseSource: Codable, Hashable, Sendable {
    /// "owner/name".
    public var repo: String
    /// Glob matched against asset names, such as "SoH-*-Mac.zip".
    public var asset: String
    /// Channels offered, default first. Unless `tags` says otherwise, `stable` follows full releases and
    /// any other Channel also includes prereleases.
    public var channels: [Channel]
    /// Optional tag glob per Channel, for projects that mark Channels by tag rather than the prerelease flag.
    public var tags: [Channel: String]?

    public init(repo: String, asset: String, channels: [Channel] = [.stable], tags: [Channel: String]? = nil) {
        self.repo = repo
        self.asset = asset
        self.channels = channels
        self.tags = tags
    }
}

/// A source-built Port: pinned git refs per Channel and the Recipe that builds them.
public struct GitSource: Codable, Hashable, Sendable {
    /// GitHub "owner/name".
    public var repo: String
    /// Pinned tag, branch or commit per Channel.
    public var refs: [Channel: String]
    /// Path of the Recipe relative to the Catalog root, such as "recipes/starship.sh".
    public var recipe: String
    /// Lowercase hex SHA-256 of the Recipe, so the Catalog's signature covers it.
    public var recipeSHA256: String

    public init(repo: String, refs: [Channel: String], recipe: String, recipeSHA256: String) {
        self.repo = repo
        self.refs = refs
        self.recipe = recipe
        self.recipeSHA256 = recipeSHA256
    }
}

/// Where a Port's Releases come from. Encoded with a `type` of `github-release` or `git`.
public enum ReleaseSource: Codable, Hashable, Sendable {
    case githubRelease(GitHubReleaseSource)
    case git(GitSource)

    enum CodingKeys: String, CodingKey { case type }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "github-release": self = .githubRelease(try GitHubReleaseSource(from: decoder))
        case "git": self = .git(try GitSource(from: decoder))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown release source \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .githubRelease(let source):
            try c.encode("github-release", forKey: .type)
            try source.encode(to: encoder)
        case .git(let source):
            try c.encode("git", forKey: .type)
            try source.encode(to: encoder)
        }
    }

    /// "owner/name" of the upstream repository.
    public var repo: String {
        switch self {
        case .githubRelease(let source): source.repo
        case .git(let source): source.repo
        }
    }

    /// Channels offered, default first.
    public var channels: [Channel] {
        switch self {
        case .githubRelease(let source):
            return source.channels
        case .git(let source):
            return source.refs.keys.sorted { a, b in
                if a == .stable || b == .stable { return a == .stable }
                return a.rawValue < b.rawValue
            }
        }
    }
}

/// Where the Port reads a Recipe's Build Assets inside the app, and which format they are in.
public struct BuildAssetsSpec: Codable, Hashable, Sendable {
    /// Path relative to the .app bundle, such as "Contents/Resources/sf64.o2r". Frontport keeps the Build Assets
    /// beside the app and links them here.
    public var path: String
    /// Opaque format version. When it changes, Build Assets are regenerated instead of carried over on update.
    public var format: String

    public init(path: String, format: String) {
        self.path = path
        self.format = format
    }
}

/// A link the Packager puts at a path inside the app, leading to a folder in the Port's own Data, for a Port that
/// writes beside its executable: the write lands in its container, where the sandbox lets it write anyway.
public struct Redirect: Codable, Hashable, Sendable {
    /// Inside the app, under `Contents/Resources/` and clear of its code (`PortLinks.isRedirectPath`), such as
    /// "Contents/Resources/data/log".
    public var path: String
    /// A folder relative to Data, such as "Library/Application Support/OpenGOAL/log".
    public var to: String

    public init(path: String, to: String) {
        self.path = path
        self.to = to
    }
}

/// Code-signing exceptions mirrored from upstream. Never user-controlled.
public struct CodeSigning: Codable, Hashable, Sendable {
    /// Suffixes of `com.apple.security.cs.`, such as "allow-jit" or "disable-library-validation".
    public var exceptions: [String]

    public init(exceptions: [String] = []) { self.exceptions = exceptions }

    public var entitlements: [String: Bool] {
        Dictionary(exceptions.map { ("com.apple.security.cs.\($0)", true) }, uniquingKeysWith: { a, _ in a })
    }
}

/// Per-Port launch quirks.
public struct LaunchSpec: Codable, Hashable, Sendable {
    public var arguments: [String]
    public var environment: [String: String]

    public init(arguments: [String] = [], environment: [String: String] = [:]) {
        self.arguments = arguments
        self.environment = environment
    }

    enum CodingKeys: String, CodingKey { case arguments, environment }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        arguments = try c.decodeIfPresent([String].self, forKey: .arguments) ?? []
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
    }
}

/// The kinds of SteamGridDB artwork and where each goes.
public enum ArtworkKind: String, Codable, Hashable, Sendable, CaseIterable {
    /// Landscape grid: Library tiles and Catalog cards.
    case grid
    /// Port page header background.
    case hero
    /// Port page header title.
    case logo
    /// Sidebar.
    case icon
}

/// Pinned SteamGridDB game ids for an entry.
public struct Artwork: Codable, Hashable, Sendable {
    /// The Port's own SteamGridDB entry, when it has one.
    public var steamgriddb: Int?
    /// The Game's SteamGridDB entry, used when the Port has none.
    public var fallback: Int?

    public init(steamgriddb: Int? = nil, fallback: Int? = nil) {
        self.steamgriddb = steamgriddb
        self.fallback = fallback
    }

    public var preferred: Int? { steamgriddb ?? fallback }
}

/// One Port in the Catalog.
public struct CatalogEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: PortID
    public var name: String
    public var kind: Kind
    public var game: GameID
    /// "HarbourMasters".
    public var developer: String
    /// One sentence for cards and the store page header.
    public var summary: String
    /// Store page "About" text, paragraphs separated by blank lines.
    public var description: String
    public var website: URL?
    /// Upstream source repository page.
    public var source: URL
    /// Ties the Port to its Data. Never changes; always `dev.frontport.port.<id>`.
    public var bundleId: String
    public var releases: ReleaseSource
    public var requirements: [Requirement]
    /// Defaults set by the Catalog; the user may change them per Installation.
    public var permissions: Permissions
    public var artwork: Artwork
    public var codeSigning: CodeSigning
    public var launch: LaunchSpec
    /// Paths inside the app, relative to the bundle, removed before signing: upstream pieces that can't work
    /// in the sandbox or would act outside it, such as a self-updater that replaces the app.
    public var strip: [String]
    /// Present when a Recipe makes Build Assets, which the Port reads inside the app through the Packager's link.
    public var buildAssets: BuildAssetsSpec?
    /// Paths inside the app that lead into the Port's Data.
    public var redirects: [Redirect]
    public var blocked: [Block]
    public var screenshots: [URL]
    /// Why the Port can't work in the sandbox. An Unsupported Port is listed but never installable.
    public var unsupported: String?
    /// Free-form labels such as "multiplayer".
    public var tags: [String]
    /// When upstream first published the Port, which orders New Ports.
    public var firstRelease: Date?
    /// The added Catalog that lists it, nil for Frontport's own. Set when Frontport reads the Catalogs as one, and kept
    /// in an Installation's entry, so the Port stays with the Catalog it was installed from.
    public var catalog: URL?

    public init(
        id: PortID, name: String, kind: Kind, game: GameID, developer: String, summary: String,
        description: String, website: URL? = nil, source: URL, bundleId: String, releases: ReleaseSource,
        requirements: [Requirement] = [], permissions: Permissions = .default, artwork: Artwork = Artwork(),
        codeSigning: CodeSigning = CodeSigning(), launch: LaunchSpec = LaunchSpec(), strip: [String] = [],
        buildAssets: BuildAssetsSpec? = nil, redirects: [Redirect] = [], blocked: [Block] = [], screenshots: [URL] = [],
        unsupported: String? = nil, tags: [String] = [], firstRelease: Date? = nil, catalog: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.game = game
        self.developer = developer
        self.summary = summary
        self.description = description
        self.website = website
        self.source = source
        self.bundleId = bundleId
        self.releases = releases
        self.requirements = requirements
        self.permissions = permissions
        self.artwork = artwork
        self.codeSigning = codeSigning
        self.launch = launch
        self.strip = strip
        self.buildAssets = buildAssets
        self.redirects = redirects
        self.blocked = blocked
        self.screenshots = screenshots
        self.unsupported = unsupported
        self.tags = tags
        self.firstRelease = firstRelease
        self.catalog = catalog
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, game, developer, summary, description, website, source, bundleId, releases
        case requirements, permissions, artwork, codeSigning, launch, strip, buildAssets, redirects, blocked, screenshots
        case unsupported, tags, firstRelease, catalog
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(PortID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(Kind.self, forKey: .kind)
        game = try c.decode(GameID.self, forKey: .game)
        developer = try c.decode(String.self, forKey: .developer)
        summary = try c.decode(String.self, forKey: .summary)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        website = try c.decodeIfPresent(URL.self, forKey: .website)
        source = try c.decode(URL.self, forKey: .source)
        bundleId = try c.decode(String.self, forKey: .bundleId)
        releases = try c.decode(ReleaseSource.self, forKey: .releases)
        requirements = try c.decodeIfPresent([Requirement].self, forKey: .requirements) ?? []
        permissions = try c.decodeIfPresent(Permissions.self, forKey: .permissions) ?? .default
        artwork = try c.decodeIfPresent(Artwork.self, forKey: .artwork) ?? Artwork()
        codeSigning = try c.decodeIfPresent(CodeSigning.self, forKey: .codeSigning) ?? CodeSigning()
        launch = try c.decodeIfPresent(LaunchSpec.self, forKey: .launch) ?? LaunchSpec()
        strip = try c.decodeIfPresent([String].self, forKey: .strip) ?? []
        buildAssets = try c.decodeIfPresent(BuildAssetsSpec.self, forKey: .buildAssets)
        redirects = try c.decodeIfPresent([Redirect].self, forKey: .redirects) ?? []
        blocked = try c.decodeIfPresent([Block].self, forKey: .blocked) ?? []
        screenshots = try c.decodeIfPresent([URL].self, forKey: .screenshots) ?? []
        unsupported = try c.decodeIfPresent(String.self, forKey: .unsupported)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        firstRelease = try c.decodeIfPresent(Date.self, forKey: .firstRelease)
        catalog = try c.decodeIfPresent(URL.self, forKey: .catalog)
    }
}

extension CatalogEntry {
    public var isInstallable: Bool { unsupported == nil }

    /// Built from source by a Recipe rather than downloaded prebuilt.
    public var isSourceBuilt: Bool {
        if case .git = releases { return true }
        return false
    }

    /// Channels offered, default first.
    public var channels: [Channel] { releases.channels }

    public var defaultChannel: Channel { channels.first ?? .stable }

    public func requirements(for stage: Stage) -> [Requirement] {
        requirements.filter { $0.stage == stage }
    }

    /// The Block for a Release, if the Catalog blocks it.
    public func block(for release: Release) -> Block? {
        blocked.first { $0.matches(release) }
    }

    /// The SHA-1s of every ROM any Requirement accepts, extras included.
    public var acceptedROMs: Set<String> {
        Set(requirements.flatMap { $0.oneOf + $0.extras })
    }

    /// Refuses an entry whose id or bundle ID could name a folder other than its own. The Catalog's lint requires
    /// both, but nothing that writes a Port's folders relies on it: an id like `..` would make `Library/<port>` the
    /// Frontport folder itself, and a bundle ID like `../x` another app's container.
    public func checkIdentity() throws {
        guard id.isWellFormed, bundleId == id.conventionalBundleID else {
            throw FrontportError.catalogInvalid("“\(id)” isn’t a valid Port id with its bundle ID.")
        }
    }
}

extension PortID {
    /// Builder workspaces for unpack Recipes are named with it, so no Port's id may start with it.
    public static let unpackPrefix = "unpack-"

    /// The bundle ID every entry uses: `dev.frontport.port.<id>`.
    public var conventionalBundleID: String { "dev.frontport.port.\(rawValue)" }

    /// True when the id is lowercase letters, digits and hyphens, starting with a letter or digit, so it names
    /// only the Port's own folders.
    public var isWellFormed: Bool {
        func allowed(_ c: Unicode.Scalar) -> Bool { ("a"..."z").contains(c) || ("0"..."9").contains(c) }
        guard let first = rawValue.unicodeScalars.first, allowed(first) else { return false }
        return rawValue.unicodeScalars.allSatisfy { allowed($0) || $0 == "-" }
    }
}

/// The curated, signed list of Ports, with the Games, Platforms, Genres and ROMs they refer to.
public struct CatalogDocument: Codable, Hashable, Sendable {
    /// The newest document schema this build understands.
    /// 2: a `KnownROM` may name a Platform instead of a Game, for a Platform's own files such as console keys.
    /// 3: the `sourceport` Kind.
    /// 4: each Platform's `medium`, and a `KnownROM`'s `type` for an update or DLC.
    public static let supportedVersion = 4

    /// Schema version. Frontport rejects a document newer than `supportedVersion`.
    public var version: Int
    public var issued: Date
    /// What Settings calls an added Catalog, such as "Switch Ports". Frontport's own has none.
    public var name: String?
    public var platforms: [Platform]
    public var genres: [Genre]
    public var games: [Game]
    public var roms: [KnownROM]
    public var ports: [CatalogEntry]

    public init(
        version: Int = CatalogDocument.supportedVersion, issued: Date, name: String? = nil, platforms: [Platform],
        genres: [Genre] = [], games: [Game], roms: [KnownROM], ports: [CatalogEntry]
    ) {
        self.version = version
        self.issued = issued
        self.name = name
        self.platforms = platforms
        self.genres = genres
        self.games = games
        self.roms = roms
        self.ports = ports
    }

    enum CodingKeys: String, CodingKey { case version, issued, name, platforms, genres, games, roms, ports }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        issued = try c.decode(Date.self, forKey: .issued)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        platforms = try c.decode([Platform].self, forKey: .platforms)
        genres = try c.decodeIfPresent([Genre].self, forKey: .genres) ?? []
        games = try c.decode([Game].self, forKey: .games)
        roms = try c.decode([KnownROM].self, forKey: .roms)
        ports = try c.decode([CatalogEntry].self, forKey: .ports)
    }

    public func entry(_ id: PortID) -> CatalogEntry? { ports.first { $0.id == id } }

    /// Every Recipe the document pins, in the order their `recipeSHA256` fields appear in it: installers' first, as
    /// `roms` comes before `ports`.
    public var pinnedRecipes: [PinnedRecipe] {
        let unpacks = roms.compactMap { rom in
            rom.unpack.map { PinnedRecipe(owner: rom.sha1, path: $0.recipe, sha256: $0.recipeSHA256) }
        }
        let builds = ports.compactMap { entry -> PinnedRecipe? in
            guard case .git(let source) = entry.releases else { return nil }
            return PinnedRecipe(owner: entry.id.rawValue, path: source.recipe, sha256: source.recipeSHA256)
        }
        return unpacks + builds
    }
    public func game(_ id: GameID) -> Game? { games.first { $0.id == id } }
    public func platform(_ id: PlatformID) -> Platform? { platforms.first { $0.id == id } }
    public func genre(_ id: GenreID) -> Genre? { genres.first { $0.id == id } }
    public func knownROM(_ sha1: String) -> KnownROM? { roms.first { $0.sha1 == sha1 } }

    public func game(for entry: CatalogEntry) -> Game? { game(entry.game) }

    public func platform(for entry: CatalogEntry) -> Platform? {
        game(for: entry).flatMap { platform($0.platform) }
    }

    // MARK: ROMs

    /// What the Catalog makes of a file with this hash. Intake, the ROMs screen and the store page all read it here.
    public enum Listing: Hashable, Sendable {
        /// An Installer: unpacked into the ROMs it yields, and never kept itself.
        case installer(KnownROM)
        /// A ROM a Requirement accepts, with its Type.
        case rom(KnownROM, ROMType)
        /// Nothing a Port takes, such as a ROM hack, another revision or a damaged dump. A hash a Requirement lists
        /// but `roms` doesn't, which the lint refuses, is one too: nothing would name it.
        case unknown

        /// The ROM, when it's one a Requirement accepts.
        public var rom: KnownROM? {
            if case .rom(let rom, _) = self { rom } else { nil }
        }
    }

    /// What the Catalog makes of a hash: an Installer it knows, a ROM a Requirement accepts, or neither. A ROM no
    /// Requirement accepts is refused even when `roms` names it.
    public func listing(_ sha1: String) -> Listing {
        guard let known = knownROM(sha1) else { return .unknown }
        if known.unpack != nil { return .installer(known) }
        guard ports.contains(where: { $0.acceptedROMs.contains(sha1) }) else { return .unknown }
        return .rom(known, type(of: known))
    }

    /// The ROMs a file of this standard format can be kept as, Unverified: those a Requirement accepts, of the same
    /// format, or for a Switch game of any of its containers. Never console keys, an Installer or a firmware, whose hash
    /// alone tells which they are.
    public func assignable(format: String) -> [KnownROM] {
        let switchGames: Set = ["nsp", "xci", "nsz", "xcz"]
        return roms.filter { rom in
            guard rom.game != nil, rom.format != "keys", listing(rom.sha1).rom != nil else { return false }
            return rom.format == format || (switchGames.contains(rom.format) && switchGames.contains(format))
        }
    }

    /// The Installers the Catalog knows that hold a ROM, such as a Game's GOG setup program.
    public func installers(holding sha1: String) -> [KnownROM] {
        roms.filter { $0.unpack?.yields.contains(sha1) == true }
    }

    /// The Game a Requirement's ROMs are dumps of; nil for a Platform's own files, such as console keys.
    public func game(for requirement: Requirement) -> Game? {
        requirement.oneOf.lazy.compactMap { self.knownROM($0) }.first?.game.flatMap { self.game($0) }
    }

    /// A ROM's Type: what the Catalog marks it, or else what its format and its Game's Platform say.
    public func type(of rom: KnownROM) -> ROMType {
        rom.type ?? ROMType(format: rom.format, game: rom.game, medium: medium(of: rom.game))
    }

    /// A stored ROM's Type, the same as its `KnownROM`'s: the Catalog's format, not the one it was stored in, decides.
    /// One the Catalog no longer lists goes by its own format.
    public func type(of record: ROMRecord) -> ROMType {
        knownROM(record.sha1).map(type(of:))
            ?? ROMType(format: record.format, game: record.game, medium: medium(of: record.game))
    }

    private func medium(of game: GameID?) -> Medium? {
        game.flatMap { self.game($0) }.flatMap { platform($0.platform) }?.medium
    }
}

extension ROMType {
    /// A stored ROM's Type as `catalog` says (`CatalogDocument.type(of:)`), or, before a Catalog is loaded, from its
    /// own format alone.
    public init(_ record: ROMRecord, in catalog: CatalogDocument?) {
        self = catalog?.type(of: record) ?? ROMType(format: record.format, game: record.game, medium: nil)
    }

    /// A known ROM's Type as `catalog` says, or, before a Catalog is loaded, from what it says itself.
    public init(_ rom: KnownROM, in catalog: CatalogDocument?) {
        self = catalog?.type(of: rom) ?? rom.type ?? ROMType(format: rom.format, game: rom.game, medium: nil)
    }
}
