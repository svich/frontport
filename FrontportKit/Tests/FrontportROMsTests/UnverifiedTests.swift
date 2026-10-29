import Foundation
import FrontportCore
import Testing
@testable import FrontportROMs

/// Files whose hash the Catalog doesn't list, kept Unverified as the ROM the user chose (ADR 0011).
@Suite struct UnverifiedTests {
    let z64 = Synthetic.z64(size: 1 << 20)
    var hack: Data {
        var hack = z64
        hack[0x1000] ^= 0xFF
        return hack
    }

    @Test func keepsAFileAsTheROMChosenForIt() async throws {
        let tmp = try TemporaryDirectory()
        let sha1 = Synthetic.sha1(z64)
        let catalog = Catalogs.accepting([sha1])
        let file = try tmp.file("hack.z64", hack)
        let store = ROMStore(paths: tmp.paths)

        let record = try #require(await store.assign(file, as: sha1, catalog: catalog).first?.addedRecord)

        #expect(record.sha1 == sha1 && record.ownSHA1 == Synthetic.sha1(hack) && record.isUnverified)
        #expect(record.fileSHA1 == Synthetic.sha1(hack))
        #expect(record.name == "Dump 0" && record.game == "ocarina-of-time" && record.originalFilename == "hack.z64")
        let stored = tmp.paths.rom(sha1, format: "z64")
        #expect(try Data(contentsOf: stored) == hack)
        #expect(try mode(of: stored) == 0o444)
        #expect(await ROMStore(paths: tmp.paths).records() == [record])

        // The same file again is already there, whether added or chosen for again.
        #expect(await store.add([file], catalog: catalog).first?.duplicateRecord == record)
        #expect(await store.assign(file, as: sha1, catalog: catalog).first?.duplicateRecord == record)
    }

    @Test func aROMTheCatalogListsTakesTheUnverifiedOnesPlace() async throws {
        let tmp = try TemporaryDirectory()
        let sha1 = Synthetic.sha1(z64)
        let catalog = Catalogs.accepting([sha1])
        let store = ROMStore(paths: tmp.paths)
        _ = await store.assign(try tmp.file("hack.z64", hack), as: sha1, catalog: catalog)

        let record = try #require(await store.add([try tmp.file("zelda.z64", z64)], catalog: catalog).first?.addedRecord)

        #expect(record.sha1 == sha1 && !record.isUnverified)
        #expect(await store.records() == [record])
        #expect(try Data(contentsOf: tmp.paths.rom(sha1, format: "z64")) == z64)
        // Nothing takes a listed ROM's place.
        let again = await store.assign(try tmp.file("hack.z64", hack), as: sha1, catalog: catalog)
        #expect(again.first?.duplicateRecord == record)
    }

    @Test func aListedFileChosenForAnotherROMIsAddedAsItself() async throws {
        let tmp = try TemporaryDirectory()
        let other = Synthetic.z64(size: 1 << 20, seed: 9)
        let catalog = Catalogs.accepting([Synthetic.sha1(z64), Synthetic.sha1(other)])
        let store = ROMStore(paths: tmp.paths)

        let results = await store.assign(try tmp.file("zelda.z64", z64), as: Synthetic.sha1(other), catalog: catalog)

        #expect(results.first?.addedRecord?.sha1 == Synthetic.sha1(z64))
        #expect(results.first?.addedRecord?.isUnverified == false)
    }

    @Test func refusesAROMTheFileCantBe() async throws {
        let tmp = try TemporaryDirectory()
        let sfc = Synthetic.sfc()
        var catalog = Catalogs.accepting([Synthetic.sha1(z64)])
        catalog.roms.append(KnownROM(sha1: Synthetic.sha1(sfc), game: "ocarina-of-time", name: "SNES", format: "sfc"))
        catalog.ports[0].requirements[0].oneOf.append(Synthetic.sha1(sfc))
        let store = ROMStore(paths: tmp.paths)
        let file = try tmp.file("hack.z64", hack)

        for target in [Synthetic.sha1(sfc), "0000000000000000000000000000000000000000"] {
            let rejection = try #require(await store.assign(file, as: target, catalog: catalog).first?.rejection)
            #expect(rejection.sha1 == Synthetic.sha1(hack))
        }
        #expect(await store.records().isEmpty)
    }

