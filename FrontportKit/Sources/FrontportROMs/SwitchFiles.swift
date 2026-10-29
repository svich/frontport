import CryptoKit
import Foundation
import FrontportCore

/// Nintendo Switch game files, identified by what they hold rather than by their container. An NSP (a PFS0 archive)
/// or an XCI (a game card image) holds the game's NCAs, each named by its content ID: the first half of its SHA-256.
/// Dumping tools wrap the same NCAs differently (with or without a ticket and certificate, with the XML or icons some
/// add, in another order), so the identity covers the NCAs' content IDs alone: the same NCAs in another dump's
/// container are the same ROM.
///
/// The meta NCA (`.cnmt.nca`) is left out, as public title databases list the other content IDs of each version, so
/// the Catalog can list a version nobody dumped for it. The file itself is kept as it is, since its ticket, when it
/// has one, holds the key that decrypts its NCAs.
///
/// Nothing here decrypts (ADR 0011). An NCA that doesn't match its content ID, as each one of a game card dump a tool
/// converted to an NSP doesn't, and an NCZ, the compressed NCA of nsz's NSZ and XCZ, count by their own hash instead:
/// the identity is still the file's own, but one no ROM in the Catalog has, so the file can only be kept Unverified.
enum SwitchContents {
    /// What intake keeps of a file: its identity, the format it's kept in, and why no ROM in the Catalog can have that
    /// identity, when none can.
    struct Identified: Sendable {
        var sha1: String
        /// `nsp` or `xci`, or `nsz` or `xcz` when it holds NCZs.
        var format: String
        /// Set when an NCA doesn't match its content ID, or it holds NCZs.
        var note: String?
    }

    /// A file inside the container, with its offset from the start of the NSP or XCI.
    struct Entry: Hashable, Sendable {
        var name: String
        var offset: UInt64
        var size: UInt64

        /// The content ID its name gives, such as `dd38de587cb690a36bf4f8c5afff81dc` for
        /// `dd38de587cb690a36bf4f8c5afff81dc.nca`, whether it's the meta NCA, and whether it's an NCZ.
        var content: (id: String, meta: Bool, compressed: Bool)? {
            let lower = name.lowercased()
            guard lower.hasSuffix(".nca") || lower.hasSuffix(".ncz") else { return nil }
            var id = lower.dropLast(4)
            let meta = id.hasSuffix(".cnmt")
            if meta { id = id.dropLast(5) }
            guard id.count == 32, id.allSatisfy(\.isHexDigit) else { return nil }
            return (String(id), meta, lower.hasSuffix(".ncz"))
        }
    }

    /// SHA-1 of the NCAs' content IDs but the meta NCA's, sorted, one lowercase line each: what
    /// `ls *.nca | grep -v cnmt | cut -c1-32 | sort | shasum` prints for the NCAs unpacked into a folder.
    static func identity(of url: URL) throws -> String {
        try identify(url).sha1
    }

    /// The identity, each NCA checked against its content ID as it's hashed. One that doesn't match, and an NCZ, count
    /// by the first half of their own SHA-256.
    static func identify(_ url: URL) throws -> Identified {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var ids: [String] = []
        var altered = false
        var compressed = false
        let (ncas, tickets, card) = try files(in: handle, size: try handle.seekToEnd())
        for ticket in tickets where try isPersonalized(ticket, in: handle) {
            throw rejected(
                "\(ticket.name) is personalized to the console it was dumped from, so no other console’s keys decrypt it. Dump the game again as a standard NSP, with a common ticket.")
        }
        for nca in ncas {
            guard let content = nca.content else { throw rejected("\(nca.name) isn’t named by its content ID.") }
            let id = String(try sha256(of: nca, in: handle).prefix(32))
            if content.compressed {
                compressed = true
            } else if id != content.id {
                altered = true
            }
            if !content.meta { ids.append(id) }
        }
        guard !ids.isEmpty else { throw rejected("This NSP or XCI holds only a meta NCA.") }
        guard Set(ids).count == ids.count else { throw rejected("This NSP or XCI holds an NCA twice.") }
        let note: String? =
            if compressed {
                "It’s compressed with nsz, so Frontport can’t check what it holds against the Catalog."
            } else if altered {
                "Its NCAs don’t match their content IDs: a tool made it from an XCI, or it’s damaged."
            } else {
                nil
            }
        return Identified(
            sha1: Hashing.sha1(Data((ids.sorted().joined(separator: "\n") + "\n").utf8)),
            format: card ? (compressed ? "xcz" : "xci") : (compressed ? "nsz" : "nsp"), note: note)
    }

