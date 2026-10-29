import Foundation
import FrontportCore
import Testing
@testable import FrontportBuilder

/// The build sandbox may write anywhere in `Builds/<port>/`, and Frontport runs unsandboxed: nothing Frontport
/// reads or writes there may follow a link a Recipe planted.
@Suite struct BuildsFolderTests {
    func workspace(in temp: TemporaryDirectory) throws -> Workspace {
        let paths = AppPaths(root: try temp.folder("Frontport"), containers: try temp.folder("Containers"))
        let workspace = try Workspace(paths: paths, port: "testport")
        try workspace.prepare(ref: "v1", recipeSHA256: "0")
        return workspace
    }

    func isFolder(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.type] as? FileAttributeType)
            == .typeDirectory
    }

    @Test func theLogNeverFollowsALink() throws {
        let temp = try TemporaryDirectory()
        let victim = try temp.file("victim_rc", contents: "# victim\n")
        let log = temp.url.appending(path: "build.log")
        try FileManager.default.createSymbolicLink(at: log, withDestinationURL: victim)

        #expect(throws: FrontportError.self) { try BuildOutput(log: log, phase: .building) { _ in } }
        #expect(try read(victim) == "# victim\n")
    }

    @Test func restartingTheLogRemovesALinkNotWhatItLeadsTo() throws {
        let temp = try TemporaryDirectory()
        let victim = try temp.file("victim_rc", contents: "# victim\n")
        let log = temp.url.appending(path: "build.log")
        try FileManager.default.createSymbolicLink(at: log, withDestinationURL: victim)

        try BuildOutput.restart(log)
        try BuildOutput.restart(log)

        #expect(!FileOperations.exists(log))
        #expect(try read(victim) == "# victim\n")
    }

    @Test func aStateFileThatIsALinkCountsAsMissing() throws {
        let temp = try TemporaryDirectory()
        let workspace = try workspace(in: temp)
        try workspace.markFetched()
        try Data("fetched\n".utf8).write(to: workspace.source.appending(path: "tree"))
        // The build step swaps state.json for a link to a file elsewhere that says the source is fetched.
        let state = workspace.root.appending(path: "state.json")
        let elsewhere = try temp.file("elsewhere.json", contents: try read(state))
        try FileManager.default.removeItem(at: state)
        try FileManager.default.createSymbolicLink(at: state, withDestinationURL: elsewhere)

        try workspace.prepare(ref: "v1", recipeSHA256: "0")

        #expect(!workspace.isFetched)
        #expect(!exists(workspace.source.appending(path: "tree")), "the source tree is fetched again")
        #expect(try read(elsewhere).contains("true"))
    }

    @Test func foldersSwappedForLinksComeBackAsFolders() throws {
        let temp = try TemporaryDirectory()
        let workspace = try workspace(in: temp)
        try workspace.markFetched()
        let outside = try temp.folder("outside")
        for folder in [workspace.source, workspace.temporary] {
            try FileManager.default.removeItem(at: folder)
            try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)
        }
        try FileManager.default.removeItem(at: workspace.output)
        try FileManager.default.createSymbolicLink(
            at: workspace.output, withDestinationURL: temp.url.appending(path: "missing"))

        try workspace.prepare(ref: "v1", recipeSHA256: "0")

        for folder in [workspace.source, workspace.output, workspace.temporary, workspace.home, workspace.roms] {
            #expect(isFolder(folder), "\(folder.lastPathComponent)")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path(percentEncoded: false)).isEmpty)
    }

    @Test func theProductMustBeAPlainAppThatStaysInsideItself() throws {
        let temp = try TemporaryDirectory()
        let workspace = try workspace(in: temp)
        let victim = try temp.folder("outside/Victim.app/Contents")
        let app = workspace.output.appending(path: "Test.app", directoryHint: .isDirectory)

        // A link in place of the app.
        try FileManager.default.createSymbolicLink(at: app, withDestinationURL: victim.deletingLastPathComponent())
        #expect(throws: FrontportError.self) { try workspace.product() }

        // An app holding a link that leads out of it.
        try FileManager.default.removeItem(at: app)
        try FileManager.default.createDirectory(at: app.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        let resources = app.appending(path: "Contents/Resources")
        try FileManager.default.createSymbolicLink(at: resources, withDestinationURL: victim)
        #expect(throws: FrontportError.self) { try workspace.product() }

        // Links that stay inside are fine.
        try FileManager.default.removeItem(at: resources)
        try FileManager.default.createSymbolicLink(atPath: resources.path(percentEncoded: false), withDestinationPath: "MacOS")
        #expect(try workspace.product().app.lastPathComponent == "Test.app")

        // Build Assets that are a link aren't.
        let assets = workspace.output.appending(path: "assets")
        try FileManager.default.createSymbolicLink(at: assets, withDestinationURL: victim)
        #expect(throws: FrontportError.self) { try workspace.product() }
    }

    /// The fetch step may write inside `tmp`; if it swaps `tmp` itself for a link, the build step's profile must not
    /// follow it to grant writing elsewhere.
    @Test func aFolderSwappedDuringFetchStopsTheBuild() async throws {
        let fixture = try BuilderFixture()
        let builder = try await fixture.readyBuilder()
        let outside = try fixture.temp.folder("outside")
        let recipe = try fixture.recipe("""
            if [ "$1" = fetch ]; then
                rm -rf "$TMPDIR" && ln -s "\(outside.path(percentEncoded: false))" "$TMPDIR" && echo SWAPPED
                exit 0
            fi
            echo escaped > "\(outside.path(percentEncoded: false))/escaped"
            \(makeApp)
            """)

        await #expect(throws: FrontportError.self) {
            try await builder.build(.fixture(), ref: "v1", recipe: recipe, roms: .none, log: fixture.log) { _ in }
        }
        #expect(!exists(outside.appending(path: "escaped")))
    }
}
