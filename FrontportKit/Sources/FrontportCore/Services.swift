import Foundation

// Contracts between FrontportLibrary, the App and the component modules. Implementations live in their
// modules; the App wires them together. Every method that throws a user-facing failure throws
// `FrontportError`, and long work honors Task cancellation by throwing `CancellationError`.

/// Loads, verifies and caches the signed Catalogs, Frontport's own and the ones the user added, read as one
/// (FrontportCatalog).
public protocol CatalogProviding: Sendable {
    /// The newest verified Catalog available without the network: the cache, else the bundled copy.
    func current() async throws -> CatalogDocument

    /// Fetches the Catalog, verifies its signature and caches it. On failure the cache is left untouched.
    func refresh() async throws -> CatalogDocument

    /// A verified local copy of a source-built entry's Recipe, from the Catalog that lists it, checked against
    /// `GitSource.recipeSHA256`.
    func recipe(for entry: CatalogEntry) async throws -> URL

    /// A verified local copy of the Recipe at `path` relative to the root of `catalog` (nil for Frontport's own),
    /// checked against `sha256`.
    func recipe(at path: String, sha256: String, in catalog: URL?) async throws -> URL
}

/// The Catalogs the user added by link (FrontportCatalog). See ADR 0012.
public protocol CatalogManaging: Sendable {
    /// Every added Catalog, in the order it was added, from its cache.
    func added() async -> [CatalogSummary]

    /// Fetches and verifies the Catalog a link names, without adding it: a `frontport://add-catalog` link, or the
    /// https URL of the folder holding its `catalog.json`.
    func preview(_ link: URL) async throws -> CatalogSummary

    /// Adds a Catalog `preview(_:)` returned: fetches it again, verifies it with its key, and caches it.
    func add(_ catalog: AddedCatalog) async throws

    /// Forgets an added Catalog and its cache. Ports installed from it stay in the Library.
    func remove(_ url: URL) async throws
}

/// Discovers upstream Releases per Channel and applies Blocks (FrontportReleases).
public protocol ReleaseDiscovering: Sendable {
    /// Releases on a Channel, newest first, Blocked ones left out. For a source-built entry, the pinned ref.
    func releases(for entry: CatalogEntry, channel: Channel) async throws -> [Release]

    /// The newest Release on a Channel that isn't Blocked, or nil when there is none.
    func latest(for entry: CatalogEntry, channel: Channel) async throws -> Release?
}

/// Downloads and unpacks prebuilt Releases (the Fetcher, in FrontportReleases).
public protocol AssetFetching: Sendable {
    /// Downloads the Release's asset into `Downloads/<downloads>/` (reusing a cached file whose digest matches),
    /// verifies its SHA-256 against `ReleaseAsset.sha256`, unpacks it into `directory`, and returns the
    /// .app inside. Throws `digestMissing` when upstream published no digest. `downloads` is the Release's Port for
    /// the Mac, or for a Device its `PortID.deviceWorkspace`.
    func fetch(_ release: Release, into directory: URL, downloads: PortID, progress: @escaping ProgressHandler) async throws -> URL
}

extension AssetFetching {
    /// The Mac's: downloads into the Release's Port's own folder, `Downloads/<port>/`.
    public func fetch(_ release: Release, into directory: URL, progress: @escaping ProgressHandler) async throws -> URL {
        try await fetch(release, into: directory, downloads: release.port, progress: progress)
    }
}

/// State of the source-build toolchain.
public enum ToolchainStatus: Hashable, Sendable {
    case ready
    /// The Xcode Command Line Tools aren't installed; Frontport asks for them on the first source build. For an iOS
    /// build, Xcode isn't (`RecipeBuilding.toolchainStatus(for:)`).
    case needsCommandLineTools
    /// The pinned prefix in `Toolchain/` is missing or outdated.
    case needsPrefix
}

/// What a Recipe produced, inside `Builds/<port>/out/`.
public struct BuildProduct: Hashable, Sendable {
    public var app: URL
    /// The Build Assets (a file or folder) to keep beside the app and link at `BuildAssetsSpec.path`, when the entry
    /// has them.
    public var assets: URL?

    public init(app: URL, assets: URL? = nil) {
        self.app = app
        self.assets = assets
    }
}

