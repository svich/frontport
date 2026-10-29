import Foundation
import FrontportCore
import Testing
@testable import FrontportROMs

/// Where each Port's Requirements stand, read through `ROMStore.matching`.
@Suite struct MatchingTests {
    let tmp: TemporaryDirectory
    let roms = (1...4).map { Synthetic.z64(size: 64 << 10, seed: UInt64($0)) }
    var hashes: [String] { roms.map(Synthetic.sha1) }

    init() throws { tmp = try TemporaryDirectory() }

    func store(holding indices: [Int]) async throws -> ROMStore {
        let store = ROMStore(paths: tmp.paths)
        try await add(indices, to: store)
        return store
    }

    func add(_ indices: [Int], to store: ROMStore) async throws {
        let files = try indices.map { try tmp.file("in/\($0).z64", roms[$0]) }
        _ = await store.add(files, catalog: Catalogs.accepting(hashes))
    }

    func reading(_ store: ROMStore, _ entry: CatalogEntry, _ installation: Installation? = nil) async throws -> PortMatching {
        let installations = installation.map { [entry.id: $0] } ?? [:]
        return try #require(await store.matching([entry], installations: installations)[entry.id])
    }

    @Test func theMatchIsTheFirstAcceptedROMThereWithTheExtrasThere() async throws {
        let requirement = Requirement(
            label: "Ocarina of Time", stage: .runtime, oneOf: [hashes[0], hashes[1]], extras: [hashes[2], hashes[3]],
            seedPath: "roms/")
        let entry = Catalogs.entry("shipwright", game: "ocarina-of-time", requirements: [requirement])
        let store = ROMStore(paths: tmp.paths)
        #expect(try await reading(store, entry).missing() == [requirement])

        try await add([1, 2], to: store)
        let first = try #require(try await reading(store, entry).requirements.first)
        #expect(first.rom == hashes[1] && first.accepted == .inROMs)
        #expect(first.extras == [hashes[2]: .inROMs, hashes[3]: .missing])

        try await add([0, 3], to: store)
        let second = try #require(try await reading(store, entry).requirements.first)
        #expect(second.rom == hashes[0] && second.state == .inROMs)
        #expect(second.extras == [hashes[2]: .inROMs, hashes[3]: .inROMs])
    }

    @Test func anInstalledPortsRuntimeROMsAreSeededOrNot() async throws {
        let requirement = Requirement(label: "Ocarina of Time", stage: .runtime, oneOf: [hashes[0]], seedPath: "roms/")
        let entry = Catalogs.entry("shipwright", game: "ocarina-of-time", requirements: [requirement])
        let store = try await store(holding: [0])
        let installation = Catalogs.installation(entry)
        #expect(try await reading(store, entry).unseeded.isEmpty, "nothing to Seed into before it's installed")

        #expect(try await reading(store, entry, installation).unseeded == [requirement])
        try await store.seed(entry)
        let state = try await reading(store, entry, installation)
        #expect(state.unseeded.isEmpty && state.requirements.first?.accepted == .seeded)
    }

    @Test func aReadingListsROMsNewestFirst() async throws {
        let store = try await store(holding: [0])
        try await add([1], to: store)

        let reading = await store.matching([], installations: [:])

        #expect(reading.roms.map(\.sha1) == [hashes[1], hashes[0]])
        #expect(reading.contains(hashes[0]) && !reading.contains(hashes[2]))
    }

    // MARK: Build Stage

    func starship(_ requirement: Requirement) -> CatalogEntry {
        Catalogs.sourceBuilt("starship", game: "ocarina-of-time", requirements: [requirement])
    }

    @Test func buildROMsFeedTheRecipeOrNameWhatsMissing() async throws {
        let requirement = Requirement(label: "Star Fox 64", stage: .build, oneOf: [hashes[0]], extras: [hashes[1]])
        let entry = starship(requirement)
        let store = ROMStore(paths: tmp.paths)
        let empty = try await reading(store, entry)
        #expect(throws: FrontportError.romMissing(entry.id, requirement: "Star Fox 64")) { try empty.buildROMs() }

        try await add([0, 1], to: store)
        let roms = try await reading(store, entry).buildROMs()
        #expect(roms.sha1s == [hashes[0], hashes[1]].sorted())
        let stored: Set<URL> = [tmp.paths.rom(hashes[0], format: "z64"), tmp.paths.rom(hashes[1], format: "z64")]
        #expect(Set(roms.files.map(\.url)) == stored)
    }

