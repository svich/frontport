import Darwin
import Foundation
import FrontportCore

/// A Recipe's two invocations, each under its own `sandbox-exec` profile.
public enum RecipeStep: String, Hashable, Sendable, CaseIterable {
    /// `recipe.sh fetch`: network allowed, writes only the source tree and tmp.
    case fetch
    /// `recipe.sh build`: no network, writes only `Builds/<port>` and tmp.
    case build

    var phase: ProgressUpdate.Phase {
        switch self {
        case .fetch: .fetching
        case .build: .building
        }
    }
}

/// The `sandbox-exec` command line for one Recipe step. Paths are passed as `-D` parameters to the
/// profile in the package's `Profiles/<step>.sb`.
struct BuildSandbox: Sendable {
    static let sandboxExec = URL(fileURLWithPath: "/usr/bin/sandbox-exec")

    var step: RecipeStep
    /// The user's home folder, denied as a whole.
    var home: URL
    /// Root of the active developer directory (Xcode.app or the Command Line Tools).
    var developer: URL
    var toolchain: URL
    var recipe: URL
    /// The source tree: the only writable place besides `temporary` during fetch.
    var source: URL
    /// `Builds/<port>`: readable and writable during build.
    var builds: URL
    var temporary: URL
    /// Xcode's Metal toolchain, readable and executable during build, when it's installed.
    var metal: URL? = nil

    static func profile(_ step: RecipeStep) throws -> URL {
        guard let url = Bundle.module.url(forResource: step.rawValue, withExtension: "sb", subdirectory: "Profiles") else {
            throw FrontportError.fileOperation("The \(step.rawValue) sandbox profile is missing from Frontport.")
        }
        return url
    }

    /// Profile parameters, as canonical paths: the sandbox matches resolved paths, so `/var/...` must be
    /// passed as `/private/var/...`.
    func parameters() throws -> [String: String] {
        var parameters = [
            "HOME": try Self.canonical(home),
            "DEVELOPER_DIR": try Self.canonical(developer),
            "TOOLCHAIN": try Self.canonical(toolchain),
            "RECIPE": try Self.canonical(recipe),
            "TMP": try Self.canonical(temporary),
        ]
        switch step {
        case .fetch: parameters["SRC"] = try Self.canonical(source)
        case .build:
            parameters["BUILDS"] = try Self.canonical(builds)
            // Without one, the developer directory stands in: the profile grants it anyway.
            parameters["METAL"] = try Self.canonical(metal ?? developer)
        }
        return parameters
    }

    /// Arguments to `sandbox-exec` that run `command` inside the profile under the step's shell, with its stderr
    /// merged into stdout so the log keeps their order.
    func arguments(running command: [String]) throws -> [String] {
        var arguments = ["-f", try Self.profile(step).path(percentEncoded: false)]
        for (key, value) in try parameters().sorted(by: { $0.key < $1.key }) {
            arguments += ["-D", "\(key)=\(value)"]
        }
        return arguments + ["/bin/bash", "-c", Self.stepShell, "frontport-recipe"] + command
    }

    /// The step's shell: runs the command, then kills every other process in the step's sandbox, also when
    /// Frontport cancels the step with SIGTERM. It exits with the command's status.
    ///
    /// The profile lets a step signal only processes in its own sandbox, which every process it starts inherits
    /// for good, so the sweep reaches processes that left the step's process group (`setsid`, job control) and
    /// nothing else. If Frontport, its parent, can be signalled, the shell isn't sandboxed and sweeps nothing.
    /// It tries every pid in turn because `kill -1` would kill the shell too, losing the command's status.
    static let stepShell = #"""
        exec 2>&1
        sweep() {
            trap '' TERM
            case $(kill -0 "$PPID" 2>&1) in *"not permitted"*) ;; *) return ;; esac
            local pid found=1 passes=0
            while ((found && passes++ < 10)); do
                found=0
                for ((pid = 2; pid < 100000; pid++)); do
                    ((pid != $$)) && kill -KILL $pid && found=1
                done
            done 2>/dev/null
        }
        trap 'sweep; exit 143' TERM
        "$@" &
        wait $!
        status=$?
        sweep
        exit $status
        """#

    /// The path with every symlink resolved. The item must exist.
    static func canonical(_ url: URL) throws -> String {
        let path = url.path(percentEncoded: false)
        guard let resolved = realpath(path, nil) else {
            throw FrontportError.fileOperation("Couldn’t resolve \(path): \(String(cString: strerror(errno)))")
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
