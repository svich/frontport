import Foundation
import Testing
@testable import FrontportCore

@Suite struct FileOperationsTests {
    @Test func clonesFileIndependently() throws {
        let tmp = try TemporaryDirectory()
        let source = try tmp.file("rom.z64", contents: "original")
        let copy = tmp.url.appending(path: "seeded.z64")

        let result = try FileOperations.clone(source, to: copy)
        #expect(result == .cloned)  // the temporary folder is on APFS
        #expect(try read(copy) == "original")

        try Data("changed".utf8).write(to: copy)
        #expect(try read(source) == "original")
    }

    @Test func clonesDirectoryTree() throws {
        let tmp = try TemporaryDirectory()
        _ = try tmp.file("Data/saves/one.sav", contents: "1")
        _ = try tmp.file("Data/settings.json", contents: "{}")
        try FileManager.default.createSymbolicLink(
            at: tmp.url.appending(path: "Data/link"), withDestinationURL: URL(filePath: "/etc/hosts"))
        let snapshot = tmp.url.appending(path: "Snapshot", directoryHint: .isDirectory)

        try FileOperations.clone(tmp.url.appending(path: "Data"), to: snapshot)

        #expect(try read(snapshot.appending(path: "saves/one.sav")) == "1")
        #expect(try read(snapshot.appending(path: "settings.json")) == "{}")
        let link = try FileManager.default.destinationOfSymbolicLink(atPath: snapshot.appending(path: "link").path(percentEncoded: false))
        #expect(link == "/etc/hosts")
    }

    @Test func removesUntrustedFolderWithoutFollowingLinks() throws {
        let tmp = try TemporaryDirectory()
        let outside = try tmp.file("outside/keep.txt", contents: "keep")
        _ = try tmp.file("Builds/port/src/file.c", contents: "int x;")
        _ = try tmp.file("Builds/port/locked/inner/file", contents: "x")
        let builds = tmp.url.appending(path: "Builds/port", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(
            at: builds.appending(path: "escape"), withDestinationURL: outside.deletingLastPathComponent())
        // Read-only and unreadable folders, as a Recipe may leave them.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: builds.appending(path: "locked/inner").path(percentEncoded: false))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: builds.appending(path: "locked").path(percentEncoded: false))
        let mode = try FileManager.default.attributesOfItem(atPath: tmp.url.appending(path: "outside").path(percentEncoded: false))[.posixPermissions]

        try FileOperations.removeUntrusted(builds)

        #expect(!FileOperations.exists(builds))
        #expect(try read(outside) == "keep")
        #expect(try FileManager.default.attributesOfItem(atPath: tmp.url.appending(path: "outside").path(percentEncoded: false))[.posixPermissions] as? Int == mode as? Int)
        try FileOperations.removeUntrusted(builds)  // absent is fine
    }

    @Test func cloneRefusesExistingDestination() throws {
        let tmp = try TemporaryDirectory()
        let source = try tmp.file("a", contents: "a")
        let destination = try tmp.file("b", contents: "b")
        #expect(throws: FrontportError.self) { try FileOperations.clone(source, to: destination) }
        #expect(try read(destination) == "b")
    }

    @Test func swapsDirectoriesAtomically() throws {
        let tmp = try TemporaryDirectory()
        let current = tmp.url.appending(path: "Port.app", directoryHint: .isDirectory)
        let staged = tmp.url.appending(path: "staging/Port.app", directoryHint: .isDirectory)
        _ = try tmp.file("Port.app/version", contents: "9.3.0")
        _ = try tmp.file("staging/Port.app/version", contents: "9.3.1")

        try FileOperations.swap(staged, current)

        #expect(try read(current.appending(path: "version")) == "9.3.1")
        #expect(try read(staged.appending(path: "version")) == "9.3.0")
    }

    @Test func swapFailsWhenOneSideIsMissing() throws {
        let tmp = try TemporaryDirectory()
        let existing = try tmp.file("a", contents: "a")
        #expect(throws: FrontportError.self) {
            try FileOperations.swap(existing, tmp.url.appending(path: "missing"))
        }
    }

