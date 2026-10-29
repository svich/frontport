import Foundation
import FrontportCore
import Testing
@testable import FrontportROMs

@Suite struct ROMStoreTests {
    @Test func addsAcceptedROMInStandardForm() async throws {
        let tmp = try TemporaryDirectory()
        let z64 = Synthetic.z64()
        let sha1 = Synthetic.sha1(z64)
        let file = try tmp.file("Zelda (USA).v64", Synthetic.v64(z64))
        let store = ROMStore(paths: tmp.paths)

        let results = await store.add([file], catalog: Catalogs.accepting([sha1]))

        let record = try #require(results.first?.addedRecord)
        #expect(results.count == 1)
        #expect(record.sha1 == sha1)
        #expect(record.game == "ocarina-of-time")
        #expect(record.name == "Dump 0")
        #expect(record.format == "z64")
        #expect(record.size == Int64(z64.count))
        #expect(record.originalFilename == "Zelda (USA).v64")

        let stored = tmp.paths.rom(sha1, format: "z64")
        #expect(try Data(contentsOf: stored) == z64)
        #expect(try mode(of: stored) == 0o444)
        #expect(try mode(of: tmp.paths.roms) == 0o700)
        #expect(await store.file(for: sha1) == ROMFile(record: record, url: stored))

        // The index survives a new store.
        let reopened = ROMStore(paths: tmp.paths)
        #expect(await reopened.records() == [record])
        #expect(await reopened.record(for: sha1) == record)
    }

    @Test func storesUnconvertedFilesUntouched() async throws {
        let tmp = try TemporaryDirectory()
        let iso = Synthetic.noise(3 << 20, seed: 7)
        let sha1 = Synthetic.sha1(iso)
        let file = try tmp.file("Jak.iso", iso)
        try FileOperations.setExtendedAttribute(FileOperations.quarantineAttribute, Data("0081;0;Safari;".utf8), at: file)
        let store = ROMStore(paths: tmp.paths)

        let results = await store.add([file], catalog: Catalogs.accepting([sha1], game: "jak", format: "iso"))

        #expect(results.first?.addedRecord?.format == "iso")
        let stored = tmp.paths.rom(sha1, format: "iso")
        #expect(try Data(contentsOf: stored) == iso)
        #expect(FileOperations.extendedAttribute(FileOperations.quarantineAttribute, at: stored) == nil)
        #expect(try Data(contentsOf: file) == iso)  // the user's file is left alone
        #expect(try mode(of: file) == 0o644)
    }

    @Test func everyByteOrderIsTheSameROM() async throws {
        let tmp = try TemporaryDirectory()
        let z64 = Synthetic.z64()
        let catalog = Catalogs.accepting([Synthetic.sha1(z64)])
        let store = ROMStore(paths: tmp.paths)

        let results = await store.add(
            [
                try tmp.file("a.z64", z64),
                try tmp.file("b.v64", Synthetic.v64(z64)),
                try tmp.file("c.n64", Synthetic.n64(z64)),
            ], catalog: catalog)

        let record = try #require(results[0].addedRecord)
        #expect(results[1].duplicateRecord == record)
        #expect(results[2].duplicateRecord == record)
        #expect(await store.records().count == 1)
    }

    @Test func snesAndNESHeadersAreTheSameROM() async throws {
        let tmp = try TemporaryDirectory()
        let sfc = Synthetic.sfc()
        let nes = Synthetic.nes()
        let catalog = Catalogs.accepting([Synthetic.sha1(sfc), Synthetic.sha1(nes)])
        let store = ROMStore(paths: tmp.paths)

        let results = await store.add(
            [
                try tmp.file("zelda3.smc", Synthetic.copierHeadered(sfc)),
                try tmp.file("zelda3.sfc", sfc),
                try tmp.file("game.nes", Synthetic.iNES(nes)),
            ], catalog: catalog)

        #expect(results[0].addedRecord?.format == "sfc")
        #expect(results[1].duplicateRecord?.sha1 == Synthetic.sha1(sfc))
        #expect(results[2].addedRecord?.format == "nes")
        #expect(try Data(contentsOf: tmp.paths.rom(Synthetic.sha1(sfc), format: "sfc")) == sfc)
        #expect(try Data(contentsOf: tmp.paths.rom(Synthetic.sha1(nes), format: "nes")) == nes)
    }

