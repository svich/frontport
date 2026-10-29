import CryptoKit
import Foundation
import FrontportCatalog
import FrontportCore

let usage = """
    usage: frontport-catalog keygen <key-file>
           frontport-catalog sign --key <key-file> [--update-recipe-hashes] [--allow-missing-recipes] <catalog.json>
           frontport-catalog verify [--public-key <base64>] <catalog.json>
           frontport-catalog bundle [--public-key <base64>] <catalog-dir> <out-dir>

    verify and bundle use the public key built into Frontport unless --public-key is given.
    """

struct UsageError: Error {}

/// Splits arguments into `--option value` pairs, bare flags and positionals.
struct Arguments {
    var options: [String: String] = [:]
    var flags: Set<String> = []
    var positionals: [String] = []

    init(_ arguments: ArraySlice<String>, options valued: Set<String>, flags known: Set<String>) throws {
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            if valued.contains(argument) {
                guard let value = iterator.next() else { throw UsageError() }
                options[argument] = value
            } else if known.contains(argument) {
                flags.insert(argument)
            } else if argument.hasPrefix("--") {
                throw UsageError()
            } else {
                positionals.append(argument)
            }
        }
    }
}

func fileURL(_ path: String) -> URL {
    URL(filePath: path, relativeTo: URL.currentDirectory()).absoluteURL
}

func publicKey(_ arguments: Arguments) throws -> Curve25519.Signing.PublicKey {
    try arguments.options["--public-key"].map(CatalogSignature.publicKey(base64:)) ?? CatalogSignature.builtInPublicKey
}

func printWarnings(_ warnings: [String]) {
    for warning in warnings {
        FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
    }
}

func run(_ command: String, _ rest: ArraySlice<String>) throws {
    switch command {
    case "keygen":
        let arguments = try Arguments(rest, options: [], flags: [])
        guard arguments.positionals.count == 1 else { throw UsageError() }
        let key = try CatalogTool.keygen(keyFile: fileURL(arguments.positionals[0]))
        print(key)

    case "sign":
        let arguments = try Arguments(
            rest, options: ["--key"], flags: ["--update-recipe-hashes", "--allow-missing-recipes"])
        guard let key = arguments.options["--key"], arguments.positionals.count == 1 else { throw UsageError() }
        let catalog = fileURL(arguments.positionals[0])
        let warnings = try CatalogTool.sign(
            catalog: catalog, keyFile: fileURL(key),
            updateRecipeHashes: arguments.flags.contains("--update-recipe-hashes"),
            allowMissingRecipes: arguments.flags.contains("--allow-missing-recipes"))
        printWarnings(warnings)
        print("Signed \(catalog.lastPathComponent).")

    case "verify":
        let arguments = try Arguments(rest, options: ["--public-key"], flags: [])
        guard arguments.positionals.count == 1 else { throw UsageError() }
        let document = try CatalogTool.verify(catalog: fileURL(arguments.positionals[0]), publicKey: publicKey(arguments))
        print("Verified: version \(document.version), issued \(document.issued.ISO8601Format()), \(document.ports.count) Ports.")

    case "bundle":
        let arguments = try Arguments(rest, options: ["--public-key"], flags: [])
        guard arguments.positionals.count == 2 else { throw UsageError() }
        let output = fileURL(arguments.positionals[1])
        let warnings = try CatalogTool.bundle(
            catalogFolder: fileURL(arguments.positionals[0]), into: output, publicKey: publicKey(arguments))
        printWarnings(warnings)
        print("Bundled into \(output.path(percentEncoded: false)).")

    default:
        throw UsageError()
    }
}

let commandLine = CommandLine.arguments.dropFirst()
do {
    guard let command = commandLine.first else { throw UsageError() }
    try run(command, commandLine.dropFirst())
} catch is UsageError {
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(64)
} catch {
    let message = (error as? FrontportError)?.errorDescription ?? error.localizedDescription
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}
