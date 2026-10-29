import Foundation
import Testing
@testable import FrontportCore

@Suite struct HashingTests {
    @Test func knownVectors() {
        let abc = Data("abc".utf8)
        #expect(Hashing.sha1(abc) == "a9993e364706816aba3e25717850c26c9cd0d89d")
        #expect(Hashing.sha256(abc) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func streamsLargeFiles() throws {
        let tmp = try TemporaryDirectory()
        let data = Data((0..<(3 << 20) + 17).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let file = tmp.url.appending(path: "big.bin")
        try data.write(to: file)
        #expect(try Hashing.sha1(file: file) == Hashing.sha1(data))
        #expect(try Hashing.sha256(file: file) == Hashing.sha256(data))
    }

    @Test func hashesEmptyFile() throws {
        let tmp = try TemporaryDirectory()
        let file = try tmp.file("empty", contents: "")
        #expect(try Hashing.sha1(file: file) == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
    }
}

@Suite struct ProcessRunnerTests {
    let runner = ProcessRunner()

    @Test func capturesOutputAndStatus() async throws {
        let result = try await runner.run(
            URL(filePath: "/bin/sh"), arguments: ["-c", "echo out; echo err >&2; exit 3"])
        #expect(result.output == "out\n")
        #expect(result.errorOutput == "err\n")
        #expect(result.status == 3 && !result.signaled && !result.succeeded)
        #expect(throws: FrontportError.processFailed(command: "sh", status: 3, output: "err")) {
            try result.check("sh")
        }
    }

    @Test func passesEnvironmentAndDirectory() async throws {
        let tmp = try TemporaryDirectory()
        let result = try await runner.run(
            URL(filePath: "/bin/sh"), arguments: ["-c", "echo $FRONTPORT_X; pwd -P"],
            environment: ["FRONTPORT_X": "42"], currentDirectory: tmp.url)
        let lines = result.output.split(separator: "\n")
        #expect(lines.first == "42")
        #expect(lines.last?.hasSuffix("/" + tmp.url.lastPathComponent) == true)
    }

    @Test func redirectsBothStreamsToOneFile() async throws {
        let tmp = try TemporaryDirectory()
        let log = tmp.url.appending(path: "run.log")
        _ = try await runner.run(
            URL(filePath: "/bin/sh"), arguments: ["-c", "echo one; echo two >&2"], stdout: .file(log), stderr: .file(log))
        _ = try await runner.run(
            URL(filePath: "/bin/sh"), arguments: ["-c", "echo three"], stdout: .append(log), stderr: .discard)
        #expect(try read(log) == "one\ntwo\nthree\n")
    }

    @Test func streamsLines() async throws {
        final class Lines: @unchecked Sendable {
            let lock = NSLock()
            var all: [String] = []
            func add(_ line: String) { lock.withLock { all.append(line) } }
        }
        let lines = Lines()
        _ = try await runner.run(
            URL(filePath: "/usr/bin/printf"), arguments: ["[1/3] a\\n[2/3] b\\n[3/3] c"],
            stdout: .lines { lines.add($0) })
        #expect(lines.all == ["[1/3] a", "[2/3] b", "[3/3] c"])
    }

    @Test func reportsSignals() async throws {
        let result = try await runner.run(URL(filePath: "/bin/sh"), arguments: ["-c", "kill -9 $$"])
        #expect(result.signaled && result.status == 9)
    }

    @Test func missingExecutableThrows() async {
        await #expect(throws: FrontportError.self) {
            try await runner.run(URL(filePath: "/nonexistent/tool"))
        }
    }

    /// The child leads its own process group; a background job left in it would otherwise hold the output open.
    @Test func killsWhatsLeftInTheGroupOnExit() async throws {
        let started = ContinuousClock.now
        let result = try await runner.run(
            URL(filePath: "/bin/sh"), arguments: ["-c", "echo $$ $(ps -o pgid= -p $$); sleep 60 & echo $!"],
            killsGroupOnExit: true)
        #expect(ContinuousClock.now - started < .seconds(20))
        let numbers = result.output.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        try #require(numbers.count == 3)
        #expect(numbers[0] == numbers[1], "the child leads its group")
        var alive = kill(numbers[2], 0) == 0
        let deadline = ContinuousClock.now + .seconds(5)
        while alive, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            alive = kill(numbers[2], 0) == 0
        }
        #expect(!alive)
    }

    @Test func cancellationTerminatesProcess() async throws {
        let started = ContinuousClock.now
        let task = Task { try await runner.run(URL(filePath: "/bin/sleep"), arguments: ["30"]) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    /// A process that ignores SIGTERM gets SIGKILL once `killAfter` has passed, so the caller doesn't wait on it.
    @Test func cancellationKillsAProcessThatIgnoresSIGTERM() async throws {
        let started = ContinuousClock.now
        let task = Task {
            try await runner.run(
                URL(filePath: "/bin/sh"), arguments: ["-c", "trap '' TERM; exec sleep 30"], killAfter: .milliseconds(500))
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(10))
    }
}

@Suite struct AppPathsTests {
    let paths = AppPaths(root: URL(filePath: "/r/Frontport/"), containers: URL(filePath: "/c/Containers/"))

    func path(_ url: URL) -> String { url.path(percentEncoded: false) }

    @Test func layoutMatchesDesign() {
        let soh: PortID = "shipwright"
        #expect(path(paths.catalogDocument) == "/r/Frontport/Catalog/catalog.json")
        #expect(path(paths.recipe("recipes/starship.sh")) == "/r/Frontport/Catalog/recipes/starship.sh")
        #expect(path(paths.rom("ab12", format: "z64")) == "/r/Frontport/ROMs/ab12.z64")
        #expect(path(paths.toolchain(version: "1")) == "/r/Frontport/Toolchain/1/")
        #expect(path(paths.builds(for: soh)) == "/r/Frontport/Builds/shipwright/")
        #expect(path(paths.snapshotData("s1", for: soh)) == "/r/Frontport/Snapshots/shipwright/s1/Data/")
        #expect(path(paths.runLog("r1", for: soh)) == "/r/Frontport/Logs/shipwright/r1.log")
        #expect(path(paths.artwork(steamgriddb: 5335518)) == "/r/Frontport/Artwork/5335518/")
        #expect(path(paths.app(for: soh, named: "soh.app")) == "/r/Frontport/Library/shipwright/soh.app/")
        #expect(path(paths.previous(for: soh)) == "/r/Frontport/Library/shipwright/previous/")
        #expect(path(paths.installRecord(for: soh)) == "/r/Frontport/Library/shipwright/install.json")
        #expect(path(paths.data(for: "dev.frontport.port.shipwright")) == "/c/Containers/dev.frontport.port.shipwright/Data/")
    }

    /// The build sandbox may write anywhere in `Builds/<port>/`, so the log Frontport appends to lives elsewhere.
    @Test func buildLogIsOutsideTheBuildsFolder() {
        let soh: PortID = "shipwright"
        #expect(path(paths.buildLog(for: soh)) == "/r/Frontport/Logs/shipwright/build.log")
        #expect(!path(paths.buildLog(for: soh)).hasPrefix(path(paths.builds(for: soh))))
    }

    @Test func defaultRootIsApplicationSupport() {
        #expect(AppPaths.default.root.path(percentEncoded: false).hasSuffix("/Library/Application Support/Frontport/"))
        #expect(AppPaths.default.containers.path(percentEncoded: false).hasSuffix("/Library/Containers/"))
    }
}