    /// One it could be kept as, Unverified, is left to the user to choose (`UnverifiedTests`); nothing is stored.
    @Test func keepsNothingOfROMsTheCatalogDoesNotList() async throws {
        let tmp = try TemporaryDirectory()
        let z64 = Synthetic.z64()
        var hack = z64
        hack[0x1000] ^= 0xFF
        let store = ROMStore(paths: tmp.paths)

        let results = await store.add([try tmp.file("hack.z64", hack)], catalog: Catalogs.accepting([Synthetic.sha1(z64)]))

        let unknown = try #require(results.first?.unknown)
        #expect(unknown.sha1 == Synthetic.sha1(hack))
        #expect(unknown.format == "z64")
        #expect(unknown.reason == ROMStore.unlisted)
        #expect(await store.records().isEmpty)
        let left = try FileManager.default.contentsOfDirectory(atPath: tmp.paths.roms.path(percentEncoded: false))
        #expect(left.isEmpty)
    }

    /// The lint refuses a Requirement listing a hash `roms` doesn't name, so nothing would name the ROM: it's refused.
    @Test func rejectsAHashOnlyARequirementLists() async throws {
        let tmp = try TemporaryDirectory()
        let z64 = Synthetic.z64(size: 1 << 20)
        let sha1 = Synthetic.sha1(z64)
        let store = ROMStore(paths: tmp.paths)

        let results = await store.add(
            [try tmp.file("extra.z64", z64)], catalog: Catalogs.accepting([], requirementOnly: [sha1]))

        #expect(results.first?.rejection?.reason == ROMStore.notInCatalog)
        #expect(await store.records().isEmpty)
    }

    /// The DESIGN rule: a hash is accepted only when a Requirement lists it, even if `roms` names it.
    @Test func rejectsAKnownROMNoRequirementLists() async throws {
        let tmp = try TemporaryDirectory()
        let z64 = Synthetic.z64(size: 1 << 20)
        let sha1 = Synthetic.sha1(z64)
        var catalog = Catalogs.accepting([])
        catalog.roms.append(KnownROM(sha1: sha1, game: "ocarina-of-time", name: "Unlisted", format: "z64"))
        let store = ROMStore(paths: tmp.paths)

        let results = await store.add([try tmp.file("unlisted.z64", z64)], catalog: catalog)

        #expect(results.first?.rejection?.sha1 == sha1)
        #expect(await store.records().isEmpty)
    }

    /// A link is added as the ROM it points to; the user's file is never changed.
    @Test func addsTheFileALinkPointsTo() async throws {
        let tmp = try TemporaryDirectory()
        let z64 = Synthetic.z64(size: 1 << 20)
        let sha1 = Synthetic.sha1(z64)
        let original = try tmp.file("Games/Zelda.z64", z64)
        let link = tmp.url.appending(path: "Zelda alias.z64")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        let store = ROMStore(paths: tmp.paths)

        let results = await store.add([link], catalog: Catalogs.accepting([sha1]))

        #expect(results.first?.addedRecord?.sha1 == sha1)
        let stored = tmp.paths.rom(sha1, format: "z64")
        let type = try FileManager.default.attributesOfItem(atPath: stored.path(percentEncoded: false))[.type] as? FileAttributeType
        #expect(type == .typeRegular)
        #expect(try Data(contentsOf: stored) == z64)
        #expect(try mode(of: stored) == 0o444)
        #expect(try mode(of: original) == 0o644)
    }

