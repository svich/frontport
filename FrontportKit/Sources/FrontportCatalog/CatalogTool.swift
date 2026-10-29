import CryptoKit
import Foundation
import FrontportCore

/// The `frontport-catalog` commands: making keys, signing and verifying the Catalog, and bundling it into
/// the app. Failures throw `FrontportError`; warnings are returned for the caller to print.
public enum CatalogTool {
    /// Writes a new private key and returns its public key, base64.
    public static func keygen(keyFile: URL) throws -> String {
        let key = Curve25519.Signing.PrivateKey()
        try CatalogSignature.write(key, to: keyFile)
        return CatalogSignature.base64(key.publicKey)
    }

    /// Validates `catalog.json`, checks each Recipe's SHA-256 (rewriting `recipeSHA256` when
    /// `updateRecipeHashes`), and writes `catalog.json.sig`. Recipes live relative to the document's folder.
    ///
    /// - Parameter allowMissingRecipes: sign even when a Recipe file doesn't exist yet, with a warning.
    @discardableResult
    public static func sign(
        catalog: URL, keyFile: URL, updateRecipeHashes: Bool = false, allowMissingRecipes: Bool = false
    ) throws -> [String] {
        let key = try CatalogSignature.privateKey(contentsOf: keyFile)
        var data = try Data(contentsOf: catalog)
        let document = try validate(data, name: catalog.lastPathComponent)
        let folder = catalog.deletingLastPathComponent()

        var warnings: [String] = []
        var hashes: [String: String] = [:]
        for pinned in document.pinnedRecipes {
            let file = folder.appending(path: pinned.path)
            guard let actual = try? Hashing.sha256(file: file) else {
                guard allowMissingRecipes else {
                    throw FrontportError.catalogInvalid("\(pinned.owner): \(pinned.path) doesn’t exist.")
                }
                warnings.append("\(pinned.owner): \(pinned.path) doesn’t exist; recipeSHA256 left as it is.")
                hashes[pinned.path] = pinned.sha256
                continue
            }
            if actual != pinned.sha256, !updateRecipeHashes {
                throw FrontportError.catalogInvalid(
                    "\(pinned.owner): \(pinned.path) has SHA-256 \(actual), but the Catalog says \(pinned.sha256).")
            }
            hashes[pinned.path] = actual
        }

        if updateRecipeHashes {
            let updated = Data(try replacingRecipeHashes(in: String(decoding: data, as: UTF8.self), with: hashes).utf8)
            if updated != data {
                _ = try validate(updated, name: catalog.lastPathComponent)
                try updated.write(to: catalog, options: .atomic)
                data = updated
            }
        }

        let signature = try CatalogSignature.sign(data, with: key)
        _ = try CatalogSignature.verifiedDocument(data, signature: signature, publicKey: key.publicKey)
        try signature.write(to: signatureURL(for: catalog), options: .atomic)
        return warnings
    }

    /// Verifies `catalog.json` against `catalog.json.sig` and returns the document.
    public static func verify(
        catalog: URL, publicKey: Curve25519.Signing.PublicKey = CatalogSignature.builtInPublicKey
    ) throws -> CatalogDocument {
        let data = try Data(contentsOf: catalog)
        let signature = try Data(contentsOf: signatureURL(for: catalog))
        let document = try CatalogSignature.verifiedDocument(data, signature: signature, publicKey: publicKey)
        let problems = document.problems()
        guard problems.isEmpty else {
            throw FrontportError.catalogInvalid(problems.joined(separator: "\n"))
        }
        return document
    }

    /// Copies the verified Catalog and the Recipes it names (each checked against its hash) from
    /// `catalogFolder` into `output`, replacing what an earlier bundle put there.
    @discardableResult
    public static func bundle(
        catalogFolder: URL, into output: URL,
        publicKey: Curve25519.Signing.PublicKey = CatalogSignature.builtInPublicKey
    ) throws -> [String] {
        let source = catalogFolder.appending(path: CatalogStore.documentName)
        let document = try verify(catalog: source, publicKey: publicKey)
        let fileManager = FileManager.default

        var warnings: [String] = []
        do {
            try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
            for name in [CatalogStore.documentName, CatalogStore.signatureName, "recipes"] {
                let target = output.appending(path: name)
                if fileManager.fileExists(atPath: target.path(percentEncoded: false)) {
                    try fileManager.removeItem(at: target)
                }
            }
            for name in [CatalogStore.documentName, CatalogStore.signatureName] {
                try fileManager.copyItem(at: catalogFolder.appending(path: name), to: output.appending(path: name))
            }
            for pinned in document.pinnedRecipes {
                let recipe = catalogFolder.appending(path: pinned.path)
                guard fileManager.fileExists(atPath: recipe.path(percentEncoded: false)) else {
                    warnings.append("\(pinned.owner): \(pinned.path) doesn’t exist, so Frontport will fetch it when needed.")
                    continue
                }
                guard CatalogStore.file(recipe, matches: pinned.sha256) else {
                    throw FrontportError.catalogInvalid("\(pinned.owner): \(pinned.path) doesn’t match its recipeSHA256.")
                }
                let target = output.appending(path: pinned.path)
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !fileManager.fileExists(atPath: target.path(percentEncoded: false)) {
                    try fileManager.copyItem(at: recipe, to: target)
                }
            }
        } catch let error as FrontportError {
            throw error
        } catch {
            throw FrontportError.fileOperation("Couldn’t bundle the Catalog: \(error.localizedDescription)")
        }
        return warnings
    }

    // MARK: Helpers

    static func signatureURL(for catalog: URL) -> URL {
        catalog.deletingLastPathComponent().appending(path: catalog.lastPathComponent + ".sig")
    }

    private static func validate(_ data: Data, name: String) throws -> CatalogDocument {
        let document: CatalogDocument
        do {
            document = try JSON.decode(CatalogDocument.self, from: data)
        } catch {
            throw FrontportError.catalogInvalid("\(name) isn’t a valid Catalog: \(error)")
        }
        guard document.version == CatalogDocument.supportedVersion else {
            throw FrontportError.catalogInvalid("\(name) is version \(document.version); this tool writes version \(CatalogDocument.supportedVersion).")
        }
        let problems = document.problems()
        guard problems.isEmpty else {
            throw FrontportError.catalogInvalid(problems.joined(separator: "\n"))
        }
        return document
    }

    /// Rewrites each `"recipeSHA256": "…"` value with the hash of the Recipe the `"recipe"` field before it names, in
    /// its own object, leaving the rest of the text untouched. `hashes` maps each pinned Recipe's path to its hash.
    static func replacingRecipeHashes(in text: String, with hashes: [String: String]) throws -> String {
        let field = #/"recipeSHA256"\s*:\s*"([^"]*)"/#
        let recipe = #/"recipe"\s*:\s*"([^"]*)"/#
        var result = ""
        var position = text.startIndex
        for match in text.matches(of: field) {
            guard let path = text[position..<match.range.lowerBound].matches(of: recipe).last?.output.1,
                let hash = hashes[String(path)]
            else {
                throw FrontportError.catalogInvalid("A recipeSHA256 field doesn’t follow its recipe; edit it by hand.")
            }
            let value = match.output.1
            result += text[position..<value.startIndex]
            result += hash
            position = value.endIndex
        }
        result += text[position...]
        return result
    }
}
