import FrontportCore
import Foundation

/// Recreates a Port's `Data/` without running the Port: wraps a trivial executable in a stand-in app with the
/// Port's bundle ID, signs it ad hoc with only the App Sandbox entitlement, and runs it once. Starting any
/// sandboxed process with that bundle ID makes macOS lay out the container's Data before `main` runs.
public struct ContainerPrimer: ContainerPriming {
    /// A program that exits at once, such as `frontport-primer` inside Frontport.app.
    private let executable: URL
    private let paths: AppPaths
    private let codesign: URL
    private let runner = ProcessRunner()

    public init(executable: URL, paths: AppPaths, codesign: URL = URL(filePath: "/usr/bin/codesign")) {
        self.executable = executable
        self.paths = paths
        self.codesign = codesign
    }

    public func prime(_ entry: CatalogEntry) async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "frontport-primer-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileOperations.createDirectory(folder)
        defer { try? FileManager.default.removeItem(at: folder) }

        let app = folder.appending(path: "Primer.app", directoryHint: .isDirectory)
        let macOS = app.appending(path: "Contents/MacOS", directoryHint: .isDirectory)
        try FileOperations.createDirectory(macOS, mode: 0o755)
        let program = macOS.appending(path: "primer")
        let info: [String: Any] = [
            "CFBundleIdentifier": entry.bundleId,
            "CFBundleExecutable": "primer",
            "CFBundleName": entry.name,
            "CFBundlePackageType": "APPL",
            "LSUIElement": true,
        ]
        let entitlements = folder.appending(path: "primer.entitlements")
        do {
            try FileManager.default.copyItem(at: executable, to: program)
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: app.appending(path: "Contents/Info.plist"))
            try PortEntitlements.plist([PortEntitlements.sandbox: true]).write(to: entitlements)
        } catch {
            throw FrontportError.fileOperation("Couldn’t prepare \(entry.name)’s Data: \(error.localizedDescription)")
        }
        try FileOperations.removeQuarantine(app)

        let signed = try await runner.run(codesign, arguments: [
            "--force", "--sign", "-", "--options", "runtime", "--entitlements", entitlements.path(percentEncoded: false),
            app.path(percentEncoded: false),
        ])
        guard signed.succeeded else {
            throw FrontportError.signingFailed(signed.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        try Task.checkCancellation()

        let result = try await runner.run(program, stdout: .discard, stderr: .capture)
        let data = paths.data(for: entry.bundleId)
        guard result.succeeded, FileManager.default.fileExists(atPath: data.path(percentEncoded: false)) else {
            throw FrontportError.processFailed(
                command: "Preparing \(entry.name)’s Data", status: result.status,
                output: result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
