import Foundation
import Testing
@testable import FrontportCore

/// What Seeding on a Device copies, given what the Device holds and the record says.
@Suite struct DeviceSeedingPlanTests {
    static let rom = StagedSeed(
        label: "Super Mario 64", sha1: "aaa", fileSHA1: "aaa", path: "Documents/sm64.z64",
        files: [DeviceFile(path: "Documents/sm64.z64", isDirectory: false, size: 8)])
    static let folder = StagedSeed(
        label: "Fallout", sha1: "fff", fileSHA1: "fff", path: "Documents",
        files: [
            DeviceFile(path: "Documents/MASTER.DAT", isDirectory: false, size: 100),
            DeviceFile(path: "Documents/DATA/TEXT.TXT", isDirectory: false, size: 5),
        ],
        marker: "fff\n")

    static func file(_ path: String, size: Int64 = 8) -> DeviceFile { DeviceFile(path: path, isDirectory: false, size: size) }

    @Test func aFileROMIsSkippedOnlyWithItsNameItsSizeAndTheRecord() {
        let there = DeviceListing(files: [Self.file("Documents/sm64.z64")])
        let seeded = ["Super Mario 64": ["aaa"]]
        #expect(DeviceSeeding.plan([Self.rom], on: there, seeded: seeded).items.map(\.step) == [.seeded])

        // Missing, another size, a folder in its place, or not recorded: copied, over whatever is there.
        let copy = DeviceSeedingPlan.Step.copy(files: ["Documents/sm64.z64"], marker: nil)
        for (listing, record) in [
            (DeviceListing(), seeded),
            (DeviceListing(files: [Self.file("Documents/sm64.z64", size: 9)]), seeded),
            (DeviceListing(files: [DeviceFile(path: "Documents/sm64.z64", isDirectory: true, size: 8)]), seeded),
            (there, [:]),
            (there, ["Super Mario 64": ["bbb"]]),
            (there, ["Another label": ["aaa"]]),
        ] {
            let plan = DeviceSeeding.plan([Self.rom], on: listing, seeded: record)
            #expect(plan.items.map(\.step) == [copy])
            #expect(plan.files == ["Documents/sm64.z64"] && plan.markers.isEmpty && !plan.copiesNothing)
        }
    }

