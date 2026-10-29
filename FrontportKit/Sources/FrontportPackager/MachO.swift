import Foundation

/// Recognizes Mach-O files by their magic bytes, never by extension.
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