/// The SDK a Recipe builds with, named as `xcrun --sdk` names it: the Mac's for the Port, or Xcode's iPhoneOS SDK for its
/// iOS version, for Devices.
public enum BuildSDK: String, Hashable, Sendable {
    case macosx
    case iphoneos

    /// The Builder's folder for a build of the Port: `Builds/<port>/` for the Mac, and for Devices `Builds/<port>.ios/`,
    /// named as the Port's other iOS folders are.
    public func workspace(for port: PortID) -> PortID {
        switch self {
        case .macosx: port
        case .iphoneos: port.deviceWorkspace
        }
    }
}

/// Runs Recipes in the build sandbox (FrontportBuilder). One that builds only for the Mac needn't implement the SDK-aware
/// toolchain calls.
public protocol RecipeBuilding: Sendable {
    func toolchainStatus() async -> ToolchainStatus

    /// Prompts for the Command Line Tools if needed and installs the pinned prefix.
    func prepareToolchain(progress: @escaping ProgressHandler) async throws

    /// What a build with `sdk` still needs. The Mac's is `toolchainStatus()`. An iOS build runs with Xcode's own tools,
    /// so with Xcode found it needs only the pinned prefix, whether or not the Command Line Tools are installed; without
    /// it, `needsCommandLineTools`.
    func toolchainStatus(for sdk: BuildSDK) async -> ToolchainStatus

    /// Readies what a build with `sdk` needs. The Mac's is `prepareToolchain(progress:)`. For an iOS build it never
    /// offers the Command Line Tools: it throws `xcodeMissing` or `noIOSPlatform` without Xcode with the iOS platform,
    /// else installs the pinned prefix.
    func prepareToolchain(for sdk: BuildSDK, progress: @escaping ProgressHandler) async throws

    /// Runs the Recipe's fetch step (network, writes the workspace's `src`) then its build step (no network), feeding it
    /// the Build-Stage ROMs, in `sdk`'s workspace for the Port (`BuildSDK.workspace(for:)`). Output of both steps goes
    /// to `log`, which then holds only this run. The product stays in the workspace's `out` for the caller to take and
    /// then remove; a run that fails leaves no output. An iOS build needs Xcode with the iOS platform.
    func build(
        _ entry: CatalogEntry, ref: String, recipe: URL, roms: BuildROMs, sdk: BuildSDK, log: URL,
        progress: @escaping ProgressHandler
    ) async throws -> BuildProduct

    /// Runs an unpack Recipe on an installer in the same sandbox, in `Builds/<workspace>/`, and returns the folders it
    /// left in its output, which stay there for the caller to take and then remove.
    func unpack(
        _ installer: URL, named name: String, workspace: PortID, recipe: URL, log: URL, progress: @escaping ProgressHandler
    ) async throws -> [URL]
}

extension RecipeBuilding {
    /// The Mac's: builds in `Builds/<port>/`.
    public func build(
        _ entry: CatalogEntry, ref: String, recipe: URL, roms: BuildROMs, log: URL,
        progress: @escaping ProgressHandler
    ) async throws -> BuildProduct {
        try await build(entry, ref: ref, recipe: recipe, roms: roms, sdk: .macosx, log: log, progress: progress)
    }

    /// For a Builder that builds only for the Mac, whose `build` refuses `iphoneos`: the Mac's.
    public func toolchainStatus(for sdk: BuildSDK) async -> ToolchainStatus { await toolchainStatus() }

    public func prepareToolchain(for sdk: BuildSDK, progress: @escaping ProgressHandler) async throws {
        try await prepareToolchain(progress: progress)
    }
}

/// Unpacks an installer the Catalog lists into the folders it holds (FrontportLibrary composes the Catalog and the
/// Builder). The folders are the caller's to identify; they stay where the unpack left them until `discard`.
public protocol ROMUnpacking: Sendable {
    func unpack(_ installer: URL, as rom: KnownROM, progress: @escaping ProgressHandler) async throws -> [URL]

    /// Removes the folders the last `unpack` of an installer like `rom` left, once the ROMs among them are in ROMs.
    func discard(_ rom: KnownROM)
}

/// The user's ROMs: intake, and Matching, which says where each Port's Requirements stand and Seeds them
/// (FrontportROMs).
public protocol ROMStoring: Sendable {
    /// Standardizes and hashes each file, keeping those the Catalog lists. One result per input file, except for an
    /// installer, which has one per ROM it holds.
    func add(_ files: [URL], catalog: CatalogDocument) async -> [ROMIntake]

