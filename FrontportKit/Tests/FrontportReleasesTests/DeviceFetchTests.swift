import Foundation
import FrontportCore
import Testing

@testable import FrontportReleases

/// A Port's iOS version arrives as an `.ipa`, a zip with one app in `Payload/`, or as a zip holding one.
@Suite struct DeviceFetchTests {
    /// A flat iOS-style app in `folder`: Info.plist and executable at its top.
    @discardableResult
    static func iosApp(_ name: String, in folder: URL) throws -> URL {
        let app = folder.appending(path: "\(name).app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("<plist><dict><key>CFBundleExecutable</key><string>\(name)</string></dict></plist>".utf8)
            .write(to: app.appending(path: "Info.plist"))
        try Data("executable \(name)".utf8).write(to: app.appending(path: name))
        return app
    }

    /// An `.ipa` of the apps named, each in `Payload/`.
    static func ipa(_ names: [String], named file: String = "Fake.ipa", in temp: TemporaryDirectory) async throws -> URL {
        let payload = try temp.folder("ipa-\(UUID().uuidString)").appending(path: "Payload", directoryHint: .isDirectory)
        for name in names { try iosApp(name, in: payload) }
        let ipa = try temp.folder("archives").appending(path: file)
        try await shell("/usr/bin/ditto", ["-c", "-k", "--keepParent", path(payload), path(ipa)])
        return ipa
    }

    static func unpack(_ archive: URL, in temp: TemporaryDirectory) async throws -> URL {
        try await Unpacker(runner: ProcessRunner(), progress: { _ in }).app(in: archive, work: try temp.folder("work"))
    }

    @Test func recognizesAnIPAAsAZip() {
        #expect(ArchiveFormat(name: "fallout-ce-ios.ipa") == .zip)
        #expect(ArchiveFormat(name: "Ghostship-unsigned.IPA") == .zip)
    }

    @Test func unpacksTheAppInAnIPA() async throws {
        let temp = try TemporaryDirectory()
        let ipa = try await Self.ipa(["fallout-ce"], named: "fallout-ce-ios.ipa", in: temp)

        let app = try await Self.unpack(ipa, in: temp)

        #expect(app.lastPathComponent == "fallout-ce.app")
        #expect(app.deletingLastPathComponent().lastPathComponent == "Payload")
        #expect(try String(contentsOf: app.appending(path: "fallout-ce"), encoding: .utf8) == "executable fallout-ce")
    }

    /// As Ghostship ships it: a zip holding the `.ipa` and a text file, which is ignored.
    @Test func unpacksAnIPAInsideAZip() async throws {
        let temp = try TemporaryDirectory()
        let ipa = try await Self.ipa(["Ghostship"], named: "Ghostship-unsigned.ipa", in: temp)
        let folder = try temp.folder("release")
        try FileManager.default.moveItem(at: ipa, to: folder.appending(path: ipa.lastPathComponent))
        try Data("Drop your ROM in Files.".utf8).write(to: folder.appending(path: "SIDELOADING.txt"))
        let zip = try temp.folder("archives").appending(path: "Nautilus-Alfa-iOS.zip")
        try await shell("/usr/bin/ditto", ["-c", "-k", path(folder), path(zip)])

        let app = try await Self.unpack(zip, in: temp)

        #expect(app.lastPathComponent == "Ghostship.app")
        #expect(exists(app.appending(path: "Ghostship")))
    }

    @Test func refusesAnIPAWithTwoApps() async throws {
        let temp = try TemporaryDirectory()
        let ipa = try await Self.ipa(["One", "Two"], in: temp)

        await #expect(throws: FrontportError.extractionFailed("Fake.ipa holds more than one app: One.app, Two.app.")) {
            try await Self.unpack(ipa, in: temp)
        }
    }

    /// The iOS version's archive goes in its own folder, so sweeping the Mac's leftovers never takes it mid-download,
    /// and the Mac's call still downloads into the Port's.
    @Test func downloadsIntoTheFolderItIsGiven() async throws {
        let temp = try TemporaryDirectory()
        let ipa = try await Self.ipa(["fallout-ce"], named: "fallout-ce-ios.ipa", in: temp)
        let data = try Data(contentsOf: ipa)
        let (host, requests) = StubURLProtocol.host { _ in StubResponse(body: data) }
        let release = Release(
            port: "fallout-ce", version: "1.1.0",
            asset: ReleaseAsset(
                name: ipa.lastPathComponent, url: URL(string: "https://\(host)/download/\(ipa.lastPathComponent)")!,
                size: Int64(data.count), sha256: Hashing.sha256(data)))
        let paths = temp.paths
        let fetcher = AssetFetcher(paths: paths, session: StubURLProtocol.session())
        let workspace = PortID("fallout-ce").deviceWorkspace

        let app = try await fetcher.fetch(
            release, into: try temp.folder("device-staging"), downloads: workspace, progress: { _ in })

        #expect(app.lastPathComponent == "fallout-ce.app")
        #expect(exists(paths.downloads(for: workspace).appending(path: "fallout-ce-ios.ipa")))
        #expect(!exists(paths.downloads(for: "fallout-ce")))

        // Cached by its digest in that folder: no second download.
        _ = try await fetcher.fetch(release, into: try temp.folder("device-staging"), downloads: workspace, progress: { _ in })
        #expect(requests.count == 1)

        _ = try await fetcher.fetch(release, into: try temp.folder("mac-staging"), progress: { _ in })
        #expect(exists(paths.download(release.asset!, for: "fallout-ce")))
        #expect(requests.count == 2)
    }
}
