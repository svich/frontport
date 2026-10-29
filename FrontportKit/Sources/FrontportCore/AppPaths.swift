import Foundation

/// Every location Frontport reads or writes. Inject a temporary `root` and `containers` in tests.
///
/// Methods only compute URLs; callers create directories (with `FileOperations.createDirectory`).
public struct AppPaths: Hashable, Sendable {
    /// `~/Library/Application Support/Frontport`.
    public let root: URL
    /// `~/Library/Containers`, where macOS keeps each Port's Data.
    public let containers: URL

    public init(root: URL, containers: URL) {
        self.root = root
        self.containers = containers
    }

    public static var `default`: AppPaths {
        let library = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library", directoryHint: .isDirectory)
        return AppPaths(
            root: library.appending(path: "Application Support/Frontport", directoryHint: .isDirectory),
            containers: library.appending(path: "Containers", directoryHint: .isDirectory)
        )
    }

    private func dir(_ path: String) -> URL { root.appending(path: path, directoryHint: .isDirectory) }

    // MARK: Catalog

    /// `Catalog/`: the cached signed Catalog.
    public var catalog: URL { dir("Catalog") }
    public var catalogDocument: URL { catalog.appending(path: "catalog.json") }
    public var catalogSignature: URL { catalog.appending(path: "catalog.json.sig") }
    /// A Recipe from the cached Catalog, by its path relative to the Catalog root ("recipes/starship.sh").
    public func recipe(_ relativePath: String) -> URL { catalog.appending(path: relativePath) }
    /// `Catalogs/`: the Catalogs the user added.
    public var addedCatalogs: URL { dir("Catalogs") }
    /// `Catalogs/added.json`: the `AddedCatalog`s, in the order they were added.
    public var addedCatalogList: URL { addedCatalogs.appending(path: "added.json") }
    /// `Catalogs/<folder name>/`: an added Catalog's cache, laid out like `Catalog/`.
    public func addedCatalog(_ catalog: URL) -> URL {
        addedCatalogs.appending(path: AddedCatalog.folderName(for: catalog), directoryHint: .isDirectory)
    }

    // MARK: ROMs

    /// `ROMs/`: ROM files in standard form, named by hash.
    public var roms: URL { dir("ROMs") }
    /// `ROMs/index.json`: the `ROMRecord`s.
    public var romIndex: URL { roms.appending(path: "index.json") }
    /// `ROMs/<sha1>.<format>`.
    public func rom(_ sha1: String, format: String) -> URL { roms.appending(path: "\(sha1).\(format)") }
    public func rom(for record: ROMRecord) -> URL { rom(record.sha1, format: record.format) }

    // MARK: Downloads, Toolchain, Builds

    /// `Downloads/`: each Release asset until the Release it holds is installed.
    public var downloads: URL { dir("Downloads") }
    /// `Downloads/<port>/`.
    public func downloads(for port: PortID) -> URL { downloads.appending(path: port.rawValue, directoryHint: .isDirectory) }
    /// `Downloads/<port>/<asset name>`.
    public func download(_ asset: ReleaseAsset, for port: PortID) -> URL {
        downloads(for: port).appending(path: asset.name)
    }

    /// `Toolchain/`: the pinned prefix Frontport manages.
    public var toolchain: URL { dir("Toolchain") }
    /// `Toolchain/<version>/`.
    public func toolchain(version: String) -> URL { toolchain.appending(path: version, directoryHint: .isDirectory) }

    /// `Builds/`: a folder per Port built from source, and per unpack Recipe.
    public var builds: URL { dir("Builds") }
    /// `Builds/<port>/`: the Recipe's working directory, the only place the build step may write. Untrusted: a
    /// Recipe can leave links anywhere in it.
    public func builds(for port: PortID) -> URL { builds.appending(path: port.rawValue, directoryHint: .isDirectory) }
    /// `Builds/<port>/src/`: where the fetch step writes the source tree.
    public func buildSource(for port: PortID) -> URL { builds(for: port).appending(path: "src", directoryHint: .isDirectory) }
    /// `Builds/<port>/out/`: where the Recipe leaves the .app and Build Assets.
    public func buildOutput(for port: PortID) -> URL { builds(for: port).appending(path: "out", directoryHint: .isDirectory) }
    /// `Builds/<port>/tmp/`: the steps' private tmp folder, which the fetch step may write too.
    public func buildTemporary(for port: PortID) -> URL { builds(for: port).appending(path: "tmp", directoryHint: .isDirectory) }
    /// `Logs/<port>/build.log`: outside every folder a Recipe may write, so it can't plant a link Frontport follows.
    public func buildLog(for port: PortID) -> URL { logs(for: port).appending(path: "build.log") }