    /// Adds a file whose hash the Catalog doesn't list as the ROM `sha1` names, Unverified: kept and matched as that
    /// ROM, which must be one the Catalog says it can be (`CatalogDocument.assignable`). A file the Catalog lists is
    /// added as itself.
    func assign(_ file: URL, as sha1: String, catalog: CatalogDocument) async -> [ROMIntake]

    /// Removes a ROM from ROMs. Installed Ports keep working.
    func remove(_ sha1: String) async throws

    /// The ROMs a Requirement accepts that Steam has installed and ROMs doesn't hold yet, read from Steam's own files
    /// without hashing any of the Game's.
    func steamOffers(catalog: CatalogDocument) async -> [SteamOffer]

    /// Adds the ROM `sha1` names from where Steam installed it: just the files Steam's manifests list, less the ones
    /// its Game rewrites, so saves and settings written beside them don't stop it matching.
    func addFromSteam(_ sha1: String, catalog: CatalogDocument) async -> [ROMIntake]

    /// The ROMs a Requirement accepts that ROMs doesn't hold and Steam can download, at the build the Catalog pins:
    /// those whose depots it lists, when Steam is installed. Whether the user owns the Game, only Steam knows.
    func steamDownloads(catalog: CatalogDocument) async -> [String]

    /// Has Steam download the ROM `sha1` names, depot by depot, then adds it as Steam installed it and removes what
    /// Steam downloaded. `progress` gets the fraction done.
    func downloadFromSteam(_ sha1: String, catalog: CatalogDocument, progress: @escaping @Sendable (Double) -> Void) async -> [ROMIntake]

    /// The ROMs and installers the Catalog says where to download that would give a ROM ROMs doesn't hold yet.
    func webDownloads(catalog: CatalogDocument) async -> [String]

    /// Downloads the ROM or installer `sha1` names from where the Catalog says and adds what arrives, as a file the
    /// user picked. `progress` gets the fraction done.
    func downloadFromWeb(_ sha1: String, catalog: CatalogDocument, progress: @escaping @Sendable (Double) -> Void) async -> [ROMIntake]

    /// Reads ROMs, and the Data of each entry with an Installation in `installations`, into where each entry's
    /// Requirements stand. A reading is as of now: adding or removing a ROM, a change of Release and anything a Port
    /// does to its Data can make it out of date. It never fails: a Data folder it can't read holds nothing Seeded. Its
    /// only write tags a Seeded file that has no tag yet but holds its ROM (ADR 0010).
    func matching(_ entries: [CatalogEntry], installations: [PortID: Installation]) async -> Matching

    /// Seeds each of the entry's Runtime Requirements whose Match isn't all in the Port's Data, working the Match out
    /// again now. At a file `seedPath`, another accepted ROM gives way to the Match; a folder ROM filled from another
    /// release is moved aside. Never follows a link in Data, and creates the folders on the way with mode 0700. The
    /// caller makes sure Data can be written to and that the Port isn't running. Requirements Seeded before a failure
    /// stay Seeded.
    func seed(_ entry: CatalogEntry) async throws

    /// Lays out clones of the Matches of the Runtime Requirements the iOS version Seeds in `root`, as Seeding lays them
    /// out in Data but by their iOS seedPaths, for `devicectl` to copy into the app's container on a Device: a file at a
    /// file seedPath, each ROM as `<sha1>.<format>` in a folder one, a folder ROM filled in with its marker. A
    /// Requirement without a Match gets nothing. `root` is a fresh folder inside `Devices/`, and anywhere else is
    /// refused, so nothing it lays out lands in a Port's Data on this Mac.
    func stage(_ version: IOSVersion, into root: URL) async throws -> [StagedSeed]
}

extension ROMStoring {
    /// For ROMs that never lay anything out for Devices, such as a test's.
    public func stage(_ version: IOSVersion, into root: URL) async throws -> [StagedSeed] {
        throw FrontportError.fileOperation("ROMs can’t be laid out for iPhone and iPad here.")
    }
}

