import Foundation

/// Recognizes Mach-O files by their magic bytes, never by extension, and reads what one was built for.
enum MachO {
    enum FileType: Hashable, Sendable {
        /// `MH_EXECUTE`: a program.
        case executable
        /// `MH_DYLIB` or `MH_BUNDLE`: code another process loads.
        case library
        case other
    }

    private static let executableType: UInt32 = 0x2  // MH_EXECUTE
    private static let loadableTypes: Set<UInt32> = [0x6, 0x8]  // MH_DYLIB, MH_BUNDLE

    /// The file's Mach-O type, or nil when it isn't Mach-O. For a universal binary, the first slice's type.
    static func fileType(of url: URL) -> FileType? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 32), header.count >= 16 else { return nil }

        switch header.prefix(4).map({ $0 }) {
        case [0xCF, 0xFA, 0xED, 0xFE], [0xCE, 0xFA, 0xED, 0xFE]:
            return classify(header.uint32(at: 12, bigEndian: false))
        case [0xFE, 0xED, 0xFA, 0xCF], [0xFE, 0xED, 0xFA, 0xCE]:
            return classify(header.uint32(at: 12, bigEndian: true))
        case [0xCA, 0xFE, 0xBA, 0xBE], [0xCA, 0xFE, 0xBA, 0xBF]:
            // Java class files share FAT_MAGIC; their next word (the class version) is far above any arch count.
            let count = header.uint32(at: 4, bigEndian: true)
            guard count > 0, count < 32, header.count >= 32 else { return nil }
            let is64 = header[header.startIndex + 3] == 0xBF
            let offset = is64 ? header.uint64(at: 16) : UInt64(header.uint32(at: 16, bigEndian: true))
            guard (try? handle.seek(toOffset: offset)) != nil,
                let slice = try? handle.read(upToCount: 16), slice.count == 16
            else { return nil }
            switch slice.prefix(4).map({ $0 }) {
            case [0xCF, 0xFA, 0xED, 0xFE], [0xCE, 0xFA, 0xED, 0xFE]:
                return classify(slice.uint32(at: 12, bigEndian: false))
            default:
                return nil
            }
        default:
            return nil
        }
    }

    private static func classify(_ type: UInt32) -> FileType {
        if type == executableType { return .executable }
        if loadableTypes.contains(type) { return .library }
        return .other
    }

    // MARK: Build

    /// What an arm64 slice says it was built for, which decides whether a Device can run it.
    struct Build: Hashable, Sendable {
        var platform: Platform
        /// The oldest version of its platform it runs on.
        var minimumOS: Version
        /// The SDK it was built with.
        var sdk: Version
        /// True when the App Store encrypted it (`cryptid` not 0), so it can't be signed again. Upstream builds carry
        /// the command with `cryptid` 0.
        var isEncrypted: Bool
    }

    /// A Mach-O platform, as `LC_BUILD_VERSION` numbers it.
    struct Platform: RawRepresentable, Hashable, Sendable {
        let rawValue: UInt32
        init(rawValue: UInt32) { self.rawValue = rawValue }

        static let macOS = Platform(rawValue: 1)
        static let iOS = Platform(rawValue: 2)
        static let tvOS = Platform(rawValue: 3)
        static let watchOS = Platform(rawValue: 4)
        static let macCatalyst = Platform(rawValue: 6)
        static let iOSSimulator = Platform(rawValue: 7)
    }

    /// A version packed as `xxxx.yy.zz` in 32 bits.
    struct Version: Hashable, Comparable, Sendable, CustomStringConvertible {
        let packed: UInt32
        var major: Int { Int(packed >> 16) }
        var minor: Int { Int((packed >> 8) & 0xFF) }
        var patch: Int { Int(packed & 0xFF) }

        /// Such as "11.0" or "16.2.1".
        var description: String { patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)" }
        static func < (a: Self, b: Self) -> Bool { a.packed < b.packed }
    }

    private static let cpuTypeARM64: UInt32 = 0x0100_000C
    private static let buildVersionCommand: UInt32 = 0x32  // LC_BUILD_VERSION
    /// `LC_VERSION_MIN_*`, which builds for older systems carry instead, such as Fallout CE's iOS 11 one.
    private static let legacyVersionCommands: [UInt32: Platform] = [
        0x24: .macOS, 0x25: .iOS, 0x2F: .tvOS, 0x30: .watchOS,
    ]
    private static let encryptionCommands: Set<UInt32> = [0x21, 0x2C]  // LC_ENCRYPTION_INFO, LC_ENCRYPTION_INFO_64
    /// More than any real binary's load commands, so a corrupt size can't make Frontport read a whole file.
    private static let maxCommandsSize: UInt32 = 16 << 20

    /// What the file's arm64 slice, thin or in a universal binary, was built for, from the first platform its load
    /// commands name. Nil when it isn't Mach-O, has no arm64 slice, names no platform, or doesn't hold together.
    static func build(of url: URL) -> Build? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let offset = arm64Slice(handle),
            (try? handle.seek(toOffset: offset)) != nil,
            let header = try? handle.read(upToCount: 32), header.count == 32,
            header.prefix(4).elementsEqual([0xCF, 0xFA, 0xED, 0xFE]),
            header.uint32(at: 4, bigEndian: false) == cpuTypeARM64
        else { return nil }
        let count = header.uint32(at: 16, bigEndian: false)
        let size = header.uint32(at: 20, bigEndian: false)
        guard size <= maxCommandsSize, UInt64(count) * 8 <= UInt64(size),
            let commands = try? handle.read(upToCount: Int(size)), commands.count == Int(size)
        else { return nil }

        var platform: (Platform, minimumOS: UInt32, sdk: UInt32)?
        var isEncrypted = false
        var position = 0
        for _ in 0..<count {
            guard position + 8 <= commands.count else { return nil }
            let command = commands.uint32(at: position, bigEndian: false)
            let length = Int(commands.uint32(at: position + 4, bigEndian: false))
            guard length >= 8, position + length <= commands.count else { return nil }
            if command == buildVersionCommand, length >= 24, platform == nil {
                platform = (
                    Platform(rawValue: commands.uint32(at: position + 8, bigEndian: false)),
                    commands.uint32(at: position + 12, bigEndian: false),
                    commands.uint32(at: position + 16, bigEndian: false))
            } else if let legacy = legacyVersionCommands[command], length >= 16, platform == nil {
                platform = (
                    legacy, commands.uint32(at: position + 8, bigEndian: false),
                    commands.uint32(at: position + 12, bigEndian: false))
            } else if encryptionCommands.contains(command), length >= 20 {
                isEncrypted = isEncrypted || commands.uint32(at: position + 16, bigEndian: false) != 0
            }
            position += length
        }
        guard let platform else { return nil }
        return Build(
            platform: platform.0, minimumOS: Version(packed: platform.minimumOS), sdk: Version(packed: platform.sdk),
            isEncrypted: isEncrypted)
    }

    /// Where the arm64 slice starts: 0 for a thin file, which `build` then checks, or its offset in a universal one.
    private static func arm64Slice(_ handle: FileHandle) -> UInt64? {
        guard let header = try? handle.read(upToCount: 8), header.count == 8 else { return nil }
        let magic = header.prefix(4).map { $0 }
        guard magic == [0xCA, 0xFE, 0xBA, 0xBE] || magic == [0xCA, 0xFE, 0xBA, 0xBF] else { return 0 }
        let is64 = magic[3] == 0xBF
        let count = header.uint32(at: 4, bigEndian: true)
        let entrySize = is64 ? 32 : 20
        guard count > 0, count < 32, let entries = try? handle.read(upToCount: Int(count) * entrySize),
            entries.count == Int(count) * entrySize
        else { return nil }
        for index in 0..<Int(count) {
            let entry = index * entrySize
            guard entries.uint32(at: entry, bigEndian: true) == cpuTypeARM64 else { continue }
            return is64 ? entries.uint64(at: entry + 8) : UInt64(entries.uint32(at: entry + 8, bigEndian: true))
        }
        return nil
    }
}

extension Data {
    fileprivate func uint32(at offset: Int, bigEndian: Bool) -> UInt32 {
        let bytes = self[(startIndex + offset)..<(startIndex + offset + 4)]
        let value = bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return bigEndian ? value : value.byteSwapped
    }

    fileprivate func uint64(at offset: Int) -> UInt64 {
        self[(startIndex + offset)..<(startIndex + offset + 8)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }
}
