import Foundation

/// The JSON settings every Frontport file uses: ISO 8601 dates (whole seconds), sorted keys, pretty printed.
public enum JSON {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func encode(_ value: some Encodable) throws -> Data {
        try encoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder().decode(type, from: data)
    }

    /// Reads and decodes a file.
    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try decode(type, from: Data(contentsOf: url))
    }

    /// Encodes and writes a file atomically.
    public static func write(_ value: some Encodable, to url: URL) throws {
        try encode(value).write(to: url, options: .atomic)
    }
}
