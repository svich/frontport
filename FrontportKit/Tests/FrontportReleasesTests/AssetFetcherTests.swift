import Foundation
import FrontportCore
import Testing

@testable import FrontportReleases

/// Archives built at test time around a tiny fake app.
enum Fixture {
    /// A minimal app bundle in `folder`, optionally with a quarantined executable.
    @discardableResult
    static func app(_ name: String = "Fake", in folder: URL, quarantined: Bool = false, payload: Int = 0) throws -> URL {
        let app = folder.appending(path: "\(name).app", directoryHint: .isDirectory)
        let macOS = app.appending(path: "Contents/MacOS", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try Data("<plist><dict><key>CFBundleExecutable</key><string>\(name)</string></dict></plist>".utf8)
            .write(to: app.appending(path: "Contents/Info.plist"))
        let executable = macOS.appending(path: name)
        try Data("#!/bin/sh\necho \(name)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path(executable))
        if payload > 0 {
            // Random, so the archive is as large as the payload.
            var generator = SystemRandomNumberGenerator()
            let bytes = (0..<payload).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
            try Data(bytes).write(to: app.appending(path: "Contents/payload.bin"))
        }
        if quarantined {
            try FileOperations.setExtendedAttribute(
                FileOperations.quarantineAttribute, Data("0083;00000000;Safari;".utf8), at: executable)
        }
        return app
    }

    /// Zips a file or folder the way upstream Mac builds are, extended attributes included.
    static func zip(_ item: URL, to archive: URL) async throws {
        try await shell("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", path(item), path(archive)])
    }

    static func tarGz(_ item: URL, to archive: URL) async throws {
        try await shell(
            "/usr/bin/tar", ["-czf", path(archive), "-C", path(item.deletingLastPathComponent()), item.lastPathComponent])
    }

    /// A compressed disk image of `folder`'s contents.
    static func dmg(_ folder: URL, to image: URL) async throws {
        try await shell("/usr/bin/hdiutil", [
            "create", "-quiet", "-format", "UDZO", "-volname", "Fake", "-srcfolder", path(folder), path(image),
        ])
    }

    /// A disk image laid out like upstream ones: the app and a link to /Applications.
    static func diskImage(in temp: TemporaryDirectory, named name: String = "Fake.dmg") async throws -> URL {
        let folder = try temp.folder("image")
        try app(in: folder)
        try FileManager.default.createSymbolicLink(
            at: folder.appending(path: "Applications"), withDestinationURL: URL(filePath: "/Applications"))
        let image = try temp.folder("archives").appending(path: name)
        try await dmg(folder, to: image)
        return image
    }

    /// `diskImage` with a license agreement, as Ghostship ships: hdiutil won't attach it without consent.
    static func licensedDiskImage(in temp: TemporaryDirectory) async throws -> URL {
        let image = try await diskImage(in: temp, named: "Licensed.dmg")
        func pascal(_ text: String) -> Data { Data([UInt8(text.utf8.count)]) + Data(text.utf8) }
        let strings = ["English", "Agree", "Disagree", "Print", "Save…", "Agree to use this test image.", "License",
                       "Can’t save.", "Can’t print."]
        let lpic: [UInt8] = [0, 0, 0, 1, 0, 0, 0, 2, 0, 0]  // default language 0, one entry: region 0 → 5002
        func resource(_ id: String, _ name: String, _ data: Data) -> [[String: Any]] {
            [["Attributes": "0x0000", "ID": id, "Name": name, "Data": data]]
        }
        let resources: [String: Any] = [
            "LPic": resource("5000", "", Data(lpic)),
            "STR#": resource("5002", "English", Data([0, UInt8(strings.count)]) + strings.map(pascal).reduce(Data(), +)),
            "TEXT": resource("5002", "English", Data("A test license.".utf8)),
        ]
        let plist = try temp.folder("license").appending(path: "license.plist")
        try PropertyListSerialization.data(fromPropertyList: resources, format: .xml, options: 0).write(to: plist)
        try await shell("/usr/bin/hdiutil", ["udifrez", "-quiet", "-xml", path(plist), "", path(image)])
        return image
    }
}

private enum Digest { case correct, missing, wrong }

/// A Fetcher whose AppPaths live in `temp`, and a Release whose asset the stub serves.
private struct Served {
    let fetcher: AssetFetcher
    let release: Release
    let requests: RequestLog
    let paths: AppPaths
    /// Where the app should end up: the Library's staging folder.
    let destination: URL

    var cachedDownload: URL { paths.download(release.asset!, for: release.port) }

