import Foundation
import FrontportCore

/// Runs Recipes in the build sandbox: `recipe.sh fetch` with network, then `recipe.sh build` without,
/// each under its own `sandbox-exec` profile. See catalog/recipes/README.md for the Recipe contract.
public actor RecipeBuilder: RecipeBuilding {
    private let paths: AppPaths
    private let developerTools: DeveloperTools
    private let installer: ToolchainInstaller
    private let home: URL
    /// The install in progress, which concurrent callers join.
    private var installing: Task<Void, any Error>?

    /// - Parameters:
    ///   - home: the folder the sandbox denies as a whole; the user's home folder outside tests.
    public init(
        paths: AppPaths = .default,
        manifest: ToolchainManifest = .pinned,
        developerTools: DeveloperTools = .system,
        download: ToolchainDownload? = nil,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.paths = paths
        self.developerTools = developerTools
        self.installer = ToolchainInstaller(paths: paths, manifest: manifest, download: download ?? ToolchainInstaller.urlSession)
        self.home = home
    }

    // MARK: Toolchain

    public func toolchainStatus() async -> ToolchainStatus {
        guard await developerTools.directory() != nil else { return .needsCommandLineTools }
        return installer.isInstalled ? .ready : .needsPrefix
    }

    /// Without the Command Line Tools this shows the system installer and throws `toolchainMissing` at once;
    /// call it again once they're installed.
    public func prepareToolchain(progress: @escaping ProgressHandler) async throws {
        guard await developerTools.directory() != nil else {
            await developerTools.requestInstall()
            throw FrontportError.toolchainMissing(
                "Install the Command Line Tools from the window macOS just opened, then try again.")
        }
        guard !installer.isInstalled else { return }
        if let installing {
            return try await installing.value
        }
        let installer = self.installer
        let task = Task { try await installer.install(progress: progress) }
        installing = task
        defer { installing = nil }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: Build

    public func build(
        _ entry: CatalogEntry, ref: String, recipe: URL, roms: BuildROMs, log: URL,
        progress: @escaping ProgressHandler
    ) async throws -> BuildProduct {
        guard let developer = await developerTools.directory() else {
            throw FrontportError.toolchainMissing("The Command Line Tools aren’t installed.")
        }
        guard installer.isInstalled else {
            throw FrontportError.toolchainMissing("Frontport’s build tools aren’t installed.")
        }
        let port = entry.id
        let workspace = try Workspace(paths: paths, port: port)
        try workspace.prepare(ref: ref, recipeSHA256: try Hashing.sha256(file: recipe))
        try BuildOutput.restart(log)
        var built = false
        defer { workspace.finish(keepingOutput: built) }

        let sdk = await developerTools.sdk(developer)
        let metal = await developerTools.metalToolchain(developer)
        let environment = try workspace.environment(
            port: port, ref: ref, toolchain: installer.root, toolchainBin: installer.bin, developer: developer, sdk: sdk,
            metal: metal)

        if !workspace.isFetched {
            progress(ProgressUpdate(.fetching, message: "Fetching \(entry.name) \(ref)"))
            try await run(.fetch, port: port, recipe: recipe, workspace: workspace, developer: developer, metal: metal,
                environment: environment, log: log, progress: progress)
            try workspace.markFetched()
        }

        try workspace.clone(roms)
        progress(ProgressUpdate(.building, message: "Building \(entry.name) \(ref)"))
        try await run(.build, port: port, recipe: recipe, workspace: workspace, developer: developer, metal: metal,
            environment: environment, log: log, progress: progress)
        let product = try workspace.product()
        built = true
        return product
    }

    // MARK: Unpack

    public func unpack(
        _ file: URL, named name: String, workspace port: PortID, recipe: URL, log: URL, progress: @escaping ProgressHandler
    ) async throws -> [URL] {
        guard let developer = await developerTools.directory() else {
            throw FrontportError.toolchainMissing("The Command Line Tools aren’t installed.")
        }
        guard installer.isInstalled else {
            throw FrontportError.toolchainMissing("Frontport’s build tools aren’t installed.")
        }
        let workspace = try Workspace(paths: paths, port: port)
        try workspace.prepare(ref: "unpack", recipeSHA256: try Hashing.sha256(file: recipe))
        try BuildOutput.restart(log)
        var unpacked = false
        defer { workspace.finish(keepingOutput: unpacked) }

        let sdk = await developerTools.sdk(developer)
        let environment = try workspace.environment(
            port: port, ref: "", toolchain: installer.root, toolchainBin: installer.bin, developer: developer, sdk: sdk)
        if !workspace.isFetched {
            progress(ProgressUpdate(.fetching, message: "Fetching the unpacker"))
            try await run(.fetch, port: port, recipe: recipe, workspace: workspace, developer: developer, metal: nil,
                environment: environment, log: log, progress: progress)
            try workspace.markFetched()
        }
        try workspace.clone(file, as: name)
        progress(ProgressUpdate(.building, message: "Unpacking \(file.lastPathComponent)"))
        try await run(.build, port: port, recipe: recipe, workspace: workspace, developer: developer, metal: nil,
            environment: environment, log: log, progress: progress)
        let folders = try workspace.folders()
        unpacked = true
        return folders
    }

    private func run(
        _ step: RecipeStep, port: PortID, recipe: URL, workspace: Workspace, developer: URL, metal: URL?,
        environment: [String: String], log: URL, progress: @escaping ProgressHandler
    ) async throws {
        // The profile grants its folders by their resolved paths, so one swapped for a link would grant the target.
        try workspace.checkFolders()
        let sandbox = BuildSandbox(
            step: step, home: home, developer: DeveloperTools.sandboxRoot(of: developer), toolchain: installer.root,
            recipe: recipe, source: workspace.source, builds: workspace.root, temporary: workspace.temporary, metal: metal)
        let arguments = try sandbox.arguments(running: ["/bin/bash", try BuildSandbox.canonical(recipe), step.rawValue])

        let output = try BuildOutput(log: log, phase: step.phase, progress: progress)
        defer { output.close() }
        output.note("\(step.rawValue) \(port) at \(environment["FRONTPORT_REF"] ?? "")")
        let result: ProcessResult
        do {
            // The step's shell sweeps its sandbox; killing the group too covers a shell that didn't get to.
            result = try await ProcessRunner().run(
                BuildSandbox.sandboxExec, arguments: arguments, environment: environment,
                currentDirectory: workspace.source,
                stdout: .lines { output.consume($0) }, stderr: .lines { output.consume($0) }, killsGroupOnExit: true)
        } catch is CancellationError {
            output.note("\(step.rawValue) cancelled")
            throw CancellationError()
        }
        guard result.succeeded else {
            output.note("\(step.rawValue) failed with \(result.signaled ? "signal" : "status") \(result.status)")
            throw FrontportError.buildFailed(port, status: result.status, log: log)
        }
        output.note("\(step.rawValue) done")
    }
}

/// `Builds/<port>/`: the source tree, output, ROMs, tmp, and the state that decides whether to fetch again.
///
/// The build step may write anywhere in it, and a Recipe's processes may outlive their step, so Frontport never
/// follows a link there: it reads only regular files, replaces folders that aren't plain folders, and takes the
/// product only once it's sure the product holds no link out of itself.
struct Workspace: Sendable {
    let root: URL
    let source: URL
    let output: URL
    let temporary: URL
    let roms: URL
    private let state: URL

    private struct State: Codable, Equatable {
        var ref: String
        var recipeSHA256: String
        /// True once fetch succeeded for this ref and Recipe; the next build reuses the source tree.
        var fetched: Bool
    }

    init(paths: AppPaths, port: PortID) throws {
        root = paths.builds(for: port)
        source = paths.buildSource(for: port)
        output = paths.buildOutput(for: port)
        temporary = paths.buildTemporary(for: port)
        roms = root.appending(path: "roms", directoryHint: .isDirectory)
        state = root.appending(path: "state.json")
    }

    var home: URL { temporary.appending(path: "home", directoryHint: .isDirectory) }

    var isFetched: Bool { readState()?.fetched == true }

    /// Starts every run with empty out, tmp and ROMs folders, and an empty source tree unless the last fetch
    /// succeeded for the same ref and Recipe and left a plain folder.
    func prepare(ref: String, recipeSHA256: String) throws {
        try FileOperations.createDirectory(root)
        let wanted = State(ref: ref, recipeSHA256: recipeSHA256, fetched: true)
        if readState() != wanted || !FileOperations.isDirectory(source) {
            try remove(state)
            try remove(source)
        }
        for folder in [output, temporary, roms] {
            try remove(folder)
        }
        for folder in [source, output, temporary, home, roms] {
            try FileOperations.createDirectory(folder)
        }
        try JSON.write(State(ref: ref, recipeSHA256: recipeSHA256, fetched: isFetched), to: state)
    }

    func markFetched() throws {
        guard var current = readState() else {
            throw FrontportError.fileOperation("The build folder’s state is missing.")
        }
        current.fetched = true
        try JSON.write(current, to: state)
    }

    /// Refuses unless each folder a step is given is a plain folder at its own path, not a link to elsewhere.
    func checkFolders() throws {
        let base = try BuildSandbox.canonical(root)
        let folders = [(source, "src"), (output, "out"), (temporary, "tmp"), (home, "tmp/home"), (roms, "roms")]
        for (folder, relative) in folders {
            guard FileOperations.isDirectory(folder), (try? BuildSandbox.canonical(folder)) == base + "/" + relative else {
                throw FrontportError.fileOperation("The build folder’s \(relative) folder was replaced by a link.")
            }
        }
    }

    /// Clones the Build-Stage ROMs into `roms/` as `<sha1>.<format>`, so the build sandbox can read them.
    func clone(_ buildROMs: BuildROMs) throws {
        for file in buildROMs.files {
            let destination = roms.appending(path: "\(file.record.sha1).\(file.record.format)")
            guard !Self.exists(destination) else { continue }
            try FileOperations.clone(file.url, to: destination)
        }
    }

    /// Clones one file into `roms/` under `name`, such as an installer to unpack.
    func clone(_ file: URL, as name: String) throws {
        try FileOperations.clone(file, to: roms.appending(path: name))
    }

    /// The folders in `out/`, not links, by name: what an unpack Recipe left.
    func folders() throws -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)) ?? []
        return items.filter { FileOperations.isDirectory($0) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Removes what a run leaves that nothing reads again, since the next run starts each of them empty: the ROMs, the
    /// tmp folder, and the output unless the run succeeded and its caller has yet to take what's there. A source tree
    /// whose fetch didn't finish goes too, as the next run would fetch it again from scratch.
    func finish(keepingOutput: Bool) {
        // A folder ROM's clone keeps its read-only folders.
        try? FileOperations.removeUntrusted(roms)
        try? FileOperations.removeUntrusted(temporary)
        if !keepingOutput { try? FileOperations.removeUntrusted(output) }
        if !isFetched { try? FileOperations.removeUntrusted(source) }
    }

    /// The one .app in `out/`, and `out/assets` when the Recipe left Build Assets there. Refuses an app or
    /// Build Assets that are a link or hold a link leading out of them.
    func product() throws -> BuildProduct {
        let items = (try? FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)) ?? []
        let apps = items.filter { $0.pathExtension == "app" }
        guard apps.count == 1, let app = apps.first else {
            let found = apps.isEmpty ? "none" : apps.map(\.lastPathComponent).joined(separator: ", ")
            throw FrontportError.appNotFound("The Recipe must leave exactly one app in its output folder; found \(found).")
        }
        guard FileOperations.isDirectory(app) else {
            throw FrontportError.appNotFound("The Recipe left \(app.lastPathComponent), which isn’t an app folder.")
        }
        try FileOperations.refuseEscapingLinks(in: app)
        let assets = output.appending(path: "assets")
        guard Self.exists(assets) else { return BuildProduct(app: app) }
        try FileOperations.refuseEscapingLinks(in: assets)
        return BuildProduct(app: app, assets: assets)
    }

    func environment(
        port: PortID, ref: String, toolchain: URL, toolchainBin: URL, developer: URL, sdk: URL?, metal: URL? = nil
    ) throws -> [String: String] {
        let path = ([toolchainBin] + DeveloperTools.binaryFolders(in: developer)).map { $0.path(percentEncoded: false) }
            + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var environment = [
            "FRONTPORT_PORT": port.rawValue,
            "FRONTPORT_REF": ref,
            "FRONTPORT_SRC": try BuildSandbox.canonical(source),
            "FRONTPORT_OUT": try BuildSandbox.canonical(output),
            "FRONTPORT_TOOLCHAIN": try BuildSandbox.canonical(toolchain),
            "FRONTPORT_ROMS": try BuildSandbox.canonical(roms),
            "FRONTPORT_JOBS": String(ProcessInfo.processInfo.activeProcessorCount),
            "TMPDIR": try BuildSandbox.canonical(temporary),
            "HOME": try BuildSandbox.canonical(home),
            "PATH": path.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }.joined(separator: ":"),
            "DEVELOPER_DIR": developer.path(percentEncoded: false),
            "LANG": "en_US.UTF-8",
        ]
        if let sdk { environment["SDKROOT"] = sdk.path(percentEncoded: false) }
        if let metal { environment["FRONTPORT_METAL"] = metal.appending(path: "usr/bin").path(percentEncoded: false) }
        return environment
    }

    /// The state, read without following a link; nil when it's missing or isn't a regular file.
    private func readState() -> State? {
        try? JSON.decode(State.self, from: FileOperations.readRegularFile(state))
    }

    /// Removes a file, folder or link (never what a link points to), read-only folders included; absent is fine.
    private func remove(_ url: URL) throws {
        guard Self.exists(url) else { return }
        try FileOperations.removeUntrusted(url)
    }

    /// True when anything is at `url`, a dangling link included.
    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        var path = url.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return lstat(path, &info) == 0
    }
}
