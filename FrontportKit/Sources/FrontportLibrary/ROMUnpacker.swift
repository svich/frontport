import Foundation
import FrontportCore

/// Unpacks an installer the Catalog lists with its unpack Recipe, in the Builder's sandbox: an installer is untrusted
/// input to a parser, so it never runs in Frontport itself. Each Recipe gets its own `Builds/unpack-<name>/`, where the
/// unpacker it builds is kept for the next installer, but not what it unpacked.
public struct ROMUnpacker: ROMUnpacking {
    private let catalog: any CatalogProviding
    private let builder: any RecipeBuilding
    private let paths: AppPaths

    public init(catalog: any CatalogProviding, builder: any RecipeBuilding, paths: AppPaths) {
        self.catalog = catalog
        self.builder = builder
        self.paths = paths
    }

    public func unpack(_ installer: URL, as rom: KnownROM, progress: @escaping ProgressHandler) async throws -> [URL] {
        guard let unpack = rom.unpack else {
            throw FrontportError.romRejected(sha1: rom.sha1, reason: "The Catalog doesn’t say how to unpack this installer.")
        }
        let recipe = try await catalog.recipe(at: unpack.recipe, sha256: unpack.recipeSHA256, in: rom.catalog)
        try await builder.prepareToolchain(progress: progress)
        let workspace = Self.workspace(for: rom)
        return try await builder.unpack(
            installer, named: "\(rom.sha1).\(rom.format)", workspace: workspace, recipe: recipe,
            log: paths.buildLog(for: workspace), progress: progress)
    }

    /// The ROMs in ROMs are clones of the files left here, so they'd keep the installer's whole contents taking space,
    /// even once those ROMs are removed.
    public func discard(_ rom: KnownROM) {
        guard rom.unpack != nil else { return }
        try? FileOperations.removeUntrusted(paths.buildOutput(for: Self.workspace(for: rom)))
    }

    /// `unpack-<the Recipe's name>`, a name no Port may take (`CatalogLint`), with `-<folder name>` for an added
    /// Catalog's installer, so its Recipe never shares the unpacker another Catalog's built.
    static func workspace(for rom: KnownROM) -> PortID {
        let name = URL(filePath: rom.unpack?.recipe ?? "").deletingPathExtension().lastPathComponent.lowercased()
        let safe = String(name.unicodeScalars.filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" })
        let catalog = rom.catalog.map { "-\(AddedCatalog.folderName(for: $0))" } ?? ""
        return PortID("\(PortID.unpackPrefix)\(safe.isEmpty ? "recipe" : safe)\(catalog)")
    }
}