    /// The NCAs (and NCZs) and tickets of an NSP, or of an XCI's secure partition, and whether it's an XCI.
    static func files(in handle: FileHandle, size: UInt64) throws -> (ncas: [Entry], tickets: [Entry], card: Bool) {
        let entries: [Entry]
        let card: Bool
        if try read(handle, at: 0, count: 4) == Data("PFS0".utf8) {
            entries = try partition(handle, at: 0, in: 0..<size, magic: "PFS0")
            card = false
        } else if let root = try xciRoot(handle, size: size) {
            let partitions = try partition(handle, at: root, in: 0..<size, magic: "HFS0")
            guard let secure = partitions.first(where: { $0.name == "secure" }) else {
                throw rejected("This game card image has no secure partition.")
            }
            entries = try partition(handle, at: secure.offset, in: secure.offset..<secure.offset + secure.size, magic: "HFS0")
            card = true
        } else {
            throw rejected("This isn’t an NSP or XCI.")
        }
        let ncas = entries.filter { [".nca", ".ncz"].contains($0.name.lowercased().suffix(4)) }
        guard !ncas.isEmpty else { throw rejected("This NSP or XCI holds no NCAs.") }
        guard Set(ncas.map(\.name)).count == ncas.count else { throw rejected("This NSP or XCI names an NCA twice.") }
        return (ncas, entries.filter { $0.name.lowercased().hasSuffix(".tik") }, card)
    }

    /// True for a ticket whose title key is encrypted for one console's eTicket key, which the shared keys don't
    /// include. Its signature comes first, sized by its type; the title key type is byte 0x141 of the data after it.
    private static func isPersonalized(_ ticket: Entry, in handle: FileHandle) throws -> Bool {
        let signatures: [UInt32: UInt64] = [
            0x10000: 0x23C, 0x10001: 0x13C, 0x10002: 0x7C, 0x10003: 0x23C, 0x10004: 0x13C, 0x10005: 0x7C,
        ]
        guard ticket.size >= 4, let signature = signatures[try read(handle, at: ticket.offset, count: 4).uint32(at: 0)],
            4 + signature + 0x142 <= ticket.size
        else { throw rejected("\(ticket.name) isn’t a ticket.") }
        return try read(handle, at: ticket.offset + 4 + signature + 0x141, count: 1)[0] == 1
    }

    /// The root HFS0 header's offset of an XCI, whose header starts at 0x100, or at 0x1100 when the dump keeps the
    /// card's key area in front of it.
    private static func xciRoot(_ handle: FileHandle, size: UInt64) throws -> UInt64? {
        for base: UInt64 in [0, 0x1000] where size >= base + 0x200 {
            let header = try read(handle, at: base + 0x100, count: 0x40)
            guard header.prefix(4) == Data("HEAD".utf8) else { continue }
            let (root, overflow) = base.addingReportingOverflow(header.uint64(at: 0x30))
            guard !overflow else { throw damaged }
            return root
        }
        return nil
    }

    /// The files of a PFS0 (NSP) or HFS0 (XCI partition) header at `offset`, which must lie within `bounds` with
    /// all of its files.
    private static func partition(_ handle: FileHandle, at offset: UInt64, in bounds: Range<UInt64>, magic: String) throws -> [Entry] {
        let entrySize: UInt64 = magic == "PFS0" ? 0x18 : 0x40
        guard bounds.contains(offset), offset + 0x10 <= bounds.upperBound else { throw damaged }
        let header = try read(handle, at: offset, count: 0x10)
        guard header.prefix(4) == Data(magic.utf8) else { throw damaged }
        let count = UInt64(header.uint32(at: 4)), namesSize = UInt64(header.uint32(at: 8))
        guard count <= 4096, namesSize <= 1 << 20 else { throw damaged }
        let table = try read(handle, at: offset + 0x10, count: Int(count * entrySize + namesSize))
        let names = table.suffix(from: table.startIndex + Int(count * entrySize))
        let data = offset + 0x10 + count * entrySize + namesSize

        var entries: [Entry] = []
        for index in 0..<count {
            let at = Int(index * entrySize)
            let start = table.uint64(at: at), length = table.uint64(at: at + 8), nameOffset = Int(table.uint32(at: at + 16))
            guard nameOffset < names.count, let end = names[(names.startIndex + nameOffset)...].firstIndex(of: 0),
                let name = String(bytes: names[(names.startIndex + nameOffset)..<end], encoding: .utf8),
                !name.isEmpty, name.allSatisfy({ $0.isASCII && $0 != "/" })
            else { throw damaged }
            let (begin, beginOverflow) = data.addingReportingOverflow(start)
            let (finish, finishOverflow) = begin.addingReportingOverflow(length)
            guard !beginOverflow, !finishOverflow, begin >= bounds.lowerBound, finish <= bounds.upperBound else { throw damaged }
            entries.append(Entry(name: name, offset: begin, size: length))
        }
        return entries
    }