    @Test func aFolderROMGetsOnlyItsMissingFilesThenItsMarker() {
        let marker = "Documents/.frontport-rom"
        // Nothing there: every file, then the marker.
        let empty = DeviceSeeding.plan([Self.folder], on: DeviceListing(), seeded: [:])
        #expect(empty.items.map(\.step) == [.copy(files: ["Documents/MASTER.DAT", "Documents/DATA/TEXT.TXT"], marker: marker)])
        #expect(empty.files == ["Documents/MASTER.DAT", "Documents/DATA/TEXT.TXT"] && empty.markers == [marker])

        // Its own folder with a file gone: that file only; the marker is there already.
        let own = DeviceListing(
            files: [Self.file(marker), Self.file("Documents/MASTER.DAT", size: 999), Self.file("Documents/SAVEGAME/SLOT01")],
            markers: [marker: "fff"])
        #expect(DeviceSeeding.plan([Self.folder], on: own, seeded: [:]).items.map(\.step) == [
            .copy(files: ["Documents/DATA/TEXT.TXT"], marker: nil)
        ])

        // Complete and marked as its own: Seeded, whatever the record says and whatever the Port rewrote.
        var complete = own
        complete.files["Documents/DATA/TEXT.TXT"] = Self.file("Documents/DATA/TEXT.TXT", size: 1)
        let plan = DeviceSeeding.plan([Self.folder], on: complete, seeded: [:])
        #expect(plan.items.map(\.step) == [.seeded] && plan.copiesNothing)
    }

    @Test func aFolderWithoutAMarkerIsFilledInNeverOverwritten() {
        let listing = DeviceListing(files: [Self.file("Documents/MASTER.DAT", size: 1), Self.file("Documents/notes.txt")])
        #expect(DeviceSeeding.plan([Self.folder], on: listing, seeded: ["Fallout": ["fff"]]).items.map(\.step) == [
            .copy(files: ["Documents/DATA/TEXT.TXT"], marker: "Documents/.frontport-rom")
        ])
    }

    @Test func aLinkTheDeviceHasCountsAsThereButIsNeverTheROM() {
        // A link the Port made in place of one of the folder's files: left as it is.
        let link = DeviceFile(path: "Documents/MASTER.DAT", isDirectory: false, size: 100, isLink: true)
        #expect(DeviceSeeding.plan([Self.folder], on: DeviceListing(files: [link]), seeded: [:]).items.map(\.step) == [
            .copy(files: ["Documents/DATA/TEXT.TXT"], marker: "Documents/.frontport-rom")
        ])
        // At a file ROM's path, even of its size and recorded: copied over.
        let there = DeviceListing(files: [DeviceFile(path: "Documents/sm64.z64", isDirectory: false, size: 8, isLink: true)])
        #expect(DeviceSeeding.plan([Self.rom], on: there, seeded: ["Super Mario 64": ["aaa"]]).items.map(\.step) == [
            .copy(files: ["Documents/sm64.z64"], marker: nil)
        ])
    }

    @Test func aFileCutShortWhileTheFolderHasNoMarkerIsCopiedAgain() {
        let marker = "Documents/.frontport-rom"
        let filling = ["Documents/MASTER.DAT", "Documents/DATA/TEXT.TXT"]
        let short = DeviceListing(files: [Self.file("Documents/MASTER.DAT", size: 40), Self.file("Documents/DATA/TEXT.TXT", size: 5)])
        let copied = DeviceSeeding.plan([Self.folder], on: short, seeded: [:], filling: filling)
        #expect(copied.items.map(\.step) == [.copy(files: ["Documents/MASTER.DAT"], marker: marker)])
        #expect(copied.folderFiles == ["Documents/MASTER.DAT"])

        // Not one Seeding was copying, longer than the ROM's, a link, or in a folder its marker says is filled: kept.
        #expect(DeviceSeeding.plan([Self.folder], on: short, seeded: [:]).items.map(\.step) == [.copy(files: [], marker: marker)])
        let longer = DeviceListing(files: [Self.file("Documents/MASTER.DAT", size: 400), Self.file("Documents/DATA/TEXT.TXT", size: 5)])
        #expect(DeviceSeeding.plan([Self.folder], on: longer, seeded: [:], filling: filling).items.map(\.step) == [
            .copy(files: [], marker: marker)
        ])
        let link = DeviceListing(files: [
            DeviceFile(path: "Documents/MASTER.DAT", isDirectory: false, size: 40, isLink: true), Self.file("Documents/DATA/TEXT.TXT", size: 5),
        ])
        #expect(DeviceSeeding.plan([Self.folder], on: link, seeded: [:], filling: filling).items.map(\.step) == [
            .copy(files: [], marker: marker)
        ])
        var marked = short
        marked.files[marker] = Self.file(marker)
        marked.markers[marker] = "fff"
        #expect(DeviceSeeding.plan([Self.folder], on: marked, seeded: [:], filling: filling).items.map(\.step) == [.seeded])

        // A file ROM is copied whatever its size: `filling` is only the folders'.
        #expect(DeviceSeeding.plan([Self.rom], on: DeviceListing(), seeded: [:]).folderFiles.isEmpty)
    }

    @Test func aFolderMarkedAsAnotherROMsIsLeftAlone() {
        let listing = DeviceListing(files: [Self.file("Documents/.frontport-rom")], markers: ["Documents/.frontport-rom": "demo"])
        let plan = DeviceSeeding.plan([Self.folder, Self.rom], on: listing, seeded: [:])
        #expect(plan.items.map(\.step) == [.heldBy("demo"), .copy(files: ["Documents/sm64.z64"], marker: nil)])
        #expect(plan.held == [Self.folder])
        #expect(plan.files == ["Documents/sm64.z64"] && plan.markers.isEmpty, "nothing of the folder")
    }

    @Test func theRecordKeepsWhatIsThereAndWhatWasntStaged() {
        let listing = DeviceListing(files: [Self.file("Documents/.frontport-rom")], markers: ["Documents/.frontport-rom": "demo"])
        let plan = DeviceSeeding.plan([Self.folder, Self.rom], on: listing, seeded: ["Super Mario 64": ["old"], "Other": ["ooo"]])
        // Carried out, the file is copied; the held folder gets nothing.
        #expect(plan.carriedOut(over: ["Super Mario 64": ["old"], "Other": ["ooo"]]) == ["Super Mario 64": ["aaa"], "Other": ["ooo"]])
        // As found, nothing staged is there yet.
        #expect(plan.found(over: ["Super Mario 64": ["old"], "Other": ["ooo"]]) == ["Other": ["ooo"]])

        let done = DeviceSeeding.plan([Self.rom], on: DeviceListing(files: [Self.file("Documents/sm64.z64")]), seeded: ["Super Mario 64": ["aaa"]])
        #expect(done.found(over: [:]) == ["Super Mario 64": ["aaa"]])
    }
}

/// Where each Runtime Requirement on iOS stands on one Device.
@Suite struct DeviceMatchingTests {
    static let sm64 = Requirement(label: "Super Mario 64", stage: .runtime, oneOf: ["aaa", "bbb"], seedPath: "roms/sm64.z64")
    static let build = Requirement(label: "Assets", stage: .build, oneOf: ["ccc"])
    static let macOnly = Requirement(label: "Mac only", stage: .runtime, oneOf: ["ddd"], seedPath: "roms/")

