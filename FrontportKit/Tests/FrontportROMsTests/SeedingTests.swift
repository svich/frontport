import Foundation
import FrontportCore
import Testing
@testable import FrontportROMs

@Suite struct SeedingTests {
    /// A store holding `roms`, and Ship of Harkinian with one Runtime Requirement that accepts `oneOf` (the first of
    /// `roms` by default) and takes the rest of `roms` as extras.
    func store(
        _ roms: [Data], oneOf: [Data]? = nil, seedPath: String?, in tmp: TemporaryDirectory
    ) async throws -> (store: ROMStore, entry: CatalogEntry) {
        let accepted = (oneOf ?? [roms[0]]).map(Synthetic.sha1)
        let extras = roms.map(Synthetic.sha1).filter { !accepted.contains($0) }
        let store = ROMStore(paths: tmp.paths)
        let files = try roms.enumerated().map { try tmp.file("in/\($0).z64", $1) }
        _ = await store.add(files, catalog: Catalogs.accepting(roms.map(Synthetic.sha1)))
        let requirement = Requirement(
            label: "Ocarina of Time", stage: .runtime, oneOf: accepted, extras: extras, seedPath: seedPath)
        return (store, Catalogs.entry("shipwright", game: "ocarina-of-time", requirements: [requirement]))
    }

    /// A Data folder as macOS creates it on first launch: mode 755.
    func data(in tmp: TemporaryDirectory) throws -> URL {
        let data = tmp.paths.data(for: "dev.frontport.port.shipwright")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        return data
    }

    func state(_ store: ROMStore, _ entry: CatalogEntry) async throws -> RequirementState {
        let installed = [entry.id: Catalogs.installation(entry)]
        return try #require(await store.matching([entry], installations: installed)[entry.id]?.requirements.first)
    }

    @Test func seedsIntoAFolderWithPrivateFolders() async throws {
        let tmp = try TemporaryDirectory()
        let roms = [Synthetic.z64(size: 1 << 20, seed: 1), Synthetic.z64(size: 1 << 20, seed: 2)]
        let (store, entry) = try await store(roms, seedPath: "Library/Application Support/soh/", in: tmp)
        let data = try data(in: tmp)
        #expect(try await state(store, entry).state == .unseeded)

        try await store.seed(entry)

        let folder = data.appending(path: "Library/Application Support/soh", directoryHint: .isDirectory)
        for rom in roms {
            let url = folder.appending(path: "\(Synthetic.sha1(rom)).z64")
            #expect(try Data(contentsOf: url) == rom)
            #expect(try mode(of: url) == 0o644)
            #expect(tag(url) == Synthetic.sha1(rom))
        }
        #expect(try mode(of: folder) == 0o700)
        #expect(try mode(of: data.appending(path: "Library")) == 0o700)
        #expect(try mode(of: data.appending(path: "Library/Application Support")) == 0o700)
        #expect(try mode(of: data) == 0o755)  // macOS's own folder is left alone
        let state = try await state(store, entry)
        #expect(state.accepted == .seeded && state.extras == [Synthetic.sha1(roms[1]): .seeded])
    }

    @Test func thePortCanRewriteItsCopyButNotTheOneInROMs() async throws {
        let tmp = try TemporaryDirectory()
        let rom = Synthetic.z64(size: 1 << 20)
        let (store, entry) = try await store([rom], seedPath: "roms/", in: tmp)

        try await store.seed(entry)
        let seeded = try data(in: tmp).appending(path: "roms/\(Synthetic.sha1(rom)).z64")
        let handle = try FileHandle(forWritingTo: seeded)
        try handle.seek(toOffset: 0x100)
        try handle.write(contentsOf: Data(repeating: 0xEE, count: 64))
        try handle.close()

        let stored = tmp.paths.rom(Synthetic.sha1(rom), format: "z64")
        #expect(try Data(contentsOf: seeded) != rom)
        #expect(try Data(contentsOf: stored) == rom)
        #expect(try mode(of: stored) == 0o444)
    }

