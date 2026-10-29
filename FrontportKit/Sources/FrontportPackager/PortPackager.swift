import FrontportCore
import Foundation

/// Prepares an app to run sandboxed as a Port: bundle ID, Build Assets, Redirects, entitlements, inside-out ad-hoc
/// signing under the hardened runtime through its `Signer`, and no quarantine. It makes the folders the Redirects lead
/// to in the Port's Data itself, priming Data when it's gone, so nobody has to make them ready for it.
public struct PortPackager: PortPackaging {
    /// Where each Port's Data is, which its Redirects lead into.
    private let paths: AppPaths
    private let data: PortData
    private let signer: any Signer

    public init(paths: AppPaths, primer: (any ContainerPriming)? = nil, signer: any Signer = Codesign()) {
        self.paths = paths
        data = PortData(paths: paths, primer: primer)
        self.signer = signer
    }

    /// The app is untrusted until it's signed: it's refused when it, its Build Assets, or anything in them, leads
    /// outside them, by a link's text or by where it resolves, before anything is placed. The only links out it may
    /// hold afterwards are the ones just placed: to the Build Assets beside it, and the entry's Redirects, whose
    /// folders in Data must exist.
    public func package(
        _ app: URL, entry: CatalogEntry, permissions: Permissions, assets: URL?, installedAssets: URL?
    ) async throws {
        try Self.checkContained(app, allowing: [:])
        if let assets { try FileOperations.refuseEscapingLinks(in: assets) }
        // Upstream may ship read-only files, such as UZDoom's libraries, which this changes and signs in place.
        try FileOperations.makeWritable(app)
        try setBundleIdentifier(entry.bundleId, in: app)
        for path in ["Contents/_CodeSignature", "Contents/embedded.provisionprofile"] + entry.strip {
            try remove(try Self.location(path, in: app))
        }
        var links = MadeLinks(data: PortLinks.redirectData(bundleId: entry.bundleId, containers: paths.containers))
        if let assets {
            guard let installedAssets else {
                throw FrontportError.fileOperation("\(entry.name)’s Build Assets have nowhere to be kept.")
            }
            let link = try AssetsLink(entry: entry, installed: installedAssets)
            try place(assets, beside: app, link: link)
            links.assets = link
        }
        links.redirects = try await placeRedirects(entry, in: app, data: links.data)
        try Self.checkContained(app, allowing: links.all)
        try FileOperations.removeQuarantine(app)
        try Task.checkCancellation()

        let layout = try CodeLayout(app: app)
        let helper = PortEntitlements.helper(codeSigning: entry.codeSigning, hasLibraries: layout.hasLibraries)
        for item in layout.nested {
            try Task.checkCancellation()
            try await signer.sign(item.url, entitlements: item.isExecutable ? helper : nil)
        }
        try await signApp(app, entry: entry, permissions: permissions, hasLibraries: layout.hasLibraries, links: links)
    }

    /// The Packager's links are found in the app itself, not from the entry, which may have changed since: the app
    /// was packaged here and lives where the Port can't write, and `package` refused every other link leading out
    /// before signing. Each must still have exactly the shape the Packager gives it, and every other link out is
    /// refused.
    ///
    /// Signing changes the app in place, so a clone of it, beside it, takes its place again when signing or verifying
    /// fails: the app keeps the signature the Installation's record describes.
    public func resign(_ app: URL, entry: CatalogEntry, permissions: Permissions, installedAssets: URL?) async throws {
        guard FileOperations.isDirectory(app) else {
            throw FrontportError.signingFailed("\(app.lastPathComponent) isn’t an app folder.")
        }
        let links = try foundLinks(in: app, entry: entry, installedAssets: installedAssets)
        try Self.checkContained(app, allowing: links.all)
        let kept = app.deletingLastPathComponent()
            .appending(path: ".\(app.lastPathComponent).resigning", directoryHint: .isDirectory)
        try remove(kept)
        try FileOperations.clone(app, to: kept)
        do {
            try FileOperations.removeQuarantine(app)
            let layout = try CodeLayout(app: app)
            try await signApp(app, entry: entry, permissions: permissions, hasLibraries: layout.hasLibraries, links: links)
        } catch {
            // `kept` then holds the app that failed, removed with it. When the swap fails, `kept` stays: it's the one
            // copy whose signature matches the record.
            if (try? FileOperations.swap(kept, app)) != nil { try? remove(kept) }
            throw error
        }
        try? remove(kept)
    }

    // MARK: Steps

