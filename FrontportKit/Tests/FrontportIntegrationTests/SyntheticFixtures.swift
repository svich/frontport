import CryptoKit
import Darwin
import Foundation
import FrontportBuilder
import FrontportCore

// Stand-ins for what the synthetic end-to-end test can't use: ROMs, upstream Ports, a Recipe and a toolchain package.
// None of them is a real game or a real Port.

// MARK: ROMs

/// Synthetic ROMs: deterministic noise with the right magic and sizes, never a real dump.
enum SyntheticROM {
    /// Deterministic bytes; `count` is a multiple of 8.
    static func noise(_ count: Int, seed: UInt64) -> Data {
        var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        var data = Data(count: count)
        data.withUnsafeMutableBytes { bytes in
            for offset in stride(from: 0, to: count, by: 8) {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                bytes.storeBytes(of: state, toByteOffset: offset, as: UInt64.self)
            }
        }
        return data
    }

    /// An 8 MiB N64 ROM in its standard `.z64` byte order: the big-endian magic, then noise ending in 0xFF, so a
    /// Port writing 0 to its last byte changes it.
    static func z64() -> Data {
        var data = noise(8 << 20, seed: 64)
        data.replaceSubrange(0..<4, with: [0x80, 0x37, 0x12, 0x40])
        data[data.count - 1] = 0xFF
        return data
    }

    /// The same ROM as a `.v64` file: every 16-bit pair byte-swapped.
    static func v64(_ z64: Data) -> Data {
        var data = z64
        data.withUnsafeMutableBytes { bytes in
            for offset in stride(from: 0, to: bytes.count, by: 2) {
                bytes.swapAt(offset, offset + 1)
            }
        }
        return data
    }

    /// A 1 MiB SNES ROM, headerless as its standard form is.
    static func sfc() -> Data { noise(1 << 20, seed: 16) }

    /// A 256 KiB optional extra for the SNES ROM's Requirement.
    static func extra(seed: UInt64) -> Data { noise(256 << 10, seed: seed) }

    /// The same ROM as a copier dump: a 512-byte header in front.
    static func copierHeadered(_ sfc: Data) -> Data { Data(repeating: 0xAA, count: 512) + sfc }
}

// MARK: Prebuilt Port

/// A stand-in upstream Port with a Runtime Requirement: a Swift app that reads the ROM Seeded at the path its first
/// argument names, relative to its sandbox home, prints what it read, and rewrites its own copy. It also tries to read
/// `SYNTHETIC_OUTSIDE`, a file outside its container.
enum SyntheticPrebuiltPort {
    static let executableName = "synthetic"

    static let source = #"""
        import CryptoKit
        import Foundation

        func hex(_ digest: some Sequence<UInt8>) -> String { digest.map { String(format: "%02x", $0) }.joined() }

        let home = NSHomeDirectory()
        let environment = ProcessInfo.processInfo.environment
        print("version=\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
        print("home=\(home)")
        print("container=\(environment["APP_SANDBOX_CONTAINER_ID"] ?? "none")")

        let rom = URL(filePath: home).appending(path: CommandLine.arguments.dropFirst().first ?? "")
        let path = rom.path(percentEncoded: false)
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else {
            print("rom=unreadable")
            exit(1)
        }
        print("sha1=\(hex(Insecure.SHA1.hash(data: data)))")
        print("size=\(data.count)")

        // Its own copy is writable; the copy in Frontport's ROMs it was cloned from must stay as it was.
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seek(toFileOffset: UInt64(data.count - 1))
            handle.write(Data([0]))
            handle.closeFile()
            print("rewrote=yes")
        } else {
            print("rewrote=no")
        }