    @Test func createsPrivateDirectories() throws {
        let tmp = try TemporaryDirectory()
        let data = tmp.url.appending(path: "Data", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        let seedFolder = data.appending(path: "Library/Application Support/soh", directoryHint: .isDirectory)

        try FileOperations.createDirectory(seedFolder)

        #expect(try mode(of: seedFolder) == 0o700)
        #expect(try mode(of: data.appending(path: "Library")) == 0o700)
        #expect(try mode(of: data.appending(path: "Library/Application Support")) == 0o700)
        #expect(try mode(of: data) == 0o755)  // existing folders are left alone

        try FileOperations.createDirectory(seedFolder)  // idempotent
    }

    @Test func removesQuarantineRecursively() throws {
        let tmp = try TemporaryDirectory()
        let app = tmp.url.appending(path: "Port.app", directoryHint: .isDirectory)
        let binary = try tmp.file("Port.app/Contents/MacOS/Port", contents: "binary")
        let library = try tmp.file("Port.app/Contents/Frameworks/libSDL3.dylib", contents: "dylib")
        let value = Data("0081;00000000;Safari;".utf8)
        for item in [app, binary, library] {
            try FileOperations.setExtendedAttribute(FileOperations.quarantineAttribute, value, at: item)
        }
        try FileOperations.setExtendedAttribute("com.example.keep", Data("x".utf8), at: binary)
        #expect(FileOperations.extendedAttribute(FileOperations.quarantineAttribute, at: binary) == value)

        try FileOperations.removeQuarantine(app)

        for item in [app, binary, library] {
            #expect(FileOperations.extendedAttribute(FileOperations.quarantineAttribute, at: item) == nil)
        }
        #expect(FileOperations.extendedAttribute("com.example.keep", at: binary) == Data("x".utf8))
        try FileOperations.removeQuarantine(app)  // nothing left to remove is fine
    }

    /// Build Assets may hold a read-only folder, which never had the attribute and can't have one removed.
    @Test func removingQuarantinePassesReadOnlyFoldersWithoutIt() throws {
        let tmp = try TemporaryDirectory()
        let assets = tmp.url.appending(path: "assets", directoryHint: .isDirectory)
        let file = try tmp.file("assets/read-only/file", contents: "data")
        let folder = file.deletingLastPathComponent()
        #expect(chmod(folder.path(percentEncoded: false), 0o555) == 0)
        defer { chmod(folder.path(percentEncoded: false), 0o755) }

        try FileOperations.removeQuarantine(assets)
        #expect(try mode(of: folder) == 0o555)
    }

    @Test func makesReadOnlyFilesWritableWithoutFollowingLinks() throws {
        let tmp = try TemporaryDirectory()
        let app = tmp.url.appending(path: "Port.app", directoryHint: .isDirectory)
        let library = try tmp.file("Port.app/Contents/Frameworks/libMoltenVK.dylib", contents: "dylib")
        let outside = try tmp.file("outside/secret", contents: "secret")
        let frameworks = library.deletingLastPathComponent()
        try FileManager.default.createSymbolicLink(
            at: frameworks.appending(path: "secret"), withDestinationURL: outside)
        try FileOperations.setExtendedAttribute(FileOperations.quarantineAttribute, Data("0081;0;Safari;".utf8), at: library)
        for (item, mode) in [(library, 0o444), (outside, 0o444), (frameworks, 0o555)] {
            #expect(chmod(item.path(percentEncoded: false), mode_t(mode)) == 0)
        }

        try FileOperations.makeWritable(app)
        try FileOperations.removeQuarantine(app)

        #expect(try mode(of: library) == 0o644)
        #expect(try mode(of: frameworks) == 0o755)
        #expect(try mode(of: outside) == 0o444)
        #expect(FileOperations.extendedAttribute(FileOperations.quarantineAttribute, at: library) == nil)
    }

    @Test func refusesLinksThatLeadOutOfAFolder() throws {
        let tmp = try TemporaryDirectory()
        let app = tmp.url.appending(path: "Port.app", directoryHint: .isDirectory)
        _ = try tmp.file("Port.app/Contents/Frameworks/Kit.framework/Versions/A/Kit", contents: "kit")
        _ = try tmp.file("outside/secret", contents: "secret")
        let fm = FileManager.default
        func link(_ path: String, _ destination: String) throws {
            try fm.createSymbolicLink(atPath: app.appending(path: path).path(percentEncoded: false), withDestinationPath: destination)
        }
        try link("Contents/Frameworks/Kit.framework/Versions/Current", "A")
        try link("Contents/Frameworks/Kit.framework/Kit", "Versions/Current/Kit")
        try link("Contents/Self", "..")
        try link("Contents/Frameworks/Root", "../..")
        try FileOperations.refuseEscapingLinks(in: app)  // links that stay inside are fine

        // Also refused by their text alone, though they resolve inside: an absolute link, and one that climbs out and
        // back, either of which a link on the way, such as one the Port controls, could have bounced back in.
        let inside = try #require(realpath(app.appending(path: "Contents/Frameworks").path(percentEncoded: false), nil))
        defer { free(inside) }
        for (path, destination) in [
            ("Contents/Escape", tmp.url.appending(path: "outside").path(percentEncoded: false)),
            ("Contents/Up", "../../outside/secret"),
            ("Contents/Dangling", "/nowhere/at/all"),
            ("Contents/Absolute", String(cString: inside)),
            ("Contents/Around", "../../Port.app/Contents/Frameworks"),
            // Or by following them, though their text alone stays inside: through Root, the app itself, and out.
            ("Contents/Chain", "Frameworks/Root/../Port.app/Contents/Frameworks"),
            ("Contents/Loop", "Loop"),
        ] {
            try link(path, destination)
            #expect(throws: FrontportError.self, "\(path)") { try FileOperations.refuseEscapingLinks(in: app) }
            try fm.removeItem(at: app.appending(path: path))
        }

        // A folder it can't read is refused, since the links in it can't be checked.
        let locked = app.appending(path: "Contents/Locked", directoryHint: .isDirectory)
        try fm.createDirectory(at: locked, withIntermediateDirectories: false)
        try link("Contents/Locked/Escape", "../../../outside/secret")
        #expect(chmod(locked.path(percentEncoded: false), 0) == 0)
        #expect(throws: FrontportError.self) { try FileOperations.refuseEscapingLinks(in: app) }
        #expect(chmod(locked.path(percentEncoded: false), 0o755) == 0)
        try fm.removeItem(at: locked)

        #expect(mkfifo(app.appending(path: "Contents/pipe").path(percentEncoded: false), 0o644) == 0)
        #expect(throws: FrontportError.self) { try FileOperations.refuseEscapingLinks(in: app) }
        try fm.removeItem(at: app.appending(path: "Contents/pipe"))

        let linkedApp = tmp.url.appending(path: "Linked.app")
        try fm.createSymbolicLink(at: linkedApp, withDestinationURL: app)
        #expect(throws: FrontportError.self) { try FileOperations.refuseEscapingLinks(in: linkedApp) }
        #expect(!FileOperations.isDirectory(linkedApp) && FileOperations.isDirectory(app))
        try FileOperations.refuseEscapingLinks(in: tmp.url.appending(path: "outside/secret"))  // a plain file
    }

    /// The one link out a caller may allow: at that path, with exactly that destination.
    @Test func allowsOnlyTheLinkItIsTold() throws {
        let tmp = try TemporaryDirectory()
        let app = tmp.url.appending(path: "Port.app", directoryHint: .isDirectory)
        _ = try tmp.file("Port.app/Contents/Resources/icon", contents: "icon")
        _ = try tmp.file("assets", contents: "assets")
        let fm = FileManager.default
        func link(_ path: String, _ destination: String) throws {
            try fm.createSymbolicLink(atPath: app.appending(path: path).path(percentEncoded: false), withDestinationPath: destination)
        }
        let allowed = ["Contents/Resources/game.o2r": "../../../assets"]
        try link("Contents/Resources/game.o2r", "../../../assets")

        try FileOperations.refuseEscapingLinks(in: app, allowing: allowed)
        #expect(throws: FrontportError.self, "allowed only when asked") { try FileOperations.refuseEscapingLinks(in: app) }
        #expect(throws: FrontportError.self, "another destination") {
            try FileOperations.refuseEscapingLinks(in: app, allowing: ["Contents/Resources/game.o2r": "../../../assets/"])
        }
        #expect(try PortLinks.assetsLink(in: app) == "Contents/Resources/game.o2r")
        try link("Contents/Resources/other.o2r", "../../../assets")
        #expect(throws: FrontportError.self, "the same destination elsewhere") {
            try FileOperations.refuseEscapingLinks(in: app, allowing: allowed)
        }
        #expect(throws: FrontportError.self, "two links to Build Assets") { try PortLinks.assetsLink(in: app) }
        try fm.removeItem(at: app.appending(path: "Contents/Resources/other.o2r"))
        // No link may lead through an allowed one, though it then leads where that one does.
        try link("Contents/Resources/through", "game.o2r")
        #expect(throws: FrontportError.self, "through the allowed link") {
            try FileOperations.refuseEscapingLinks(in: app, allowing: allowed)
        }
        try fm.removeItem(at: app.appending(path: "Contents/Resources/through"))
        try link("Contents/Resources/other.o2r", "../../../assets")
        #expect(try FileOperations.links(in: app) == allowed.merging(["Contents/Resources/other.o2r": "../../../assets"]) { a, _ in a })
        #expect(FileOperations.exists(app.appending(path: "Contents/Resources/other.o2r")))
        #expect(!FileOperations.isFileOrFolder(app.appending(path: "Contents/Resources/other.o2r")))
        #expect(FileOperations.isFileOrFolder(app.appending(path: "Contents/Resources/icon")) && FileOperations.isFileOrFolder(app))
    }

    @Test func opensOnlyRegularFilesAndNeverFollowsALink() throws {
        let tmp = try TemporaryDirectory()
        let victim = try tmp.file("victim", contents: "victim\n")
        let link = tmp.url.appending(path: "link.log")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: victim)
        let pipe = tmp.url.appending(path: "pipe")
        #expect(mkfifo(pipe.path(percentEncoded: false), 0o644) == 0)

        #expect(throws: FrontportError.self) { try FileOperations.openForAppending(link) }
        #expect(throws: FrontportError.self) { try FileOperations.readRegularFile(link) }
        #expect(throws: FrontportError.self) { try FileOperations.openForAppending(pipe) }
        #expect(throws: FrontportError.self) { try FileOperations.readRegularFile(pipe) }
        #expect(try read(victim) == "victim\n")

        let log = tmp.url.appending(path: "build.log")
        for line in ["one\n", "two\n"] {
            let handle = try FileOperations.openForAppending(log)
            try handle.write(contentsOf: Data(line.utf8))
            try handle.close()
        }
        #expect(try FileOperations.readRegularFile(log) == Data("one\ntwo\n".utf8))
    }

    @Test func measuresDirectorySize() throws {
        let tmp = try TemporaryDirectory()
        _ = try tmp.file("Data/a", contents: String(repeating: "a", count: 1000))
        _ = try tmp.file("Data/nested/b", contents: String(repeating: "b", count: 24))
        try FileManager.default.createSymbolicLink(
            at: tmp.url.appending(path: "Data/link"), withDestinationURL: URL(filePath: "/bin/zsh"))

        #expect(try FileOperations.size(of: tmp.url.appending(path: "Data")) == 1024)
        #expect(try FileOperations.size(of: tmp.url.appending(path: "Data/nested/b")) == 24)
    }

    /// A file cloned elsewhere, such as an extracted game cloned into Build Assets, frees nothing when its folder goes.
    @Test func measuresWhatRemovingAFolderFrees() throws {
        let tmp = try TemporaryDirectory()
        let game = try tmp.file("Build/game", contents: String(repeating: "g", count: 1 << 20))
        _ = try tmp.file("Build/nested/own", contents: String(repeating: "o", count: 1 << 20))
        try FileManager.default.createSymbolicLink(
            at: tmp.url.appending(path: "Build/link"), withDestinationURL: URL(filePath: "/bin/zsh"))
        try FileOperations.createDirectory(tmp.url.appending(path: "Assets"))
        #expect(try FileOperations.clone(game, to: tmp.url.appending(path: "Assets/game")) == .cloned)

        let usage = try FileOperations.usage(of: tmp.url.appending(path: "Build"))

        #expect(usage == FileOperations.DiskUsage(allocated: 2 << 20, unshared: 1 << 20))
        #expect(try FileOperations.usage(of: game) == FileOperations.DiskUsage(allocated: 1 << 20, unshared: 0))
        #expect(throws: (any Error).self) { try FileOperations.usage(of: tmp.url.appending(path: "Missing")) }
    }
}
