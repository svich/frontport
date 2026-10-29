import Foundation

/// A Port's Data in its container, made ready for its app: a `Data/` that can be written to, and the folders the app's
/// Redirects lead to. The Library, the Packager and the Launcher each hold one over the same paths and primer, so
/// Data is made the same way whoever needs it, and no caller has to make it ready for another.
public struct PortData: Sendable {
    /// The protected file macOS keeps in a container it manages.
    public static let containerMetadata = ".com.apple.containermanagerd.metadata.plist"

    private let paths: AppPaths
    /// Has macOS lay out a `Data/` it manages again. Without one, Data that macOS manages and is gone waits for the
    /// Port's next launch.
    private let primer: (any ContainerPriming)?

    public init(paths: AppPaths, primer: (any ContainerPriming)?) {
        self.paths = paths
        self.primer = primer
    }

    /// Makes sure the Port's `Data/` can be written to, and says whether it can.
    ///
    /// Before a Port's first launch macOS adopts a Data folder Frontport made. Once it manages the container
    /// (after Delete Data, say), it never fills a Data folder made by anyone else with its standard layout, so
    /// the primer has macOS recreate it.
    @discardableResult
    public func prepare(_ entry: CatalogEntry) async throws -> Bool {
        let data = paths.data(for: entry.bundleId)
        if isFolder(data) { return true }
        guard isManaged(entry) else {
            try FileOperations.createDirectory(data)
            return true
        }
        guard let primer else { return false }
        try await primer.prime(entry)
        return isFolder(data)
    }

    /// True when macOS manages the Port's container, having run something with its bundle ID there. Until then any
    /// container is one Frontport made, and only Frontport has written in it.
    public func isManaged(_ entry: CatalogEntry) -> Bool {
        let metadata = paths.container(for: entry.bundleId).appending(path: Self.containerMetadata)
        return FileManager.default.fileExists(atPath: metadata.path(percentEncoded: false))
    }

    /// Creates the folders in the Port's Data that the app's Redirects lead to, found in its own links
    /// (`PortLinks.redirects`), preparing Data first when it's gone. Throws when the app holds a link shaped like a
    /// Redirect that isn't one, or when a folder can't be made.
    public func prepareRedirects(of app: URL, for entry: CatalogEntry) async throws {
        try await prepareRedirects(try PortLinks.redirects(in: app, data: redirectData(entry)).values.sorted(), for: entry)
    }

    /// Creates the folders in the Port's Data that Redirects lead to, `targets`, for an app whose links aren't placed
    /// yet, preparing Data first when it's gone. A Redirect that leads nowhere fails the app's verification, and a
    /// Port that makes its folder only when it looks missing would try to make it inside its bundle. As in Seeding,
    /// no link is ever followed: the Port can plant one anywhere in its Data.
    public func prepareRedirects(_ targets: [String], for entry: CatalogEntry) async throws {
        guard !targets.isEmpty else { return }
        guard targets.allSatisfy(PortLinks.isPlainRelative) else {
            throw FrontportError.fileOperation("\(entry.name) redirects outside its Data.")
        }
        guard try await prepare(entry) else {
            throw FrontportError.fileOperation("\(entry.name)’s Data is gone, so its Redirects lead nowhere.")
        }
        for target in targets {
            try FileOperations.createFolders(target.split(separator: "/").map(String.init), in: paths.data(for: entry.bundleId))
        }
    }

    /// Creates the folders the app's Redirects lead to once Data has changed under a change that is otherwise
    /// complete, as after restoring a Snapshot or deleting Data. A failure doesn't undo the change, so it's returned
    /// to be reported rather than thrown: the Launcher makes the folders again before each launch.
    public func prepareRedirectsAfterChange(of app: URL, for entry: CatalogEntry) async -> String? {
        do {
            try await prepareRedirects(of: app, for: entry)
            return nil
        } catch {
            let reason = (error as? FrontportError)?.errorDescription ?? error.localizedDescription
            return "\(entry.name)’s Redirects couldn’t be prepared in its Data. \(reason)"
        }
    }

    private func redirectData(_ entry: CatalogEntry) -> String {
        PortLinks.redirectData(bundleId: entry.bundleId, containers: paths.containers)
    }

    private func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
