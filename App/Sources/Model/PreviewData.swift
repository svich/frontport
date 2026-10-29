import FrontportCore
import Foundation

/// Sample state shaped like the UI mocks, for the Debug snapshot driver.
/// Hashes, asset patterns and seed paths are illustrative, not Catalog data.
struct PreviewData {
    var catalog: CatalogDocument
    var installations: [Installation]
    var roms: [ROMRecord]
    var releases: [Release]
    var updates: [PortID: Release]
    var lastChecked: Date?
    var running: Set<PortID>
    var activities: [PortID: Activity]
    /// Requirements of installed Ports whose ROMs aren't in their Data; every other one is.
    var unseeded: [PortID: [Requirement]] = [:]
    var snapshots: [PortID: [Snapshot]]
    var runs: [PortID: [Run]]
    var addedCatalogs: [CatalogSummary] = []

    /// Where each Port's Requirements stand over these ROMs, as a reading would find them: an installed Port's Build
    /// ROMs built in, and its Runtime ROMs Seeded but for `unseeded`.
    var matching: Matching {
        let present = Set(roms.map(\.sha1))
        let installed = Set(installations.map(\.port))
        var ports: [PortID: PortMatching] = [:]
        for entry in catalog.ports {
            let isInstalled = installed.contains(entry.id)
            let notSeeded = Set((unseeded[entry.id] ?? []).map(\.id))
            let states = entry.requirements.map { requirement in
                func state(_ sha1: String) -> ROMState {
                    guard present.contains(sha1) else { return .missing }
                    guard isInstalled else { return .inROMs }
                    if requirement.stage == .build { return .builtIn }
                    return notSeeded.contains(requirement.id) ? .unseeded : .seeded
                }
                let rom = requirement.oneOf.first(where: present.contains)
                return RequirementState(
                    requirement: requirement, rom: rom, accepted: rom.map(state) ?? .missing,
                    extras: Dictionary(requirement.extras.map { ($0, state($0)) }, uniquingKeysWith: { a, _ in a }))
            }
            ports[entry.id] = PortMatching(port: entry.id, isInstalled: isInstalled, requirements: states)
        }
        return Matching(roms: roms, ports: ports)
    }