    // MARK: Snapshots and Logs

    /// `Snapshots/<port>/`: the last 3 Snapshots.
    public func snapshots(for port: PortID) -> URL { dir("Snapshots").appending(path: port.rawValue, directoryHint: .isDirectory) }
    /// `Snapshots/<port>/<id>/`.
    public func snapshot(_ id: String, for port: PortID) -> URL {
        snapshots(for: port).appending(path: id, directoryHint: .isDirectory)
    }
    /// `Snapshots/<port>/<id>/snapshot.json`: the `Snapshot` record.
    public func snapshotRecord(_ id: String, for port: PortID) -> URL { snapshot(id, for: port).appending(path: "snapshot.json") }
    /// `Snapshots/<port>/<id>/Data/`: the cloned Data.
    public func snapshotData(_ id: String, for port: PortID) -> URL {
        snapshot(id, for: port).appending(path: "Data", directoryHint: .isDirectory)
    }

    /// `Logs/`: a folder per Port, and per unpack Recipe.
    public var logs: URL { dir("Logs") }
    /// `Logs/<port>/`: the last 5 run logs and the last build's log.
    public func logs(for port: PortID) -> URL { logs.appending(path: port.rawValue, directoryHint: .isDirectory) }
    /// `Logs/<port>/<id>.log`.
    public func runLog(_ id: String, for port: PortID) -> URL { logs(for: port).appending(path: "\(id).log") }
    /// `Logs/<port>/<id>.json`: the `Run` record.
    public func runRecord(_ id: String, for port: PortID) -> URL { logs(for: port).appending(path: "\(id).json") }

    // MARK: Artwork

    /// `Artwork/`: cached SteamGridDB artwork.
    public var artwork: URL { dir("Artwork") }
    /// `Artwork/<steamgriddb id>/`, holding one file per `ArtworkKind`.
    public func artwork(steamgriddb id: Int) -> URL { artwork.appending(path: String(id), directoryHint: .isDirectory) }

    // MARK: Library

    /// `Library/`.
    public var library: URL { dir("Library") }
    /// `Library/<port>/`.
    public func library(for port: PortID) -> URL { library.appending(path: port.rawValue, directoryHint: .isDirectory) }
    /// `Library/<port>/<appName>`: the current Release.
    public func app(for port: PortID, named appName: String) -> URL {
        library(for: port).appending(path: appName, directoryHint: .isDirectory)
    }
    public func app(for installation: Installation) -> URL { app(for: installation.port, named: installation.appName) }
    /// The name of a Release's Build Assets beside its app, a file or folder, wherever the app is: in
    /// `Library/<port>/`, `previous/` or `staging/`. The app links to them from `BuildAssetsSpec.path`.
    public static let assetsName = "assets"
    /// `Library/<port>/assets`: the current Release's Build Assets.
    public func assets(for port: PortID) -> URL { library(for: port).appending(path: Self.assetsName) }
    /// `Library/<port>/previous/`: the previous Release, kept for Rollback.
    public func previous(for port: PortID) -> URL { library(for: port).appending(path: "previous", directoryHint: .isDirectory) }
    /// `Library/<port>/previous/assets`: the previous Release's Build Assets.
    public func previousAssets(for port: PortID) -> URL { previous(for: port).appending(path: Self.assetsName) }
    /// `Library/<port>/staging/`: where a new Release is packaged before the swap, on the Library's volume.
    public func staging(for port: PortID) -> URL { library(for: port).appending(path: "staging", directoryHint: .isDirectory) }
    /// `Library/<port>/blocked/`: where a stop Block moves the app aside.
    public func blocked(for port: PortID) -> URL { library(for: port).appending(path: "blocked", directoryHint: .isDirectory) }
    /// `Library/<port>/install.json`: the `Installation` record.
    public func installRecord(for port: PortID) -> URL { library(for: port).appending(path: "install.json") }

    // MARK: Port Data

    /// `~/Library/Containers/<bundleId>/`. macOS protects the folder itself and its metadata plist.
    public func container(for bundleId: String) -> URL { containers.appending(path: bundleId, directoryHint: .isDirectory) }
    /// `~/Library/Containers/<bundleId>/Data/`: the Port's Data.
    public func data(for bundleId: String) -> URL { container(for: bundleId).appending(path: "Data", directoryHint: .isDirectory) }
}
