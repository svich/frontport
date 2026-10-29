import Foundation
import Testing
@testable import FrontportCore

@Suite struct MoveTests {
    static let day: TimeInterval = 86_400
    static func release(_ version: String, created days: Double? = nil, channel: Channel = .stable) -> Release {
        Release(
            port: "soh", version: version, tag: "v\(version)", channel: channel,
            created: days.map { Date(timeIntervalSinceReferenceDate: $0 * day) })
    }

    static let installed = release("9.3.0", created: 10)
    static let older = release("9.2.0", created: 5)
    static let newer = release("9.3.1", created: 20)
    static let warn = Block(release: "9.3.0", severity: .warn, reason: "Saves may not load.")
    static let olderBlocked = Block(release: "9.2.0", severity: .warn, reason: "It crashes.")

    static func entry(blocked: [Block] = [], releases: ReleaseSource? = nil) -> CatalogEntry {
        CatalogEntry(
            id: "soh", name: "Ship of Harkinian", kind: .decomp, game: "ocarina-of-time", developer: "HarbourMasters",
            summary: "", description: "", source: URL(string: "https://example.org/soh")!, bundleId: "dev.frontport.port.soh",
            releases: releases
                ?? .githubRelease(GitHubReleaseSource(repo: "a/soh", asset: "*.zip", channels: [.stable, .nightly])),
            blocked: blocked)
    }

    static func installation(
        _ release: Release = installed, previous: Release? = nil, channel: Channel = .stable, disabled: Bool = false
    ) -> Installation {
        Installation(
            port: "soh", release: release, channel: channel, installedAt: .now, appName: "soh.app", previous: previous,
            disabled: disabled)
    }

    // MARK: Direction

    /// Undated, by version number `high` ("45a149d") compares as newer than `low` ("1f2e3d4").
    static let high = Release(port: "soh", version: "45a149d", tag: "45a149d8b4bb8098f53d1009f76e76e7d8b79bbf")
    static let low = Release(port: "soh", version: "1f2e3d4", tag: "1f2e3d4c5b6a79881726354453627180918a7b6c")
    static func pinning(_ ref: Release, on channel: Channel = .stable) -> CatalogEntry {
        entry(releases: .git(GitSource(repo: "a/soh", refs: [channel: ref.tag], recipe: "recipes/soh.sh", recipeSHA256: "0")))
    }

    @Test func direction() throws {
        try #require(Self.high.isNewer(than: Self.low))
        let rows: [(String, CatalogEntry, Installation, Release, Channel, Move.Direction)] = [
            ("the same Release", Self.entry(), Self.installation(), Self.installed, .stable, .none),
            ("the same Release on another Channel", Self.entry(), Self.installation(), Self.installed, .nightly, .none),
            ("the same Release, disabled", Self.entry(), Self.installation(disabled: true), Self.installed, .stable, .forward),
            ("newer", Self.entry(), Self.installation(), Self.newer, .stable, .forward),
            ("older", Self.entry(), Self.installation(), Self.older, .stable, .back),
            ("older on another Channel", Self.entry(), Self.installation(), Self.older, .nightly, .back),
            ("undated, by version", Self.entry(), Self.installation(Self.release("1.9")), Self.release("1.10"), .stable, .forward),
            ("the newly pinned ref", Self.pinning(Self.low), Self.installation(Self.high), Self.low, .stable, .forward),
            ("a ref that isn't the pin", Self.pinning(Self.high), Self.installation(Self.high), Self.low, .stable, .back),
            ("another Channel's pinned ref", Self.pinning(Self.low, on: .nightly), Self.installation(Self.high), Self.low,
             .nightly, .back),
        ]
        for (name, entry, installation, target, channel, direction) in rows {
            let move = Move(entry, from: installation, to: target, on: channel)
            #expect(move.direction == direction, "\(name)")
            #expect(move.from == installation.release && move.to == target && move.channel == channel, "\(name)")
        }
    }