/// Prepares an app to run sandboxed as a Port (FrontportPackager).
public protocol PortPackaging: Sendable {
    /// In place: sets `CFBundleIdentifier` to the entry's `bundleId`, signs inside-out with entitlements from
    /// `permissions` and the entry's code-signing exceptions, and strips quarantine.
    ///
    /// With `assets`, it first clones them beside the app as `assets` and links `BuildAssetsSpec.path` to them, and
    /// signs the app to read them, read-only, at `installedAssets`: where the Library keeps them once the app is
    /// installed (`Library/<port>/assets`). `installedAssets` is ignored without `assets`. It links the entry's
    /// Redirects into the Port's Data and makes their folders there (`PortData`), preparing Data first when it's gone,
    /// so no caller has to.
    func package(_ app: URL, entry: CatalogEntry, permissions: Permissions, assets: URL?, installedAssets: URL?) async throws

    /// Re-signs an app after a Permissions change, without touching anything else but the folders its Redirects lead
    /// to, which it makes as `package` does. `installedAssets` is where the Library keeps the Build Assets the app links
    /// to, as for `package`, or nil when it has no such link.
    func resign(_ app: URL, entry: CatalogEntry, permissions: Permissions, installedAssets: URL?) async throws
}

/// Prepares a Port's iOS version to install on Devices (FrontportPackager).
public protocol DevicePackaging: Sendable {
    /// Reads what a Device is checked against from an app as upstream ships it, changing nothing: refuses one that
    /// isn't an arm64, unencrypted iPhone and iPad app, or holds a link leading out of it. Its `bundleId` is
    /// upstream's.
    func inspect(_ app: URL, version: IOSVersion) async throws -> DeviceAppInfo

    /// In place: refuses an app that isn't one arm64, unencrypted iPhone and iPad app with only frameworks and
    /// libraries nested, sets its `CFBundleIdentifier` to `signing.bundleId`, removes upstream signatures and the iOS
    /// version's `strip` paths, gives it `icon` (an image file) as its home screen icon when there is one, embeds the
    /// Provisioning Profile and signs inside-out with `signing.certificate`. The `bundleId` it returns is
    /// `signing.bundleId`.
    func package(_ app: URL, version: IOSVersion, signing: DeviceSigning, icon: URL?) async throws -> DeviceAppInfo

    /// Signs an app it packaged again, with another Provisioning Profile or certificate of the same Apple Team, for
    /// Renew, refusing one whose bundle ID isn't `signing.bundleId`. When that fails, the app is as it was.
    func resign(_ app: URL, signing: DeviceSigning) async throws -> DeviceAppInfo
}

extension DevicePackaging {
    /// Packages the app with its own icon.
    public func package(_ app: URL, version: IOSVersion, signing: DeviceSigning) async throws -> DeviceAppInfo {
        try await package(app, version: version, signing: signing, icon: nil)
    }
}

/// Has macOS lay out a Port's Data folder without running the Port (FrontportPackager).
///
/// macOS creates `Data/` with its standard layout only when a sandboxed process with the bundle ID starts.
/// Once it manages a container (after Delete Data, say), it never adopts a `Data/` someone else made.
public protocol ContainerPriming: Sendable {
    /// Runs a stand-in app with the entry's bundle ID once in the sandbox, so `Data/` exists afterwards.
    func prime(_ entry: CatalogEntry) async throws
}

/// A change in what's running.
public enum LaunchEvent: Hashable, Sendable {
    case started(Run)
    case ended(Run)
}

/// Launches Ports and keeps their run logs (FrontportLauncher).
public protocol PortLaunching: Sendable {
    /// Launches the Installation's app with the entry's `LaunchSpec`, capturing stdout and stderr into a
    /// new run log (keeping the last 5).
    func launch(_ entry: CatalogEntry, installation: Installation) async throws -> Run

    /// True when the Port is running, however it was launched.
    func isRunning(_ entry: CatalogEntry) async -> Bool

    /// Ports launched through Frontport that are still running.
    func running() async -> Set<PortID>

    /// Asks a running Port to quit.
    func stop(_ entry: CatalogEntry) async

    /// Recent runs, newest first.
    func runs(for port: PortID) async -> [Run]

    /// A new stream of launch events per call; it finishes when the subscriber stops iterating.
    func events() async -> AsyncStream<LaunchEvent>
}

/// SteamGridDB artwork, fetched through Frontport's artwork Worker and cached in `Artwork/` (FrontportArtwork).
public protocol ArtworkProviding: Sendable {
    /// The cached file, fetching it if needed, using the Port's own entry or the Game's. Nil when there is
    /// none or the fetch fails: the UI then shows a flat color with the Game's name.
    func artwork(_ kind: ArtworkKind, for entry: CatalogEntry) async -> URL?

