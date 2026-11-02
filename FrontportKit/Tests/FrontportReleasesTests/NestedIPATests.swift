import Foundation
import FrontportCore
import Testing

@testable import FrontportReleases

/// A Mac Release may carry its iOS version beside the Mac app's own archive: the `.ipa` is opened only when nothing
/// else holds an app, so the Mac still finds its app alone.
@Suite struct NestedIPATests {
    @Test func aMacArchiveBesideAnIPAYieldsTheMacAppAlone() async throws {
        let temp = try TemporaryDirectory()
        let bundle = try temp.folder("bundle")
        let macApp = try Fixture.app("Fake", in: try temp.folder("mac"))
        try await Fixture.zip(macApp, to: bundle.appending(path: "Fake-macOS.zip"))
        let ipa = try await DeviceFetchTests.ipa(["Fake"], named: "Fake-iOS.ipa", in: temp)
        try FileManager.default.moveItem(at: ipa, to: bundle.appending(path: ipa.lastPathComponent))
        let release = try temp.folder("archives").appending(path: "Fake-all.zip")
        try await shell("/usr/bin/ditto", ["-c", "-k", path(bundle), path(release)])

        let app = try await DeviceFetchTests.unpack(release, in: temp)

        #expect(app.lastPathComponent == "Fake.app")
        #expect(exists(app.appending(path: "Contents/MacOS/Fake")))
    }

    /// With no other archive holding an app, the `.ipa`'s is the one.
    @Test func anIPABesideAnArchiveWithoutAnAppIsOpened() async throws {
        let temp = try TemporaryDirectory()
        let bundle = try temp.folder("bundle")
        let notes = try temp.folder("notes")
        try Data("read me".utf8).write(to: notes.appending(path: "README.txt"))
        try await Fixture.zip(notes, to: bundle.appending(path: "notes.zip"))
        let ipa = try await DeviceFetchTests.ipa(["Ghostship"], named: "Ghostship-unsigned.ipa", in: temp)
        try FileManager.default.moveItem(at: ipa, to: bundle.appending(path: ipa.lastPathComponent))
        let release = try temp.folder("archives").appending(path: "Nautilus-Alfa-iOS.zip")
        try await shell("/usr/bin/ditto", ["-c", "-k", path(bundle), path(release)])

        let app = try await DeviceFetchTests.unpack(release, in: temp)

        #expect(app.lastPathComponent == "Ghostship.app")
        #expect(exists(app.appending(path: "Ghostship")))
    }
}
