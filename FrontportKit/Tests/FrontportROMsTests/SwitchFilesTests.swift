import CryptoKit
import Foundation
import FrontportCore
import Testing
@testable import FrontportROMs

/// Synthetic Switch files: NCAs of noise, named by their content ID, in NSP and XCI containers.
enum SyntheticSwitch {
    /// An NCA's file name: its content ID (the first half of its SHA-256), then `.nca` or `.cnmt.nca`.
    static func name(_ nca: Data, meta: Bool = false) -> String {
        String(SHA256.hash(data: nca).map { String(format: "%02x", $0) }.joined().prefix(32)) + (meta ? ".cnmt.nca" : ".nca")
    }

    static let program = Synthetic.noise(300_000, seed: 1)
    static let control = Synthetic.noise(5_000, seed: 2)
    static let meta = Synthetic.noise(700, seed: 3)

    /// The game's NCAs, with the meta NCA last.
    static var ncas: [(String, Data)] {
        [(name(program), program), (name(control), control), (name(meta, meta: true), meta)]
    }

    /// SHA-1 of the sorted content IDs but the meta NCA's, as the Catalog lists it.
    static var identity: String { identity(of: [name(program), name(control)]) }

    /// The identity of NCAs with these names.
    static func identity(of names: [String]) -> String {
        Hashing.sha1(Data((names.map { String($0.prefix(32)) }.sorted().joined(separator: "\n") + "\n").utf8))
    }

    /// A PFS0 (NSP) or HFS0 (XCI partition) holding `files` in order.
    static func partition(_ magic: String, _ files: [(String, Data)]) -> Data {
        let entrySize = magic == "PFS0" ? 0x18 : 0x40
        var names = Data()
        var offsets: [(Int, Int)] = []
        for (name, _) in files {
            offsets.append((names.count, 0))
            names.append(Data(name.utf8) + [0])
        }
        while names.count % 16 != 0 { names.append(0) }
        var header = Data(magic.utf8)
        header.append(le32(files.count) + le32(names.count) + le32(0))
        var dataOffset = 0
        for (index, (_, bytes)) in files.enumerated() {
            var entry = le64(dataOffset) + le64(bytes.count) + le32(offsets[index].0) + le32(0)
            entry.append(Data(count: entrySize - entry.count))
            header.append(entry)
            dataOffset += bytes.count
        }
        return header + names + files.reduce(Data()) { $0 + $1.1 }
    }

    static func nsp(_ files: [(String, Data)]) -> Data { partition("PFS0", files) }

    /// A game card image: its header at 0x100, the root HFS0 at 0x200 with an empty update partition and the secure
    /// partition holding `files`. With `keyArea`, the 0x1000 bytes some dumps keep in front come first.
    static func xci(_ files: [(String, Data)], keyArea: Bool = false) -> Data {
        let secure = partition("HFS0", files)
        let root = partition("HFS0", [("update", partition("HFS0", [])), ("secure", secure)])
        var card = Data(count: 0x200)
        card.replaceSubrange(0x100..<0x104, with: Data("HEAD".utf8))
        card.replaceSubrange(0x130..<0x138, with: le64(0x200))
        card.replaceSubrange(0x138..<0x140, with: le64(root.count))
        return (keyArea ? Data(count: 0x1000) : Data()) + card + root
    }

