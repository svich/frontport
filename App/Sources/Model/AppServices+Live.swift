import Foundation
import FrontportArtwork
import FrontportBuilder
import FrontportCatalog
import FrontportCore
import FrontportLauncher
import FrontportLibrary
import FrontportPackager
import FrontportReleases
import FrontportROMs

extension AppServices {
    /// The real services over `paths`, with the signed Catalog and the container primer from `bundle`.
    static func live(paths: AppPaths, bundle: Bundle = .main) -> AppServices {
        let catalog = catalogs(paths: paths, bundle: bundle)
        let releases = gitHubReleases(paths: paths)
        let builder = RecipeBuilder(paths: paths)
        // One Builder, so unpacking an installer and building a Port share its toolchain install.
        let roms = ROMStore(paths: paths, unpacker: ROMUnpacker(catalog: catalog, builder: builder, paths: paths))
        let primer = bundle.url(forAuxiliaryExecutable: "frontport-primer").map {
            ContainerPrimer(executable: $0, paths: paths)
        }
        let launcher = PortLauncher(paths: paths, primer: primer)
        let library = Library(
            paths: paths, catalog: catalog, releases: releases, fetcher: AssetFetcher(paths: paths),
            builder: builder, roms: roms, packager: PortPackager(paths: paths, primer: primer), launcher: launcher,
            primer: primer)
        return AppServices(
            catalog: prepared(catalog), catalogs: catalog, releases: releases, roms: roms, library: library, launcher: launcher,
            artwork: ArtworkStore(paths: paths, keyStore: KeychainAPIKeyStore()))
    }

    /// Frontport's own Catalog, bundled and fetched from `catalog/` on `main`, and the ones the user added.
    private static func catalogs(paths: AppPaths, bundle: Bundle) -> Catalogs {
        #if DEBUG
        if let test = TestHooks.catalog, let key = try? CatalogSignature.publicKey(base64: test.key) {
            // Signed with another key, so the bundled Catalog wouldn't verify.
            let store = CatalogStore(paths: paths, bundled: nil, baseURL: test.url, publicKey: key)
            return Catalogs(paths: paths, builtIn: store, builtInURL: test.url)
        }
        #endif
        let store = CatalogStore(paths: paths, bundled: bundle.resourceURL?.appending(path: "catalog", directoryHint: .isDirectory))
        return Catalogs(paths: paths, builtIn: store)
    }

    /// The Catalog as the app reads it: in Debug, with what the UI tests' launch arguments add.
    private static func prepared(_ catalog: Catalogs) -> any CatalogProviding {
        #if DEBUG
        PreparedCatalog(store: catalog)
        #else
        catalog
        #endif
    }

    private static func gitHubReleases(paths: AppPaths) -> GitHubReleases {
        let cache = paths.catalog.appending(path: "releases", directoryHint: .isDirectory)
        #if DEBUG
        if let api = TestHooks.gitHubAPI { return GitHubReleases(cache: cache, api: api) }
        #endif
        return GitHubReleases(cache: cache)
    }
}

#if DEBUG
/// The Catalog with `TestHooks.prepared` applied to every document read.
private struct PreparedCatalog: CatalogProviding {
    let store: Catalogs

    func current() async throws -> CatalogDocument { TestHooks.prepared(try await store.current()) }
    func refresh() async throws -> CatalogDocument { TestHooks.prepared(try await store.refresh()) }
    func recipe(for entry: CatalogEntry) async throws -> URL { try await store.recipe(for: entry) }
    func recipe(at path: String, sha256: String, in catalog: URL?) async throws -> URL {
        try await store.recipe(at: path, sha256: sha256, in: catalog)
    }
}
#endif

extension AppPaths {
    /// Where the app keeps its files: `AppPaths.default`, or in Debug builds a root named by `FRONTPORT_ROOT`, so the
    /// app can run against a scratch Library. Port Data always lives in the real containers.
    static var app: AppPaths {
        #if DEBUG
        if let root = ProcessInfo.processInfo.environment["FRONTPORT_ROOT"], !root.isEmpty {
            return AppPaths(
                root: URL(filePath: (root as NSString).expandingTildeInPath, directoryHint: .isDirectory),
                containers: AppPaths.default.containers)
        }
        #endif
        return .default
    }
}