    func artwork(_ kind: ArtworkKind, for game: Game) async -> URL?

    /// Refetches cached artwork for these entries; run during update checks.
    func refresh(_ entries: [CatalogEntry]) async

    /// Scales artwork cached before Frontport scaled it when fetching down to `ArtworkKind.maxPixels`.
    func compact() async
}

extension ArtworkProviding {
    public func compact() async {}
}

/// Installations and everything that changes them (FrontportLibrary). Orchestrates the other services.
public protocol LibraryManaging: Sendable {
    func installations() async -> [Installation]

    func installation(for port: PortID) async -> Installation?

    /// Runs the install pipeline on a Channel: resolve, Requirements, fetch or build, package, sign, swap,
    /// Seed. Throws `romMissing` for a missing Build-Stage ROM; a missing Runtime ROM doesn't stop the
    /// install, it is Seeded once added (`applyROMs`).
    ///
    /// Here and in every other change of Release, Seeding comes after the change is complete: a Seeding
    /// failure is reported as a progress message rather than thrown, and `ROMStoring.matching` says what's left.
    func install(_ entry: CatalogEntry, channel: Channel, progress: @escaping ProgressHandler) async throws -> Installation

    /// Updates to `release`, or to the newest non-Blocked Release on the Installation's Channel. Takes a
    /// Snapshot first and keeps the current Release in `previous/`. An older Release (when the newest is
    /// Blocked, say) is handled like switching to it: no previous Release is kept, and the Data from when the
    /// Port was last on it comes back.
    func update(_ entry: CatalogEntry, to release: Release?, progress: @escaping ProgressHandler) async throws -> Installation

    /// Snapshots the current Data, restores the Snapshot taken before the update, and swaps `previous/` back in.
    func rollback(_ entry: CatalogEntry, progress: @escaping ProgressHandler) async throws -> Installation

    /// Follows another Channel, installing its newest Release. Landing on an older Release is handled like a Rollback.
    func switchChannel(_ entry: CatalogEntry, to channel: Channel, progress: @escaping ProgressHandler) async throws -> Installation

    /// Re-signs with new Permissions. Throws `running` while the Port runs.
    func setPermissions(_ permissions: Permissions, for entry: CatalogEntry) async throws -> Installation

    /// Seeds Runtime ROMs now present in ROMs and regenerates Build Assets when a Build-Stage extra was added.
    /// Throws `running` while the Port runs.
    func applyROMs(to entry: CatalogEntry, progress: @escaping ProgressHandler) async throws

    /// Removes the Installation with its build folder, download and logs, keeping Data and Snapshots.
    func uninstall(_ entry: CatalogEntry) async throws

    /// Removes the Port's Data and Snapshots, leaving the Installation and its Build Assets.
    func deleteData(_ entry: CatalogEntry) async throws

    /// Removes the Port's build folder, which only lets the next build reuse the source tree and what the Recipe made
    /// there. The Installation keeps working; its next build fetches and builds from scratch.
    func removeBuildFolder(_ entry: CatalogEntry) async throws

    /// Removes what operations that failed or were cut short left: every `staging/`, a `Library/<port>/` without a
    /// record, every download, and the build folder and logs of a Port that isn't installed. A failed install keeps
    /// them for another try until then. Call it at launch, before anything else changes a Port.
    func removeLeftovers() async

    /// Snapshots, newest first.
    func snapshots(for port: PortID) async -> [Snapshot]

    /// Replaces the Port's Data with one of its own Snapshots, taking a Snapshot of the current Data first.
    func restore(_ snapshot: Snapshot, entry: CatalogEntry) async throws

    /// Applies the Catalog's Blocks: disables Installations on a stop-Blocked Release and re-enables those no
    /// longer Blocked. Returns the Installations that changed.
    func enforceBlocks(_ catalog: CatalogDocument) async throws -> [Installation]
}

/// The iPhones and iPads paired with this Mac, through Xcode's `devicectl` (FrontportDevices). A call the Device can't
/// carry out throws `deviceUnavailable` with `devicectl`'s own words.
public protocol DeviceControlling: Sendable {
    /// Every paired Device, read now: how it's reachable, and, when it is, whether it's locked and has Developer Mode
    /// on.
    func readings() async throws -> [DeviceReading]