    /// A Build ROM removed from ROMs is still built in: the Port runs without it, and only a rebuild asks for it again.
    @Test func aRemovedBuildROMStaysBuiltIn() async throws {
        let requirement = Requirement(label: "Star Fox 64", stage: .build, oneOf: [hashes[0]])
        let entry = starship(requirement)
        let store = try await store(holding: [0])
        let installation = Catalogs.installation(entry, builtFrom: [hashes[0]])
        let before = try await reading(store, entry, installation)
        #expect(before.requirements.first?.accepted == .builtIn && before.carriesBuildAssets)
        #expect(await store.matching([entry], installations: [entry.id: installation]).askingAgain(for: hashes[0]) == [entry.id])

        try await store.remove(hashes[0])

        let after = try await reading(store, entry, installation)
        #expect(after.requirements.first?.rom == hashes[0] && after.requirements.first?.accepted == .builtIn)
        #expect(after.missing().isEmpty, "built in, not missing")
        #expect(after.carriesBuildAssets, "an update can still carry the Build Assets forward")
        #expect(throws: FrontportError.romMissing(entry.id, requirement: "Star Fox 64")) { try after.buildROMs() }
    }

    /// Another accepted ROM, or an extra, added since the Build Assets were made is in ROMs, for a rebuild to take.
    @Test func aROMTheBuildAssetsWerentMadeFromMeansARebuild() async throws {
        let requirement = Requirement(label: "Star Fox 64", stage: .build, oneOf: [hashes[0]], extras: [hashes[1]])
        let entry = starship(requirement)
        let store = try await store(holding: [0, 1])
        let installation = Catalogs.installation(entry, builtFrom: [hashes[0]])

        let state = try await reading(store, entry, installation)

        #expect(state.requirements.first?.accepted == .builtIn)
        #expect(state.requirements.first?.extras == [hashes[1]: .inROMs])
        #expect(state.requirements.first?.state == .inROMs)
        #expect(!state.carriesBuildAssets)
    }

    @Test func buildAssetsInAnotherFormatArentCarried() async throws {
        let requirement = Requirement(label: "Star Fox 64", stage: .build, oneOf: [hashes[0]])
        let entry = starship(requirement)
        let store = try await store(holding: [0])

        let state = try await reading(store, entry, Catalogs.installation(entry, builtFrom: [hashes[0]], format: "0"))

        #expect(!state.carriesBuildAssets)
    }

    @Test func onlyThePortsLeftWithoutAMatchWouldAskAgain() async throws {
        let requirement = Requirement(label: "Star Fox 64", stage: .build, oneOf: [hashes[0], hashes[1]], extras: [hashes[2]])
        let entry = starship(requirement)
        let store = try await store(holding: [0, 1, 2])
        let installation = Catalogs.installation(entry, builtFrom: [hashes[0], hashes[2]])

        let reading = await store.matching([entry], installations: [entry.id: installation])
        #expect(reading.askingAgain(for: hashes[0]).isEmpty, "the other accepted ROM stands in")
        #expect(reading.askingAgain(for: hashes[2]).isEmpty, "an extra is never asked for")

        try await store.remove(hashes[1])
        #expect(await store.matching([entry], installations: [entry.id: installation]).askingAgain(for: hashes[0]) == [entry.id])
        #expect(await store.matching([entry], installations: [:]).askingAgain(for: hashes[0]).isEmpty, "not installed")
    }

    // MARK: Identity and the index

    @Test func anEntryThatCouldNameAnotherPortsFolderGetsNoDataRead() async throws {
        let requirement = Requirement(label: "Ocarina of Time", stage: .runtime, oneOf: [hashes[0]], seedPath: "roms/")
        var entry = Catalogs.entry("shipwright", game: "ocarina-of-time", requirements: [requirement])
        entry.bundleId = "../elsewhere"
        let store = try await store(holding: [0])

        let state = try await reading(store, entry, Catalogs.installation(entry))

        #expect(!state.isInstalled && state.requirements.first?.accepted == .inROMs)
        await #expect(throws: FrontportError.self) { try await store.seed(entry) }
    }

    @Test func aRecordWhoseFileIsGoneIsDroppedWhenTheIndexLoads() async throws {
        _ = try await store(holding: [0, 1])
        try FileManager.default.removeItem(at: tmp.paths.rom(hashes[0], format: "z64"))

        #expect(await ROMStore(paths: tmp.paths).records().map(\.sha1) == [hashes[1]])
    }
}