        if let outside = environment["SYNTHETIC_OUTSIDE"] {
            print("outside=\(FileManager.default.contents(atPath: outside) == nil ? "denied" : "read")")
        }
        """#

    /// Compiles the executable with swiftc.
    static func compile(in folder: URL) async throws -> URL {
        let source = folder.appending(path: "synthetic.swift")
        let executable = folder.appending(path: executableName)
        try Data(Self.source.utf8).write(to: source)
        try await tool("/usr/bin/xcrun", ["swiftc", "-O", "-o", path(executable), path(source)])
        return executable
    }

    /// `Synthetic.app` at `version`, signed ad hoc as upstream would have, zipped as upstream publishes it.
    static func zip(_ version: String, executable: URL, in folder: URL) async throws -> Data {
        let work = folder.appending(path: "release-\(version)", directoryHint: .isDirectory)
        let contents = work.appending(path: "Synthetic.app/Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: executable, to: contents.appending(path: "MacOS/\(executableName)"))
        let info: [String: Any] = [
            "CFBundleExecutable": executableName,
            "CFBundleIdentifier": "org.example.synthetic",
            "CFBundleName": "Synthetic",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": version,
            "LSMinimumSystemVersion": "26.0",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
        let app = contents.deletingLastPathComponent()
        try await tool("/usr/bin/codesign", ["--force", "--sign", "-", path(app)])
        let archive = folder.appending(path: "Synthetic-\(version)-mac.zip")
        try await tool("/usr/bin/ditto", ["-c", "-k", "--keepParent", path(app), path(archive)])
        return try Data(contentsOf: archive)
    }
}

// MARK: Source-built Port

/// The Recipe of a stand-in source-built Port with a Build-Stage Requirement. Fetch writes a small C program; build
/// compiles it into `Synthetic.app` and, when it's given ROMs, makes Build Assets from them: a file with `layout`,
/// which stands for how this Recipe makes them, the ref they were made at, and each ROM's SHA-1 and size. The app
/// prints the ref it was built from and the Build Assets it finds in `Contents/Resources/synthetic.assets`, and, as
/// OpenGOAL's gk does with its log, writes the ref beside its executable, into `Contents/Resources/log/ran`.
enum SyntheticRecipe {
    static let assetsPath = "Contents/Resources/synthetic.assets"
    static let logPath = "Contents/Resources/log"

    static func script(layout: Int) -> Data {
        Data(template.replacingOccurrences(of: "@LAYOUT@", with: String(layout)).utf8)
    }

    private static let template = #"""
        #!/bin/bash
        # A stand-in Recipe for Frontport's synthetic end-to-end test (FrontportIntegrationTests). Not a real Port.
        set -euo pipefail
        layout=@LAYOUT@

