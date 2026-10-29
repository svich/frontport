import Foundation
import FrontportCore
import Testing
@testable import FrontportROMs

@Suite struct ROMFormatTests {
    /// Detects `file` and writes its standard form, returning the format and the standard bytes.
    func standardize(_ file: URL, in tmp: TemporaryDirectory) throws -> (format: ROMFormat, sha1: String, bytes: Data) {
        let format = try ROMFormat.detect(file)
        let output = tmp.url.appending(path: "standard-\(UUID().uuidString)")
        let (sha1, size) = try ROMFormat.standardize(file, format.standardization, into: output)
        let bytes = try Data(contentsOf: output)
        #expect(Int64(bytes.count) == size)
        return (format, sha1, bytes)
    }

    @Test func n64ByteOrdersHashIdentically() throws {
        let tmp = try TemporaryDirectory()
        let z64 = Synthetic.z64()
        #expect(z64.count == 8 << 20)
        let files = [
            try tmp.file("game.z64", z64),
            try tmp.file("game.v64", Synthetic.v64(z64)),
            try tmp.file("game.n64", Synthetic.n64(z64)),
        ]
        #expect(Synthetic.v64(z64).prefix(4) == Data([0x37, 0x80, 0x40, 0x12]))
        #expect(Synthetic.n64(z64).prefix(4) == Data([0x40, 0x12, 0x37, 0x80]))

        let results = try files.map { try standardize($0, in: tmp) }

        #expect(results.map(\.format) == [ROMFormat("z64"), ROMFormat("z64", .swap16), ROMFormat("z64", .swap32)])
        for result in results {
            #expect(result.sha1 == Synthetic.sha1(z64))
            #expect(result.bytes == z64)
        }
    }

    @Test func headerBytesWinOverExtension() throws {
        let tmp = try TemporaryDirectory()
        let z64 = Synthetic.z64(size: 64 << 10)
        let mislabeled = try tmp.file("game.z64", Synthetic.v64(z64))
        let unlabeled = try tmp.file("game", Synthetic.n64(z64))

        #expect(try ROMFormat.detect(mislabeled) == ROMFormat("z64", .swap16))
        #expect(try ROMFormat.detect(unlabeled) == ROMFormat("z64", .swap32))
        #expect(try standardize(unlabeled, in: tmp).sha1 == Synthetic.sha1(z64))
    }

    @Test func snesCopierHeaderIsStripped() throws {
        let tmp = try TemporaryDirectory()
        let sfc = Synthetic.sfc()
        let plain = try standardize(try tmp.file("game.sfc", sfc), in: tmp)
        let headered = try standardize(try tmp.file("game.smc", Synthetic.copierHeadered(sfc)), in: tmp)

        #expect(plain.format == ROMFormat("sfc"))
        #expect(headered.format == ROMFormat("sfc", .dropHeader(512)))
        #expect(plain.sha1 == Synthetic.sha1(sfc))
        #expect(headered.sha1 == Synthetic.sha1(sfc))
        #expect(headered.bytes == sfc)
    }

    @Test func snesWithoutCopierHeaderIsKept() throws {
        let tmp = try TemporaryDirectory()
        // 1.5 MiB: a size that isn't a whole MiB, but still a multiple of 1024.
        let sfc = Synthetic.sfc(size: 3 << 19)
        #expect(try ROMFormat.detect(try tmp.file("game.smc", sfc)) == ROMFormat("sfc"))
    }

    @Test func iNESHeaderIsStripped() throws {
        let tmp = try TemporaryDirectory()
        let nes = Synthetic.nes()
        let headered = try standardize(try tmp.file("game.nes", Synthetic.iNES(nes)), in: tmp)
        let headerless = try standardize(try tmp.file("headerless.nes", nes), in: tmp)

        #expect(headered.format == ROMFormat("nes", .dropHeader(16)))
        #expect(headered.sha1 == Synthetic.sha1(nes))
        #expect(headered.bytes == nes)
        #expect(headerless.format == ROMFormat("nes"))
        #expect(headerless.sha1 == Synthetic.sha1(nes))
    }

    @Test func discImagesAndUnknownFilesAreKeptAsTheyAre() throws {
        let tmp = try TemporaryDirectory()
        let bytes = Synthetic.noise(4096, seed: 9)
        #expect(try ROMFormat.detect(try tmp.file("game.ISO", bytes)) == ROMFormat("iso"))
        #expect(try ROMFormat.detect(try tmp.file("game.gba", bytes)) == ROMFormat("gba"))
        #expect(try ROMFormat.detect(try tmp.file("game", bytes)) == ROMFormat("bin"))
        #expect(try ROMFormat.detect(try tmp.file("game.n64 copy?", bytes)) == ROMFormat("bin"))
        #expect(try ROMFormat.recognize(try tmp.file("readme.txt", bytes)) == nil)
    }

    @Test func eachListedExtensionIsRecognizedAsItsFormat() throws {
        let tmp = try TemporaryDirectory()
        let bytes = Data(count: 4096)
        for format in ["z64", "sfc", "nes", "iso", "nsp", "xci", "keys", "wad", "pk3", "ipk3"] {
            let extensions = ROMFormat.extensions(of: format)
            #expect(extensions.contains(format))
            for ext in extensions {
                let recognized = try #require(try ROMFormat.recognize(try tmp.file("rom.\(ext)", bytes)))
                // NSP and XCI share their list: their contents, not their container, identify the ROM.
                #expect(ROMFormat.extensions(of: recognized.format) == extensions, "\(ext)")
            }
        }
    }

    @Test func doomFilesAreKeptAsTheyAre() throws {
        let tmp = try TemporaryDirectory()
        let iwad = Data("IWAD".utf8) + Synthetic.noise(4092, seed: 3)
        let pwad = Data("PWAD".utf8) + Synthetic.noise(4092, seed: 5)
        let zip = Data([0x50, 0x4B, 0x03, 0x04]) + Synthetic.noise(4092, seed: 7)

        #expect(try ROMFormat.detect(try tmp.file("DOOM2.WAD", iwad)) == ROMFormat("wad"))
        #expect(try ROMFormat.detect(try tmp.file("doom2", iwad)) == ROMFormat("wad"))
        #expect(try ROMFormat.detect(try tmp.file("sigil.wad", pwad)) == ROMFormat("wad"))
        #expect(try ROMFormat.recognize(try tmp.file("mod.PK3", zip)) == ROMFormat("pk3"))
        #expect(try ROMFormat.recognize(try tmp.file("game.ipk3", zip)) == ROMFormat("ipk3"))
        #expect(try standardize(try tmp.file("doom.wad", iwad), in: tmp).bytes == iwad)
    }

    @Test func trailingPartialWordIsLeftAlone() throws {
        let tmp = try TemporaryDirectory()
        let z64 = Synthetic.z64(size: (2 << 20) + 3)  // spans two chunks, then 3 stray bytes
        let file = try tmp.file("odd.n64", Synthetic.n64(z64))

        let result = try standardize(file, in: tmp)

        #expect(result.bytes == z64)
    }

    @Test func standardizingNeverReadsTheWholeFile() throws {
        // Chunked streaming is what keeps disc images out of memory.
        #expect(ROMFormat.chunkSize == 1 << 20)
        let tmp = try TemporaryDirectory()
        let file = try tmp.file("disc.iso", Synthetic.noise((3 << 20) + 5, seed: 4))
        var chunks: [Int] = []
        try ROMFormat.stream(file, .none) { chunks.append($0.count) }
        #expect(chunks == [1 << 20, 1 << 20, 1 << 20, 5])
    }
}