    /// The bundle IDs of the apps a developer installed on the Device, such as Frontport's Ports.
    func apps(on device: DeviceID) async throws -> Set<String>

    /// Installs a signed app over the one with its bundle ID, which keeps that one's Data.
    func install(_ app: URL, on device: DeviceID) async throws

    /// Removes the app and its Data. An app that isn't installed counts as removed.
    func uninstall(_ bundleId: String, from device: DeviceID) async throws

    /// What the app's container on the Device holds where `seeds` go: every file and folder at each one's path and
    /// below it, at every depth, links listed as links, with paths relative to the container; a folder it doesn't have
    /// yet holds nothing. More may be listed. Each of `markers` listed as a file, not a folder or link, is read, and
    /// what it names goes in the listing's `markers`.
    func list(_ seeds: [StagedSeed], markers: [String], of bundleId: String, on device: DeviceID) async throws -> DeviceListing

    /// Puts every file under `root` into the app's container on the Device at the same path relative to it, over what
    /// is there, leaving everything else there as it is; the files at `markers` go last, once all the others are there.
    /// `listing`, the container as last listed, is what the files replace. `root` is used up: its files may be moved
    /// or dated anew.
    func put(_ root: URL, markers: [String], over listing: DeviceListing, of bundleId: String, on device: DeviceID) async throws

    /// The executables running on the Device, by process ID.
    func processes(on device: DeviceID) async throws -> [Int32: URL]
}

/// The user's Apple Teams and their Provisioning Profiles (FrontportDevices).
public protocol Provisioning: Sendable {
    /// The Apple Teams whose Apple Development certificates have their keys in the keychain, by name.
    func teams() async -> [AppleTeam]

    /// How to sign `bundleId` for `device` with `team`: a Provisioning Profile that lets it run there, lasting past a
    /// day from now and past `outlasting`, and the certificate it names. Throws `noAppleTeam` when the keychain holds
    /// no certificate of `team`, `provisioningFailed` when there's no such Provisioning Profile.
    func signing(for bundleId: String, team: AppleTeamID, device: DeviceID, outlasting: Date?) async throws -> DeviceSigning
}

/// The records of Installations on Devices and of the Devices remembered (FrontportLibrary): what the Survey reads.
public protocol DeviceRecords: Sendable {
    /// Every Installation on a Device, by Device then Port.
    func installations() async -> [DeviceInstallation]

    /// The Devices remembered in `Devices/<udid>/device.json`, by name.
    func devices() async -> [Device]
}

/// Installations on Devices and everything that changes them (FrontportLibrary): the iOS version of a Port, fetched on
/// this Mac, packaged and signed with the user's Apple Team, and installed through `devicectl`. One operation runs per
/// Port at a time, whichever Device it's for. It never writes the Mac's Library, a Port's container on the Mac or a
/// Port's Mac downloads, builds and logs, and refuses any entry whose id or bundle ID could name a folder other than
/// its own.
public protocol DeviceLibraryManaging: DeviceRecords {
    /// Remembers the Device as it was just read, so its Installations still show while it's away.
    func remember(_ device: Device) async throws

    /// Forgets a Device with the records of its Installations, leaving their apps and Data on it.
    func forget(_ device: DeviceID) async throws

    /// Readies the iOS version for Devices, none in particular: resolves the newest iOS Release on the Channel, fetches
    /// it into `Downloads/<port>.ios/` and unpacks it, or for a source-built one runs its iOS Recipe in
    /// `Builds/<port>.ios/`, then reads what Devices are checked against, signing nothing. The prepared app replaces the
    /// one before, which is reused instead when it's for that Release on that Channel, and stays while a Device has the
    /// Port. Throws `blocked` or `noRelease` when the iOS version doesn't offer that Release (`IOSVersion.check`).
    func prepare(_ version: IOSVersion, channel: Channel, progress: @escaping ProgressHandler) async throws -> PreparedDeviceApp

    /// The Port's prepared app, if there is one.
    func prepared(_ port: PortID) async -> PreparedDeviceApp?

