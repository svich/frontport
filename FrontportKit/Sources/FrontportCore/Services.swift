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
    /// Downloads the Release's asset into `Downloads/` (reusing a cached file whose digest matches),
    /// verifies its SHA-256 against `ReleaseAsset.sha256`, unpacks it into `directory`, and returns the
    /// .app inside. Throws `digestMissing` when upstream published no digest.
    func fetch(_ release: Release, into directory: URL, progress: @escaping ProgressHandler) async throws -> URL
}

/// State of the source-build toolchain.
public enum ToolchainStatus: Hashable, Sendable {
    case ready
    /// The Xcode Command Line Tools aren't installed; Frontport asks for them on the first source build.
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

/// Runs Recipes in the build sandbox (FrontportBuilder).
public protocol RecipeBuilding: Sendable {
    func toolchainStatus() async -> ToolchainStatus

    /// Prompts for the Command Line Tools if needed and installs the pinned prefix.
    func prepareToolchain(progress: @escaping ProgressHandler) async throws

    /// Runs the Recipe's fetch step (network, writes `Builds/<port>/src`) then its build step (no network),
    /// feeding it the Build-Stage ROMs. Output of both steps goes to `log`, which then holds only this run. The
    /// product stays in `Builds/<port>/out` for the caller to take and then remove; a run that fails leaves no output.
    func build(
        _ entry: CatalogEntry, ref: String, recipe: URL, roms: BuildROMs, log: URL,
        progress: @escaping ProgressHandler
    ) async throws -> BuildProduct

    /// Runs an unpack Recipe on an installer in the same sandbox, in `Builds/<workspace>/`, and returns the folders it
    /// left in its output, which stay there for the caller to take and then remove.
    func unpack(
        _ installer: URL, named name: String, workspace: PortID, recipe: URL, log: URL, progress: @escaping ProgressHandler
    ) async throws -> [URL]
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

/// SteamGridDB artwork, cached in `Artwork/` (FrontportArtwork).
public protocol ArtworkProviding: Sendable {
    /// The cached file, fetching it if needed, using the Port's own entry or the Game's. Nil when there is
    /// none, no API key is set, or the fetch fails: the UI then shows a flat color with the Game's name.
    func artwork(_ kind: ArtworkKind, for entry: CatalogEntry) async -> URL?

    func artwork(_ kind: ArtworkKind, for game: Game) async -> URL?

    /// Refetches cached artwork for these entries; run during update checks.
    func refresh(_ entries: [CatalogEntry]) async

    /// Whose key artwork is fetched with; nil when there is none.
    func apiKeySource() async -> APIKeySource?

    /// Stores the user's SteamGridDB API key in the Keychain; nil removes it.
    func setAPIKey(_ key: String?) async throws
}

/// Whose SteamGridDB API key Frontport fetches artwork with.
public enum APIKeySource: Sendable {
    /// The user's own, saved in Settings.
    case user
    /// The key a release build ships with, used while the user has none of their own.
    case builtIn
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
