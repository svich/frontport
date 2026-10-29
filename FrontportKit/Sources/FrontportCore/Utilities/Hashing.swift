import CryptoKit
import Foundation

/// SHA-1 (ROM identity) and SHA-256 (download digests) as lowercase hex.
public enum Hashing {
    public static func sha1(_ data: Data) -> String { hex(Insecure.SHA1.hash(data: data)) }

    public static func sha256(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

    /// Streams the file, so large ones aren't read into memory. Blocking: call it off the main actor.
    public static func sha1(file url: URL) throws -> String {
        var hasher = Insecure.SHA1()
        try stream(url) { hasher.update(data: $0) }
        return hex(hasher.finalize())
    }

    /// Streams the file, so large ones aren't read into memory. Blocking: call it off the main actor.
    public static func sha256(file url: URL) throws -> String {
        var hasher = SHA256()
        try stream(url) { hasher.update(data: $0) }
        return hex(hasher.finalize())
    }

    private static let chunkSize = 1 << 20

    private static func stream(_ url: URL, _ body: (Data) -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            body(chunk)
        }
    }

    private static func hex(_ digest: some Sequence<UInt8>) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
