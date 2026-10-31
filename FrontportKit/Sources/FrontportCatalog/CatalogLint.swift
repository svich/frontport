import Foundation
import FrontportCore

extension CatalogDocument {
    /// Mistakes a signed Catalog must not contain: duplicate ids, malformed ids and bundle IDs, dangling or
    /// unused references, malformed hashes and paths. Empty when the document is consistent.
    public func problems() -> [String] {
        var problems: [String] = []

        func duplicates<T: Hashable>(_ values: [T]) -> [T] {
            Dictionary(grouping: values, by: { $0 }).filter { $0.value.count > 1 }.map(\.key)
        }
        for id in duplicates(platforms.map(\.id)) { problems.append("Platform \(id) is listed twice.") }
        for id in duplicates(genres.map(\.id)) { problems.append("Genre \(id) is listed twice.") }
        for id in duplicates(games.map(\.id)) { problems.append("Game \(id) is listed twice.") }
        for sha1 in duplicates(roms.map(\.sha1)) { problems.append("ROM \(sha1) is listed twice.") }
        for id in duplicates(ports.map(\.id)) { problems.append("Port \(id) is listed twice.") }
        for bundleId in duplicates(ports.map(\.bundleId)) { problems.append("Bundle ID \(bundleId) is used twice.") }

        let platformIDs = Set(platforms.map(\.id))
        let gameIDs = Set(games.map(\.id))
        let romsBySHA1 = Dictionary(roms.map { ($0.sha1, $0) }, uniquingKeysWith: { a, _ in a })

        for game in games where !platformIDs.contains(game.platform) {
            problems.append("Game \(game.id) names unknown Platform \(game.platform).")
        }
        let genreIDs = Set(genres.map(\.id))
        for game in games {
            for genre in game.genres where !genreIDs.contains(genre) {
                problems.append("Game \(game.id) names unknown Genre \(genre).")
            }
            // One step only: an expansion builds on a Game that builds on none.
            if let base = game.base, base == game.id || self.game(base)?.base != nil || !gameIDs.contains(base) {
                problems.append("Game \(game.id) must have as its base another Game, which has no base itself.")
            }
        }
        let usedGenres = Set(games.flatMap(\.genres))
        for genre in genres where !usedGenres.contains(genre.id) {
            problems.append("Genre \(genre.id) has no Games.")
        }
        // ROM intake accepts only hashes a Requirement lists, so a ROM nothing lists could never be added.
        let accepted = Set(ports.flatMap(\.acceptedROMs))
        for rom in roms {
            if !Self.isHex(rom.sha1, length: 40) { problems.append("ROM \(rom.sha1) isn’t a lowercase SHA-1.") }
            switch (rom.game, rom.platform) {
            case (let game?, nil):
                if !gameIDs.contains(game) { problems.append("ROM \(rom.sha1) names unknown Game \(game).") }
            case (nil, let platform?):
                if !platformIDs.contains(platform) { problems.append("ROM \(rom.sha1) names unknown Platform \(platform).") }
            default:
                problems.append("ROM \(rom.sha1) must name either its Game or, for a Platform’s own files, its Platform.")
            }
            // Every other Type is told from the ROM's format and its Game's Platform.
            if let type = rom.type, ![.update, .dlc].contains(type) || rom.game == nil {
                problems.append("ROM \(rom.sha1) may have a type only as a Game’s update or dlc.")
            }
            // Both name paths inside the folder, which intake reads and Steam's install folder holds.
            if let configs = rom.configs {
                if !rom.isFolder { problems.append("ROM \(rom.sha1) has configs but isn’t a folder ROM.") }
                if configs.isEmpty || Set(configs).count != configs.count {
                    problems.append("ROM \(rom.sha1) has empty or repeated configs.")
                }
                for path in configs where (try? CatalogStore.checkedRelativePath(path)) == nil {
                    problems.append("ROM \(rom.sha1) has a config outside its folder: \(path).")
                }
            }
            if let steam = rom.steam {
                if steam.app <= 0 { problems.append("ROM \(rom.sha1) has a malformed Steam app id.") }
                if rom.isFolder, steam.file != nil { problems.append("ROM \(rom.sha1) is a folder ROM but names a Steam file.") }
                if let alongside = steam.alongside {
                    if !rom.isFolder { problems.append("ROM \(rom.sha1) isn’t a folder ROM but has Steam apps alongside.") }
                    if alongside.isEmpty || alongside.contains(where: { $0 <= 0 || $0 == steam.app }) || Set(alongside).count != alongside.count {
                        problems.append("ROM \(rom.sha1) has malformed Steam apps alongside.")
                    }
                }
                if !rom.isFolder, steam.file == nil || steam.folder != nil {
                    problems.append("ROM \(rom.sha1) is from Steam but names no Steam file, which a ROM other than a folder needs.")
                }
                if let path = steam.path, (try? CatalogStore.checkedRelativePath(path)) == nil {
                    problems.append("ROM \(rom.sha1) has a Steam path outside the install folder: \(path).")
                }
            }
            guard let unpack = rom.unpack else {
                if !accepted.contains(rom.sha1) { problems.append("ROM \(rom.sha1) isn’t accepted by any Requirement.") }
                continue
            }
            // An installer never enters ROMs: the folders it yields do, so they're what Requirements accept.
            if accepted.contains(rom.sha1) { problems.append("Installer \(rom.sha1) is accepted by a Requirement; accept what it yields.") }
            if (try? CatalogStore.checkedRelativePath(unpack.recipe)) == nil {
                problems.append("Installer \(rom.sha1) has a Recipe path outside the Catalog: \(unpack.recipe).")
            }
            if !Self.isHex(unpack.recipeSHA256, length: 64) { problems.append("Installer \(rom.sha1) has a malformed recipeSHA256.") }
            if unpack.yields.isEmpty { problems.append("Installer \(rom.sha1) yields no ROM.") }
            for sha1 in unpack.yields {
                guard let yielded = romsBySHA1[sha1], yielded.isFolder else {
                    problems.append("Installer \(rom.sha1) yields \(sha1), which isn’t a folder ROM in roms.")
                    continue
                }
                if !accepted.contains(sha1) { problems.append("Installer \(rom.sha1) yields \(sha1), which no Requirement accepts.") }
            }
        }

        // Ports from one repository are one Project, which the app names and describes from its first Port.
        var projects: [String: CatalogEntry] = [:]
        for port in ports {
            guard let first = projects[port.releases.repo] else {
                projects[port.releases.repo] = port
                continue
            }
            let differing = [
                ("name", port.name != first.name), ("developer", port.developer != first.developer),
                ("kind", port.kind != first.kind), ("source", port.source != first.source),
                ("website", port.website != first.website),
            ].filter(\.1).map(\.0)
            if !differing.isEmpty {
                problems.append(
                    "Port \(port.id) shares \(port.releases.repo) with \(first.id), so its "
                        + "\(differing.joined(separator: ", ")) must match.")
            }
        }

        // A Platform's own files of one format, as `roms` orders them: newest first.
        let platformFiles = Dictionary(grouping: roms.filter { $0.platform != nil && $0.game == nil }) {
            "\($0.platform?.rawValue ?? "")/\($0.format)"
        }

        for port in ports {
            let name = "Port \(port.id)"
            // The id names the Port's folders and the bundle ID its container: nothing else may be possible.
            if !port.id.isWellFormed {
                problems.append("\(name) must have an id of lowercase letters, digits and hyphens.")
            }
            if port.id.rawValue.hasPrefix(PortID.unpackPrefix) {
                problems.append("\(name) may not start with \(PortID.unpackPrefix), which names the unpack Recipes’ build folders.")
            }
            if port.bundleId != port.id.conventionalBundleID {
                problems.append("\(name) has bundle ID \(port.bundleId); it must be \(port.id.conventionalBundleID).")
            }
            if !gameIDs.contains(port.game) { problems.append("\(name) names unknown Game \(port.game).") }
            if port.releases.channels.isEmpty { problems.append("\(name) offers no Channel.") }
            if case .git(let source) = port.releases {
                if (try? CatalogStore.checkedRelativePath(source.recipe)) == nil {
                    problems.append("\(name) has a Recipe path outside the Catalog: \(source.recipe).")
                }
                if !Self.isHex(source.recipeSHA256, length: 64) {
                    problems.append("\(name) has a malformed recipeSHA256.")
                }
            }
            if Set(port.requirements.map(\.label)).count != port.requirements.count {
                problems.append("\(name) has two Requirements with the same label.")
            }
            for requirement in port.requirements {
                let label = "\(name) Requirement \(requirement.label)"
                if requirement.oneOf.isEmpty { problems.append("\(label) accepts no ROM.") }
                for sha1 in requirement.oneOf + requirement.extras {
                    guard let rom = romsBySHA1[sha1] else {
                        problems.append("\(label) lists \(sha1), which isn’t in roms.")
                        continue
                    }
                    // A Port takes its own Game's ROMs and its base Game's, and its Game's Platform's own files.
                    if let game = rom.game, game != port.game, game != self.game(port.game)?.base {
                        problems.append("\(label) lists \(sha1), a ROM of \(game).")
                    }
                    if let platform = rom.platform, platform != self.game(port.game)?.platform {
                        problems.append("\(label) lists \(sha1), a file of \(platform).")
                    }
                }
                // Intake keeps the newest form of a Platform's file that any Requirement accepts, such as console keys
                // with the most master keys, so each Requirement accepts a run of them from the newest, which `roms`
                // lists first. Otherwise a newer file would be stored in a form this Requirement refuses.
                let listed = Set(requirement.oneOf + requirement.extras)
                for (_, files) in platformFiles where files.contains(where: { listed.contains($0.sha1) }) {
                    let run = files.prefix { listed.contains($0.sha1) }.count
                    if files.dropFirst(run).contains(where: { listed.contains($0.sha1) }) || run == 0 {
                        problems.append(
                            "\(label) must accept \(files[0].platform?.rawValue ?? "")’s .\(files[0].format) files from the first in roms on, without a gap.")
                    }
                }
                switch requirement.stage {
                case .runtime:
                    guard let seedPath = requirement.seedPath else {
                        // An Unsupported Port still lists its ROMs, but may not know where they'd go.
                        if port.isInstallable { problems.append("\(label) is Runtime Stage but has no seedPath.") }
                        break
                    }
                    // The rule Seeding goes by.
                    do {
                        _ = try requirement.seedTarget()
                    } catch {
                        switch error {
                        case .outsideData: problems.append("\(label) has a seedPath outside Data: \(seedPath).")
                        case .extrasNeedAFolder: problems.append("\(label) has extras, so its seedPath must be a folder.")
                        }
                    }
                case .build:
                    if requirement.seedPath != nil { problems.append("\(label) is Build Stage but has a seedPath.") }
                    if port.buildAssets == nil { problems.append("\(label) is Build Stage but \(name) has no buildAssets.") }
                    if !port.isSourceBuilt { problems.append("\(label) is Build Stage but \(name) isn’t built from source.") }
                }
            }
            // The Packager links Build Assets from this path, "../" once per component, so each must be a real one, in
            // plain ASCII, which the volume can't fold into another name.
            if let assets = port.buildAssets, !PortLinks.isPlainRelative(assets.path) {
                problems.append("\(name) has a buildAssets path that isn’t plainly inside the app: \(assets.path).")
            }
            // A Redirect leads from a path inside the app's Contents/Resources to a folder in the Port's Data, and no
            // two of the Packager's links may sit at, or inside, one another. Nor may any stand in for the app's code
            // or what its signature rests on: through its Data, the Port could swap in a program that runs unsandboxed.
            for redirect in port.redirects {
                if !redirect.path.hasPrefix("Contents/Resources/") || !PortLinks.isPlainRelative(redirect.path) {
                    problems.append(
                        "\(name) redirects a path that isn’t plainly inside the app’s Contents/Resources: \(redirect.path).")
                }
                if !PortLinks.isPlainRelative(redirect.to) {
                    problems.append("\(name) redirects to a folder that isn’t plainly inside Data: \(redirect.to).")
                }
            }
            let linked = port.redirects.map(\.path) + (port.buildAssets.map { [$0.path] } ?? [])
            for path in linked where PortLinks.isPlainRelative(path) && !PortLinks.isClearOfCode(path) {
                problems.append("\(name) links a path at, above or inside the app’s code or signature: \(path).")
            }
            for (index, path) in linked.enumerated() {
                for other in linked[(index + 1)...] where PortLinks.overlaps(path, other) {
                    problems.append("\(name) links both \(path) and \(other), which overlap.")
                }
            }
            for path in port.strip
            where path.isEmpty || path.hasPrefix("/") || path.split(separator: "/").contains("..")
                || !path.hasPrefix("Contents/")
            {
                problems.append("\(name) strips a path outside the app's Contents: \(path).")
            }
            for exception in port.codeSigning.exceptions where exception.contains(".") || exception.isEmpty {
                problems.append("\(name) code-signing exception \(exception) must be a suffix of com.apple.security.cs.")
            }
            for exception in duplicates(port.codeSigning.exceptions) {
                problems.append("\(name) lists code-signing exception \(exception) twice.")
            }
        }
        return problems
    }

    private static func isHex(_ string: String, length: Int) -> Bool {
        string.count == length && string.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
}