    /// Only ROMs a Requirement accepts, of the file's format or another Switch container, and never console keys,
    /// firmware or an Installer.
    @Test func theCatalogOffersOnlyWhatAFileCanBe() {
        var catalog = Catalogs.accepting(["aa"], format: "nsp")
        catalog.roms += [
            KnownROM(sha1: "bb", game: "ocarina-of-time", name: "Card", format: "xci"),
            KnownROM(sha1: "cc", game: nil, platform: "n64", name: "Keys", format: "keys"),
            KnownROM(sha1: "dd", game: nil, platform: "n64", name: "Firmware", format: ROMRecord.folderFormat),
            KnownROM(
                sha1: "ee", game: "ocarina-of-time", name: "Setup", format: "exe",
                unpack: Unpack(recipe: "recipes/x.sh", recipeSHA256: "", yields: [])),
            KnownROM(sha1: "ff", game: "ocarina-of-time", name: "Unaccepted", format: "nsp"),
        ]
        catalog.ports[0].requirements[0].oneOf += ["bb", "cc", "dd", "ee"]

        for format in ["nsp", "xci", "nsz", "xcz"] {
            #expect(catalog.assignable(format: format).map(\.sha1) == ["aa", "bb"])
        }
        #expect(catalog.assignable(format: "keys").isEmpty)
        #expect(catalog.assignable(format: "z64").isEmpty)
        #expect(catalog.assignable(format: ROMRecord.folderFormat).isEmpty)
    }

    /// An NSZ is kept compressed, as `<sha1>.nsz`, until the NSP it was made from takes its place.
    @Test func anNSZIsKeptAsTheNSPChosenForIt() async throws {
        let tmp = try TemporaryDirectory()
        let ncas = SyntheticSwitch.ncas
        let compressed = Synthetic.noise(40_000, seed: 8)
        let nsz = try tmp.file(
            "game.nsz",
            SyntheticSwitch.nsp([(String(SyntheticSwitch.name(SyntheticSwitch.program).prefix(32)) + ".ncz", compressed)] + ncas.dropFirst()))
        let catalog = Catalogs.accepting([SyntheticSwitch.identity], format: "nsp")
        let store = ROMStore(paths: tmp.paths)

        let unknown = try #require(await store.add([nsz], catalog: catalog).first?.unknown)
        #expect(unknown.format == "nsz")
        #expect(unknown.reason.contains("nsz"))
        let record = try #require(await store.assign(nsz, as: SyntheticSwitch.identity, catalog: catalog).first?.addedRecord)
        #expect(record.format == "nsz" && record.ownSHA1 == unknown.sha1)
        #expect(FileOperations.exists(tmp.paths.rom(SyntheticSwitch.identity, format: "nsz")))

        let nsp = try tmp.file("game.nsp", SyntheticSwitch.nsp(ncas))
        #expect(await store.add([nsp], catalog: catalog).first?.addedRecord?.format == "nsp")
        #expect(!FileOperations.exists(tmp.paths.rom(SyntheticSwitch.identity, format: "nsz")))
    }

    /// Seeded under the ROM's name but tagged with the file's own hash, so a listed ROM that takes its place is Seeded
    /// over it.
    @Test func aSeededUnverifiedROMGivesWayToTheListedOne() async throws {
        let tmp = try TemporaryDirectory()
        let sha1 = Synthetic.sha1(z64)
        let catalog = Catalogs.accepting([sha1])
        let entry = catalog.ports[0]
        let store = ROMStore(paths: tmp.paths)
        let data = tmp.paths.data(for: entry.bundleId)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let installed = [entry.id: Catalogs.installation(entry)]
        func state() async throws -> RequirementState {
            try #require(await store.matching([entry], installations: installed)[entry.id]?.requirements.first)
        }
        _ = await store.assign(try tmp.file("hack.z64", hack), as: sha1, catalog: catalog)

        try await store.seed(entry)

        let seeded = data.appending(path: "roms/\(sha1).z64")
        #expect(try Data(contentsOf: seeded) == hack)
        #expect(tag(seeded) == Synthetic.sha1(hack))
        #expect(try await state().accepted == .seeded)

        _ = await store.add([try tmp.file("zelda.z64", z64)], catalog: catalog)
        #expect(try await state().accepted == .unseeded)
        try await store.seed(entry)
        #expect(try Data(contentsOf: seeded) == z64)
        #expect(try await state().accepted == .seeded)
    }

    func tag(_ url: URL) -> String? {
        FileOperations.extendedAttribute(Seeding.tag, at: url).map { String(decoding: $0, as: UTF8.self) }
    }
}
