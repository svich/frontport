import Foundation
import Testing
@testable import FrontportCore

@Suite struct StatusTests {
    static let installed = Release(port: "soh", version: "9.3.0")
    static let older = Release(port: "soh", version: "9.2.0")
    static let newer = Release(port: "soh", version: "9.3.1")
    static let buildROM = Requirement(label: "Ocarina of Time", stage: .build, oneOf: ["a"])
    static let runtimeROM = Requirement(label: "Master Quest", stage: .runtime, oneOf: ["b"])
    static let warn = Block(release: "9.3.0", severity: .warn, reason: "Saves may not load.")
    static let stop = Block(release: "9.3.0", severity: .stop, reason: "It deletes saves.")
    static let olderBlocked = Block(release: "9.2.0", severity: .warn, reason: "It crashes.")

    /// A Port as the App sees it: installed on 9.3.0 with 9.2.0 kept for Rollback, its Build ROM built in and its
    /// Runtime ROM Seeded, unless a test says otherwise.
    struct Scenario {
        var blocked: [Block] = []
        var unsupported: String?
        var channels: [Channel] = [.stable, .nightly]
        var isInstalled = true
        var previous: Release? = StatusTests.older
        var build = ROMState.builtIn
        var runtime = ROMState.seeded
        var offer: Move.Offer?
        var activity: Activity?
        var isRunning = false
        var isListed = true
        var keptEntry = false

        var entry: CatalogEntry {
            CatalogEntry(
                id: "soh", name: "Ship of Harkinian", kind: .decomp, game: "ocarina-of-time", developer: "HarbourMasters",
                summary: "", description: "", source: URL(string: "https://example.org/soh")!,
                bundleId: "dev.frontport.port.soh",
                releases: .githubRelease(GitHubReleaseSource(repo: "a/soh", asset: "*.zip", channels: channels)),
                requirements: [StatusTests.buildROM, StatusTests.runtimeROM], blocked: blocked, unsupported: unsupported)
        }

        var status: Status {
            let installation = isInstalled
                ? Installation(
                    port: "soh", release: StatusTests.installed, channel: .stable, installedAt: .now, appName: "soh.app",
                    previous: previous, entry: keptEntry ? entry : nil)
                : nil
            let matching = PortMatching(port: "soh", isInstalled: isInstalled, requirements: [
                RequirementState(requirement: StatusTests.buildROM, rom: build == .missing ? nil : "a", accepted: build),
                RequirementState(requirement: StatusTests.runtimeROM, rom: runtime == .missing ? nil : "b", accepted: runtime),
            ])
            return Status(
                entry: entry, installation: installation, matching: matching, offer: offer, activity: activity,
                isRunning: isRunning, isListed: isListed)
        }
    }

    static func activity(_ kind: Activity.Kind) -> Activity {
        Activity(kind: kind, progress: ProgressUpdate(.resolving))
    }