    @Test func seedsTheExactFilePathWithThePreferredROM() async throws {
        let tmp = try TemporaryDirectory()
        let roms = [Synthetic.z64(size: 64 << 10, seed: 1), Synthetic.z64(size: 64 << 10, seed: 2)]
        let (store, entry) = try await store(roms, oneOf: roms, seedPath: "Documents/baserom.z64", in: tmp)
        let data = try data(in: tmp)

        try await store.seed(entry)

        #expect(try Data(contentsOf: data.appending(path: "Documents/baserom.z64")) == roms[0])
        #expect(try FileManager.default.contentsOfDirectory(atPath: data.appending(path: "Documents").path(percentEncoded: false)) == ["baserom.z64"])
        #expect(try mode(of: data.appending(path: "Documents")) == 0o700)
    }

    @Test func seedsBeforeThePortsFirstLaunch() async throws {
        let tmp = try TemporaryDirectory()
        let rom = Synthetic.z64(size: 64 << 10)
        let (store, entry) = try await store([rom], seedPath: "roms/", in: tmp)
        let data = tmp.paths.data(for: "dev.frontport.port.shipwright")

        try await store.seed(entry)

        #expect(FileManager.default.fileExists(atPath: data.appending(path: "roms/\(Synthetic.sha1(rom)).z64").path(percentEncoded: false)))
        #expect(try mode(of: data) == 0o700)
        #expect(try mode(of: tmp.paths.container(for: "dev.frontport.port.shipwright")) == 0o700)
    }

    /// The Doom case: a newly preferred IWAD replaces the shareware one at `doom.wad`.
    @Test func thePreferredROMReplacesAnotherAtAFileSeedPath() async throws {
        let tmp = try TemporaryDirectory()
        let (ultimate, shareware) = (Synthetic.z64(size: 64 << 10, seed: 1), Synthetic.z64(size: 64 << 10, seed: 2))
        let store = ROMStore(paths: tmp.paths)
        let catalog = Catalogs.accepting([ultimate, shareware].map(Synthetic.sha1))
        let requirement = Requirement(
            label: "Doom", stage: .runtime, oneOf: [ultimate, shareware].map(Synthetic.sha1), seedPath: "doom.wad")
        let entry = Catalogs.entry("shipwright", game: "ocarina-of-time", requirements: [requirement])
        let target = try data(in: tmp).appending(path: "doom.wad")
        _ = await store.add([try tmp.file("shareware.z64", shareware)], catalog: catalog)
        try await store.seed(entry)
        #expect(try await state(store, entry).accepted == .seeded)

        _ = await store.add([try tmp.file("ultimate.z64", ultimate)], catalog: catalog)
        let state = try await state(store, entry)
        #expect(state.rom == Synthetic.sha1(ultimate) && state.accepted == .unseeded)
        try await store.seed(entry)

        #expect(try Data(contentsOf: target) == ultimate)
        #expect(tag(target) == Synthetic.sha1(ultimate))
        #expect(try await self.state(store, entry).accepted == .seeded)
    }

