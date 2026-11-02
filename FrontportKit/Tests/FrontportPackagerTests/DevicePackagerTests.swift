import Foundation
import FrontportCore
import Testing
@testable import FrontportPackager

@Suite struct MachOBuildTests {
    func read(_ bytes: Data) throws -> MachO.Build? {
        let tmp = try TemporaryDirectory()
        let file = tmp.url.appending(path: "binary")
        try bytes.write(to: file)
        return MachO.build(of: file)
    }

    @Test func readsAnIOSBuild() throws {
        let build = try #require(try read(MachOBytes.iOS(minimumOS: MachOBytes.version(13, 0), sdk: MachOBytes.version(18, 5))))
        #expect(build.platform == .iOS)
        #expect(build.minimumOS.description == "13.0" && build.sdk.description == "18.5")
        #expect(!build.isEncrypted)
        #expect(MachO.Version(packed: MachOBytes.version(16, 2, 1)).description == "16.2.1")
        #expect(MachO.Version(packed: MachOBytes.version(11, 0)) < MachO.Version(packed: MachOBytes.version(11, 0, 1)))
    }

    /// Simulator, Mac and Mac Catalyst builds say so, and the Device Packager refuses them.
    @Test(arguments: zip([UInt32(7), 1, 6, 11], [MachO.Platform.iOSSimulator, .macOS, .macCatalyst, MachO.Platform(rawValue: 11)]))
    func readsOtherPlatforms(_ number: UInt32, _ platform: MachO.Platform) throws {
        let bytes = MachOBytes.thin(commands: [
            MachOBytes.buildVersion(platform: number, minimumOS: MachOBytes.version(15, 0), sdk: MachOBytes.version(18, 0)),
        ])
        #expect(try read(bytes)?.platform == platform)
    }

    /// Fallout CE's and Fallout 2 CE's upstream builds carry `LC_VERSION_MIN_IPHONEOS` and no `LC_BUILD_VERSION`.
    @Test func readsTheLegacyCommand() throws {
        let fallout = MachOBytes.thin(commands: [
            MachOBytes.uuid, MachOBytes.versionMin(minimumOS: MachOBytes.version(11, 0), sdk: MachOBytes.version(16, 2)),
            MachOBytes.encryption(cryptid: 0),
        ])
        let build = try #require(try read(fallout))
        #expect(build.platform == .iOS && build.minimumOS.description == "11.0" && build.sdk.description == "16.2")
        #expect(!build.isEncrypted, "the command is there, with cryptid 0")

        let mac = MachOBytes.thin(commands: [MachOBytes.versionMin(0x24, minimumOS: MachOBytes.version(10, 13), sdk: MachOBytes.version(14, 0))])
        #expect(try read(mac)?.platform == .macOS)
    }

    @Test func readsWhetherTheAppStoreEncryptedIt() throws {
        let encrypted = MachOBytes.thin(commands: [
            MachOBytes.encryption(cryptid: 1),
            MachOBytes.buildVersion(platform: 2, minimumOS: MachOBytes.version(15, 0), sdk: MachOBytes.version(18, 0)),
        ])
        #expect(try read(encrypted)?.isEncrypted == true)
    }

    @Test func picksTheARM64SliceOfAUniversalBinary() throws {
        let mac = MachOBytes.thin(cpu: MachOBytes.x86_64, commands: [
            MachOBytes.buildVersion(platform: 1, minimumOS: MachOBytes.version(11, 0), sdk: MachOBytes.version(15, 0)),
        ])
        let ios = MachOBytes.iOS()
        #expect(try read(MachOBytes.fat([(MachOBytes.x86_64, mac), (MachOBytes.arm64, ios)]))?.platform == .iOS)
        #expect(try read(MachOBytes.fat([(MachOBytes.x86_64, mac), (MachOBytes.arm64, ios)], is64: true))?.platform == .iOS)
        #expect(try read(MachOBytes.fat([(MachOBytes.x86_64, mac)])) == nil)
        #expect(try read(mac) == nil, "a thin x86_64 file has no arm64 slice")
    }