    /// Each row outranks the next: it holds what the next shows, and shows its own state instead.
    @Test func precedence() {
        let rows: [(Scenario, Status.State, Status.Action?)] = [
            (Scenario(activity: Self.activity(.update), isRunning: true), .running, .stop),
            (Scenario(unsupported: "No sandbox.", activity: Self.activity(.update)), .working(Self.activity(.update)), .cancel),
            (Scenario(unsupported: "No sandbox.", isInstalled: false, build: .missing), .unsupported("No sandbox."), nil),
            (Scenario(isInstalled: false, build: .missing), .needsBuildROM([Self.buildROM]), .addROM(.build)),
            (Scenario(isInstalled: false, build: .inROMs, runtime: .missing), .available, .install),
            (Scenario(blocked: [Self.warn], runtime: .missing), .blocked(Self.warn), .play),
            (Scenario(runtime: .missing, offer: .update(Self.newer)), .needsROM([Self.runtimeROM]), .addROM(.runtime)),
            (Scenario(runtime: .unseeded, offer: .update(Self.newer)), .unseeded([Self.runtimeROM]), .seed),
            (Scenario(offer: .update(Self.newer)), .updateAvailable(Self.newer), .update),
            (Scenario(), .ready, .play),
        ]
        for (scenario, state, main) in rows {
            let status = scenario.status
            #expect(status.state == state)
            #expect(status.main == main, "\(state)")
            if let main { #expect(status.check(main) == .allowed, "\(state)") }
        }
        #expect(Scenario(offer: .update(Self.newer)).status.others == [.play])
    }

    /// Update, then Play past a warning, then an older Release, then Rollback; the rest are offered besides.
    @Test func wayOffABlockedRelease() {
        let update = Scenario(blocked: [Self.warn], offer: .update(Self.newer)).status
        #expect(update.main == .update)
        #expect(update.others == [.rollBack])

        let warned = Scenario(blocked: [Self.warn]).status
        #expect(warned.main == .play)
        #expect(warned.others == [.rollBack])

        let fallback = Scenario(blocked: [Self.stop, Self.olderBlocked], offer: .fallback(Self.older)).status
        #expect(fallback.main == .installFallback)
        #expect(fallback.others.isEmpty)
        #expect(fallback.check(.rollBack) == .disabled(.previousBlocked))
        #expect(fallback.check(.play) == .unavailable)

        let rollBack = Scenario(blocked: [Self.stop]).status
        #expect(rollBack.main == .rollBack)
        #expect(rollBack.check(.rollBack) == .allowed)

        let stuck = Scenario(blocked: [Self.stop, Self.olderBlocked]).status
        #expect(stuck.main == nil)
        #expect(stuck.others.isEmpty)

        let noPrevious = Scenario(blocked: [Self.stop], previous: nil).status
        #expect(noPrevious.main == nil)
        #expect(noPrevious.check(.rollBack) == .unavailable)

        // The banner offers them while the Port runs too, waiting for it to quit.
        let running = Scenario(blocked: [Self.warn], offer: .update(Self.newer), isRunning: true).status
        #expect(running.state == .running)
        #expect(running.waysOff == [.update, .rollBack])
        #expect(running.check(.update) == .disabled(.running))
        #expect(Scenario().status.waysOff.isEmpty)

        let unknownEntry = Scenario(blocked: [Self.stop], isListed: false).status
        #expect(unknownEntry.main == .rollBack)
        #expect(unknownEntry.check(.rollBack) == .disabled(.unknownEntry))
        #expect(Scenario(blocked: [Self.stop], isListed: false, keptEntry: true).status.check(.rollBack) == .allowed)
    }

    /// One change at a time, and those that change the app or its Data wait for the Port to quit.
    @Test func waitingRules() {
        let quitFirst: [Status.Action] = [
            .update, .rollBack, .restore, .switchChannel, .setPermissions, .uninstall, .deleteData,
        ]
        let changes = quitFirst + [.removeBuildFolder]

        let quiet = Scenario(offer: .update(Self.newer)).status
        for action in changes + [.play, .seed] { #expect(quiet.check(action) == .allowed, "\(action)") }

        let busy = Scenario(offer: .update(Self.newer), activity: Self.activity(.permissions)).status
        for action in changes + [.play] {
            #expect(busy.check(action) == .disabled(.activity(.permissions)), "\(action)")
        }
        #expect(busy.check(.cancel) == .allowed)
        #expect(busy.check(.seed) == .allowed)

        let running = Scenario(offer: .update(Self.newer), isRunning: true).status
        for action in quitFirst { #expect(running.check(action) == .disabled(.running), "\(action)") }
        #expect(running.check(.removeBuildFolder) == .allowed)
        #expect(running.check(.seed) == .allowed)
        #expect(running.check(.stop) == .allowed)
        #expect(running.check(.play) == .unavailable)

        let deleting = Scenario(isInstalled: false, activity: Self.activity(.deleteData)).status
        #expect(deleting.check(.install) == .disabled(.activity(.deleteData)))
    }

    /// A reason waiting won't fix comes before one it would.
    @Test func lastingReasonsComeFirst() {
        let status = Scenario(blocked: [Self.olderBlocked], activity: Self.activity(.update)).status
        #expect(status.check(.rollBack) == .disabled(.previousBlocked))
        let unlisted = Scenario(isRunning: true, isListed: false).status
        #expect(unlisted.check(.setPermissions) == .disabled(.unknownEntry))
        #expect(unlisted.check(.seed) == .disabled(.unknownEntry))
    }

    @Test func inLibrary() {
        #expect(Scenario().status.isInLibrary)
        #expect(Scenario(isInstalled: false, activity: Self.activity(.install)).status.isInLibrary)
        #expect(!Scenario(isInstalled: false, activity: Self.activity(.deleteData)).status.isInLibrary)
        #expect(!Scenario(isInstalled: false).status.isInLibrary)
    }

    /// Nothing to act on: unavailable rather than disabled.
    @Test func unavailableActions() {
        let notInstalled = Scenario(isInstalled: false).status
        let installedOnly: [Status.Action] = [
            .play, .stop, .cancel, .update, .installFallback, .rollBack, .switchChannel, .setPermissions, .seed,
            .uninstall, .addROM(.runtime), .addROM(.build),
        ]
        for action in installedOnly { #expect(notInstalled.check(action) == .unavailable, "\(action)") }
        // Data, Snapshots and a build folder can be left over from an earlier Installation.
        for action in [Status.Action.install, .deleteData, .restore, .removeBuildFolder] {
            #expect(notInstalled.check(action) == .allowed, "\(action)")
        }

        let needsBuildROM = Scenario(isInstalled: false, build: .missing).status
        #expect(needsBuildROM.check(.install) == .unavailable)
        #expect(needsBuildROM.check(.addROM(.build)) == .allowed)
        #expect(Scenario(unsupported: "No sandbox.", isInstalled: false).status.check(.install) == .unavailable)
        #expect(Scenario().status.check(.install) == .unavailable)
        #expect(Scenario(previous: nil).status.check(.rollBack) == .unavailable)
        #expect(Scenario(channels: [.stable]).status.check(.switchChannel) == .unavailable)
        #expect(Scenario().status.check(.update) == .unavailable)

        let everything: [Status.Action] = installedOnly + [.install, .deleteData, .restore, .removeBuildFolder]
        for action in everything { #expect(Status.unknown.check(action) == .unavailable, "\(action)") }
        #expect(Status.unknown.main == nil)
        #expect(!Status.unknown.isInLibrary)
    }
}