    static func le32(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).littleEndian) { Data($0) } }
    static func le64(_ value: Int) -> Data { withUnsafeBytes(of: UInt64(value).littleEndian) { Data($0) } }

    /// A full prod.keys: shared keys, then console-unique ones and the master keys.
    static func keys(masterKeys: Int, console: String = "11") -> String {
        var lines = [
            "aes_kek_generation_source = A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1",
            "aes_key_generation_source = A2A2A2A2A2A2A2A2A2A2A2A2A2A2A2A2",
            "bis_key_00 = \(String(repeating: console, count: 32))",
            "device_key_4x = \(String(repeating: console, count: 16))",
            "header_key = \(String(repeating: "AB", count: 32))",
            "key_area_key_application_source = A3A3A3A3A3A3A3A3A3A3A3A3A3A3A3A3",
            "titlekek_source = A4A4A4A4A4A4A4A4A4A4A4A4A4A4A4A4",
        ]
        for index in 0..<masterKeys {
            lines.append(String(format: "master_key_%02x = ", index) + String(repeating: String(format: "%02X", index), count: 16))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

@Suite struct SwitchFilesTests {
    @Test func nspIsKnownByMagicAndIdentifiedByItsContent() throws {
        let tmp = try TemporaryDirectory()
        let nsp = try tmp.file("game", SyntheticSwitch.nsp(SyntheticSwitch.ncas))
        #expect(try ROMFormat.detect(nsp) == ROMFormat("nsp", .contents))
        #expect(try SwitchContents.identity(of: nsp) == SyntheticSwitch.identity)
    }

    @Test func otherContainersOfTheSameNCAsAreTheSameROM() throws {
        let tmp = try TemporaryDirectory()
        let ncas = SyntheticSwitch.ncas
        let ticketed = SyntheticSwitch.nsp(
            [("0100aaaa000000000000000000000000.tik", SwitchFilesTests.ticket(personalized: false))] + ncas.reversed()
                + [("00000000000000000000000000000000.cnmt.xml", Data("<ContentMeta/>".utf8))])
        let files = [
            try tmp.file("ticketed.nsp", ticketed),
            try tmp.file("card.xci", SyntheticSwitch.xci(ncas)),
            try tmp.file("full.xci", SyntheticSwitch.xci(ncas, keyArea: true)),
        ]
        #expect(try ROMFormat.detect(files[1]) == ROMFormat("xci", .contents))
        for file in files {
            #expect(try SwitchContents.identity(of: file) == SyntheticSwitch.identity)
        }
    }

    @Test func misnamedNCAsAreRefused() throws {
        let tmp = try TemporaryDirectory()
        let cases = [
            SyntheticSwitch.nsp([("program.nca", SyntheticSwitch.program)]),
            SyntheticSwitch.nsp([(SyntheticSwitch.name(SyntheticSwitch.meta, meta: true), SyntheticSwitch.meta)]),
            SyntheticSwitch.nsp([("readme.txt", Data("hi".utf8))]),
        ]
        for (index, bytes) in cases.enumerated() {
            let file = try tmp.file("case\(index).nsp", bytes)
            #expect(throws: FrontportError.self) { try SwitchContents.identity(of: file) }
        }
    }

    /// As each NCA of a game card dump a tool converted to an NSP is: it counts by its own hash, so no ROM in the
    /// Catalog has the identity, and the note says why.
    @Test func anAlteredNCACountsByItsOwnHash() throws {
        let tmp = try TemporaryDirectory()
        var altered = SyntheticSwitch.program
        altered[1000] ^= 0xFF
        let file = try tmp.file(
            "converted.nsp", SyntheticSwitch.nsp([(SyntheticSwitch.name(SyntheticSwitch.program), altered), SyntheticSwitch.ncas[1]]))

        let identified = try SwitchContents.identify(file)

        #expect(identified.sha1 == SyntheticSwitch.identity(of: [SyntheticSwitch.name(altered), SyntheticSwitch.name(SyntheticSwitch.control)]))
        #expect(identified.format == "nsp")
        #expect(identified.note?.contains("content IDs") == true)
        #expect(try SwitchContents.identify(try tmp.file("game.nsp", SyntheticSwitch.nsp(SyntheticSwitch.ncas))).note == nil)
    }

    /// An NCZ counts by its own hash too: nothing here can rebuild the NCA it holds.
    @Test func nszAndXCZAreToldByTheirNCZs() throws {
        let tmp = try TemporaryDirectory()
        let ncz = Synthetic.noise(9_000, seed: 6)
        let files = [(String(SyntheticSwitch.name(SyntheticSwitch.program).prefix(32)) + ".ncz", ncz)] + SyntheticSwitch.ncas.dropFirst()
        let expected = SyntheticSwitch.identity(of: [SyntheticSwitch.name(ncz), SyntheticSwitch.name(SyntheticSwitch.control)])

        let nsz = try SwitchContents.identify(try tmp.file("game.nsz", SyntheticSwitch.nsp(Array(files))))
        let xcz = try SwitchContents.identify(try tmp.file("game.xcz", SyntheticSwitch.xci(Array(files))))

        #expect(nsz.format == "nsz" && xcz.format == "xcz")
        #expect(nsz.sha1 == expected && xcz.sha1 == expected)
        #expect(nsz.note?.contains("nsz") == true)
    }

    /// A ticket: an RSA-2048 SHA-256 signature, then its data, whose title key type is byte 0x141.
    static func ticket(personalized: Bool) -> Data {
        var ticket = Data([0x04, 0x00, 0x01, 0x00]) + Data(count: 0x13C + 0x180)
        ticket[4 + 0x13C + 0x141] = personalized ? 1 : 0
        return ticket
    }

    @Test func personalizedTicketsAreRefusedAndCommonOnesKept() throws {
        let tmp = try TemporaryDirectory()
        let common = try tmp.file("common.nsp", SyntheticSwitch.nsp(SyntheticSwitch.ncas + [("0100aaaa000000000000000000000000.tik", Self.ticket(personalized: false))]))
        #expect(try SwitchContents.identity(of: common) == SyntheticSwitch.identity)
        let personal = try tmp.file("personal.nsp", SyntheticSwitch.nsp(SyntheticSwitch.ncas + [("0100aaaa000000000000000000000000.tik", Self.ticket(personalized: true))]))
        #expect(throws: FrontportError.self) { try SwitchContents.identity(of: personal) }
    }

    @Test func aCardHeaderPointingPastTheEndIsRefused() throws {
        let tmp = try TemporaryDirectory()
        var card = SyntheticSwitch.xci(SyntheticSwitch.ncas, keyArea: true)
        card.replaceSubrange(0x1130..<0x1138, with: Data(repeating: 0xFF, count: 8))
        let file = try tmp.file("broken.xci", card)
        #expect(throws: FrontportError.self) { try SwitchContents.identity(of: file) }
    }

    @Test func truncatedOrOverlongTablesAreRefused() throws {
        let tmp = try TemporaryDirectory()
        let whole = SyntheticSwitch.nsp(SyntheticSwitch.ncas)
        let truncated = try tmp.file("truncated.nsp", whole.prefix(whole.count - 10))
        #expect(throws: FrontportError.self) { try SwitchContents.identity(of: truncated) }

        var huge = whole
        huge.replaceSubrange(4..<8, with: SyntheticSwitch.le32(1_000_000))
        let overlong = try tmp.file("overlong.nsp", huge)
        #expect(throws: FrontportError.self) { try SwitchContents.identity(of: overlong) }
    }

    @Test func keysKeepOnlyWhatEveryConsoleShares() throws {
        let tmp = try TemporaryDirectory()
        let mine = try tmp.file("prod.keys", Data(SyntheticSwitch.keys(masterKeys: 4, console: "11").utf8))
        let theirs = try tmp.file("theirs/prod.keys", Data(SyntheticSwitch.keys(masterKeys: 4, console: "22").utf8))
        #expect(try ROMFormat.detect(mine) == ROMFormat("keys", .keys))

        let forms = try ConsoleKeys.forms(of: mine)
        #expect(forms.map(\.masterKeys) == [4, 3, 2, 1])
        #expect(try ConsoleKeys.forms(of: theirs) == forms)
        let longest = try #require(forms.first?.text)
        #expect(!longest.contains("bis_key") && !longest.contains("device_key"))
        #expect(longest.hasPrefix("aes_kek_generation_source = a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1\n"))
        #expect(longest.hasSuffix("master_key_03 = 03030303030303030303030303030303\n"))
    }

    @Test func newerKeysStillYieldTheFormsTheCatalogLists() async throws {
        let tmp = try TemporaryDirectory()
        let older = try tmp.file("older.keys", Data(SyntheticSwitch.keys(masterKeys: 3).utf8))
        let newer = try tmp.file("newer.keys", Data(SyntheticSwitch.keys(masterKeys: 5).utf8))
        let listed = try #require(ConsoleKeys.forms(of: older).first).sha1
        let work = tmp.url.appending(path: "work", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        let candidate = try await Intake.prepare(newer, in: work) { $0 == listed }
        #expect(candidate.sha1 == listed)
        #expect(try String(contentsOf: candidate.file, encoding: .utf8) == ConsoleKeys.forms(of: older).first?.text)
    }

    @Test func filesWithoutTheSharedKeysAreRefused() throws {
        let tmp = try TemporaryDirectory()
        let title = try tmp.file("title.keys", Data("0100aaaa000000000000000000000000 = 00112233445566778899aabbccddeeff\n".utf8))
        #expect(throws: FrontportError.self) { try ConsoleKeys.forms(of: title) }
        let noMasters = SyntheticSwitch.keys(masterKeys: 0)
        let partial = try tmp.file("partial.keys", Data(noMasters.utf8))
        #expect(throws: FrontportError.self) { try ConsoleKeys.forms(of: partial) }
    }
}

/// Prints the hashes the Catalog lists for real Switch files: an NSP's or XCI's content identity, or each standard
/// form of a keys file (its key values are never printed). Opt-in, since an NSP can be tens of gigabytes:
///
///     FRONTPORT_SWITCH_FILES=/path/game.nsp,/path/prod.keys swift test --filter SwitchFileHashes
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FRONTPORT_SWITCH_FILES"] != nil))
struct SwitchFileHashes {
    @Test func printsTheHashesOfTheGivenFiles() throws {
        let paths = (ProcessInfo.processInfo.environment["FRONTPORT_SWITCH_FILES"] ?? "").split(separator: ",")
        for path in paths {
            let url = URL(fileURLWithPath: String(path))
            switch try ROMFormat.detect(url).standardization {
            case .contents:
                let identified = try SwitchContents.identify(url)
                print("\(url.lastPathComponent): \(identified.sha1)\(identified.note.map { " (\($0))" } ?? "")")
            case .keys:
                for form in try ConsoleKeys.forms(of: url) {
                    print(String(format: "%@ through master_key_%02x: %@", url.lastPathComponent, form.masterKeys - 1, form.sha1))
                }
            default:
                Issue.record("\(url.lastPathComponent) isn’t an NSP, XCI or keys file")
            }
        }
    }
}