    init(
        _ archive: URL, in temp: TemporaryDirectory, digest: Digest = .correct, status: Int = 200,
        chunkSize: Int? = nil, chunkDelay: TimeInterval = 0, stalls: Bool = false
    ) throws {
        let data = try Data(contentsOf: archive)
        let (host, requests) = StubURLProtocol.host { _ in
            // As GitHub's download host answers.
            StubResponse(
                status: status, headers: ["Content-Type": "application/octet-stream"], body: data, chunkSize: chunkSize,
                chunkDelay: chunkDelay, stalls: stalls)
        }
        let sha256: String? = switch digest {
        case .correct: Hashing.sha256(data)
        case .missing: nil
        case .wrong: String(repeating: "0", count: 64)
        }
        let name = archive.lastPathComponent
        release = Release(
            port: "shipwright", version: "9.3.1",
            asset: ReleaseAsset(
                name: name, url: URL(string: "https://\(host)/download/9.3.1/\(name)")!, size: Int64(data.count),
                sha256: sha256))
        self.requests = requests
        paths = temp.paths
        destination = paths.staging(for: "shipwright")
        fetcher = AssetFetcher(paths: paths, session: StubURLProtocol.session())
    }

    func fetch(_ progress: ProgressLog = ProgressLog()) async throws -> URL {
        try await fetcher.fetch(release, into: destination, progress: progress.handler)
    }
}

/// Checks the fake app arrived whole, unquarantined, directly in `folder`.
private func expectFakeApp(_ app: URL, in folder: URL, sourceLocation: SourceLocation = #_sourceLocation) throws {
    #expect(app.lastPathComponent == "Fake.app", sourceLocation: sourceLocation)
    #expect(path(app.deletingLastPathComponent()) == path(folder), sourceLocation: sourceLocation)
    let executable = app.appending(path: "Contents/MacOS/Fake")
    #expect(try String(contentsOf: executable, encoding: .utf8) == "#!/bin/sh\necho Fake\n", sourceLocation: sourceLocation)
    #expect(FileManager.default.isExecutableFile(atPath: path(executable)), sourceLocation: sourceLocation)
    #expect(
        FileOperations.extendedAttribute(FileOperations.quarantineAttribute, at: executable) == nil,
        sourceLocation: sourceLocation)
}

private func expectNoPartialDownloads(_ served: Served, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let folder = served.cachedDownload.deletingLastPathComponent()
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: path(folder))) ?? []
    #expect(leftovers.filter { $0.hasSuffix(".part") }.isEmpty, sourceLocation: sourceLocation)
}

/// Paths of disk images currently attached.
private func attachedImages() async throws -> [String] {
    let info = try await ProcessRunner().run(URL(filePath: "/usr/bin/hdiutil"), arguments: ["info", "-plist"], stderr: .discard)
    let data = info.stdout
    guard let start = data.firstRange(of: Data("<?xml".utf8)),
        let plist = try PropertyListSerialization.propertyList(from: data[start.lowerBound...], format: nil) as? [String: Any],
        let images = plist["images"] as? [[String: Any]]
    else { return [] }
    return images.compactMap { $0["image-path"] as? String }
}

@Suite struct AssetFetcherTests {
    // MARK: Archive shapes

