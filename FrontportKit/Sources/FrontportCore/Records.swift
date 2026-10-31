import Foundation

/// One Port in the Library: the record stored as `Library/<port>/install.json`.
public struct Installation: Codable, Hashable, Sendable, Identifiable {
    public var port: PortID
    public var release: Release
    public var channel: Channel
    public var installedAt: Date
    /// File name of the app in `Library/<port>/`, such as "soh.app".
    public var appName: String
    /// The Release kept in `previous/` for Rollback.
    public var previous: Release?
    /// The user's Permissions, starting from the Catalog's defaults.
    public var permissions: Permissions
    /// Present when the Release has Build Assets: in `Library/<port>/assets`, or inside the app in Installations
    /// from before Frontport kept them beside it.
    public var buildAssets: BuildAssetsRecord?
    /// True while a stop Block keeps the app moved aside.
    public var disabled: Bool
    /// The Catalog entry as of the last change, so the Port can still be launched, re-signed and rolled back
    /// once the Catalog no longer lists it. Nil in records written before Frontport kept it.
    public var entry: CatalogEntry?

    public var id: PortID { port }

    public init(
        port: PortID, release: Release, channel: Channel, installedAt: Date, appName: String,
        previous: Release? = nil, permissions: Permissions = .default, buildAssets: BuildAssetsRecord? = nil,
        disabled: Bool = false, entry: CatalogEntry? = nil
    ) {
        self.port = port
        self.release = release
        self.channel = channel
        self.installedAt = installedAt
        self.appName = appName
        self.previous = previous
        self.permissions = permissions
        self.buildAssets = buildAssets
        self.disabled = disabled
        self.entry = entry
    }
}

/// What an Installation's Build Assets were made from, to decide whether an update can carry them over.
public struct BuildAssetsRecord: Codable, Hashable, Sendable {
    /// SHA-1s of the ROMs the Recipe consumed.
    public var roms: [String]
    /// `BuildAssetsSpec.format` at build time.
    public var format: String

    public init(roms: [String], format: String) {
        self.roms = roms
        self.format = format
    }
}

/// A copy of a Port's Data, taken before a change of Release.
public struct Snapshot: Codable, Hashable, Sendable, Identifiable {
    public enum Reason: String, Codable, Hashable, Sendable {
        case update, rollback, channelSwitch
        /// Taken before restoring another Snapshot over the Data.
        case restore
    }

    /// Folder name under `Snapshots/<port>/`.
    public var id: String
    public var port: PortID
    public var created: Date
    public var reason: Reason
    /// Version the Port was on when the Snapshot was taken.
    public var release: String
    /// Version the change was moving to: the Snapshot is "Before <target>".
    public var target: String?
    /// Bytes, if measured.
    public var size: Int64?

    public init(
        id: String, port: PortID, created: Date, reason: Reason, release: String, target: String? = nil,
        size: Int64? = nil
    ) {
        self.id = id
        self.port = port
        self.created = created
        self.reason = reason
        self.release = release
        self.target = target
        self.size = size
    }
}

/// One launch of a Port.
public struct Run: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var port: PortID
    /// Version that ran.
    public var release: String
    public var started: Date
    /// Nil while running.
    public var ended: Date?
    public var exitStatus: Int32?
    /// True when the process died from an uncaught signal; `exitStatus` is then the signal number.
    public var signaled: Bool
    /// stdout and stderr of the run.
    public var log: URL

    public init(
        id: String, port: PortID, release: String, started: Date, ended: Date? = nil, exitStatus: Int32? = nil,
        signaled: Bool = false, log: URL
    ) {
        self.id = id
        self.port = port
        self.release = release
        self.started = started
        self.ended = ended
        self.exitStatus = exitStatus
        self.signaled = signaled
        self.log = log
    }

    public var isRunning: Bool { ended == nil }
    public var crashed: Bool { signaled || (exitStatus ?? 0) != 0 }
    public var duration: TimeInterval? { ended.map { $0.timeIntervalSince(started) } }
}