    @Test func refusesWhatDoesntHoldTogether() throws {
        let platform = MachOBytes.buildVersion(platform: 2, minimumOS: MachOBytes.version(15, 0), sdk: MachOBytes.version(18, 0))
        var lying = MachOBytes.thin(commands: [platform])
        lying.replaceSubrange(16..<20, with: MachOBytes.words([1000]))  // more commands than their size holds
        var endless = MachOBytes.thin(commands: [MachOBytes.words([0x1B, 0, 0, 0, 0, 0]), platform])  // a 0-size command
        endless.replaceSubrange(20..<24, with: MachOBytes.words([48]))
        var overrun = MachOBytes.thin(commands: [MachOBytes.words([0x1B, 4096, 0, 0, 0, 0])])
        overrun.replaceSubrange(20..<24, with: MachOBytes.words([24]))
        var arm32 = MachOBytes.iOS()
        arm32.replaceSubrange(0..<4, with: [0xCE, 0xFA, 0xED, 0xFE])
        var garbage = Data(count: 4096)
        for index in garbage.indices { garbage[index] = UInt8.random(in: 0...255) }
        garbage.replaceSubrange(0..<4, with: [0x7F, 0x45, 0x4C, 0x46])

        for (name, bytes) in [
            ("lying", lying), ("endless", endless), ("overrun", overrun), ("32-bit", arm32), ("garbage", garbage),
            ("truncated", MachOBytes.iOS().prefix(20)), ("empty", Data()), ("text", Data("#!/bin/sh\n".utf8)),
            ("no platform", MachOBytes.thin(commands: [MachOBytes.uuid])),
            ("truncated universal", MachOBytes.fat([(MachOBytes.arm64, MachOBytes.iOS())]).prefix(0x1010)),
        ] {
            #expect(try read(bytes) == nil, "\(name)")
        }
    }

    /// clang's own output, for a Mac program.
    @Test func readsWhatClangBuilds() async throws {
        let tmp = try TemporaryDirectory()
        let source = tmp.url.appending(path: "main.c")
        try write("int main(void) { return 0; }\n", to: source)
        let binary = tmp.url.appending(path: "main")
        try await clang(["-arch", "arm64", "-arch", "x86_64", "-mmacosx-version-min=14.0", "-o", binary.path(percentEncoded: false), source.path(percentEncoded: false)])

        let build = try #require(MachO.build(of: binary))
        #expect(build.platform == .macOS && build.minimumOS.description == "14.0" && !build.isEncrypted)
    }
}

@Suite struct FlatCodeLayoutTests {
    @Test func signsFrameworksAsBundlesAndLibrariesAsFilesDeepestFirst() throws {
        let tmp = try TemporaryDirectory()
        let app = try DeviceApp.make(in: tmp.url)
        try write(MachOBytes.iOS(fileType: MachOBytes.bundle), to: app.appending(path: "Resources/plugin.so"))
        try write(MachOBytes.iOS(fileType: MachOBytes.object), to: app.appending(path: "Resources/thing.o"))

        let layout = try CodeLayout(app: app, layout: .flat)
        let root = app.resolvingSymlinksInPath().path(percentEncoded: false)
        let relative = layout.nested.map {
            String($0.url.resolvingSymlinksInPath().path(percentEncoded: false).dropFirst(root.count))
                .trimmingCharacters(in: ["/"])
        }

        #expect(relative == [
            "Frameworks/Kit.framework/libinner.dylib", "Frameworks/Kit.framework", "Frameworks/libloose.dylib",
            "Resources/plugin.so",
        ])
        #expect(layout.refused.isEmpty && layout.hasLibraries)
        let framework = try #require(layout.nested.first { $0.url.lastPathComponent == "Kit.framework" })
        #expect(framework.kind == .bundle && !framework.isExecutable)
        #expect(layout.nested.allSatisfy { $0.url.lastPathComponent == "Kit.framework" || $0.kind == .file })
    }

    @Test func refusesProgramsIOSWontRunFromAPort() throws {
        let tmp = try TemporaryDirectory()
        let app = try DeviceApp.make(in: tmp.url)
        let program = MachOBytes.iOS()
        try program.write(to: app.appending(path: "helper"))
        try program.write(to: app.appending(path: "Frameworks/Kit.framework/tool"))
        let appex = app.appending(path: "PlugIns/Widget.appex", directoryHint: .isDirectory)
        try write(DeviceApp.dictionary("<key>CFBundleExecutable</key><string>Widget</string>"), to: appex.appending(path: "Info.plist"))
        try program.write(to: appex.appending(path: "Widget"))
        try write(MachOBytes.iOS(fileType: MachOBytes.dylib), to: appex.appending(path: "Frameworks/libwidget.dylib"))
        try write("watch", to: app.appending(path: "Watch/Face.app/Info.plist"))
        try write("nested", to: app.appending(path: "Extras/Other.app/Info.plist"))
        try write("service", to: app.appending(path: "XPCServices/Service.xpc/Info.plist"))

        let layout = try CodeLayout(app: app, layout: .flat)
        let root = app.resolvingSymlinksInPath().path(percentEncoded: false)
        let refused = layout.refused.map {
            String($0.path(percentEncoded: false).dropFirst(root.count)).trimmingCharacters(in: ["/"])
        }

        #expect(refused == [
            "Extras/Other.app", "Frameworks/Kit.framework/tool", "PlugIns/Widget.appex", "Watch",
            "XPCServices/Service.xpc", "helper",
        ])
        #expect(!layout.nested.contains { $0.url.path(percentEncoded: false).contains("Widget.appex") })
    }

    @Test func macLayoutRefusesNothing() async throws {
        let tmp = try TemporaryDirectory()
        let app = try await TestApp.make(in: tmp.url)
        #expect(try CodeLayout(app: app).refused.isEmpty)
    }
}