    /// Back to the previous Release, even one that compares as newer, as when the Catalog pinned an older ref.
    @Test func rollbackGoesBackWhateverTheDatesSay() throws {
        #expect(Move.rollback(from: Self.installation()) == nil)

        let rollback = try #require(Move.rollback(from: Self.installation(Self.low, previous: Self.high)))
        #expect(rollback.direction == .back)
        #expect(rollback.from == Self.low && rollback.to == Self.high)
    }

    // MARK: Offer

    @Test func offer() {
        let rows: [(String, CatalogEntry, Installation, Release?, Move.Offer?)] = [
            ("nothing found", Self.entry(), Self.installation(), nil, nil),
            ("newer", Self.entry(), Self.installation(), Self.newer, .update(Self.newer)),
            ("the Release it's on", Self.entry(), Self.installation(), Self.installed, nil),
            ("the Release it's on, disabled", Self.entry(), Self.installation(disabled: true), Self.installed, nil),
            ("found on another Channel", Self.entry(), Self.installation(), Self.release("9.4.0", created: 30, channel: .nightly), nil),
            ("older", Self.entry(), Self.installation(), Self.older, nil),
            ("older, Blocked, with a previous Release", Self.entry(blocked: [Self.warn]),
             Self.installation(previous: Self.release("9.1.0", created: 1)), Self.older, nil),
            ("older, Blocked, no previous Release", Self.entry(blocked: [Self.warn]), Self.installation(), Self.older,
             .fallback(Self.older)),
            ("older, Blocked, previous Blocked", Self.entry(blocked: [Self.warn, Self.olderBlocked]),
             Self.installation(previous: Self.older), Self.release("9.1.0", created: 1), .fallback(Self.release("9.1.0", created: 1))),
            ("Blocked, newer", Self.entry(blocked: [Self.warn]), Self.installation(), Self.newer, .update(Self.newer)),
            ("the newly pinned ref", Self.pinning(Self.low), Self.installation(Self.high), Self.low, .update(Self.low)),
        ]
        for (name, entry, installation, newest, offer) in rows {
            #expect(Move.offer(entry, for: installation, newest: newest) == offer, "\(name)")
        }
    }

    // MARK: Snapshots

    static func snapshot(_ id: String, release: String, target: String?, reason: Snapshot.Reason = .update) -> Snapshot {
        Snapshot(id: id, port: "soh", created: .now, reason: reason, release: release, target: target)
    }

    /// Newest first, as the Library lists them.
    static let snapshots = [
        snapshot("e", release: "9.3.0", target: "9.2.0", reason: .channelSwitch),
        snapshot("d", release: "9.2.0", target: "9.3.0"),
        snapshot("c", release: "9.3.0", target: "9.2.0", reason: .rollback),
        snapshot("b", release: "9.2.0", target: "9.3.0"),
        snapshot("a", release: "9.1.0", target: "9.2.0"),
    ]

    @Test func aBackMoveBringsBackTheNewestSnapshotFromItsTarget() throws {
        let back = Move(Self.entry(), from: Self.installation(), to: Self.older, on: .stable)
        #expect(back.restores(from: Self.snapshots)?.id == "d")
        #expect(back.restores(from: []) == nil, "the current Data stays")

        let rollback = try #require(Move.rollback(from: Self.installation(previous: Self.older)))
        #expect(rollback.restores(from: Self.snapshots)?.id == "d")

        let forward = Move(Self.entry(), from: Self.installation(), to: Self.newer, on: .stable)
        #expect(forward.restores(from: Self.snapshots + [Self.snapshot("f", release: "9.3.1", target: nil)]) == nil)
    }

    @Test func theSnapshotAMoveTookRecordsWhereItWent() {
        let back = Move(Self.entry(), from: Self.installation(), to: Self.older, on: .nightly)
        #expect(back.taken(in: Self.snapshots)?.id == "e")
        #expect(back.taken(in: Array(Self.snapshots.dropFirst()))?.id == "c")
        #expect(Move(Self.entry(), from: Self.installation(), to: Self.newer, on: .stable).taken(in: Self.snapshots) == nil)
    }
}