    /// Seven Ports installed (2Ship running, Ship of Harkinian and OpenGOAL's Jak and Daxter and Jak II with updates,
    /// SpaghettiKart needing a ROM, Starship building, Zelda 64: Recompiled with its ROM not Seeded) and eight more in
    /// the Catalog, Ghostship with a Snapshot left from an earlier Installation.
    static func standard(paths: AppPaths = .default) -> PreviewData {
        let installed: [Installation] = [
            Installation(
                port: "opengoal-jak1", release: Sample.openGOAL038("opengoal-jak1"), channel: .stable,
                installedAt: Sample.date(2026, 9, 21), appName: "OpenGOAL Jak 1.app"),
            Installation(
                port: "opengoal-jak2", release: Sample.openGOAL038("opengoal-jak2"), channel: .stable,
                installedAt: Sample.date(2026, 9, 22), appName: "OpenGOAL Jak 2.app"),
            Installation(
                port: "2ship", release: Sample.latest("2ship"), channel: .stable,
                installedAt: Sample.date(2026, 8, 26), appName: "2s2h.app",
                previous: Release(port: "2ship", version: "5.0.0")),
            Installation(
                port: "shipwright", release: Sample.shipwright930, channel: .stable,
                installedAt: Sample.date(2026, 10, 7), appName: "soh.app",
                previous: Release(port: "shipwright", version: "9.2.3", title: "Dewey Charlie")),
            Installation(
                port: "spaghettikart", release: Sample.latest("spaghettikart"), channel: .stable,
                installedAt: Sample.date(2026, 10, 23), appName: "Spaghettify.app"),
            Installation(
                port: "zelda64recomp", release: Sample.latest("zelda64recomp"), channel: .stable,
                installedAt: Sample.date(2026, 3, 2), appName: "Zelda64Recompiled.app"),
        ]
        return PreviewData(
            catalog: Sample.catalog,
            installations: installed,
            roms: [
                ROMRecord(
                    sha1: Sample.oot, game: "ocarina-of-time", name: "NTSC 1.0 (US)", format: "z64",
                    size: 33_554_432, added: Sample.date(2026, 4, 15),
                    originalFilename: "Legend of Zelda, The - Ocarina of Time (USA).z64"),
                ROMRecord(
                    sha1: Sample.mm, game: "majoras-mask", name: "NTSC (US)", format: "z64", size: 33_554_432,
                    added: Sample.date(2026, 3, 2), originalFilename: "Legend of Zelda, The - Majora's Mask (USA).z64"),
                ROMRecord(
                    sha1: Sample.sf64, game: "star-fox-64", name: "NTSC 1.1 (US)", format: "z64", size: 12_582_912,
                    added: Sample.date(2026, 10, 24), originalFilename: "Star Fox 64 (USA) (Rev 1).v64"),
                ROMRecord(
                    sha1: Sample.jak, game: "jak-and-daxter", name: "NTSC-U", format: "iso", size: 1_420_000_000,
                    added: Sample.date(2026, 9, 21), originalFilename: "Jak and Daxter - The Precursor Legacy (USA).iso"),
                ROMRecord(
                    sha1: Sample.jak2, game: "jak-ii", name: "NTSC-U", format: "iso", size: 4_480_000_000,
                    added: Sample.date(2026, 9, 22), originalFilename: "Jak II (USA).iso"),
                ROMRecord(
                    sha1: Sample.wonder, game: "super-mario-bros-wonder", name: "1.2.1", format: "nsp",
                    size: 4_630_000_000, added: Sample.date(2026, 10, 26), originalFilename: "Super Mario Bros. Wonder.nsp"),
                ROMRecord(
                    sha1: Sample.switchKeys, game: nil, platform: "switch", name: "Firmware 20", format: "keys",
                    size: 1_890, added: Sample.date(2026, 10, 26), originalFilename: "prod.keys"),
                ROMRecord(
                    sha1: Sample.switchFirmware, game: nil, platform: "switch", name: "20.1.0",
                    format: ROMRecord.folderFormat, size: 284_000_000, added: Sample.date(2026, 10, 26),
                    originalFilename: "Firmware 20.1.0"),
            ],
            releases: Sample.releases.values.sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) },
            updates: [
                "shipwright": Sample.latest("shipwright"), "opengoal-jak1": Sample.latest("opengoal-jak1"),
                "opengoal-jak2": Sample.latest("opengoal-jak2"),
            ],
            lastChecked: Sample.date(2026, 10, 24, hour: 9),
            running: ["2ship"],
            activities: [
                "starship": Activity(
                    kind: .install,
                    progress: ProgressUpdate(.building, fraction: 0.62, message: "Sandboxed build · no network"))
            ],
            unseeded: ["zelda64recomp": Sample.catalog.entry("zelda64recomp")?.requirements(for: .runtime) ?? []],
            snapshots: [
                "shipwright": [
                    Snapshot(
                        id: "2026-10-07T18-20-00Z", port: "shipwright", created: Sample.date(2026, 10, 7, hour: 18),
                        reason: .update, release: "9.2.3", target: "9.3.0", size: 3_480_000),
                    Snapshot(
                        id: "2026-04-15T20-05-00Z", port: "shipwright", created: Sample.date(2026, 4, 15, hour: 20),
                        reason: .update, release: "9.2.2", target: "9.2.3", size: 2_910_000),
                ],
                // Left from an earlier Installation, so its store page offers Delete Data….
                "ghostship": [
                    Snapshot(
                        id: "2026-09-08T19-10-00Z", port: "ghostship", created: Sample.date(2026, 9, 8, hour: 19),
                        reason: .update, release: "2.0.1", target: "3.0.0", size: 1_240_000)
                ],
            ],
            runs: ["shipwright": Sample.runs(paths: paths)],
            addedCatalogs: [Sample.addedCatalog]
        )
    }

    /// Nothing installed: Frontport opens on the Catalog.
    static func empty() -> PreviewData {
        PreviewData(
            catalog: Sample.catalog, installations: [], roms: [],
            releases: Sample.releases.values.sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) },
            updates: [:], lastChecked: nil, running: [], activities: [:], snapshots: [:], runs: [:])
    }
}

private enum Sample {
    static let oot = "ad69c91157f6705e8ab06c79fe08aad47bb57ba7"
    static let ootMasterQuest = "50bebedad9e0f10746a52b07239e47fa6c284d03"
    static let mm = "d6133ace5afaa0882cf214cf88daba39e266c078"
    static let mk64 = "579c48e211ae952530ffc8738709f078d5dd215e"
    static let sf64 = "09f0d105f476b00efa5303a3ebc42e60a7753b7a"
    static let sm64 = "9bef1128717f958171a4afac3ed78ee2bb4e86ce"
    static let bk = "1fe1632098865f639e22c11b9a81ee8f29c75d7a"
    static let alttp = "6d4f10a8b10e10dbe624cb23cf03b88bb8252973"
    static let jak = "4c5bbb2b0e8f3c4e1b2f6d3a9e7c1d0f5a8b6e2c"
    static let jak2 = "7d2e1f0a9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e"
    static let jak3 = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
    static let wonder = "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c"
    static let totk = "f0e1d2c3b4a5968778695a4b3c2d1e0ff0e1d2c3"
    static let totkEShop = "a69ed9952cd3eafcdb8bdabfa6d6e890656f0b1f"
    static let totkUpdate = "0f58226cc2cde91f1d97051b284fe0109824ef98"
    static let switchKeys = "5e4d3c2b1a0f9e8d7c6b5a4f3e2d1c0b9a8f7e6d"
    static let switchFirmware = "c0ffee00d15ea5e0b1e55ed0123456789abcdef0"