    /// Installs the Port's prepared app on the Device, signed with `team`: check it against the Device, take a
    /// Provisioning Profile that names the Device, package and sign a clone of it, install, record. The prepared app
    /// stays as it was, for the next Device. The record follows `devicectl`'s install: a failed install leaves nothing
    /// recorded. With nothing prepared any more, as when the last Device's uninstall took it, it prepares again on the
    /// iOS version's default Channel. Throws `alreadyInstalled` when the Port is on the Device, and `blocked` or
    /// `noRelease` when `version` no longer offers its Release (`IOSVersion.check`).
    func installPrepared(
        _ version: IOSVersion, on device: DeviceReading, team: AppleTeamID, progress: @escaping ProgressHandler
    ) async throws -> DeviceInstallation

    /// Installs the newest iOS Release on `channel` over the Port's Installation on the Device, which keeps its Data
    /// there: prepares it, reusing what's prepared for that Release, then packages, signs and installs a clone as
    /// installing does, and records it with what the record said was Seeded there. Moves forward only
    /// (`IOSVersion.update`): the Release installed, built by the same iOS Recipe, returns the Installation as it is,
    /// and an older one is refused. Needs the
    /// Installation, `team` being the Apple Team it's signed with (`otherAppleTeam` otherwise), and the Device
    /// reachable and in Developer Mode. Seed afterwards.
    func update(
        _ version: IOSVersion, on device: DeviceReading, team: AppleTeamID, channel: Channel,
        progress: @escaping ProgressHandler
    ) async throws -> DeviceInstallation

    /// Renews the Port's Installation on the Device: takes, or has Xcode make, a Provisioning Profile for its bundle
    /// ID that names the Device and lasts longer than the app's signature does now, signs a clone of the app kept for
    /// it again with that, installs it over the one there, which keeps its Data, then swaps it in and records the new
    /// expiry. Whatever fails, the app kept and the record stay as they were. Needs the Installation, `team` being the
    /// Apple Team it's signed with (`otherAppleTeam` otherwise: another's bundle ID is an install of its own), and the
    /// Device reachable, unlocked and in Developer Mode. Refused, before Xcode is asked, while the app isn't on the
    /// Device (`deviceUnavailable(.notInstalled)`), so one the user deleted is never put back, and while the Port runs
    /// there (`running`). The record's entry is enough, so it works for a Port the Catalog no longer lists.
    func renew(
        _ port: PortID, on device: DeviceReading, team: AppleTeamID, progress: @escaping ProgressHandler
    ) async throws -> DeviceInstallation

    /// Removes the Port's app from the Device, and its Data with it, then its record and kept app. An app already gone
    /// from the Device counts as removed; a Device that can't be reached keeps the Installation.
    func uninstall(_ port: PortID, from device: DeviceID) async throws

    /// Seeds the Port's Runtime ROMs on the Device: lays their Matches out in `seeds/`, lists the Device, copies only
    /// what `DeviceSeeding.plan` says, files then markers, lists it again and records what's there. Needs the Port's
    /// Installation on the Device and the Device reachable, unlocked and in Developer Mode, refused otherwise with
    /// `DeviceReadiness`'s error, which Seeding's wait reads back; throws `running` while the Port runs there. When the Device goes away part way, the record stays as it was. Returns the plan as the Device
    /// stands afterwards, nil when the iOS version Seeds nothing. `version` is the one Seeding goes by
    /// (`IOSVersion(seeding:listed:)`).
    func seed(_ version: IOSVersion, on device: DeviceReading, progress: @escaping ProgressHandler) async throws -> DeviceSeedingPlan?

    /// What `seed` would copy to the Device now, read from its listing, copying nothing and leaving the record alone; nil
    /// when the iOS version Seeds nothing. Needs the Device reachable and in Developer Mode, though it may be locked.
    func seedingPlan(for version: IOSVersion, on device: DeviceReading) async throws -> DeviceSeedingPlan?

    /// Whether the Port runs on the Device now, as the Device says, which Renew and Seeding refuse; false without its
    /// Installation there. Throws when the Device can't be asked.
    func isRunning(_ port: PortID, on device: DeviceID) async throws -> Bool

    /// Removes what operations that failed or were cut short left: every `staging/` and `seeds/` on a Device, a
    /// `Devices/<udid>/<port>/` without a record, every iOS download and `preparing/`, and the iOS build folder, with
    /// its prepared app, and logs of a Port on no Device. Call it at launch, before anything else changes a Port.
    func removeLeftovers() async
}