        case "$1" in
        fetch)
            echo "==> Writing the source of $FRONTPORT_REF"
            cat > "$FRONTPORT_SRC/main.c" <<'SOURCE'
        #include <libgen.h>
        #include <limits.h>
        #include <mach-o/dyld.h>
        #include <stdint.h>
        #include <stdio.h>
        #include <stdlib.h>

        int main(void) {
            char path[PATH_MAX], resolved[PATH_MAX], assets[PATH_MAX], log[PATH_MAX];
            uint32_t size = sizeof path;
            if (_NSGetExecutablePath(path, &size) != 0 || realpath(path, resolved) == NULL) return 2;
            const char *folder = dirname(resolved);
            snprintf(assets, sizeof assets, "%s/../Resources/synthetic.assets", folder);
            snprintf(log, sizeof log, "%s/../Resources/log/ran", folder);
            printf("ref=%s\n", SYNTHETIC_REF);
            FILE *ran = fopen(log, "w");
            if (ran == NULL) {
                printf("log=failed\n");
                return 3;
            }
            fprintf(ran, "ref=%s\n", SYNTHETIC_REF);
            fclose(ran);
            FILE *file = fopen(assets, "r");
            if (file == NULL) {
                printf("assets=missing\n");
                return 1;
            }
            char line[256];
            while (fgets(line, sizeof line, file) != NULL) printf("assets: %s", line);
            fclose(file);
            return 0;
        }
        SOURCE
            ;;
        build)
            contents="$FRONTPORT_OUT/Synthetic.app/Contents"
            mkdir -p "$contents/MacOS" "$contents/Resources"
            synthtool "building $FRONTPORT_REF"
            echo "==> Compiling $FRONTPORT_REF"
            clang -O2 -Wall -DSYNTHETIC_REF="\"$FRONTPORT_REF\"" -o "$contents/MacOS/synthetic" "$FRONTPORT_SRC/main.c"
            cat > "$contents/Info.plist" <<PLIST
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleExecutable</key><string>synthetic</string>
            <key>CFBundleIdentifier</key><string>org.example.synthetic-source</string>
            <key>CFBundleName</key><string>Synthetic</string>
            <key>CFBundlePackageType</key><string>APPL</string>
            <key>CFBundleShortVersionString</key><string>${FRONTPORT_REF#v}</string>
            <key>CFBundleVersion</key><string>${FRONTPORT_REF#v}</string>
        </dict>
        </plist>
        PLIST

            shopt -s nullglob
            roms=("$FRONTPORT_ROMS"/*)
            if ((${#roms[@]} == 0)); then
                echo "==> ROMs: none, so no Build Assets"
                exit 0
            fi
            echo "==> ROMs: ${roms[*]##*/}"
            {
                printf 'layout=%s\nmade-at=%s\n' "$layout" "$FRONTPORT_REF"
                for rom in "${roms[@]}"; do
                    printf 'rom=%s %s\n' "$(shasum -a 1 "$rom" | cut -d ' ' -f 1)" "$(wc -c < "$rom" | tr -d ' ')"
                done
            } > "$FRONTPORT_OUT/assets"
            echo "==> Build Assets from ${#roms[@]} ROMs"
            ;;
        *)
            echo "Unknown step $1" >&2
            exit 2
            ;;
        esac
        """#
}

// MARK: Toolchain

/// A one-command toolchain package standing in for cmake and ninja, so the Builder installs and verifies a pinned
/// prefix from the local server without downloading the real ones.
enum SyntheticToolchain {
    static func zip(in folder: URL) async throws -> Data {
        let work = folder.appending(path: "toolchain", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let command = work.appending(path: "synthtool")
        try Data("#!/bin/sh\necho \"synthtool: $*\"\n".utf8).write(to: command)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path(command))
        let archive = folder.appending(path: "synthtool.zip")
        try await tool("/usr/bin/ditto", ["-c", "-k", path(work), path(archive)])
        return try Data(contentsOf: archive)
    }

    static func manifest(url: URL, sha256: String) -> ToolchainManifest {
        ToolchainManifest(packages: [
            ToolchainPackage(
                name: "synthtool", version: "1", url: url, sha256: sha256, archive: .zip, commands: ["synthtool": "synthtool"])
        ])
    }
}

// MARK: Helpers

@discardableResult
func tool(_ executable: String, _ arguments: [String]) async throws -> ProcessResult {
    try await ProcessRunner().run(URL(filePath: executable), arguments: arguments).check(executable)
}

func path(_ url: URL) -> String { url.path(percentEncoded: false) }

func exists(_ url: URL) -> Bool {
    var info = stat()
    return lstat(path(url), &info) == 0
}

/// Permission bits, without following a link.
func mode(of url: URL) -> mode_t? {
    var info = stat()
    return lstat(path(url), &info) == 0 ? info.st_mode & 0o7777 : nil
}

/// True when APFS reports that the file shares all its blocks with another: a clone neither side has written to.
func sharesAllBlocks(_ url: URL) -> Bool {
    var request = attrlist()
    request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
    request.forkattr = attrgroup_t(ATTR_CMNEXT_EXT_FLAGS)
    // u_int32_t length, attribute_set_t returned (five u_int32_t), then u_int64_t extended flags.
    var buffer = [UInt8](repeating: 0, count: 64)
    let options = UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW)
    guard getattrlist(path(url), &request, &buffer, buffer.count, options) == 0 else { return false }
    let flags = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: UInt64.self) }
    return flags & UInt64(EF_SHARES_ALL_BLOCKS) != 0
}

func text(_ url: URL) throws -> String { String(decoding: try Data(contentsOf: url), as: UTF8.self) }