    @Test func rejectsWhatIsNotAFile() async throws {
        let tmp = try TemporaryDirectory()
        let folder = tmp.url.appending(path: "folder.z64", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fifo = tmp.url.appending(path: "pipe.z64")
        #expect(mkfifo(fifo.path(percentEncoded: false), 0o644) == 0)
        let store = ROMStore(paths: tmp.paths)

        let results = await store.add([folder, fifo], catalog: Catalogs.accepting([]))

        #expect(results.allSatisfy { $0.rejection != nil })
    }

    @Test func rejectsUnreadableFiles() async throws {
        let tmp = try TemporaryDirectory()
        let store = ROMStore(paths: tmp.paths)

        let results = await store.add([tmp.url.appending(path: "missing.z64")], catalog: Catalogs.accepting([]))

        let rejection = try #require(results.first?.rejection)
        #expect(rejection.sha1 == nil)
        #expect(!rejection.reason.isEmpty)
    }

    @Test func addsTheOneROMInAZip() async throws {
        let tmp = try TemporaryDirectory()
        let z64 = Synthetic.z64()
        let sha1 = Synthetic.sha1(z64)
        let archive = try tmp.zip(
            "Zelda.zip", ["Zelda (USA).n64": Synthetic.n64(z64), "readme.txt": Data("Dumped by me".utf8)])
        let store = ROMStore(paths: tmp.paths)

        let results = await store.add([archive], catalog: Catalogs.accepting([sha1]))

        let record = try #require(results.first?.addedRecord)
        #expect(record.sha1 == sha1)
        #expect(record.originalFilename == "Zelda (USA).n64")
        #expect(try Data(contentsOf: tmp.paths.rom(sha1, format: "z64")) == z64)
        #expect(try mode(of: tmp.paths.rom(sha1, format: "z64")) == 0o444)
    }

    @Test func addsAZippedROMKeptAsItIs() async throws {
        let tmp = try TemporaryDirectory()
        let z64 = Synthetic.z64(size: 1 << 20)
        let sha1 = Synthetic.sha1(z64)
        let store = ROMStore(paths: tmp.paths)

        let results = await store.add([try tmp.zip("game.zip", ["game.z64": z64])], catalog: Catalogs.accepting([sha1]))

        #expect(results.first?.addedRecord?.sha1 == sha1)
        #expect(try Data(contentsOf: tmp.paths.rom(sha1, format: "z64")) == z64)
    }

    @Test func rejectsZipsWithoutExactlyOneROM() async throws {
        let tmp = try TemporaryDirectory()
        let a = Synthetic.z64(size: 1 << 20, seed: 1)
        let b = Synthetic.z64(size: 1 << 20, seed: 2)
        let catalog = Catalogs.accepting([Synthetic.sha1(a), Synthetic.sha1(b)])
        let store = ROMStore(paths: tmp.paths)

        let results = await store.add(
            [
                try tmp.zip("two.zip", ["a.z64": a, "b.z64": b]),
                try tmp.file("broken.zip", Data("not a zip".utf8)),
            ], catalog: catalog)

        #expect(results.count == 2)
        for result in results {
            let rejection = try #require(result.rejection)
            #expect(rejection.sha1 == nil)
        }
        #expect(results[0].rejection?.reason.contains("exactly one ROM") == true)
        #expect(await store.records().isEmpty)
    }

    @Test func concurrentAddsKeepTheIndexConsistent() async throws {
        let tmp = try TemporaryDirectory()
        let roms = (1...4).map { Synthetic.z64(size: 1 << 20, seed: UInt64($0)) }
        let catalog = Catalogs.accepting(roms.map(Synthetic.sha1))
        var files: [URL] = []
        for (n, rom) in roms.enumerated() {
            files.append(try tmp.file("\(n).z64", rom))
            files.append(try tmp.file("\(n).v64", Synthetic.v64(rom)))
            files.append(try tmp.file("\(n).n64", Synthetic.n64(rom)))
        }
        let store = ROMStore(paths: tmp.paths)

        let results = await withTaskGroup(of: ROMIntake.self) { group in
            for file in files {
                group.addTask { await store.add([file], catalog: catalog)[0] }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        #expect(results.compactMap(\.addedRecord).count == roms.count)
        #expect(results.compactMap(\.duplicateRecord).count == files.count - roms.count)
        let records = await store.records()
        #expect(Set(records.map(\.sha1)) == Set(roms.map(Synthetic.sha1)))
        #expect(records.count == roms.count)
        #expect(Set(await ROMStore(paths: tmp.paths).records()) == Set(records))

        let stored = try FileManager.default.contentsOfDirectory(atPath: tmp.paths.roms.path(percentEncoded: false))
        #expect(Set(stored) == Set(roms.map { "\(Synthetic.sha1($0)).z64" } + ["index.json"]))
    }

    @Test func recordsAreNewestFirst() async throws {
        let tmp = try TemporaryDirectory()
        let roms = (1...3).map { Synthetic.z64(size: 64 << 10, seed: UInt64($0)) }
        let store = ROMStore(paths: tmp.paths)
        let catalog = Catalogs.accepting(roms.map(Synthetic.sha1))

        for (n, rom) in roms.enumerated() {
            _ = await store.add([try tmp.file("\(n).z64", rom)], catalog: catalog)
        }

        #expect(await store.records().map(\.sha1) == roms.reversed().map(Synthetic.sha1))
        #expect(await ROMStore(paths: tmp.paths).records().map(\.sha1) == roms.reversed().map(Synthetic.sha1))
    }

    @Test func removesFileAndRecord() async throws {
        let tmp = try TemporaryDirectory()
        let z64 = Synthetic.z64(size: 1 << 20)
        let sha1 = Synthetic.sha1(z64)
        let store = ROMStore(paths: tmp.paths)
        _ = await store.add([try tmp.file("a.z64", z64)], catalog: Catalogs.accepting([sha1]))

        try await store.remove(sha1)

        #expect(await store.record(for: sha1) == nil)
        #expect(await store.file(for: sha1) == nil)
        #expect(!FileManager.default.fileExists(atPath: tmp.paths.rom(sha1, format: "z64").path(percentEncoded: false)))
        #expect(await ROMStore(paths: tmp.paths).records().isEmpty)
        try await store.remove(sha1)  // already gone is fine

        // It can be added again.
        let again = await store.add([try tmp.file("b.z64", z64)], catalog: Catalogs.accepting([sha1]))
        #expect(again.first?.addedRecord?.sha1 == sha1)
    }

    @Test func readdsAROMWhoseFileWentMissing() async throws {
        let tmp = try TemporaryDirectory()
        let z64 = Synthetic.z64(size: 1 << 20)
        let sha1 = Synthetic.sha1(z64)
        let store = ROMStore(paths: tmp.paths)
        let file = try tmp.file("a.z64", z64)
        _ = await store.add([file], catalog: Catalogs.accepting([sha1]))
        try FileManager.default.removeItem(at: tmp.paths.rom(sha1, format: "z64"))

        let results = await store.add([file], catalog: Catalogs.accepting([sha1]))

        #expect(results.first?.addedRecord?.sha1 == sha1)
        #expect(await store.records().count == 1)
    }

    @Test func oneResultPerFileInOrder() async throws {
        let tmp = try TemporaryDirectory()
        let z64 = Synthetic.z64(size: 64 << 10)
        let store = ROMStore(paths: tmp.paths)

        let results = await store.add(
            [
                try tmp.file("good.z64", z64),
                try tmp.file("bad.z64", Synthetic.z64(size: 64 << 10, seed: 99)),
                try tmp.file("again.v64", Synthetic.v64(z64)),
            ], catalog: Catalogs.accepting([Synthetic.sha1(z64)]))

        #expect(results[0].addedRecord != nil)
        #expect(results[1].unknown != nil)
        #expect(results[2].duplicateRecord != nil)
    }

    @Test func setsAsideAnUnreadableIndex() async throws {
        let tmp = try TemporaryDirectory()
        try tmp.file("Frontport/ROMs/index.json", Data("{ not json".utf8))
        let store = ROMStore(paths: tmp.paths)

        #expect(await store.records().isEmpty)

        let names = try FileManager.default.contentsOfDirectory(atPath: tmp.paths.roms.path(percentEncoded: false))
        #expect(names.contains { $0.hasPrefix("index-unreadable-") })
    }
}
