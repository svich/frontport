import Darwin
import Foundation
import FrontportCore

/// Discovers Releases on GitHub for each Channel and leaves out Blocked ones.
///
/// For a `github-release` source it reads the newest 50 releases; for a `git` source it returns the Channel's
/// pinned ref, dated from GitHub when it can be reached. Responses are cached with their ETags in `cache`.
public actor GitHubReleases: ReleaseDiscovering {
    public static let pageSize = 50

    private var client: GitHubClient

    /// - Parameters:
    ///   - cache: Folder for cached responses, such as `AppPaths.catalog/releases`. Created when first needed.
    ///   - token: Optional GitHub token, raising the rate limit from 60 to 5,000 requests per hour.
    public init(
        cache: URL, token: String? = nil, session: URLSession = GitHubReleases.defaultSession,
        api: URL = URL(string: "https://api.github.com")!
    ) {
        client = GitHubClient(api: api, cache: cache, session: session, token: token)
    }

    /// An ephemeral session without URLCache, so revalidation is left to the ETag cache.
    public static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    public func setToken(_ token: String?) {
        client = GitHubClient(api: client.api, cache: client.cache, session: client.session, token: token)
    }

    public func releases(for entry: CatalogEntry, channel: Channel) async throws -> [Release] {
        try Self.validate(entry.releases.repo)
        switch entry.releases {
        case .githubRelease(let source):
            guard source.channels.contains(channel) else { return [] }
            let response = try await client.get(
                "repos/\(source.repo)/releases", query: [URLQueryItem(name: "per_page", value: String(Self.pageSize))])
            guard let body = response.body else {
                throw FrontportError.network("GitHub has no repository \(source.repo).")
            }
            let list: [GitHubRelease]
            do {
                list = try JSON.decode([GitHubRelease].self, from: body)
            } catch {
                throw FrontportError.network("GitHub’s release list for \(source.repo) couldn’t be read.")
            }
            return Self.releases(from: list, entry: entry, source: source, channel: channel)
        case .git(let source):
            guard let ref = source.refs[channel] else { return [] }
            let release = try await pinnedRelease(ref, entry: entry, source: source, channel: channel)
            return entry.block(for: release) == nil ? [release] : []
        }
    }

    /// The newest Release that can be installed: source-built, or with a digest to verify its download against.
    /// Releases from before GitHub computed digests are listed by `releases` but never offered.
    public func latest(for entry: CatalogEntry, channel: Channel) async throws -> Release? {
        try await releases(for: entry, channel: channel).first { $0.asset.map { $0.sha256 != nil } ?? true }
    }

    // MARK: github-release

    /// The Releases on `channel`, newest first: no drafts, nothing without an asset matching the entry's
    /// glob, nothing Blocked.
    static func releases(
        from list: [GitHubRelease], entry: CatalogEntry, source: GitHubReleaseSource, channel: Channel
    ) -> [Release] {
        let releases = list.enumerated().compactMap { offset, item -> (offset: Int, release: Release)? in
            guard !item.draft, source.includes(item, on: channel),
                let asset = item.assets.first(where: { Glob.matches(source.asset, $0.name) })
            else { return nil }
            let release = Release(
                port: entry.id,
                version: displayVersion(item.tagName),
                tag: item.tagName,
                title: item.name.flatMap { $0.isEmpty ? nil : $0 },
                channel: channel,
                published: item.publishedAt ?? item.createdAt,
                created: item.createdAt ?? item.publishedAt,
                notes: item.body.flatMap { $0.isEmpty ? nil : $0 },
                notesURL: item.htmlURL,
                asset: ReleaseAsset(
                    name: asset.name, url: asset.browserDownloadURL, size: asset.size, sha256: asset.sha256))
            return entry.block(for: release) == nil ? (offset, release) : nil
        }
        // The order every part of Frontport uses; GitHub's own order breaks ties.
        return releases.sorted { a, b in
            a.release.isNewer(than: b.release) || (!b.release.isNewer(than: a.release) && a.offset < b.offset)
        }.map(\.release)
    }

    // MARK: git

    private func pinnedRelease(_ ref: String, entry: CatalogEntry, source: GitSource, channel: Channel) async throws -> Release {
        var release = Release(
            port: entry.id, version: Self.displayVersion(ref), tag: ref, channel: channel,
            notesURL: URL(string: "https://github.com/\(source.repo)/tree/\(ref)"))
        // Best effort: a pinned ref is installable without GitHub, it just has no date.
        do {
            let tagged = try await client.get("repos/\(source.repo)/releases/tags/\(ref)")
            if let body = tagged.body, let item = try? JSON.decode(GitHubRelease.self, from: body) {
                release.title = item.name.flatMap { $0.isEmpty ? nil : $0 }
                release.published = item.publishedAt ?? item.createdAt
                release.created = item.createdAt ?? item.publishedAt
                release.notes = item.body.flatMap { $0.isEmpty ? nil : $0 }
                release.notesURL = item.htmlURL ?? release.notesURL
                return release
            }
            let commit = try await client.get("repos/\(source.repo)/commits/\(ref)")
            if let body = commit.body, let item = try? JSON.decode(GitHubCommit.self, from: body) {
                release.published = item.date
                release.created = item.date
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {}
        return release
    }

    // MARK: Helpers

    /// "v1.2.2" → "1.2.2"; a full commit hash → its first 7 characters; anything else as is.
    static func displayVersion(_ tag: String) -> String {
        if tag.count == 40, tag.allSatisfy(\.isHexDigit) { return String(tag.prefix(7)) }
        if let first = tag.first, first == "v" || first == "V", tag.dropFirst().first?.isNumber == true {
            return String(tag.dropFirst())
        }
        return tag
    }

    private static func validate(_ repo: String) throws {
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let valid = parts.count == 2 && parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && part.unicodeScalars.allSatisfy(allowed.contains)
        }
        if !valid { throw FrontportError.catalogInvalid("“\(repo)” isn’t a GitHub repository.") }
    }
}

extension GitHubReleaseSource {
    /// Whether a GitHub release belongs to a Channel: by the Channel's tag glob when it has one, otherwise
    /// `stable` takes full releases only and any other Channel takes prereleases too.
    func includes(_ release: GitHubRelease, on channel: Channel) -> Bool {
        if let pattern = tags?[channel] { return Glob.matches(pattern, release.tagName) }
        return channel != .stable || !release.prerelease
    }
}

/// Shell-style globs with fnmatch(3) semantics: `*`, `?` and `[...]`, case-sensitive.
enum Glob {
    static func matches(_ pattern: String, _ name: String) -> Bool {
        fnmatch(pattern, name, 0) == 0
    }
}