@Suite struct CodesignArgumentsTests {
    /// The Mac's ad-hoc arguments, exactly as they were before Devices.
    @Test func adHocArgumentsAreTheMacsOwn() {
        let item = URL(filePath: "/tmp/Tiny.app")
        let plist = URL(filePath: "/tmp/frontport-entitlements/port.entitlements")
        #expect(Codesign.signArguments(item, signature: .adHoc, entitlements: nil)
            == ["--force", "--sign", "-", "--options", "runtime", "/tmp/Tiny.app"])
        #expect(Codesign.signArguments(item, signature: .adHoc, entitlements: plist)
            == ["--force", "--sign", "-", "--options", "runtime", "--entitlements", "/tmp/frontport-entitlements/port.entitlements", "/tmp/Tiny.app"])
    }

    @Test func certificateArgumentsHaveNoRuntimeOrTimestamp() {
        let item = URL(filePath: "/tmp/Tiny.app")
        let plist = URL(filePath: "/tmp/e/port.entitlements")
        #expect(Codesign.signArguments(item, signature: .certificate(testCertificate), entitlements: plist)
            == ["--force", "--sign", testCertificate, "--timestamp=none", "--entitlements", "/tmp/e/port.entitlements", "/tmp/Tiny.app"])
        #expect(Codesign.signArguments(item, signature: .certificate(testCertificate), entitlements: nil)
            == ["--force", "--sign", testCertificate, "--timestamp=none", "/tmp/Tiny.app"])
    }

    @Test func signsOnlyWithACertificatesSHA1() async throws {
        let codesign = Codesign(codesign: URL(filePath: "/nonexistent/codesign"))
        for certificate in ["-", "Apple Development: Tests", String(repeating: "G", count: 40)] {
            await #expect(throws: FrontportError.signingFailed("“\(certificate)” isn’t an Apple Development certificate’s SHA-1.")) {
                try await codesign.sign(URL(filePath: "/tmp/Tiny.app"), certificate: certificate, entitlements: nil)
            }
        }
    }

    @Test func saysWhatToDoWhenTheKeychainSaysNo() async throws {
        let keychain = Codesign.certificateFailure("/tmp/Tiny.app: errSecInternalComponent")
        #expect(keychain == .signingFailed(
            "macOS didn’t let codesign use your Apple Team’s key in the keychain. Try again, and when macOS asks, enter "
                + "your login password and click Always Allow."))
        #expect(Codesign.certificateFailure("error: \(testCertificate): no identity found") == .signingFailed(
            "Your Apple Team’s Apple Development certificate isn’t in the keychain. Check Xcode › Settings › Accounts, "
                + "then try again."))
        #expect(Codesign.certificateFailure("something else") == .signingFailed("something else"))

        // Through codesign itself, as it fails when the prompt is denied or can't be shown.
        let tmp = try TemporaryDirectory()
        let fake = tmp.url.appending(path: "codesign")
        try write("#!/bin/sh\necho \"$@: errSecInternalComponent\" >&2\nexit 1\n", to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path(percentEncoded: false))
        await #expect(throws: keychain) {
            try await Codesign(codesign: fake).sign(tmp.url, certificate: testCertificate, entitlements: ["get-task-allow": true])
        }
    }

    @Test func deviceEntitlementsAreTheThreeEveryProfileGrants() throws {
        let entitlements = DeviceEntitlements.app(team: testTeam, bundleId: "dev.frontport.port.tiny.a1b2c3d4e5")
        #expect(entitlements == [
            "application-identifier": .string("A1B2C3D4E5.dev.frontport.port.tiny.a1b2c3d4e5"),
            "com.apple.developer.team-identifier": .string("A1B2C3D4E5"),
            "get-task-allow": .flag(true),
        ])
        let written = try PropertyListSerialization.propertyList(from: PortEntitlements.plist(entitlements), format: nil) as? [String: Any]
        #expect(written?["application-identifier"] as? String == "A1B2C3D4E5.dev.frontport.port.tiny.a1b2c3d4e5")
        #expect(written?["get-task-allow"] as? Bool == true)
    }
}