    @Test func unpacksAZip() async throws {
        let temp = try TemporaryDirectory()
        let app = try Fixture.app(in: try temp.folder("source"), quarantined: true)
        let zip = try temp.folder("archives").appending(path: "SoH-Dewey-Bravo-Mac.zip")
        try await Fixture.zip(app, to: zip)

        // Plain extraction keeps the quarantine flag, so the Fetcher has to strip it.
        let plain = try temp.folder("plain")
        try await shell("/usr/bin/ditto", ["-x", "-k", path(zip), path(plain)])
        #expect(FileOperations.extendedAttribute(
            FileOperations.quarantineAttribute, at: plain.appending(path: "Fake.app/Contents/MacOS/Fake")) != nil)

        let served = try Served(zip, in: temp)
        let result = try await served.fetch()

        try expectFakeApp(result, in: served.destination)
        #expect(try Hashing.sha256(file: served.cachedDownload) == served.release.asset?.sha256)
        try expectNoPartialDownloads(served)
        #expect(served.requests.count == 1)
    }

    @Test func unquarantinesReadOnlyFiles() async throws {
        let temp = try TemporaryDirectory()
        let app = try Fixture.app(in: try temp.folder("source"), quarantined: true)
        let executable = app.appending(path: "Contents/MacOS/Fake")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: path(executable))
        let zip = try temp.folder("archives").appending(path: "SoH-Dewey-Bravo-Mac.zip")
        try await Fixture.zip(app, to: zip)

        let served = try Served(zip, in: temp)
        let result = try await served.fetch()

        try expectFakeApp(result, in: served.destination)
        #expect(FileManager.default.isWritableFile(atPath: path(result.appending(path: "Contents/MacOS/Fake"))))
    }

    @Test func unpacksAZipInsideAZip() async throws {
        let temp = try TemporaryDirectory()
        let app = try Fixture.app(in: try temp.folder("source"))
        let archives = try temp.folder("archives")
        let inner = try temp.folder("inner").appending(path: "Fake-inner.zip")
        try await Fixture.zip(app, to: inner)
        let outer = archives.appending(path: "Fake-outer.zip")
        try await Fixture.zip(inner, to: outer)

        let served = try Served(outer, in: temp)
        try expectFakeApp(try await served.fetch(), in: served.destination)
    }

    @Test func unpacksATarball() async throws {
        let temp = try TemporaryDirectory()
        let app = try Fixture.app(in: try temp.folder("source"))
        let tarball = try temp.folder("archives").appending(path: "Fake-macOS.tar.gz")
        try await Fixture.tarGz(app, to: tarball)

        let served = try Served(tarball, in: temp)
        try expectFakeApp(try await served.fetch(), in: served.destination)
    }

    @Test func findsTheAppInsideAFolder() async throws {
        let temp = try TemporaryDirectory()
        let folder = try temp.folder("source/Fake-1.0-macOS")
        try Fixture.app(in: folder)
        try Data("Read me".utf8).write(to: folder.appending(path: "README.txt"))
        let zip = try temp.folder("archives").appending(path: "Fake-1.0-macOS.zip")
        try await Fixture.zip(folder, to: zip)

        let served = try Served(zip, in: temp)
        try expectFakeApp(try await served.fetch(), in: served.destination)
    }

    @Test func replacesAnAppAlreadyThere() async throws {
        let temp = try TemporaryDirectory()
        let app = try Fixture.app(in: try temp.folder("source"))
        let zip = try temp.folder("archives").appending(path: "Fake.zip")
        try await Fixture.zip(app, to: zip)
        let served = try Served(zip, in: temp)
        let stale = served.destination.appending(path: "Fake.app/stale.txt")
        try FileManager.default.createDirectory(at: stale.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: stale)

        try expectFakeApp(try await served.fetch(), in: served.destination)
        #expect(!exists(stale))
    }

    @Test func archiveWithoutAnAppFails() async throws {
        let temp = try TemporaryDirectory()
        let folder = try temp.folder("source/NoApp")
        try Data("nothing".utf8).write(to: folder.appending(path: "README.txt"))
        let zip = try temp.folder("archives").appending(path: "NoApp.zip")
        try await Fixture.zip(folder, to: zip)

        let served = try Served(zip, in: temp)
        await #expect(throws: FrontportError.appNotFound("NoApp.zip")) { try await served.fetch() }
    }

    @Test func archiveWithTwoAppsFails() async throws {
        let temp = try TemporaryDirectory()
        let folder = try temp.folder("source/Two")
        try Fixture.app("Fake", in: folder)
        try Fixture.app("Uninstaller", in: folder)
        let zip = try temp.folder("archives").appending(path: "Two.zip")
        try await Fixture.zip(folder, to: zip)

        let served = try Served(zip, in: temp)
        await #expect {
            try await served.fetch()
        } throws: { error in
            guard case .extractionFailed(let detail) = error as? FrontportError else { return false }
            return detail.contains("Fake.app") && detail.contains("Uninstaller.app")
        }
        #expect(!exists(served.destination.appending(path: "Fake.app")))
    }

    /// An app whose `Contents` links to another app's must never reach the Packager.
    @Test func refusesAnAppHoldingALinkThatLeadsOutOfIt() async throws {
        let temp = try TemporaryDirectory()
        let victim = try temp.folder("victim/Contents")
        try Data("<plist/>".utf8).write(to: victim.appending(path: "Info.plist"))
        let evil = try temp.folder("source/Evil.app")
        try FileManager.default.createSymbolicLink(at: evil.appending(path: "Contents"), withDestinationURL: victim)
        let zip = try temp.folder("archives").appending(path: "Evil.zip")
        try await Fixture.zip(evil, to: zip)

        let served = try Served(zip, in: temp)
        await #expect(throws: FrontportError.self) { try await served.fetch() }
        #expect(!exists(served.destination.appending(path: "Evil.app")))
    }

    @Test func unknownFormatFails() async throws {
        let temp = try TemporaryDirectory()
        let file = try temp.folder("archives").appending(path: "Fake.pkg")
        try Data("xar!".utf8).write(to: file)

        let served = try Served(file, in: temp)
        await #expect {
            try await served.fetch()
        } throws: { error in
            guard case .extractionFailed = error as? FrontportError else { return false }
            return true
        }
    }

    // MARK: Digests and the download cache

    @Test func missingDigestDownloadsNothing() async throws {
        let temp = try TemporaryDirectory()
        let zip = try temp.folder("archives").appending(path: "Fake.zip")
        try await Fixture.zip(try Fixture.app(in: try temp.folder("source")), to: zip)

        let served = try Served(zip, in: temp, digest: .missing)
        await #expect(throws: FrontportError.digestMissing(asset: "Fake.zip")) { try await served.fetch() }
        #expect(served.requests.count == 0)
        #expect(!exists(served.destination.appending(path: "Fake.app")))
    }

    @Test func digestMismatchKeepsNothing() async throws {
        let temp = try TemporaryDirectory()
        let zip = try temp.folder("archives").appending(path: "Fake.zip")
        try await Fixture.zip(try Fixture.app(in: try temp.folder("source")), to: zip)

        let served = try Served(zip, in: temp, digest: .wrong)
        await #expect(throws: FrontportError.digestMismatch(
            asset: "Fake.zip", expected: String(repeating: "0", count: 64), actual: try Hashing.sha256(file: zip)
        )) {
            try await served.fetch()
        }
        #expect(!exists(served.cachedDownload))
        try expectNoPartialDownloads(served)
        #expect(!exists(served.destination.appending(path: "Fake.app")))
    }

    @Test func reusesAVerifiedDownload() async throws {
        let temp = try TemporaryDirectory()
        let zip = try temp.folder("archives").appending(path: "Fake.zip")
        try await Fixture.zip(try Fixture.app(in: try temp.folder("source")), to: zip)
        let served = try Served(zip, in: temp)
        try FileManager.default.createDirectory(
            at: served.cachedDownload.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: zip, to: served.cachedDownload)

        try expectFakeApp(try await served.fetch(), in: served.destination)
        #expect(served.requests.count == 0)
    }

    @Test func replacesACachedDownloadThatDoesNotMatch() async throws {
        let temp = try TemporaryDirectory()
        let zip = try temp.folder("archives").appending(path: "Fake.zip")
        try await Fixture.zip(try Fixture.app(in: try temp.folder("source")), to: zip)
        let served = try Served(zip, in: temp)
        try FileManager.default.createDirectory(
            at: served.cachedDownload.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("truncated".utf8).write(to: served.cachedDownload)

        try expectFakeApp(try await served.fetch(), in: served.destination)
        #expect(served.requests.count == 1)
        #expect(try Data(contentsOf: served.cachedDownload) == Data(contentsOf: zip))
    }

    @Test func httpErrorsFail() async throws {
        let temp = try TemporaryDirectory()
        let zip = try temp.folder("archives").appending(path: "Fake.zip")
        try await Fixture.zip(try Fixture.app(in: try temp.folder("source")), to: zip)

        let served = try Served(zip, in: temp, status: 404)
        await #expect {
            try await served.fetch()
        } throws: { error in
            guard case .network(let detail) = error as? FrontportError else { return false }
            return detail.contains("404")
        }
        #expect(!exists(served.cachedDownload))
        try expectNoPartialDownloads(served)
    }

    @Test func sourceBuiltReleasesHaveNothingToFetch() async throws {
        let temp = try TemporaryDirectory()
        let fetcher = AssetFetcher(paths: temp.paths, session: StubURLProtocol.session())
        let release = Release(port: "starship", version: "2.0.0", tag: "v2.0.0")
        await #expect {
            try await fetcher.fetch(release, into: temp.url, progress: { _ in })
        } throws: { error in
            guard case .assetNotFound = error as? FrontportError else { return false }
            return true
        }
    }

    // MARK: Progress and cancellation

    @Test func reportsByteProgress() async throws {
        let temp = try TemporaryDirectory()
        let zip = try temp.folder("archives").appending(path: "Fake.zip")
        try await Fixture.zip(try Fixture.app(in: try temp.folder("source"), payload: 256 << 10), to: zip)
        let served = try Served(zip, in: temp, chunkSize: 16 << 10, chunkDelay: 0.005)
        let progress = ProgressLog()

        _ = try await served.fetch(progress)

        let updates = progress.all
        let fractions = updates.filter { $0.phase == .downloading }.compactMap(\.fraction)
        #expect(fractions.count > 2)
        #expect(fractions == fractions.sorted())
        #expect(fractions.last == 1)
        let phases = updates.map(\.phase).reduce(into: [ProgressUpdate.Phase]()) { if $0.last != $1 { $0.append($1) } }
        #expect(phases == [.downloading, .verifying, .extracting])
    }

    @Test func cancellingStopsTheDownload() async throws {
        let temp = try TemporaryDirectory()
        let zip = try temp.folder("archives").appending(path: "Fake.zip")
        try await Fixture.zip(try Fixture.app(in: try temp.folder("source"), payload: 64 << 10), to: zip)
        let served = try Served(zip, in: temp, chunkSize: 16 << 10, stalls: true)
        let canceller = Canceller<URL>()

        let task = Task {
            try await served.fetcher.fetch(served.release, into: served.destination) { update in
                if update.phase == .downloading, (update.fraction ?? 0) > 0 { canceller.cancel() }
            }
        }
        canceller.attach(task)

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!exists(served.cachedDownload))
        try expectNoPartialDownloads(served)
    }

    // MARK: Units

    @Test(arguments: [
        ("SoH-Dewey-Bravo-Mac.zip", ArchiveFormat.zip), ("Game.DMG", .dmg), ("x.tar", .tar), ("x.tar.gz", .tar),
        ("x.tgz", .tar), ("x.tar.xz", .tar), ("x.tar.bz2", .tar),
    ])
    func recognizesArchives(_ name: String, _ format: ArchiveFormat) {
        #expect(ArchiveFormat(name: name) == format)
    }

    @Test func ignoresOtherFiles() {
        for name in ["Fake.pkg", "Fake.app", "README.md", "Fake.appimage", "zip"] {
            #expect(ArchiveFormat(name: name) == nil)
        }
    }
}