    private func signApp(
        _ app: URL, entry: CatalogEntry, permissions: Permissions, hasLibraries: Bool, links: MadeLinks
    ) async throws {
        let entitlements = PortEntitlements.app(
            permissions: permissions, codeSigning: entry.codeSigning, hasLibraries: hasLibraries,
            readOnly: links.assets?.readable(from: app),
            home: URL(filePath: FileOperations.canonicalPath(FileManager.default.homeDirectoryForCurrentUser)))
        try await signer.sign(app, entitlements: entitlements)
        // codesign opens what each Redirect leads to: one that's missing fails it, and anything but a folder could
        // hold it up, so the folders are walked to again right before.
        try await data.prepareRedirects(links.redirects.values.sorted(), for: entry)
        try await signer.verify(app, strictness: Self.strictness(app, links: links))
        try FileOperations.removeQuarantine(app)
    }

    /// `checkContained` polices links rather than codesign, which would reject the Packager's own. While a stop Block
    /// has the app aside, its link to the Build Assets leads nowhere.
    private static func strictness(_ app: URL, links: MadeLinks) -> Strictness {
        guard !links.all.isEmpty else { return .strict }
        if links.assets != nil, !FileOperations.exists(AssetsLink.beside(app)) { return .lenient }
        return .sideband
    }

    private func setBundleIdentifier(_ bundleId: String, in app: URL) throws {
        let url = try Self.location("Contents/Info.plist", in: app)
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let data = try? Data(contentsOf: url),
            var info = try? PropertyListSerialization.propertyList(from: data, format: &format) as? [String: Any]
        else {
            throw FrontportError.signingFailed("\(app.lastPathComponent) has no readable Info.plist.")
        }
        guard info["CFBundleIdentifier"] as? String != bundleId else { return }
        info["CFBundleIdentifier"] = bundleId
        do {
            try PropertyListSerialization.data(fromPropertyList: info, format: format, options: 0)
                .write(to: url, options: .atomic)
        } catch {
            throw FrontportError.fileOperation("Couldn’t update Info.plist: \(error.localizedDescription)")
        }
    }

    // MARK: Links

    /// Clones the Build Assets, already checked, beside the app as `assets`, replacing what's there without following
    /// a link, and puts the link to them at the entry's path inside the app.
    private func place(_ assets: URL, beside app: URL, link: AssetsLink) throws {
        let beside = AssetsLink.beside(app)
        try remove(beside)
        try FileOperations.clone(assets, to: beside)
        try FileOperations.refuseEscapingLinks(in: beside)  // in case they changed while being cloned
        try FileOperations.removeQuarantine(beside)
        try self.link(link.path, to: link.destination, in: app)
    }

    /// Puts each Redirect's link at its path inside the app, leading to its folder in the Port's Data, and returns
    /// them by path, with that folder. Each is inside `Contents/Resources/`, clear of the app's code, and no two of the
    /// Packager's links may sit at, or inside, one another.
    private func placeRedirects(_ entry: CatalogEntry, in app: URL, data: String) async throws -> [String: String] {
        let linked = entry.redirects.map(\.path) + (entry.buildAssets.map { [$0.path] } ?? [])
        var placed: [String: String] = [:]
        for redirect in entry.redirects {
            guard PortLinks.isRedirectPath(redirect.path), PortLinks.isPlainRelative(redirect.to) else {
                throw FrontportError.fileOperation("Invalid Redirect from \(redirect.path) to \(redirect.to).")
            }
            guard linked.filter({ PortLinks.overlaps($0, redirect.path) }).count == 1 else {
                throw FrontportError.fileOperation("\(entry.name) links \(redirect.path) more than once.")
            }
            placed[redirect.path] = redirect.to
        }
        // Made before any link leads to them, so no link leads anywhere but a folder in Data.
        try await self.data.prepareRedirects(placed.values.sorted(), for: entry)
        for (path, to) in placed {
            try link(path, to: PortLinks.redirectDestination(to, data: data), in: app)
        }
        return placed
    }

    /// Puts a link at `path` inside the app, in place of whatever is there.
    private func link(_ path: String, to destination: String, in app: URL) throws {
        let url = try Self.location(path, in: app)
        let folder = url.deletingLastPathComponent()
        try FileOperations.createDirectory(folder, mode: 0o755)
        // A relative link leads on from the folder it's in, and no link may hide another: no folder on the way may be
        // a link.
        let parent = path.split(separator: "/").dropLast().joined(separator: "/")
        let root = FileOperations.canonicalPath(app)
        guard FileOperations.canonicalPath(folder) == (parent.isEmpty ? root : root + "/" + parent) else {
            throw FrontportError.fileOperation("Invalid path inside the app: \(path).")
        }
        try remove(url)
        do {
            try FileManager.default.createSymbolicLink(atPath: self.path(url), withDestinationPath: destination)
        } catch {
            throw FrontportError.fileOperation("Couldn’t link \(path): \(error.localizedDescription)")
        }
    }