    @Test func otherAcceptedROMsStayInAFolderSeedPath() async throws {
        let tmp = try TemporaryDirectory()
        let (preferred, other) = (Synthetic.z64(size: 64 << 10, seed: 1), Synthetic.z64(size: 64 << 10, seed: 2))
        let store = ROMStore(paths: tmp.paths)
        let catalog = Catalogs.accepting([preferred, other].map(Synthetic.sha1))
        let requirement = Requirement(
            label: "Ocarina of Time", stage: .runtime, oneOf: [preferred, other].map(Synthetic.sha1), seedPath: "roms/")
        let entry = Catalogs.entry("shipwright", game: "ocarina-of-time", requirements: [requirement])
        let folder = try data(in: tmp).appending(path: "roms", directoryHint: .isDirectory)
        _ = await store.add([try tmp.file("other.z64", other)], catalog: catalog)
        try await store.seed(entry)

        _ = await store.add([try tmp.file("preferred.z64", preferred)], catalog: catalog)
        try await store.seed(entry)

        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).sorted()
        #expect(names == ["\(Synthetic.sha1(other)).z64", "\(Synthetic.sha1(preferred)).z64"].sorted())
    }

    /// A file Seeded before Frontport tagged them holds its ROM all the same: it's compared once, then tagged.
    @Test func anUntaggedFileWithTheROMIsTaggedNotReplaced() async throws {
        let tmp = try TemporaryDirectory()
        let rom = Synthetic.z64(size: 1 << 20)
        let (store, entry) = try await store([rom], seedPath: "baserom.z64", in: tmp)
        let target = try data(in: tmp).appending(path: "baserom.z64")
        try rom.write(to: target)
        let inode = try self.inode(target)

        #expect(try await state(store, entry).accepted == .seeded)
        #expect(tag(target) == Synthetic.sha1(rom))
        try await store.seed(entry)
        #expect(try self.inode(target) == inode)
    }

    @Test func skipsATaggedTargetAndReplacesADifferentOne() async throws {
        let tmp = try TemporaryDirectory()
        let rom = Synthetic.z64(size: 1 << 20)
        let (store, entry) = try await store([rom], seedPath: "roms/", in: tmp)
        let target = try data(in: tmp).appending(path: "roms/\(Synthetic.sha1(rom)).z64")
        try await store.seed(entry)
        let inode = try self.inode(target)

        try await store.seed(entry)
        #expect(try self.inode(target) == inode)

        // Another file in its place, untagged, is replaced; so is a same-sized one with other contents.
        try FileManager.default.removeItem(at: target)
        try Data("not the ROM".utf8).write(to: target)
        #expect(try await state(store, entry).accepted == .unseeded)
        try await store.seed(entry)
        #expect(try Data(contentsOf: target) == rom)

        var corrupted = rom
        corrupted[0x2000] ^= 0x01
        try FileManager.default.removeItem(at: target)
        try corrupted.write(to: target)
        try await store.seed(entry)
        #expect(try Data(contentsOf: target) == rom)

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path(percentEncoded: false))
        #expect(leftovers == [target.lastPathComponent])
    }

    @Test func seededROMsOutliveTheirRemovalFromROMs() async throws {
        let tmp = try TemporaryDirectory()
        let rom = Synthetic.z64(size: 64 << 10)
        let (store, entry) = try await store([rom], seedPath: "roms/", in: tmp)
        try await store.seed(entry)

        try await store.remove(Synthetic.sha1(rom))

        #expect(try Data(contentsOf: data(in: tmp).appending(path: "roms/\(Synthetic.sha1(rom)).z64")) == rom)
        #expect(try await state(store, entry).state == .missing)
    }

    @Test(arguments: ["../escape/", "/etc/", "roms/../../x.z64", "./roms/", "", "/", "roms//x.z64"])
    func refusesSeedPathsOutsideData(_ seedPath: String) async throws {
        let tmp = try TemporaryDirectory()
        let (store, entry) = try await store([Synthetic.z64(size: 64 << 10)], seedPath: seedPath, in: tmp)
        _ = try data(in: tmp)

        await #expect(throws: FrontportError.self) { try await store.seed(entry) }
        #expect(try await state(store, entry).state == .unseeded)
    }

    @Test func refusesExtrasAtAFileSeedPath() async throws {
        let tmp = try TemporaryDirectory()
        let roms = [Synthetic.z64(size: 64 << 10, seed: 1), Synthetic.z64(size: 64 << 10, seed: 2)]
        let (store, entry) = try await store(roms, seedPath: "baserom.z64", in: tmp)

        await #expect(throws: FrontportError.self) { try await store.seed(entry) }
    }

    @Test func leavesARequirementWithoutASeedPathAlone() async throws {
        let tmp = try TemporaryDirectory()
        let (store, entry) = try await store([Synthetic.z64(size: 64 << 10)], seedPath: nil, in: tmp)
        let data = try data(in: tmp)

        try await store.seed(entry)

        #expect(try FileManager.default.contentsOfDirectory(atPath: data.path(percentEncoded: false)).isEmpty)
        #expect(try await state(store, entry).state == .seeded)
    }

    @Test func refusesToFollowASymlinkOutOfData() async throws {
        let tmp = try TemporaryDirectory()
        let (store, entry) = try await store([Synthetic.z64(size: 64 << 10)], seedPath: "Library/roms/", in: tmp)
        let data = try data(in: tmp)
        let outside = tmp.url.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: data.appending(path: "Library"), withDestinationURL: outside)

        await #expect(throws: FrontportError.self) { try await store.seed(entry) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path(percentEncoded: false)).isEmpty)
        #expect(try await state(store, entry).state == .unseeded)
    }

    /// The Port can swap a folder for a link at any moment; once Seeding has opened a folder, its writes land
    /// in that folder wherever it has moved, never through the link. A race the interface can't stage, so this goes
    /// to the step that writes.
    @Test func aFolderSwappedForALinkAfterItWasOpenedStillGetsTheROM() async throws {
        let tmp = try TemporaryDirectory()
        let rom = Synthetic.z64(size: 64 << 10)
        let (store, _) = try await store([rom], seedPath: "roms/", in: tmp)
        let file = try #require(await store.file(for: Synthetic.sha1(rom)))
        let data = try data(in: tmp)
        let outside = tmp.url.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)

        let folder = try FileOperations.openFolder(["roms"], in: data)
        defer { close(folder) }
        try FileManager.default.moveItem(at: data.appending(path: "roms"), to: data.appending(path: "moved"))
        try FileManager.default.createSymbolicLink(at: data.appending(path: "roms"), withDestinationURL: outside)
        try Seeding.place(file, named: "baserom.z64", in: folder)

        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path(percentEncoded: false)).isEmpty)
        #expect(try Data(contentsOf: data.appending(path: "moved/baserom.z64")) == rom)
    }

    @Test func replacesASymlinkAtTheTarget() async throws {
        let tmp = try TemporaryDirectory()
        let rom = Synthetic.z64(size: 64 << 10)
        let (store, entry) = try await store([rom], seedPath: "baserom.z64", in: tmp)
        let data = try data(in: tmp)
        let outside = try tmp.file("outside.z64", Data("keep".utf8))
        try FileManager.default.createSymbolicLink(at: data.appending(path: "baserom.z64"), withDestinationURL: outside)
        #expect(try await state(store, entry).accepted == .unseeded)

        try await store.seed(entry)

        let placed = data.appending(path: "baserom.z64")
        #expect(try Data(contentsOf: placed) == rom)
        #expect(try Data(contentsOf: outside) == Data("keep".utf8))
        let type = try FileManager.default.attributesOfItem(atPath: placed.path(percentEncoded: false))[.type] as? FileAttributeType
        #expect(type == .typeRegular)
    }

    @Test func aFIFOInTheROMsPlaceIsNotSeededAndDoesntHang() async throws {
        let tmp = try TemporaryDirectory()
        let rom = Synthetic.z64(size: 64 << 10)
        let (store, entry) = try await store([rom], seedPath: "baserom.z64", in: tmp)
        let target = try data(in: tmp).appending(path: "baserom.z64")
        #expect(mkfifo(target.path(percentEncoded: false), 0o644) == 0)

        #expect(try await state(store, entry).accepted == .unseeded)
        try await store.seed(entry)
        #expect(try Data(contentsOf: target) == rom)
    }

    func tag(_ url: URL) -> String? {
        FileOperations.extendedAttribute(Seeding.tag, at: url).map { String(decoding: $0, as: UTF8.self) }
    }

    func inode(_ url: URL) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.systemFileNumber] as? Int
    }
}
