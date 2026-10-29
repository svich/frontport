import CryptoKit
import Foundation
import FrontportCore

/// Ed25519 signing of the Catalog. `catalog.json.sig` holds the base64 detached signature over the exact
/// bytes of `catalog.json`, followed by a newline.
public enum CatalogSignature {
    /// DEVELOPMENT KEY. Its private half is `catalog/dev.key`, which is never committed. A release build
    /// replaces this with the release key's public half; see catalog/README.md.
    public static let builtInPublicKeyBase64 = "vcdxGTYC02uARNy6AP5En27gbhD+1WdiM3ZEfPWlQTg="

    /// The key Frontport verifies every Catalog with.
    public static var builtInPublicKey: Curve25519.Signing.PublicKey {
        // A malformed constant is caught by the test suite.
        try! publicKey(base64: builtInPublicKeyBase64)
    }

    public static func publicKey(base64: String) throws -> Curve25519.Signing.PublicKey {
        guard let raw = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw FrontportError.catalogInvalid("The public key isn’t base64.")
        }
        do {
            return try Curve25519.Signing.PublicKey(rawRepresentation: raw)
        } catch {
            throw FrontportError.catalogInvalid("The public key isn’t an Ed25519 key.")
        }
    }

    public static func base64(_ key: Curve25519.Signing.PublicKey) -> String {
        key.rawRepresentation.base64EncodedString()
    }

    // MARK: Private keys

    /// Reads a private key file: the base64 raw key on one line.
    public static func privateKey(contentsOf url: URL) throws -> Curve25519.Signing.PrivateKey {
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        guard let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
            let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        else {
            throw FrontportError.catalogInvalid("\(url.lastPathComponent) isn’t an Ed25519 private key.")
        }
        return key
    }

    /// Writes a new private key file readable only by its owner. Never overwrites an existing key.
    public static func write(_ key: Curve25519.Signing.PrivateKey, to url: URL) throws {
        let path = url.path(percentEncoded: false)
        guard !FileManager.default.fileExists(atPath: path) else {
            throw FrontportError.fileOperation("\(url.lastPathComponent) already exists; delete it first to replace the key.")
        }
        let contents = Data((key.rawRepresentation.base64EncodedString() + "\n").utf8)
        guard FileManager.default.createFile(atPath: path, contents: contents, attributes: [.posixPermissions: 0o600]) else {
            throw FrontportError.fileOperation("Couldn’t write \(url.lastPathComponent).")
        }
    }

    // MARK: Signatures

    /// The contents of a `.sig` file for `data`.
    public static func sign(_ data: Data, with key: Curve25519.Signing.PrivateKey) throws -> Data {
        Data((try key.signature(for: data).base64EncodedString() + "\n").utf8)
    }

    /// True when `signatureFile` (a `.sig` file's contents) is a valid signature of `data`.
    public static func isValid(_ signatureFile: Data, for data: Data, publicKey: Curve25519.Signing.PublicKey) -> Bool {
        let text = String(decoding: signatureFile, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let signature = Data(base64Encoded: text) else { return false }
        return publicKey.isValidSignature(signature, for: data)
    }

    /// Verifies the signature over the exact bytes, then decodes the document and checks its version.
    /// Throws `catalogInvalid` for any failure.
    public static func verifiedDocument(
        _ data: Data, signature: Data, publicKey: Curve25519.Signing.PublicKey
    ) throws -> CatalogDocument {
        guard isValid(signature, for: data, publicKey: publicKey) else {
            throw FrontportError.catalogInvalid("Its signature doesn’t match.")
        }
        let document: CatalogDocument
        do {
            document = try JSON.decode(CatalogDocument.self, from: data)
        } catch {
            throw FrontportError.catalogInvalid("It couldn’t be read: \(error).")
        }
        guard document.version == CatalogDocument.supportedVersion else {
            throw FrontportError.catalogInvalid(
                "It uses version \(document.version), but this Frontport reads version \(CatalogDocument.supportedVersion).")
        }
        return document
    }
}