    /// The Packager's links in an app: the one to the Build Assets beside it, and Redirects into the Port's own Data.
    private struct MadeLinks {
        /// The Port's Data as Redirects lead into it (`PortLinks.redirectData`).
        let data: String
        var assets: AssetsLink?
        /// By path inside the app, with the folder in Data each leads to.
        var redirects: [String: String] = [:]

        /// Every one of them, by path inside the app, with its exact destination.
        var all: [String: String] {
            var all = redirects.mapValues { PortLinks.redirectDestination($0, data: data) }
            if let assets { all[assets.path] = assets.destination }
            return all
        }
    }

    /// The Packager's links in an app it packaged, found in it: the link to the Build Assets leading `../` to
    /// `assets` beside the app, and Redirects leading, absolute and canonical, into this Port's own Data, each from
    /// where the Packager may put it. A link of either shape anywhere else is refused.
    private func foundLinks(in app: URL, entry: CatalogEntry, installedAssets: URL?) throws -> MadeLinks {
        let assets = try PortLinks.assetsLink(in: app).map { path in
            guard let installedAssets else {
                throw FrontportError.fileOperation("\(app.lastPathComponent) links to Build Assets that have no place.")
            }
            return AssetsLink(path: path, installed: installedAssets)
        }
        let data = PortLinks.redirectData(bundleId: entry.bundleId, containers: paths.containers)
        return MadeLinks(data: data, assets: assets, redirects: try PortLinks.redirects(in: app, data: data))
    }

    /// Refuses an app that is a link, isn't a folder, or holds a link leading out of it, since Frontport runs
    /// unsandboxed and would follow it. The only links out it lets through are those `allowing` names, exactly.
    private static func checkContained(_ app: URL, allowing links: [String: String]) throws {
        guard FileOperations.isDirectory(app) else {
            throw FrontportError.signingFailed("\(app.lastPathComponent) isn’t an app folder.")
        }
        try FileOperations.refuseEscapingLinks(in: app, allowing: links)
    }

    /// A path relative to the bundle, refused when it, or a symlinked folder on the way, leads out of it.
    private static func location(_ path: String, in app: URL) throws -> URL {
        let components = path.split(separator: "/")
        let url = app.appending(path: path)
        let root = FileOperations.canonicalPath(app)
        let parent = FileOperations.canonicalPath(url.deletingLastPathComponent())
        guard !components.isEmpty, !components.contains(".."), !path.hasPrefix("/"),
            parent == root || parent.hasPrefix(root + "/")
        else {
            throw FrontportError.fileOperation("Invalid path inside the app: \(path).")
        }
        return url
    }

    private func remove(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
        } catch {
            throw FrontportError.fileOperation("Couldn’t remove \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func path(_ url: URL) -> String { url.path(percentEncoded: false) }
}

/// The Packager's link from inside an app to the Build Assets beside it (`PortLinks`), and where the Library keeps
/// them once the app is installed.
struct AssetsLink {
    /// Inside the app, such as "Contents/Resources/sf64.o2r".
    let path: String
    /// Where the Library keeps the Build Assets once the app is installed: the place the app may read.
    let installed: URL

    var destination: String { PortLinks.assetsDestination(for: path) }

    init(path: String, installed: URL) {
        self.path = path
        self.installed = installed
    }

    /// The link at the entry's `buildAssets.path`.
    init(entry: CatalogEntry, installed: URL) throws {
        guard let spec = entry.buildAssets else {
            throw FrontportError.fileOperation("\(entry.name) declares no place for Build Assets.")
        }
        let components = spec.path.split(separator: "/")
        // A "." would make the link climb one folder too many, a name the volume folds could reach another path, and
        // the Port could swap code in through a link where the app's code is.
        guard PortLinks.isPlainRelative(spec.path), PortLinks.isClearOfCode(spec.path) else {
            throw FrontportError.fileOperation("Invalid path inside the app: \(spec.path).")
        }
        self.init(path: components.joined(separator: "/"), installed: installed)
    }

    /// The Build Assets beside `app`, where its link leads.
    static func beside(_ app: URL) -> URL {
        app.deletingLastPathComponent().appending(path: AppPaths.assetsName)
    }

    /// The installed Build Assets as the app's exception names them: in their folder's canonical path, so nothing
    /// planted at `assets` itself can steer it, and a folder when the ones beside the app are one, or, while its link
    /// leads nowhere, when the installed ones are.
    func readable(from app: URL) -> URL {
        let beside = Self.beside(app)
        let folder = FileOperations.isDirectory(FileOperations.exists(beside) ? beside : installed)
        let parent = installed.deletingLastPathComponent()
        return URL(filePath: FileOperations.canonicalPath(parent), directoryHint: .isDirectory)
            .appending(path: installed.lastPathComponent, directoryHint: folder ? .isDirectory : .notDirectory)
    }
}
