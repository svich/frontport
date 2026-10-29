import Foundation
import FrontportCore

/// A unique scratch folder, removed when the test drops it.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "FrontportPackagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    // Folder ROMs and some tests leave read-only folders, which a plain removal stops at.
    deinit { try? FileOperations.removeUntrusted(url) }
}

/// Runs a tool and returns stdout and stderr together, failing the test on a non-zero exit.
@discardableResult
func tool(_ path: String, _ arguments: [String]) async throws -> String {
    let log = FileManager.default.temporaryDirectory.appending(path: "tool-\(UUID().uuidString).log")
    defer { try? FileManager.default.removeItem(at: log) }
    let result = try await ProcessRunner().run(URL(filePath: path), arguments: arguments, stdout: .file(log), stderr: .file(log))
    let output = String(decoding: try Data(contentsOf: log), as: UTF8.self)
    guard result.succeeded else {
        throw FrontportError.processFailed(command: "\(path) \(arguments.joined(separator: " "))", status: result.status, output: output)
    }
    return output
}

func clang(_ arguments: [String]) async throws {
    try await tool("/usr/bin/xcrun", ["clang"] + arguments)
}

func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

func infoPlist(executable: String, identifier: String, packageType: String = "APPL") -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>\(identifier)</string>
    <key>CFBundleExecutable</key><string>\(executable)</string>
    <key>CFBundlePackageType</key><string>\(packageType)</string>
    <key>CFBundleName</key><string>\(executable)</string>
    </dict></plist>
    """
}

/// Builds a small upstream-style app: a main program that prints what the sandbox lets it see, linking a
/// dylib and a framework in `Contents/Frameworks`, with a helper, a plug-in, a Mach-O library without an
/// extension, a decoy "dylib" that isn't Mach-O, an upstream signature and a provisioning profile.
enum TestApp {
    static let decoyContents = "not really a library"

    static func make(in directory: URL, name: String = "Tiny", nested: Bool = true) async throws -> URL {
        let app = directory.appending(path: "\(name).app", directoryHint: .isDirectory)
        let contents = app.appending(path: "Contents", directoryHint: .isDirectory)
        let sources = directory.appending(path: "src-\(name)", directoryHint: .isDirectory)
        try write(infoPlist(executable: name, identifier: "com.upstream.\(name.lowercased())"), to: contents.appending(path: "Info.plist"))
        try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)

        let main = sources.appending(path: "main.c")
        let executable = contents.appending(path: "MacOS/\(name)").path(percentEncoded: false)
        if nested {
            let frameworks = contents.appending(path: "Frameworks", directoryHint: .isDirectory)
            try write("int tiny_answer(void) { return 42; }\n", to: sources.appending(path: "lib.c"))
            try write("int tiny_framework_answer(void) { return 7; }\n", to: sources.appending(path: "framework.c"))
            try write(mainSource(withLibraries: true), to: main)

            try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
            try await clang(["-dynamiclib", "-o", frameworks.appending(path: "libtiny.dylib").path(percentEncoded: false),
                "-install_name", "@rpath/libtiny.dylib", sources.appending(path: "lib.c").path(percentEncoded: false)])
            try await clang(["-dynamiclib", "-o", frameworks.appending(path: "libnoext").path(percentEncoded: false),
                "-install_name", "@rpath/libnoext", sources.appending(path: "lib.c").path(percentEncoded: false)])
            try write(decoyContents, to: frameworks.appending(path: "decoy.dylib"))

            let framework = frameworks.appending(path: "TinyKit.framework", directoryHint: .isDirectory)
            let version = framework.appending(path: "Versions/A", directoryHint: .isDirectory)
            try write(
                infoPlist(executable: "TinyKit", identifier: "com.upstream.tinykit", packageType: "FMWK"),
                to: version.appending(path: "Resources/Info.plist"))
            try await clang(["-dynamiclib", "-o", version.appending(path: "TinyKit").path(percentEncoded: false),
                "-install_name", "@rpath/TinyKit.framework/Versions/A/TinyKit",
                sources.appending(path: "framework.c").path(percentEncoded: false)])
            let fm = FileManager.default
            try fm.createSymbolicLink(atPath: framework.appending(path: "Versions/Current").path(percentEncoded: false), withDestinationPath: "A")
            try fm.createSymbolicLink(atPath: framework.appending(path: "TinyKit").path(percentEncoded: false), withDestinationPath: "Versions/Current/TinyKit")
            try fm.createSymbolicLink(atPath: framework.appending(path: "Resources").path(percentEncoded: false), withDestinationPath: "Versions/Current/Resources")

            try await clang(["-o", executable, main.path(percentEncoded: false),
                "-L", frameworks.path(percentEncoded: false), "-ltiny",
                "-F", frameworks.path(percentEncoded: false), "-framework", "TinyKit",
                "-Wl,-rpath,@executable_path/../Frameworks"])

            try write("int main(void) { return 0; }\n", to: sources.appending(path: "helper.c"))
            try FileManager.default.createDirectory(at: contents.appending(path: "Helpers"), withIntermediateDirectories: true)
            try await clang(["-o", contents.appending(path: "Helpers/tinyhelper").path(percentEncoded: false),
                sources.appending(path: "helper.c").path(percentEncoded: false)])

            let plugin = contents.appending(path: "PlugIns/Thing.bundle/Contents", directoryHint: .isDirectory)
            try write(infoPlist(executable: "Thing", identifier: "com.upstream.thing", packageType: "BNDL"), to: plugin.appending(path: "Info.plist"))
            try write("int thing(void) { return 1; }\n", to: sources.appending(path: "thing.c"))
            try FileManager.default.createDirectory(at: plugin.appending(path: "MacOS"), withIntermediateDirectories: true)
            try await clang(["-bundle", "-o", plugin.appending(path: "MacOS/Thing").path(percentEncoded: false),
                sources.appending(path: "thing.c").path(percentEncoded: false)])
        } else {
            try write(mainSource(withLibraries: false), to: main)
            try await clang(["-o", executable, main.path(percentEncoded: false)])
        }

        // What an upstream download looks like: signed, with a profile, quarantined.
        try write("profile", to: contents.appending(path: "embedded.provisionprofile"))
        try await tool("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", app.path(percentEncoded: false)])
        try FileOperations.setExtendedAttribute(
            FileOperations.quarantineAttribute, Data("0081;00000000;Safari;".utf8), at: app)
        try FileOperations.setExtendedAttribute(
            FileOperations.quarantineAttribute, Data("0081;00000000;Safari;".utf8), at: URL(filePath: executable))
        try FileManager.default.removeItem(at: sources)
        return app
    }

    private static func mainSource(withLibraries: Bool) -> String {
        """
        #include <stdio.h>
        #include <stdlib.h>
        #include <fcntl.h>
        \(withLibraries ? "int tiny_answer(void); int tiny_framework_answer(void);" : "")
        int main(int argc, char **argv) {
            \(withLibraries ? #"printf("answer=%d framework=%d\n", tiny_answer(), tiny_framework_answer());"# : "")
            printf("HOME=%s\\n", getenv("HOME"));
            for (int i = 1; i < argc; i++) printf("arg=%s\\n", argv[i]);
            return 0;
        }
        """
    }
}

func entry(
    id: PortID = "tiny", bundleId: String = "dev.frontport.tests.packager", exceptions: [String] = [],
    buildAssets: BuildAssetsSpec? = nil
) -> CatalogEntry {
    CatalogEntry(
        id: id, name: "Tiny", kind: .recomp, game: "tiny-game", developer: "Tests", summary: "", description: "",
        source: URL(string: "https://example.com/tiny")!, bundleId: bundleId,
        releases: .githubRelease(GitHubReleaseSource(repo: "tests/tiny", asset: "*.zip")),
        codeSigning: CodeSigning(exceptions: exceptions), buildAssets: buildAssets)
}

/// The canonical path of an existing item, as the sandbox resolves it (`/var` is `/private/var`).
func canonicalPath(_ url: URL) -> String {
    guard let resolved = realpath(url.path(percentEncoded: false), nil) else { return url.path(percentEncoded: false) }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// The entitlements a signed item carries.
func entitlements(of url: URL) async throws -> [String: Any] {
    let log = FileManager.default.temporaryDirectory.appending(path: "ent-\(UUID().uuidString).plist")
    defer { try? FileManager.default.removeItem(at: log) }
    _ = try await ProcessRunner().run(
        URL(filePath: "/usr/bin/codesign"), arguments: ["-d", "--entitlements", "-", "--xml", url.path(percentEncoded: false)],
        stdout: .file(log), stderr: .discard)
    let data = try Data(contentsOf: log)
    if data.isEmpty { return [:] }
    return try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] ?? [:]
}

/// `codesign -dv` output: the signature's flags and identifier.
func signatureInfo(of url: URL) async throws -> String {
    try await tool("/usr/bin/codesign", ["-dv", url.path(percentEncoded: false)])
}

extension AppPaths {
    /// For a Packager that never reaches a Port's Data: the tests that use it package no Redirects.
    static let withoutData = AppPaths(
        root: FileManager.default.temporaryDirectory.appending(path: "FrontportPackagerTests-root", directoryHint: .isDirectory),
        containers: FileManager.default.temporaryDirectory.appending(
            path: "FrontportPackagerTests-Containers", directoryHint: .isDirectory))
}

extension Result where Failure == any Error {
    /// The outcome of async work, to look at once it's done.
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
