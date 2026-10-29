import Foundation

/// The links the Packager makes inside a Port's app: the only links out of an app Frontport allows, because it makes
/// them itself. One leads to the Build Assets beside the app; Redirects lead into the Port's own Data.
public enum PortLinks {
    /// Where nested code lives in a bundle, relative to its `Contents/`. The Packager signs what's there.
    public static let codeLocations = ["Frameworks", "PlugIns", "XPCServices", "Helpers", "Library/LoginItems", "MacOS"]

    /// What else a bundle's signature rests on, relative to its `Contents/`.
    static let signatureLocations = ["_CodeSignature", "Info.plist", "CodeResources", "PkgInfo"]

    /// Where the link to the Build Assets beside the app leads from `path` inside it: "../" once per component of
    /// `path`, then `assets`. Relative, so it holds wherever the app is, in `staging/`, `Library/<port>/`,
    /// `previous/` or `blocked/`.
    public static func assetsDestination(for path: String) -> String {
        String(repeating: "../", count: path.split(separator: "/").count) + AppPaths.assetsName
    }

    /// The path inside `app` of its link to the Build Assets beside it, or nil when it has none. It's found by its
    /// destination, not from the Catalog, whose `buildAssets.path` may have moved since the app was packaged; the
    /// enumeration never follows a link, so the folders on its way are real. Refuses an app with more than one, or
    /// with one where no link of the Packager's may be (`isClearOfCode`).
    public static func assetsLink(in app: URL) throws -> String? {
        let found = try FileOperations.links(in: app).filter { $0.value == assetsDestination(for: $0.key) }.keys
        guard found.count <= 1 else {
            throw FrontportError.fileOperation("\(app.lastPathComponent) holds more than one link to Build Assets.")
        }
        if let path = found.first, !isClearOfCode(path) {
            throw FrontportError.fileOperation(
                "\(app.lastPathComponent) links to Build Assets from \(path), where no such link may be.")
        }
        return found.first
    }

    /// The Port's Data as Redirects lead into it: `containers` canonical, then `<bundleId>/Data`, so nothing the Port
    /// plants in its container can steer it.
    public static func redirectData(bundleId: String, containers: URL) -> String {
        FileOperations.canonicalPath(containers) + "/\(bundleId)/Data"
    }

    /// Where a Redirect to the folder `to` in Data leads: absolute, since the app's depth differs in `staging/`,
    /// `Library/<port>/`, `previous/` and `blocked/`.
    public static func redirectDestination(_ to: String, data: String) -> String {
        data + "/" + to.split(separator: "/").joined(separator: "/")
    }

    /// The Redirects in `app`: every link whose destination lies inside `data`, absolute, with no empty, "." or ".."
    /// component, by its path inside the app, with the folder in Data it leads to. They're found in the app, not
    /// from the Catalog, which may have changed since the app was packaged, so each must still be where a Redirect
    /// may be: one anywhere else is refused.
    public static func redirects(in app: URL, data: String) throws -> [String: String] {
        let found = try FileOperations.links(in: app).compactMapValues { destination -> String? in
            guard destination.hasPrefix(data + "/") else { return nil }
            let to = String(destination.dropFirst(data.count + 1))
            return isPlainRelative(to) ? to : nil
        }
        if let path = found.keys.sorted().first(where: { !isRedirectPath($0) }) {
            throw FrontportError.fileOperation("\(app.lastPathComponent) links into its Data from \(path), where no Redirect may be.")
        }
        return found
    }

    /// True when a Redirect may be at `path`: plainly inside `Contents/Resources/`, and clear of the app's code.
    public static func isRedirectPath(_ path: String) -> Bool {
        path.hasPrefix("Contents/Resources/") && isPlainRelative(path) && isClearOfCode(path)
    }

    /// True when a link at plain `path` (`isPlainRelative`) can't stand in for code or what its signature rests on:
    /// it's at, above or inside none of the code locations or signature files of the app or of an app nested in it,
    /// as the Packager signs them. Otherwise the Port could swap in, through its Data, a program that runs outside its
    /// sandbox. Compared without case, as the volume may; any other path is never clear.
    public static func isClearOfCode(_ path: String) -> Bool {
        guard isPlainRelative(path) else { return false }
        let components = path.lowercased().split(separator: "/")
        let path = components.joined(separator: "/")
        let bundles = [""] + components.indices.filter { components[$0].hasSuffix(".app") }.map {
            components[...$0].joined(separator: "/") + "/"
        }
        return !bundles.contains { bundle in
            (codeLocations + signatureLocations).contains { overlaps(path, bundle + "contents/" + $0.lowercased()) }
        }
    }

    /// True when one path is the other or inside it, so links at both would collide. Compared without case, as the
    /// volume may.
    public static func overlaps(_ a: String, _ b: String) -> Bool {
        let (a, b) = (a.lowercased(), b.lowercased())
        return a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }

    /// A relative path whose every component is plain ASCII, letters, digits, spaces, ".", "_" and "-", and neither
    /// empty, "." nor "..". The volume may fold case and Unicode, so that "Contentſ" names "Contents" there; between
    /// plain names, comparing without case is enough.
    public static func isPlainRelative(_ path: String) -> Bool {
        !path.hasPrefix("/")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { component in
                !["", ".", ".."].contains(component) && component.unicodeScalars.allSatisfy(isPlain)
            }
    }

    private static func isPlain(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
            || [" ", ".", "_", "-"].contains(scalar)
    }
}