    static let entry = CatalogEntry(
        id: "ghostship", name: "Ghostship", kind: .decomp, game: "super-mario-64", developer: "Tests", summary: "",
        description: "", source: URL(string: "https://github.com/tests/ghostship")!, bundleId: "dev.frontport.port.ghostship",
        releases: .githubRelease(GitHubReleaseSource(repo: "tests/ghostship", asset: "*-Mac.zip")),
        requirements: [build, sm64, macOnly],
        ios: IOSSpec(
            releases: .githubRelease(GitHubReleaseSource(repo: "tests/ghostship", asset: "*-iOS.zip")),
            seedPaths: [nil, "Documents/sm64.z64", nil]))

    static func installation(seeded: [String: [String]]) -> DeviceInstallation {
        var installation = DeviceInstallationTests.installation(
            profileExpires: Date(timeIntervalSince1970: 1_900_000_000), certificateExpires: Date(timeIntervalSince1970: 1_900_000_000))
        installation.port = "ghostship"
        installation.seeded = seeded
        installation.entry = entry
        return installation
    }

    /// The Mac's reading: `rom` in ROMs for Super Mario 64, or none.
    static func matching(_ rom: String?) -> PortMatching {
        PortMatching(port: "ghostship", isInstalled: false, requirements: [
            RequirementState(requirement: build, rom: nil, accepted: .missing),
            RequirementState(requirement: sm64, rom: rom, accepted: rom == nil ? .missing : .inROMs),
            RequirementState(requirement: macOnly, rom: "ddd", accepted: .inROMs),
        ])
    }

    static let roms = [
        ROMRecord(sha1: "aaa", game: "super-mario-64", name: "US", format: "z64", size: 8, added: Date(), originalFilename: "a.z64"),
        ROMRecord(
            sha1: "bbb", game: "super-mario-64", name: "JP", format: "z64", size: 8, added: Date(), originalFilename: "b.z64",
            ownSHA1: "own"),
    ]

    static func state(
        _ rom: String?, seeded: [String: [String]], plan: DeviceSeedingPlan? = nil, reachable: Bool = true
    ) -> DeviceMatching {
        DeviceMatching(
            version: IOSVersion(entry)!, matching: matching(rom), roms: roms, installation: installation(seeded: seeded), plan: plan,
            isReachable: reachable)
    }

    static func plan(_ step: DeviceSeedingPlan.Step, fileSHA1: String = "aaa") -> DeviceSeedingPlan {
        DeviceSeedingPlan(items: [
            .init(
                seed: StagedSeed(label: "Super Mario 64", sha1: "aaa", fileSHA1: fileSHA1, path: "Documents/sm64.z64", files: []),
                step: step)
        ])
    }

    @Test func coversOnlyTheRuntimeRequirementsTheIOSVersionSeeds() {
        #expect(Self.state("aaa", seeded: [:]).requirements.map(\.requirement) == IOSVersion(Self.entry)?.requirements)
        #expect(Self.state("aaa", seeded: [:]).requirements.map(\.requirement.label) == ["Super Mario 64"])
    }

    @Test func fromTheRecordWhenThereIsNoPlan() {
        #expect(Self.state("aaa", seeded: ["Super Mario 64": ["aaa"]]).requirements.map(\.state) == [.seeded])
        #expect(Self.state("aaa", seeded: [:]).requirements.map(\.state) == [.unseeded])
        #expect(Self.state("aaa", seeded: [:]).hasUnseeded)
        // The Match changed to another ROM in ROMs: that one isn't there yet.
        #expect(Self.state("aaa", seeded: ["Super Mario 64": ["bbb"]]).requirements.map(\.state) == [.unseeded])
        // An Unverified ROM goes by its own SHA-1.
        #expect(Self.state("bbb", seeded: ["Super Mario 64": ["own"]]).requirements.map(\.state) == [.seeded])
        #expect(Self.state("bbb", seeded: ["Super Mario 64": ["bbb"]]).requirements.map(\.state) == [.unseeded])
    }

    @Test func missingOnlyWhenNoROMMatchesAndNoneWasSeeded() {
        #expect(Self.state(nil, seeded: [:]).requirements.map(\.state) == [.missing])
        #expect(Self.state(nil, seeded: [:]).requirements(.missing).map(\.label) == ["Super Mario 64"])
        // Removed from ROMs since: it stays on the Device.
        #expect(Self.state(nil, seeded: ["Super Mario 64": ["aaa"]]).requirements.map(\.state) == [.seeded])
    }