/// Everything that attaches disk images, one test at a time: on macOS 27, overlapping hdiutil runs sometimes leave a
/// new image attached (unmounted) after `create`, or fail `create` or `udifrez` outright.
@Suite(.serialized) struct DiskImageTests {
    @Test func unpacksADiskImage() async throws {
        let temp = try TemporaryDirectory()
        let image = try await Fixture.diskImage(in: temp)

        let served = try Served(image, in: temp)
        try expectFakeApp(try await served.fetch(), in: served.destination)
        // The `Applications` link isn't followed and the image is detached afterwards.
        #expect(try await attachedImages().allSatisfy { !$0.contains(temp.url.lastPathComponent) })
    }

    @Test func unpacksADiskImageWithALicenseAgreement() async throws {
        let temp = try TemporaryDirectory()
        let image = try await Fixture.licensedDiskImage(in: temp)
        let info = try await ProcessRunner().run(URL(filePath: "/usr/bin/hdiutil"), arguments: ["imageinfo", "-plist", path(image)])
        try #require(Unpacker.hasLicenseAgreement(imageInfoOutput: info.stdout))

        let served = try Served(image, in: temp)
        let progress = ProgressLog()
        try expectFakeApp(try await served.fetch(progress), in: served.destination)
        #expect(progress.all.contains { $0.message == "Converting Licensed.dmg" })
        #expect(try await attachedImages().allSatisfy { !$0.contains(temp.url.lastPathComponent) && !$0.hasSuffix(".cdr") })
    }

    @Test func unpacksADiskImageInsideAZip() async throws {
        let temp = try TemporaryDirectory()
        let image = try await Fixture.diskImage(in: temp, named: "Fake-Mac.dmg")
        let zip = try temp.folder("archives").appending(path: "Fake-Mac.zip")
        try await Fixture.zip(image, to: zip)

        let served = try Served(zip, in: temp)
        try expectFakeApp(try await served.fetch(), in: served.destination)
        #expect(try await attachedImages().allSatisfy { !$0.contains(temp.url.lastPathComponent) })
    }

    @Test func cancellingDetachesTheDiskImage() async throws {
        let temp = try TemporaryDirectory()
        let image = try await Fixture.diskImage(in: temp)
        let served = try Served(image, in: temp)
        let canceller = Canceller<URL>()

        // Cancel once the image is attached, before the app is copied out.
        let task = Task {
            try await served.fetcher.fetch(served.release, into: served.destination) { update in
                if update.message?.hasPrefix("Copying from") == true { canceller.cancel() }
            }
        }
        canceller.attach(task)

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await attachedImages().allSatisfy { !$0.contains(temp.url.lastPathComponent) })
        #expect(!exists(served.destination.appending(path: "Fake.app")))
    }
}