    static func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)) ?? .distantPast
    }

    /// Literals below are valid URLs.
    static func web(_ string: String) -> URL { URL(string: string)! }

    static func github(_ repo: String) -> URL { web("https://github.com/\(repo)") }

    static func release(
        _ port: PortID, _ version: String, tag: String? = nil, title: String? = nil, on published: Date,
        asset: String?, size: Int64 = 0, repo: String, notes: String
    ) -> Release {
        let tag = tag ?? version
        return Release(
            port: port, version: version, tag: tag, title: title, channel: .stable, published: published,
            notes: notes, notesURL: web("https://github.com/\(repo)/releases/tag/\(tag)"),
            asset: asset.map {
                ReleaseAsset(
                    name: $0, url: web("https://github.com/\(repo)/releases/download/\(tag)/\($0)"), size: size,
                    sha256: String(repeating: "0", count: 64))
            })
    }

    static func latest(_ port: PortID) -> Release { releases[port] ?? Release(port: port, version: "0") }

    static func openGOAL(_ port: PortID) -> Release {
        release(
            port, "0.3.9", tag: "v0.3.9", on: date(2026, 10, 15), asset: nil, repo: "open-goal/jak-project",
            notes: "Mostly Jak 3 fixes, including a glider crash and a stray minimap icon, plus missing hint subtitles in Jak 1 and a Polish translation.")
    }

    static func openGOAL038(_ port: PortID) -> Release {
        release(
            port, "0.3.8", tag: "v0.3.8", on: date(2026, 9, 20), asset: nil, repo: "open-goal/jak-project",
            notes: "Adds Apple silicon support.")
    }

    static func git(_ repo: String, _ ref: String, recipe: String) -> ReleaseSource {
        .git(GitSource(repo: repo, refs: [.stable: ref], recipe: recipe, recipeSHA256: String(repeating: "0", count: 64)))
    }

    /// One of OpenGOAL's Ports: the same Project and Recipe, built for one Game from its disc.
    static func openGOALPort(_ number: Int, game: GameID, name: String, rom: String, steamgriddb: Int) -> CatalogEntry {
        CatalogEntry(
            id: PortID("opengoal-jak\(number)"), name: "OpenGOAL", kind: .decomp, game: game, developer: "OpenGOAL",
            summary: "\(name), decompiled and rebuilt as a native game.",
            description: """
                OpenGOAL revives GOAL, the language the Jak and Daxter games were written in. It decompiles each game’s original code and rebuilds it with its own compiler, so the games run natively instead of in an emulator.

                Frontport builds each game from source in a sandbox, then makes its Assets from your disc and keeps them beside the app.
                """,
            website: web("https://opengoal.dev"), source: github("open-goal/jak-project"),
            bundleId: "dev.frontport.port.opengoal-jak\(number)",
            releases: git("open-goal/jak-project", "v0.3.9", recipe: "recipes/opengoal.sh"),
            requirements: [Requirement(label: name, stage: .build, oneOf: [rom])],
            artwork: Artwork(fallback: steamgriddb),
            buildAssets: BuildAssetsSpec(path: "Contents/Resources/data/out", format: "1"),
            tags: ["speedrun", "mods"])
    }

    static let switchKeysRequirement = Requirement(label: "Console keys", stage: .build, oneOf: [switchKeys])

    /// The Catalog the Switch Ports come from, added in Settings.
    static let addedCatalogURL = URL(string: "https://example.org/switch-ports/")!
    static let addedCatalog = CatalogSummary(
        catalog: AddedCatalog(url: addedCatalogURL, publicKey: "KxAbheFBGO3wliN2FA/1IjYOK0966LWddUtzt35+KK4=", added: date(2026, 10, 31)),
        name: "Switch Ports", ports: ["MacNativeGames", "nxnative for Super Mario Bros. Wonder", "nxnative for Tears of the Kingdom"], issued: date(2026, 10, 31))

    static let totkRequirements = [
        Requirement(label: "Tears of the Kingdom", stage: .build, oneOf: [totk, totkEShop]),
        Requirement(label: "Update 1.4.3", stage: .build, oneOf: [totkUpdate]),
        switchKeysRequirement,
    ]

    /// One of nxnative's Ports: a Switch game's own code, built from source with the game's files and console keys.
    static func nxnativePort(_ id: PortID, game: GameID, requirements: [Requirement], summary: String) -> CatalogEntry {
        CatalogEntry(
            id: id, name: "nxnative", kind: .recomp, game: game, developer: "seedds", summary: summary,
            description: "nxnative runs a Switch game’s own arm64 code natively: it rewrites the game’s code modules so they run outside a Switch, stands in for the Switch’s system with a host of its own, and translates the game’s graphics and shaders to Metal. Frontport builds it from source and makes the game files the app plays from your dump.",
            source: github("seedds/nxnative"), bundleId: "dev.frontport.port.\(id.rawValue)",
            releases: git("seedds/nxnative", "6a0687721a1da9a6a0273c6ce2f11eedcf4af445", recipe: "recipes/nxnative.sh"),
            requirements: requirements,
            codeSigning: CodeSigning(exceptions: ["allow-unsigned-executable-memory"]),
            buildAssets: BuildAssetsSpec(path: "Contents/Resources/game", format: "6a06877"), catalog: addedCatalogURL)
    }

    static let shipwright930 = release(
        "shipwright", "9.3.0", title: "Dewey Alfa", on: date(2026, 10, 7), asset: "SoH-Dewey-Alfa-Mac.zip",
        size: 47_100_000, repo: "HarbourMasters/Shipwright",
        notes: "New enhancements, randomizer additions and a reworked menu.")

    static let releases: [PortID: Release] = [
        "shipwright": release(
            "shipwright", "9.3.1", title: "Dewey Bravo", on: date(2026, 10, 18), asset: "SoH-Dewey-Bravo-Mac.zip",
            size: 47_200_000, repo: "HarbourMasters/Shipwright",
            notes: "A quiet patch after 9.3.0: crash and typo fixes, randomizer logic fixes, and a clearer win condition screen."),
        "opengoal-jak1": openGOAL("opengoal-jak1"),
        "opengoal-jak2": openGOAL("opengoal-jak2"),
        "opengoal-jak3": openGOAL("opengoal-jak3"),
        "ghostship": release(
            "ghostship", "3.0.0", on: date(2026, 9, 7), asset: "Ghostship-3.0.0-Mac.zip", size: 38_000_000,
            repo: "HarbourMasters/Ghostship",
            notes: "Adds a Vulkan renderer, custom post-processing shaders and HD textures, and fixes Metal texture stutter and blurry menu text on Retina displays."),
        "2ship": release(
            "2ship", "5.0.1", on: date(2026, 8, 25), asset: "2Ship-5.0.1-Mac.zip", size: 52_000_000,
            repo: "HarbourMasters/2ship2harkinian",
            notes: "Glitch-friendly cutscene tweaks, randomizer logic fixes and a long list of bug fixes, including old asset files left behind on macOS."),
        "banjorecomp": release(
            "banjorecomp", "1.0.2", tag: "v1.0.2", on: date(2026, 7, 31), asset: "BanjoRecompiled-v1.0.2-macOS.zip",
            size: 29_000_000, repo: "BanjoRecomp/BanjoRecomp",
            notes: "Jinjos are now saved like Notes, a major memory leak on macOS is fixed, and mods no longer crash at startup on ARM Macs."),
        "sm64coopdx": release(
            "sm64coopdx", "1.5.1", tag: "v1.5.1", on: date(2026, 6, 1), asset: "sm64coopdx_v1.5.1_macOS_ARM.zip",
            size: 33_000_000, repo: "coop-deluxe/sm64coopdx",
            notes: "Adds a button to reset control binds, and fixes multiplayer sync issues, a Yoshi crash and the auto updater."),
        "spaghettikart": release(
            "spaghettikart", "1.0.0", on: date(2026, 2, 25), asset: "Spaghetti-1.0.0-Mac.zip", size: 41_000_000,
            repo: "HarbourMasters/SpaghettiKart",
            notes: "Harder CPU racers, a digital speedometer and rulesets, smoother frame interpolation, and a Universal Binary for macOS."),
        "zelda64recomp": release(
            "zelda64recomp", "1.2.2", tag: "v1.2.2", on: date(2025, 8, 27), asset: "Zelda64Recompiled-v1.2.2-macOS.zip",
            size: 24_000_000, repo: "Zelda64Recomp/Zelda64Recomp",
            notes: "A hotfix for bad frame pacing on some multi-monitor setups."),
        "starship": release(
            "starship", "2.0.0", tag: "v2.0.0", on: date(2025, 5, 25), asset: nil, repo: "HarbourMasters/Starship",
            notes: "Generates its asset file at first launch, adds US, JP and EU 1.0 ROM support, and brings new cheats and better controller support."),
        "zelda3": release(
            "zelda3", "0.3", tag: "v0.3", on: date(2023, 8, 17), asset: nil, repo: "snesrev/zelda3",
            notes: "Plays straight from the ROM, with no extraction step."),
    ]

    static func runs(paths: AppPaths) -> [Run] {
        let port: PortID = "shipwright"
        let sessions: [(Date, String, TimeInterval, Bool)] = [
            (date(2026, 10, 17, hour: 20), "9.3.0", 72 * 60, false),
            (date(2026, 10, 15, hour: 21), "9.3.0", 48 * 60, false),
            (date(2026, 10, 12, hour: 19), "9.3.0", 3 * 60, true),
            (date(2026, 10, 9, hour: 18), "9.3.0", 125 * 60, false),
            (date(2026, 10, 5, hour: 17), "9.2.3", 25 * 60, false),
        ]
        return sessions.enumerated().map { index, session in
            let (started, release, duration, crashed) = session
            let id = "run-\(index)"
            return Run(
                id: id, port: port, release: release, started: started, ended: started + duration,
                exitStatus: crashed ? 11 : 0, signaled: crashed, log: paths.runLog(id, for: port))
        }
    }

    static func runtime(_ label: String, _ oneOf: [String], extras: [String] = [], seed: String) -> Requirement {
        Requirement(label: label, stage: .runtime, oneOf: oneOf, extras: extras, seedPath: "Library/Application Support/\(seed)/")
    }

    static func gitHub(_ repo: String, asset: String, channels: [Channel] = [.stable]) -> ReleaseSource {
        .githubRelease(GitHubReleaseSource(repo: repo, asset: asset, channels: channels))
    }

    /// Gives the sample Ports their first Releases, as the real Catalog has them.
    static func dated(_ catalog: CatalogDocument) -> CatalogDocument {
        var catalog = catalog
        let first: [PortID: Date] = [
            "shipwright": date(2022, 3, 22), "2ship": date(2024, 5, 27), "spaghettikart": date(2025, 11, 15),
            "starship": date(2024, 12, 22), "zelda64recomp": date(2024, 5, 10), "ghostship": date(2026, 1, 18),
            "opengoal-jak1": date(2022, 4, 3), "opengoal-jak2": date(2023, 11, 2), "opengoal-jak3": date(2026, 4, 1),
            "banjorecomp": date(2026, 1, 24), "sm64coopdx": date(2024, 7, 2), "zelda3": date(2023, 8, 17),
            "nxnative-wonder": date(2026, 10, 20), "nxnative-totk": date(2026, 10, 20),
            "macnativegames-totk": date(2026, 10, 25),
        ]
        for index in catalog.ports.indices {
            catalog.ports[index].firstRelease = first[catalog.ports[index].id]
        }
        return catalog
    }

    static let catalog = dated(CatalogDocument(
        issued: date(2026, 10, 24, hour: 6),
        platforms: [
            Platform(id: "n64", name: "Nintendo 64", shortName: "N64", medium: .cartridge),
            Platform(id: "snes", name: "Super Nintendo", shortName: "SNES", medium: .cartridge),
            Platform(id: "ps2", name: "PlayStation 2", shortName: "PS2", medium: .iso),
            Platform(id: "switch", name: "Nintendo Switch", shortName: "Switch", medium: .cartridge),
        ],
        genres: [
            Genre(id: "platformer", name: "Platformer"),
            Genre(id: "adventure", name: "Adventure"),
            Genre(id: "racing", name: "Racing"),
            Genre(id: "shooter", name: "Shooter"),
        ],
        games: [
            Game(id: "ocarina-of-time", name: "The Legend of Zelda: Ocarina of Time", shortName: "Ocarina of Time", platform: "n64", genres: ["adventure"], steamgriddb: 21202),
            Game(id: "majoras-mask", name: "The Legend of Zelda: Majora’s Mask", shortName: "Majora’s Mask", platform: "n64", genres: ["adventure"], steamgriddb: 34302),
            Game(id: "mario-kart-64", name: "Mario Kart 64", platform: "n64", genres: ["racing"], steamgriddb: 21164),
            Game(id: "star-fox-64", name: "Star Fox 64", platform: "n64", genres: ["shooter"], steamgriddb: 36615),
            Game(id: "super-mario-64", name: "Super Mario 64", platform: "n64", genres: ["platformer"], steamgriddb: 37177),
            Game(id: "jak-and-daxter", name: "Jak and Daxter: The Precursor Legacy", shortName: "Jak and Daxter", platform: "ps2", genres: ["platformer"], steamgriddb: 37452),
            Game(id: "jak-ii", name: "Jak II", platform: "ps2", genres: ["platformer"], steamgriddb: 36801),
            Game(id: "jak-3", name: "Jak 3", platform: "ps2", genres: ["platformer"], steamgriddb: 35757),
            Game(id: "super-mario-bros-wonder", name: "Super Mario Bros. Wonder", shortName: "Mario Wonder", platform: "switch", genres: ["platformer"], steamgriddb: 5409928),
            Game(id: "tears-of-the-kingdom", name: "The Legend of Zelda: Tears of the Kingdom", shortName: "Tears of the Kingdom", platform: "switch", genres: ["adventure"], steamgriddb: 5303117),
            Game(id: "banjo-kazooie", name: "Banjo-Kazooie", platform: "n64", genres: ["platformer"], steamgriddb: 35564),
            Game(id: "a-link-to-the-past", name: "The Legend of Zelda: A Link to the Past", shortName: "A Link to the Past", platform: "snes", genres: ["adventure"], steamgriddb: 38124),
        ],
        roms: [
            KnownROM(sha1: oot, game: "ocarina-of-time", name: "NTSC 1.0 (US)", format: "z64"),
            KnownROM(sha1: ootMasterQuest, game: "ocarina-of-time", name: "Master Quest (US, GameCube)", format: "z64"),
            KnownROM(sha1: mm, game: "majoras-mask", name: "NTSC (US)", format: "z64"),
            KnownROM(sha1: mk64, game: "mario-kart-64", name: "NTSC (US)", format: "z64"),
            KnownROM(sha1: sf64, game: "star-fox-64", name: "NTSC 1.1 (US)", format: "z64"),
            KnownROM(sha1: sm64, game: "super-mario-64", name: "NTSC (US)", format: "z64"),
            KnownROM(sha1: bk, game: "banjo-kazooie", name: "NTSC 1.0 (US)", format: "z64"),
            KnownROM(sha1: alttp, game: "a-link-to-the-past", name: "NTSC (US)", format: "sfc"),
            KnownROM(sha1: jak, game: "jak-and-daxter", name: "NTSC-U", format: "iso"),
            KnownROM(sha1: jak2, game: "jak-ii", name: "NTSC-U", format: "iso"),
            KnownROM(sha1: jak3, game: "jak-3", name: "NTSC-U", format: "iso"),
            KnownROM(sha1: wonder, game: "super-mario-bros-wonder", name: "1.2.1", format: "nsp", type: .update),
            KnownROM(sha1: totk, game: "tears-of-the-kingdom", name: "1.0.0 (game card)", format: "nsp"),
            KnownROM(sha1: totkEShop, game: "tears-of-the-kingdom", name: "1.0.0 (eShop)", format: "nsp"),
            KnownROM(
                sha1: totkUpdate, game: "tears-of-the-kingdom", name: "Update 1.4.3 (eShop)", format: "nsp", type: .update),
            KnownROM(sha1: switchKeys, game: nil, platform: "switch", name: "Firmware 20", format: "keys"),
            KnownROM(sha1: switchFirmware, game: nil, platform: "switch", name: "20.1.0", format: ROMRecord.folderFormat),
        ],
        ports: [
            CatalogEntry(
                id: "shipwright", name: "Ship of Harkinian", kind: .decomp, game: "ocarina-of-time",
                developer: "HarbourMasters",
                summary: "Ocarina of Time, rebuilt from its decompiled source to run natively on the Mac, with higher frame rates, optional enhancements and a built-in randomizer.",
                description: """
                    Ship of Harkinian is a native port of Ocarina of Time, built from the community’s decompilation of the original game. It ships none of the game’s data: you add your own ROM, and the Port makes its Assets from it on first launch.

                    It runs at your display’s frame rate and resolution, and adds enhancements, cheats and a built-in randomizer. Every change to the original behavior sits behind a toggle, so you can still play it as it was in 1998.
                    """,
                website: web("https://www.shipofharkinian.com"), source: github("HarbourMasters/Shipwright"),
                bundleId: "dev.frontport.port.shipwright",
                releases: gitHub("HarbourMasters/Shipwright", asset: "SoH-*-Mac.zip", channels: [.stable, .nightly]),
                requirements: [runtime("Ocarina of Time", [oot], extras: [ootMasterQuest], seed: "com.shipofharkinian.soh")],
                artwork: Artwork(steamgriddb: 5335518, fallback: 21202)),
            CatalogEntry(
                id: "2ship", name: "2 Ship 2 Harkinian", kind: .decomp, game: "majoras-mask", developer: "HarbourMasters",
                summary: "Majora’s Mask, rebuilt from its decompiled source to run natively on the Mac, with enhancements and a randomizer.",
                description: "2 Ship 2 Harkinian is a native port of Majora’s Mask built from its decompilation. Add your own ROM and it makes its Assets on first launch.",
                source: github("HarbourMasters/2ship2harkinian"),
                bundleId: "dev.frontport.port.2ship",
                releases: gitHub("HarbourMasters/2ship2harkinian", asset: "2Ship-*-Mac.zip"),
                requirements: [runtime("Majora’s Mask", [mm], seed: "com.2ship2harkinian.2s2h")],
                artwork: Artwork(steamgriddb: 5453061, fallback: 34302)),
            CatalogEntry(
                id: "spaghettikart", name: "SpaghettiKart", kind: .decomp, game: "mario-kart-64", developer: "HarbourMasters",
                summary: "Mario Kart 64 running natively on the Mac, with widescreen, high frame rates and custom tracks.",
                description: "SpaghettiKart is a native port of Mario Kart 64 built from its decompilation.",
                source: github("HarbourMasters/SpaghettiKart"), bundleId: "dev.frontport.port.spaghettikart",
                releases: gitHub("HarbourMasters/SpaghettiKart", asset: "Spaghetti-*-Mac.zip"),
                requirements: [runtime("Mario Kart 64", [mk64], seed: "SpaghettiKart")],
                artwork: Artwork(steamgriddb: 5493024, fallback: 21164)),
            CatalogEntry(
                id: "starship", name: "Starship", kind: .decomp, game: "star-fox-64", developer: "HarbourMasters",
                summary: "Star Fox 64, rebuilt from its decompiled source, with high frame rates and widescreen.",
                description: "Starship is a native port of Star Fox 64. Frontport builds it from source in a sandbox, with no network during the build.",
                source: github("HarbourMasters/Starship"), bundleId: "dev.frontport.port.starship",
                releases: .git(GitSource(
                    repo: "HarbourMasters/Starship", refs: [.stable: "v2.0.0"], recipe: "recipes/starship.sh",
                    recipeSHA256: String(repeating: "0", count: 64))),
                requirements: [Requirement(label: "Star Fox 64", stage: .build, oneOf: [sf64])],
                artwork: Artwork(fallback: 36615),
                buildAssets: BuildAssetsSpec(path: "Contents/Resources/sf64.o2r", format: "1")),
            CatalogEntry(
                id: "zelda64recomp", name: "Zelda 64: Recompiled", kind: .recomp, game: "majoras-mask",
                developer: "Zelda64Recomp",
                summary: "Majora’s Mask, statically recompiled to native code, with high frame rates, widescreen and mod support.",
                description: "Zelda 64: Recompiled translates Majora’s Mask’s original machine code into native code for the Mac.",
                source: github("Zelda64Recomp/Zelda64Recomp"), bundleId: "dev.frontport.port.zelda64recomp",
                releases: gitHub("Zelda64Recomp/Zelda64Recomp", asset: "*-macOS.zip"),
                requirements: [runtime("Majora’s Mask", [mm], seed: "Zelda64Recompiled")],
                artwork: Artwork(steamgriddb: 5451974, fallback: 34302),
                codeSigning: CodeSigning(exceptions: ["allow-jit", "disable-library-validation"])),
            CatalogEntry(
                id: "ghostship", name: "Ghostship", kind: .decomp, game: "super-mario-64", developer: "HarbourMasters",
                summary: "HarbourMasters’ native port of Super Mario 64, built from its decompilation, with a Vulkan and Metal renderer, custom shaders and HD texture support.",
                description: "Ghostship is a native port of Super Mario 64 built from its decompilation.",
                source: github("HarbourMasters/Ghostship"), bundleId: "dev.frontport.port.ghostship",
                releases: gitHub("HarbourMasters/Ghostship", asset: "Ghostship-*-Mac.zip"),
                requirements: [runtime("Super Mario 64", [sm64], seed: "Ghostship")],
                artwork: Artwork(steamgriddb: 5515765, fallback: 37177)),
            openGOALPort(1, game: "jak-and-daxter", name: "Jak and Daxter", rom: jak, steamgriddb: 37452),
            openGOALPort(2, game: "jak-ii", name: "Jak II", rom: jak2, steamgriddb: 36801),
            openGOALPort(3, game: "jak-3", name: "Jak 3", rom: jak3, steamgriddb: 35757),
            CatalogEntry(
                id: "banjorecomp", name: "Banjo: Recompiled", kind: .recomp, game: "banjo-kazooie", developer: "BanjoRecomp",
                summary: "Banjo-Kazooie, statically recompiled to native code, with widescreen and mod support.",
                description: "Banjo: Recompiled translates Banjo-Kazooie’s original machine code into native code for the Mac.",
                source: github("BanjoRecomp/BanjoRecomp"), bundleId: "dev.frontport.port.banjorecomp",
                releases: gitHub("BanjoRecomp/BanjoRecomp", asset: "*-macOS.zip"),
                requirements: [runtime("Banjo-Kazooie", [bk], seed: "BanjoRecompiled")],
                artwork: Artwork(steamgriddb: 5515330, fallback: 35564),
                codeSigning: CodeSigning(exceptions: ["allow-jit"])),
            CatalogEntry(
                id: "sm64coopdx", name: "sm64coopdx", kind: .decomp, game: "super-mario-64", developer: "coop-deluxe",
                summary: "Online multiplayer Super Mario 64 for up to 16 players, built from its decompilation.",
                description: "sm64coopdx is an online co-op port of Super Mario 64. It needs the network to play together.",
                website: web("https://sm64coopdx.com"), source: github("coop-deluxe/sm64coopdx"),
                bundleId: "dev.frontport.port.sm64coopdx",
                releases: gitHub("coop-deluxe/sm64coopdx", asset: "sm64coopdx_*_macOS*.zip"),
                requirements: [runtime("Super Mario 64", [sm64], seed: "sm64coopdx")],
                permissions: Permissions(network: true),
                artwork: Artwork(steamgriddb: 5440143, fallback: 37177),
                tags: ["multiplayer"]),
            CatalogEntry(
                id: "zelda3", name: "zelda3", kind: .decomp, game: "a-link-to-the-past", developer: "snesrev",
                summary: "A Link to the Past, reimplemented in C from its reverse-engineered code.",
                description: "zelda3 is a C reimplementation of A Link to the Past. Frontport builds it from source and makes its Assets from your ROM while building.",
                source: github("snesrev/zelda3"), bundleId: "dev.frontport.port.zelda3",
                releases: .git(GitSource(
                    repo: "snesrev/zelda3", refs: [.stable: "v0.3"], recipe: "recipes/zelda3.sh",
                    recipeSHA256: String(repeating: "0", count: 64))),
                requirements: [Requirement(label: "A Link to the Past", stage: .build, oneOf: [alttp])],
                artwork: Artwork(fallback: 38124),
                buildAssets: BuildAssetsSpec(path: "Contents/Resources/zelda3_assets.dat", format: "1")),
            nxnativePort(
                "nxnative-wonder", game: "super-mario-bros-wonder",
                requirements: [
                    Requirement(label: "Super Mario Bros. Wonder", stage: .build, oneOf: [wonder]), switchKeysRequirement,
                ],
                summary: "Super Mario Bros. Wonder’s own code, running natively on the Mac."),
            nxnativePort(
                "nxnative-totk", game: "tears-of-the-kingdom", requirements: totkRequirements,
                summary: "Tears of the Kingdom’s own code, running natively on the Mac at 60 fps."),
            CatalogEntry(
                id: "macnativegames-totk", name: "MacNativeGames", kind: .recomp, game: "tears-of-the-kingdom",
                developer: "ly05010419",
                summary: "Tears of the Kingdom’s own code on the Mac, its graphics rebuilt on Metal.",
                description: "MacNativeGames links Tears of the Kingdom’s own code into a native Mac launcher and rebuilds its graphics on Metal. Frontport builds it from source and makes the game files it plays from your dump, console keys and firmware.",
                source: github("ly05010419/MacNativeGames"), bundleId: "dev.frontport.port.macnativegames-totk",
                releases: git("ly05010419/MacNativeGames", "4b3fc724f9c84fa7273dee4016932c820d9e9b19", recipe: "recipes/macnativegames.sh"),
                requirements: totkRequirements + [Requirement(label: "Firmware", stage: .build, oneOf: [switchFirmware])],
                codeSigning: CodeSigning(exceptions: ["allow-unsigned-executable-memory"]),
                buildAssets: BuildAssetsSpec(path: "Contents/Resources/totk", format: "4b3fc72"),
                tags: ["60fps", "widescreen", "gyro"], catalog: addedCatalogURL),
        ]
    ))
}