@Suite struct DevicePackagerTests {
    @Test func packagesAnIOSAppForTheAppleTeam() async throws {
        let tmp = try TemporaryDirectory()
        let app = try DeviceApp.make(in: tmp.url)
        try write("unwanted", to: app.appending(path: "Settings.bundle/Root.plist"))
        let version = deviceVersion(strip: ["Settings.bundle", "absent"])
        let signing = try deviceSigning(profile: tmp.url.appending(path: "wildcard.mobileprovision"))
        let signer = RecordingDeviceSigner()
        // Upstream may ship a library read-only.
        #expect(chmod(app.appending(path: "Frameworks/libloose.dylib").path(percentEncoded: false), 0o444) == 0)

        let info = try await DevicePackager(signer: signer).package(app, version: version, signing: signing)

        #expect(try plist(app.appending(path: "Info.plist"))["CFBundleIdentifier"] as? String == "dev.frontport.port.tiny.a1b2c3d4e5")
        #expect(try read(app.appending(path: "embedded.mobileprovision")) == "profile")
        #expect(!FileOperations.exists(app.appending(path: "SC_Info")))
        #expect(!FileOperations.exists(app.appending(path: "Settings.bundle")))
        #expect(try read(app.appending(path: "Frameworks/decoy.dylib")) == DeviceApp.decoyContents)
        #expect(FileManager.default.isWritableFile(atPath: app.appending(path: "Frameworks/libloose.dylib").path(percentEncoded: false)))

        #expect(signer.items(in: app) == [
            "Frameworks/Kit.framework/libinner.dylib", "Frameworks/Kit.framework", "Frameworks/libloose.dylib", "",
        ])
        let signed = signer.signed.withLock { $0 }
        #expect(signed.allSatisfy { $0.certificate == testCertificate })
        #expect(signed.dropLast().allSatisfy { $0.entitlements == nil })
        #expect(signed.last?.entitlements == DeviceEntitlements.app(team: testTeam, bundleId: signing.bundleId))
        #expect(signer.verified.withLock { $0 } == [app])
        #expect(try read(app.appending(path: "_CodeSignature/CodeResources")) == "signed with \(testCertificate)")

        #expect(info == DeviceAppInfo(
            bundleId: "dev.frontport.port.tiny.a1b2c3d4e5", executable: "Tiny", minimumOS: "15.0", sdk: "18.0",
            families: [1, 2]))
    }

    /// As Fallout CE's upstream build is: the legacy command, the encryption command with cryptid 0, no families.
    @Test func packagesALegacyBuild() async throws {
        let tmp = try TemporaryDirectory()
        let executable = MachOBytes.thin(commands: [
            MachOBytes.versionMin(minimumOS: MachOBytes.version(11, 0), sdk: MachOBytes.version(16, 2)),
            MachOBytes.encryption(cryptid: 0),
        ])
        let app = try DeviceApp.make(in: tmp.url, name: "fallout-ce", executable: executable, families: nil)

        let info = try await DevicePackager(signer: RecordingDeviceSigner()).package(
            app, version: deviceVersion(), signing: try deviceSigning(profile: tmp.url.appending(path: "p")))

        #expect(info.minimumOS == "11.0" && info.sdk == "16.2" && info.families == [1] && info.executable == "fallout-ce")
    }

    @Test func refusesWhatIsntAnIPhoneAndIPadApp() async throws {
        let tmp = try TemporaryDirectory()
        let profile = tmp.url.appending(path: "p")
        let version = (MachOBytes.version(15, 0), MachOBytes.version(18, 0))
        func platform(_ number: UInt32) -> Data {
            MachOBytes.thin(commands: [MachOBytes.buildVersion(platform: number, minimumOS: version.0, sdk: version.1)])
        }
        let cases: [(String, Data, FrontportError)] = [
            ("simulator", platform(7), .notForDevice("Tiny.app is built for the iOS Simulator.")),
            ("mac", platform(1), .notForDevice("Tiny.app is built for the Mac.")),
            ("catalyst", platform(6), .notForDevice("Tiny.app is built for the Mac.")),
            ("tvos", platform(3), .notForDevice("Tiny.app isn’t built for iOS.")),
            ("x86_64", MachOBytes.thin(cpu: MachOBytes.x86_64, commands: [MachOBytes.buildVersion(platform: 2, minimumOS: version.0, sdk: version.1)]),
             .notForDevice("Tiny.app’s executable isn’t built for arm64 with a platform it names.")),
            ("script", Data("#!/bin/sh\n".utf8), .notForDevice("Tiny.app’s executable isn’t built for arm64 with a platform it names.")),
            ("encrypted", MachOBytes.thin(commands: [MachOBytes.encryption(cryptid: 1), MachOBytes.buildVersion(platform: 2, minimumOS: version.0, sdk: version.1)]),
             .notForDevice("Tiny.app is encrypted by the App Store, so it can’t be signed again.")),
        ]
        for (name, executable, error) in cases {
            let app = try DeviceApp.make(in: tmp.url.appending(path: name), executable: executable)
            let signer = RecordingDeviceSigner()
            await #expect(throws: error, "\(name)") {
                try await DevicePackager(signer: signer).package(
                    app, version: deviceVersion(), signing: try deviceSigning(profile: profile))
            }
            #expect(signer.signed.withLock { $0 }.isEmpty)
            #expect(try plist(app.appending(path: "Info.plist"))["CFBundleIdentifier"] as? String == "com.upstream.tiny", "\(name)")
            #expect(try read(app.appending(path: "embedded.mobileprovision")) == "old profile", "\(name)")
        }

        let mac = try await TestApp.make(in: tmp.url.appending(path: "mac-layout"), nested: false)
        await #expect(throws: FrontportError.notForDevice("Tiny.app is laid out as a Mac app.")) {
            try await DevicePackager(signer: RecordingDeviceSigner()).package(
                mac, version: deviceVersion(), signing: try deviceSigning(profile: profile))
        }
        let unnamed = try DeviceApp.make(in: tmp.url.appending(path: "unnamed"))
        try FileManager.default.removeItem(at: unnamed.appending(path: "Info.plist"))
        await #expect(throws: FrontportError.notForDevice("Tiny.app has no executable at its top that its Info.plist names.")) {
            try await DevicePackager(signer: RecordingDeviceSigner()).package(
                unnamed, version: deviceVersion(), signing: try deviceSigning(profile: profile))
        }
    }

    @Test func refusesNestedProgramsUnlessStripped() async throws {
        let tmp = try TemporaryDirectory()
        let profile = tmp.url.appending(path: "p")
        let app = try DeviceApp.make(in: tmp.url.appending(path: "a"))
        let appex = app.appending(path: "PlugIns/Widget.appex", directoryHint: .isDirectory)
        try write(DeviceApp.dictionary("<key>CFBundleExecutable</key><string>Widget</string>"), to: appex.appending(path: "Info.plist"))
        try MachOBytes.iOS().write(to: appex.appending(path: "Widget"))
        try MachOBytes.iOS().write(to: app.appending(path: "helper"))
        let signer = RecordingDeviceSigner()

        await #expect(throws: FrontportError.signingFailed(
            "Tiny.app holds code Frontport doesn’t sign for Devices: PlugIns/Widget.appex, helper. Only frameworks and "
                + "libraries may be nested."))
        {
            try await DevicePackager(signer: signer).package(
                app, version: deviceVersion(), signing: try deviceSigning(profile: profile))
        }
        #expect(signer.signed.withLock { $0 }.isEmpty)

        _ = try await DevicePackager(signer: signer).package(
            app, version: deviceVersion(strip: ["PlugIns", "helper"]), signing: try deviceSigning(profile: profile))
        #expect(signer.items(in: app).last == "")
    }

    /// No link may lead out of an iOS app, Frontport would follow it.
    @Test func refusesLinksOut() async throws {
        let tmp = try TemporaryDirectory()
        let profile = tmp.url.appending(path: "p")
        let outside = tmp.url.appending(path: "outside")
        try write("keep", to: outside)

        let linked = try DeviceApp.make(in: tmp.url.appending(path: "linked"))
        try FileManager.default.createSymbolicLink(at: linked.appending(path: "escape"), withDestinationURL: outside)
        await #expect(throws: FrontportError.self) {
            try await DevicePackager(signer: RecordingDeviceSigner()).package(
                linked, version: deviceVersion(), signing: try deviceSigning(profile: profile))
        }
        #expect(try read(outside) == "keep")
    }

    @Test func refusesAProfileThatDoesntCoverTheSigning() async throws {
        let tmp = try TemporaryDirectory()
        let profile = tmp.url.appending(path: "p")
        let other = AppleTeamID("ABCDE12345")!
        for signing in [
            try deviceSigning(profile: profile, profileTeam: other),
            try deviceSigning(profile: profile, appID: "com.example.*"),
            try deviceSigning(profile: profile, profileCertificates: [String(repeating: "CD", count: 20)]),
        ] {
            let app = try DeviceApp.make(in: tmp.url.appending(path: UUID().uuidString))
            let signer = RecordingDeviceSigner()
            await #expect(throws: FrontportError.self) {
                try await DevicePackager(signer: signer).package(app, version: deviceVersion(), signing: signing)
            }
            #expect(signer.signed.withLock { $0 }.isEmpty)
        }
    }

    /// Renew: a new Provisioning Profile and certificate of the same Apple Team, and the app as it was when that fails.
    @Test func resignsWithAnotherProfileOrKeepsTheApp() async throws {
        let tmp = try TemporaryDirectory()
        let app = try DeviceApp.make(in: tmp.url.appending(path: "Devices"))
        let first = try deviceSigning(profile: tmp.url.appending(path: "first"), contents: "first")
        _ = try await DevicePackager(signer: RecordingDeviceSigner()).package(app, version: deviceVersion(), signing: first)

        let renewed = String(repeating: "CD", count: 20)
        let failing = RecordingDeviceSigner(failsVerifying: true)
        let second = try deviceSigning(profile: tmp.url.appending(path: "second"), contents: "second", certificate: renewed)
        await #expect(throws: FrontportError.signingFailed("verify failed")) {
            try await DevicePackager(signer: failing).resign(app, signing: second)
        }
        #expect(try read(app.appending(path: "embedded.mobileprovision")) == "first")
        #expect(try read(app.appending(path: "_CodeSignature/CodeResources")) == "signed with \(testCertificate)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: app.deletingLastPathComponent().path(percentEncoded: false)) == ["Tiny.app"])

        let signer = RecordingDeviceSigner()
        let info = try await DevicePackager(signer: signer).resign(app, signing: second)
        #expect(try read(app.appending(path: "embedded.mobileprovision")) == "second")
        #expect(signer.items(in: app) == [
            "Frameworks/Kit.framework/libinner.dylib", "Frameworks/Kit.framework", "Frameworks/libloose.dylib", "",
        ])
        #expect(signer.signed.withLock { $0 }.allSatisfy { $0.certificate == renewed })
        #expect(info.bundleId == first.bundleId)

        // Another Apple Team's bundle ID is an install of its own.
        let other = try deviceSigning(profile: tmp.url.appending(path: "other"), team: AppleTeamID("ABCDE12345")!)
        await #expect(throws: FrontportError.signingFailed(
            "Tiny.app has the bundle ID dev.frontport.port.tiny.a1b2c3d4e5, not dev.frontport.port.tiny.abcde12345."))
        {
            try await DevicePackager(signer: RecordingDeviceSigner()).resign(app, signing: other)
        }
    }
}