    @Test func thePlanReadFromTheDeviceDecidesWhileItsReachable() {
        let recorded = ["Super Mario 64": ["aaa"]]
        // Deleted on the Device, though the record says it's there.
        let deleted = Self.plan(.copy(files: ["Documents/sm64.z64"], marker: nil))
        #expect(Self.state("aaa", seeded: recorded, plan: deleted).requirements.map(\.state) == [.unseeded])
        #expect(Self.state("aaa", seeded: [:], plan: Self.plan(.seeded)).requirements.map(\.state) == [.seeded])
        #expect(Self.state("aaa", seeded: [:], plan: Self.plan(.heldBy("demo"))).requirements.map(\.state) == [.held])
        // A plan for another ROM than the Match says nothing of it: the record does.
        #expect(Self.state("aaa", seeded: recorded, plan: Self.plan(.seeded, fileSHA1: "zzz")).requirements.map(\.state) == [.seeded])

        // Away, the record alone, marked as last known.
        let away = Self.state("aaa", seeded: recorded, plan: deleted, reachable: false)
        #expect(away.requirements.map(\.state) == [.seeded] && away.isLastKnown)
        #expect(!Self.state("aaa", seeded: recorded, plan: deleted).isLastKnown)
    }
}

/// Whether a Port runs on a Device, as `devicectl` lists what runs there.
@Suite struct DeviceRunningTests {
    @Test func thePortRunsWhenAnExecutableInsideItsAppDoes() {
        let installation = DeviceInstallationTests.installation(
            profileExpires: Date(timeIntervalSince1970: 1_900_000_000), certificateExpires: Date(timeIntervalSince1970: 1_900_000_000))
        let app = URL(string: "file:///private/var/containers/Bundle/Application/4EDD/Tiny.app/Tiny")!
        let other = URL(string: "file:///private/var/containers/Bundle/Application/5EDD/Other.app/Tiny")!
        #expect(installation.isRunning(in: [30785: app, 1: URL(string: "file:///sbin/launchd")!]))
        #expect(!installation.isRunning(in: [30785: other, 1: URL(string: "file:///sbin/launchd")!]))
        #expect(!installation.isRunning(in: [:]))
    }
}

/// Seed on a Port's row for a Device.
@Suite struct DeviceSeedStatusTests {
    static func status(
        hasXcode: Bool = true, connection: DeviceReading.Connection = .wired, isLocked: Bool? = false,
        developerMode: Bool? = true, isRunning: Bool = false, activity: Activity.Kind? = nil, unseeded: Bool = true,
        installed: Bool = true
    ) -> DeviceStatus {
        let seeding = DeviceMatching(requirements: [
            .init(requirement: DeviceMatchingTests.sm64, state: unseeded ? .unseeded : .seeded)
        ])
        return DeviceStatus(
            reading: DeviceReading(
                device: DeviceStatusTests.iPhone, connection: connection, isLocked: isLocked, developerMode: developerMode),
            installation: installed ? DeviceStatusTests.installed : nil, hasXcode: hasXcode, activity: activity.map { Activity($0) },
            matching: seeding, upkeep: .init(wait: isRunning ? .running : nil))
    }

    @Test func offeredWhileARomInROMsIsntOnTheDevice() {
        #expect(Self.status().actions == [.seed, .uninstall])
        #expect(Self.status(unseeded: false).actions == [.uninstall])
        #expect(Self.status(unseeded: false).check(.seed) == .unavailable)
        #expect(Self.status(installed: false).actions.isEmpty)
        #expect(Self.status(installed: false).check(.seed) == .unavailable)
        #expect(Self.status(installed: false).seeding == nil && Self.status(installed: false).matching == nil)
    }

    @Test func reasonsComeInTheOrderTheUserFixesThem() {
        #expect(
            Self.status(hasXcode: false, connection: .away, isLocked: true, developerMode: false, isRunning: true, activity: .update)
                .check(.seed) == .disabled(.needsXcode))
        #expect(
            Self.status(connection: .away, isLocked: true, developerMode: false, isRunning: true, activity: .update)
                .check(.seed) == .disabled(.away))
        #expect(Self.status(isLocked: true, developerMode: false, isRunning: true, activity: .update).check(.seed) == .disabled(.locked))
        #expect(Self.status(developerMode: false, isRunning: true, activity: .update).check(.seed) == .disabled(.developerModeOff))
        #expect(Self.status(isRunning: true, activity: .update).check(.seed) == .disabled(.running))
        #expect(Self.status(activity: .device(.seed, DeviceStatusTests.iPhone.id)).check(.seed) == .disabled(.activity(.device(.seed, DeviceStatusTests.iPhone.id))))
        #expect(Self.status().check(.seed) == .allowed)
        // What wasn't read doesn't stand in the way.
        #expect(Self.status(isLocked: nil, developerMode: nil).allows(.seed))
    }

    @Test func uninstallIgnoresWhatOnlySeedingNeeds() {
        #expect(Self.status(isLocked: true, developerMode: false, isRunning: true).check(.uninstall) == .allowed)
    }
}
