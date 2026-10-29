import CryptoKit
import Foundation
import FrontportCore

/// How a file's bytes become a ROM's standard form.
enum Standardization: Hashable, Sendable {
    /// Already standard: hashed and stored as it is.
    case none
    /// A header of this many bytes precedes the standard form: a SNES copier header or an iNES header.
    case dropHeader(Int)
    /// N64 `.v64`: each 16-bit pair is byte-swapped.
    case swap16
    /// N64 `.n64`: each 32-bit word is little-endian.
    case swap32
    /// A Switch NSP or XCI: kept as it is, and identified by the NCAs it holds rather than by its bytes
    /// (`SwitchContents`), which also tells an NSZ or XCZ from it, kept Unverified.
    case contents
    /// Switch console keys: reduced to the keys every console shares (`ConsoleKeys`).
    case keys
}

/// A file's ROM format: the standard form's extension, and how to get there.
struct ROMFormat: Hashable, Sendable {
    /// Extension of the standard form, such as "z64".
    var format: String
    var standardization: Standardization

    init(_ format: String, _ standardization: Standardization = .none) {
        self.format = format
        self.standardization = standardization
    }

    /// Detects by header bytes first, then by extension, or nil when neither says it's a ROM.
    static func recognize(_ url: URL) throws -> ROMFormat? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let start = try handle.read(upToCount: 0x104) ?? Data()
        let header = Array(start.prefix(4))
        let size = try handle.seekToEnd()

        switch header {
        case [0x80, 0x37, 0x12, 0x40]: return ROMFormat("z64")
        case [0x37, 0x80, 0x40, 0x12]: return ROMFormat("z64", .swap16)
        case [0x40, 0x12, 0x37, 0x80]: return ROMFormat("z64", .swap32)
        case [0x4E, 0x45, 0x53, 0x1A] where size >= 16: return ROMFormat("nes", .dropHeader(16))  // "NES\x1A"
        case [0x50, 0x46, 0x53, 0x30]: return ROMFormat("nsp", .contents)  // "PFS0"
        case [0x49, 0x57, 0x41, 0x44], [0x50, 0x57, 0x41, 0x44]: return ROMFormat("wad")  // "IWAD", "PWAD"
        default: break
        }
        if start.count == 0x104, start.suffix(4) == Data("HEAD".utf8) { return ROMFormat("xci", .contents) }

        switch url.pathExtension.lowercased() {
        case "sfc", "smc": return ROMFormat("sfc", size % 1024 == 512 ? .dropHeader(512) : .none)
        case "z64", "v64", "n64": return ROMFormat("z64")
        case "nes": return ROMFormat("nes")
        case "iso": return ROMFormat("iso")
        case "nsp", "nsz": return ROMFormat("nsp", .contents)
        case "xci", "xcz": return ROMFormat("xci", .contents)
        case "keys": return ROMFormat("keys", .keys)
        case "wad": return ROMFormat("wad")
        // Doom engine zips, kept zipped: the Port reads them as they are.
        case "pk3", "ipk3": return ROMFormat(url.pathExtension.lowercased())
        default: return nil
        }
    }

    /// The extensions `recognize` takes as a ROM of this standard format: an N64 ROM in any byte order, a SNES ROM
    /// with or without a copier header, and a Switch game in any container, since its contents identify it.
    static func extensions(of format: String) -> [String] {
        switch format {
        case "z64": ["z64", "v64", "n64"]
        case "sfc": ["sfc", "smc"]
        case "nsp", "xci": ["nsp", "xci", "nsz", "xcz"]
        default: [format]
        }
    }

    /// Like `recognize`, but keeps anything unrecognized as it is under its own extension, so the Catalog
    /// alone decides whether it's accepted.
    static func detect(_ url: URL) throws -> ROMFormat {
        if let format = try recognize(url) { return format }
        let ext = url.pathExtension.lowercased()
        let safe = (1...8).contains(ext.count) && ext.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return ROMFormat(safe ? ext : "bin")
    }

    // MARK: Streaming

    static let chunkSize = 1 << 20

    /// Passes the file's standard form to `body` in chunks, so no ROM is ever held in memory whole.
    static func stream(_ url: URL, _ standardization: Standardization, _ body: (Data) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let unit: Int
        switch standardization {
        case .none, .contents, .keys: unit = 1
        case .dropHeader(let length):
            try handle.seek(toOffset: UInt64(length))
            unit = 1
        case .swap16: unit = 2
        case .swap32: unit = 4
        }

        // Bytes left over from a short read, so swaps always see whole words.
        var carry = Data()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            try Task.checkCancellation()
            var buffer = carry.isEmpty ? chunk : carry + chunk
            let whole = buffer.count - buffer.count % unit
            carry = Data(buffer[(buffer.startIndex + whole)...])
            buffer.removeSubrange((buffer.startIndex + whole)...)
            swap(&buffer, unit: unit)
            try body(buffer)
        }
        // A trailing partial word has nothing to swap with.
        if !carry.isEmpty { try body(carry) }
    }

    /// Writes the file's standard form to `destination` (which must not exist) and hashes it in one pass.
    static func standardize(
        _ url: URL, _ standardization: Standardization, into destination: URL
    ) throws -> (sha1: String, size: Int64) {
        guard FileManager.default.createFile(atPath: destination.path(percentEncoded: false), contents: nil) else {
            throw FrontportError.fileOperation("Couldn’t create \(destination.lastPathComponent)")
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var hasher = Insecure.SHA1()
        var size: Int64 = 0
        try stream(url, standardization) { chunk in
            hasher.update(data: chunk)
            try output.write(contentsOf: chunk)
            size += Int64(chunk.count)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), size)
    }

    private static func swap(_ buffer: inout Data, unit: Int) {
        guard unit > 1 else { return }
        buffer.withUnsafeMutableBytes { bytes in
            for offset in stride(from: 0, to: bytes.count, by: unit) {
                if unit == 2 {
                    let word = bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
                    bytes.storeBytes(of: word.byteSwapped, toByteOffset: offset, as: UInt16.self)
                } else {
                    let word = bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                    bytes.storeBytes(of: word.byteSwapped, toByteOffset: offset, as: UInt32.self)
                }
            }
        }
    }
}
