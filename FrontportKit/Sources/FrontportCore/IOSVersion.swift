import Foundation

/// A Port's iOS version, which Frontport installs on Devices (DESIGN › Devices): its Catalog entry's `ios`, with its
/// own Releases, Channels, Blocks and seedPaths. Built from the entry the Catalog lists, or from the one an Installation
/// kept. The Device Library, the Device Packager and ROMs take it rather than an entry, so the Mac's version is never
/// taken for it.
public struct IOSVersion: Hashable, Sendable {
    /// The full entry, as the Catalog lists it or an Installation kept it.
    public let entry: CatalogEntry
    /// The entry as its iOS version, for Releases, the Fetcher, the Builder and the Catalog's Recipes to read as they
    /// read the Mac's: `ios`'s releases, Build Assets, strip paths and Blocks; each Requirement with its iOS seedPath,
    /// leaving out one the iOS version doesn't use (Runtime without a seedPath, or Build Stage without an iOS Recipe
    /// making Build Assets); and nothing that exists only on the Mac, such as Redirects, launch quirks and code-signing
    /// exceptions. It keeps the id and the Catalog. Its bundle ID fails `checkIdentity`, so it can never reach the
    /// Library or Seeding on the Mac; the real one, per Apple Team, is `PortID.deviceBundleID(team:)`.
    package let view: CatalogEntry

    /// The entry's iOS version; nil without `ios`.
    public init?(_ entry: CatalogEntry) {
        guard let ios = entry.ios else { return nil }
        self.entry = entry
        var view = entry
        view.bundleId = "\(entry.id.conventionalBundleID).ios"
        view.releases = ios.releases
        let buildsAssets = ios.buildAssets != nil && view.isSourceBuilt
        let seedPaths = ios.seedPaths + Array(repeating: nil, count: entry.requirements.count)
        view.requirements = zip(entry.requirements, seedPaths)
            .compactMap { requirement, seedPath in
                var requirement = requirement
                requirement.seedPath = seedPath
                switch requirement.stage {
                case .runtime: return seedPath == nil ? nil : requirement
                case .build: return buildsAssets ? requirement : nil
                }
            }
        view.permissions = .default
        view.codeSigning = CodeSigning()
        view.launch = LaunchSpec()
        view.strip = ios.strip
        view.buildAssets = ios.buildAssets
        view.redirects = []
        view.blocked = ios.blocked
        view.ios = nil
        self.view = view
    }

    /// The entry's iOS version, refused without `ios`.
    public init(of entry: CatalogEntry) throws {
        guard let version = IOSVersion(entry) else {
            throw FrontportError.notForDevice("\(entry.name) has no iOS version.")
        }
        self = version
    }

    /// The iOS version Seeding goes by for `installation`, given `listed`, the Catalog's entry for the Port: its own,
    /// or once it no longer has one or the Catalog no longer lists the Port, the one the record kept. A listed entry
    /// for another Port than the record's goes as it is. Nil when the entry it goes by has no iOS version.
    public init?(seeding installation: DeviceInstallation, listed: CatalogEntry?) {
        if let listed, listed.ios != nil || listed.id != installation.entry.id {
            self.init(listed)
        } else {
            self.init(installation.entry)
        }
    }

    public var id: PortID { entry.id }

    /// Channels offered, default first.
    public var channels: [Channel] { view.channels }

    /// The Channel an Installation follows unless the user picks another.
    public var defaultChannel: Channel { view.defaultChannel }

    /// Built from source by an iOS Recipe rather than downloaded prebuilt.
    public var isSourceBuilt: Bool { view.isSourceBuilt }

    /// The SHA-256 of a source-built one's iOS Recipe, which is part of what it builds; nil for a prebuilt one.
    public var recipeSHA256: String? { view.releases.recipeSHA256 }

    /// The Runtime Requirements it Seeds on a Device, in the entry's order, each with its iOS seedPath.
    public var requirements: [Requirement] { view.requirements(for: .runtime) }

    /// Refuses `release` on `channel` unless it's offered: `noRelease` when the Channel isn't one of the iOS version's,
    /// `blocked` when `ios.blocked` Blocks the Release, by its own version, whatever the Mac's Blocks say.
    public func check(_ release: Release, on channel: Channel) throws {
        guard channels.contains(channel) else { throw FrontportError.noRelease(id, channel) }
        if let block = view.block(for: release) {
            throw FrontportError.blocked(id, release: release.version, reason: block.reason)
        }
    }

    /// True when `check` lets `release` on `channel` through.
    public func offers(_ release: Release, on channel: Channel) -> Bool {
        (try? check(release, on: channel)) != nil
    }

    /// What `installation` is offered from `newest`, the newest iOS Release on its Channel: an Update, forward only
    /// (DESIGN › Devices). The Device Library updates by it and the App offers with it, so Update never shows for what
    /// the Device Library won't install. Unlike `Move`, there's no going back: a Device keeps no previous Release and
    /// no Snapshot of its Data, so a Release that isn't forward (`isForward`), or isn't offered, never is. Nil then.
    public func update(for installation: DeviceInstallation, newest: Release?) -> Release? {
        guard let newest, newest.port == installation.port, newest.channel == installation.channel,
            offers(newest, on: installation.channel), isForward(installation, to: newest)
        else { return nil }
        return newest
    }

    /// True when installing `target` over `installation` moves it forward. A source-built one follows what the signed
    /// Catalog pins for `target`'s Channel, its ref and its iOS Recipe: the pinned ref is forward when either differs
    /// from what's installed, or the Channel does, whatever the dates say, since pinned refs often have none and commit
    /// hashes don't compare as versions; another ref never is. Otherwise, another tag newer by `Release.isNewer`.
    public func isForward(_ installation: DeviceInstallation, to target: Release) -> Bool {
        if case .git(let source) = view.releases {
            guard source.refs[target.channel] == target.tag else { return false }
            return target.tag != installation.release.tag || target.channel != installation.channel
                || installation.recipeSHA256 != source.recipeSHA256
        }
        return target.tag != installation.release.tag && target.isNewer(than: installation.release)
    }
}