/// A ROM the user added, kept in `ROMs/` in its standard form.
public struct ROMRecord: Codable, Hashable, Sendable, Identifiable {
    /// Lowercase hex SHA-1 of the standard form; for an Unverified ROM, the one of the ROM the user said it is.
    public var sha1: String
    /// `KnownROM.game`: nil for a Platform's own files, such as console keys.
    public var game: GameID?
    /// `KnownROM.platform`, for a ROM of no Game.
    public var platform: PlatformID?
    /// `KnownROM.name`, such as "NTSC 1.0 (US)".
    public var name: String
    /// Extension of the standard form, such as "z64".
    public var format: String
    /// Bytes of the standard form.
    public var size: Int64
    public var added: Date
    public var originalFilename: String
    /// Set for an Unverified ROM: the SHA-1 of its own standard form, which no ROM in the Catalog has. It's kept and
    /// matched as the ROM `sha1` names, as the user said it is.
    public var ownSHA1: String?

    public var id: String { sha1 }

    public var isUnverified: Bool { ownSHA1 != nil }

    /// The SHA-1 of the file's own standard form: `ownSHA1` for an Unverified ROM, else `sha1`.
    public var fileSHA1: String { ownSHA1 ?? sha1 }

    public init(
        sha1: String, game: GameID?, platform: PlatformID? = nil, name: String, format: String, size: Int64, added: Date,
        originalFilename: String, ownSHA1: String? = nil
    ) {
        self.sha1 = sha1
        self.game = game
        self.platform = platform
        self.name = name
        self.format = format
        self.size = size
        self.added = added
        self.originalFilename = originalFilename
        self.ownSHA1 = ownSHA1
    }

    /// The format of a game that comes as a folder of files, such as a PC game's: `ROMs/<sha1>.folder` is a folder.
    public static let folderFormat = "folder"

    public var isFolder: Bool { format == Self.folderFormat }

    /// The file in a folder ROM's Seeded folder that names the ROM it was filled from, by SHA-1.
    public static let folderMarker = ".frontport-rom"
}

/// A ROM file in `ROMs/` with its record.
public struct ROMFile: Hashable, Sendable {
    public var record: ROMRecord
    public var url: URL

    public init(record: ROMRecord, url: URL) {
        self.record = record
        self.url = url
    }
}

/// The outcome of adding one file to ROMs.
/// A ROM the Catalog accepts that Steam has installed, ready to add without finding its folder.
public struct SteamOffer: Hashable, Sendable, Identifiable {
    /// The ROM the Catalog lists.
    public var sha1: String
    /// The Steam app that installed it, and its name in Steam.
    public var app: Int
    public var appName: String
    /// Where it is: its folder, or a file ROM's file.
    public var location: URL
    /// True when Steam's manifests say its files make that ROM. False when Steam installed another build, which
    /// adding would refuse.
    public var matches: Bool

    public var id: String { sha1 }

    public init(sha1: String, app: Int, appName: String, location: URL, matches: Bool) {
        self.sha1 = sha1
        self.app = app
        self.appName = appName
        self.location = location
        self.matches = matches
    }
}

public enum ROMIntake: Hashable, Sendable {
    case added(ROMRecord)
    /// Already in ROMs; nothing changed.
    case duplicate(ROMRecord)
    /// Not a ROM the Catalog lists, but a file the user can keep as one of those it can be (`assignable`), Unverified.
    /// `sha1` is the standard form's hash and `format` its format; `reason` says why the Catalog can't list it, when
    /// Frontport can tell.
    case unknown(file: URL, sha1: String, format: String, reason: String)
    /// Not accepted. `sha1` is the standard form's hash when the file could be read, shown to the user.
    case rejected(file: URL, sha1: String?, reason: String)
}