    /// The entry's SHA-256, lowercase hex.
    private static func sha256(of entry: Entry, in handle: FileHandle) throws -> String {
        var hasher = SHA256()
        try handle.seek(toOffset: entry.offset)
        var left = entry.size
        while left > 0 {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: Int(min(left, UInt64(ROMFormat.chunkSize)))) ?? Data()
            guard !chunk.isEmpty else { throw damaged }
            hasher.update(data: chunk)
            left -= UInt64(chunk.count)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else { throw damaged }
        return data
    }

    private static var damaged: FrontportError { rejected("This NSP or XCI is damaged: its file table doesn’t fit the file.") }

    private static func rejected(_ reason: String) -> FrontportError { .romRejected(sha1: nil, reason: reason) }
}

/// Nintendo Switch console keys, a `prod.keys` file of `name = hex` lines, reduced to the keys every console
/// shares and decrypting games needs: five keys and sources, then `master_key_00` onwards. The console's own keys
/// (device, BIS and SD card keys, the eTicket RSA key pair, …) are dropped, never stored. The keys every console
/// shares are the same for everyone, so the reduced file is too, and the Catalog can list its hash.
enum ConsoleKeys {
    /// The shared keys besides the master keys, and the hex digits of each.
    static let shared: [(name: String, digits: Int)] = [
        ("aes_kek_generation_source", 32), ("aes_key_generation_source", 32), ("header_key", 64),
        ("key_area_key_application_source", 32), ("titlekek_source", 32),
    ]

    /// One standard form: the shared keys with the first `masterKeys` master keys, one `name = value` line each.
    struct Form: Hashable, Sendable {
        var masterKeys: Int
        var text: String
        var sha1: String { Hashing.sha1(Data(text.utf8)) }
    }

    /// Every standard form of the file, longest first: all its master keys from `master_key_00` without a gap, then
    /// one fewer each time. Each key generation a Switch update added is one more master key, so the Catalog lists
    /// the form for each generation a game may need, and a console with newer keys still yields them.
    static func forms(of url: URL) throws -> [Form] {
        let keys = try values(in: url)
        var lines: [String] = []
        for (name, digits) in shared {
            guard let value = keys[name], value.count == digits else { throw notKeys }
            lines.append("\(name) = \(value)")
        }
        var masters: [String] = []
        while let value = keys[String(format: "master_key_%02x", masters.count)], value.count == 32 {
            masters.append("\(String(format: "master_key_%02x", masters.count)) = \(value)")
        }
        guard !masters.isEmpty else { throw notKeys }
        return (1...masters.count).reversed().map { count in
            Form(masterKeys: count, text: (lines + masters.prefix(count)).joined(separator: "\n") + "\n")
        }
    }

    /// Each `name = value` line whose value is hex, by lowercase name.
    private static func values(in url: URL) throws -> [String: String] {
        guard try FileOperations.size(of: url) <= 1 << 20 else { throw notKeys }
        guard let text = String(data: try FileOperations.readRegularFile(url), encoding: .utf8) else { throw notKeys }
        var keys: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard parts.count == 2, parts[1].allSatisfy(\.isHexDigit) else { continue }
            keys[parts[0]] = parts[1]
        }
        return keys
    }

    private static var notKeys: FrontportError {
        .romRejected(sha1: nil, reason: "This isn’t a Switch keys file with the keys every console shares (header_key, the key sources and master_key_00 onwards).")
    }
}

extension Data {
    func uint32(at offset: Int) -> UInt32 {
        self[(startIndex + offset)..<(startIndex + offset + 4)].reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }

    func uint64(at offset: Int) -> UInt64 {
        self[(startIndex + offset)..<(startIndex + offset + 8)].reversed().reduce(0) { $0 << 8 | UInt64($1) }
    }
}
