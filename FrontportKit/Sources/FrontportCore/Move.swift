import Foundation

/// An Installation going from its Release to another on a Channel (GLOSSARY.md). The one rule the Library moves by
/// and the App predicts with: which way a Move goes, what to offer an Installation, and which Snapshots a Move takes
/// and brings back.
public struct Move: Hashable, Sendable {
    public enum Direction: Hashable, Sendable {
        /// To the Release it's on: nothing to install, beyond a change of Channel.
        case none
        /// The current Release is kept for Rollback.
        case forward
        /// Handled like a Rollback: the Data from when the Port was last on `to` comes back, and no previous Release
        /// is kept.
        case back
    }

    /// What to offer an Installation, given the newest Release on its Channel.
    public enum Offer: Hashable, Sendable {
        case update(Release)
        /// The way off a Blocked Release when there's nothing newer, and no previous Release that isn't Blocked.
        case fallback(Release)

        public var release: Release {
            switch self {
            case .update(let release), .fallback(let release): release
            }
        }
    }

    public let from: Release
    public let to: Release
    public let channel: Channel
    public let direction: Direction

    /// Moving `installation` to `target` on `channel`. The same tag is no Move, unless a stop Block disabled the
    /// Installation, which moving to it puts back. A source-built Port follows the ref the Catalog pins for its
    /// Channel, so moving to that ref is forward, whatever the dates say: pinned refs often have none, and commit
    /// hashes don't compare as versions. Only another ref, such as another Channel's, can be older. Otherwise
    /// `Release.isNewer` decides.
    public init(_ entry: CatalogEntry, from installation: Installation, to target: Release, on channel: Channel) {
        let direction: Direction
        if target.tag == installation.release.tag, !installation.disabled {
            direction = .none
        } else if Self.isPinned(target, in: entry, on: channel, by: installation) {
            direction = .forward
        } else {
            direction = installation.release.isNewer(than: target) ? .back : .forward
        }
        self.init(from: installation.release, to: target, channel: channel, direction: direction)
    }

    private init(from: Release, to: Release, channel: Channel, direction: Direction) {
        self.from = from
        self.to = to
        self.channel = channel
        self.direction = direction
    }

    /// The Rollback: back to the previous Release, whatever the dates say, since a newly pinned ref can be older than
    /// the one it replaced. Nil without a previous Release.
    public static func rollback(from installation: Installation) -> Move? {
        installation.previous.map { Move(from: installation.release, to: $0, channel: $0.channel, direction: .back) }
    }

    /// What to offer `installation`, given the newest Release on its Channel: an Update when moving to it is forward,
    /// or, on a Blocked Release with no previous one to roll back to that isn't Blocked, that older Release as its
    /// Fallback. Never the Release it's on.
    public static func offer(_ entry: CatalogEntry, for installation: Installation, newest: Release?) -> Offer? {
        guard let newest, newest.channel == installation.channel, newest.tag != installation.release.tag else {
            return nil
        }
        switch Move(entry, from: installation, to: newest, on: installation.channel).direction {
        case .forward:
            return .update(newest)
        case .back:
            let isBlocked = entry.block(for: installation.release) != nil
            let canRollBack = installation.previous.map { entry.block(for: $0) == nil } ?? false
            return isBlocked && !canRollBack ? .fallback(newest) : nil
        case .none:
            return nil
        }
    }

    /// The Snapshot whose Data a back Move brings back: the newest taken while the Port was on `to`. Nil for any other
    /// Move, which keeps the Data, and when there's none, so the current Data stays. `snapshots` are newest first.
    public func restores(from snapshots: [Snapshot]) -> Snapshot? {
        guard direction == .back else { return nil }
        return snapshots.first { $0.release == to.version }
    }

    /// The Snapshot taken before this Move, which records the Release it left and the one it went to: the newest such
    /// among `snapshots`, newest first.
    public func taken(in snapshots: [Snapshot]) -> Snapshot? {
        snapshots.first { $0.release == from.version && $0.target == to.version }
    }

    /// True when `target` is the ref the Catalog pins for the Installation's own Channel, which it stays on.
    private static func isPinned(_ target: Release, in entry: CatalogEntry, on channel: Channel, by installation: Installation)
        -> Bool
    {
        guard case .git(let source) = entry.releases, channel == installation.channel else { return false }
        return source.refs[channel] == target.tag
    }
}
