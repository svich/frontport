import FrontportCore
import Foundation

/// Prepares a Port's iOS version to install on Devices: one flat arm64 iPhone and iPad app, given the bundle ID of the
/// user's Apple Team, the Provisioning Profile embedded, and signed inside-out with the
/// Apple Team's Apple Development certificate through its `DeviceSigner`. It holds no links out, since an iOS app
/// can't follow one, and Frontport, unsandboxed, would.
public struct DevicePackager: DevicePackaging {
    private let signer: any DeviceSigner

    public init(signer: any DeviceSigner = Codesign()) {
        self.signer = signer
    }

    /// The app is untrusted: it's refused when anything in it leads outside it.
    public func inspect(_ app: URL, version: IOSVersion) async throws -> DeviceAppInfo {
        try PortPackager.checkContained(app, allowing: [:])
        let (executable, build) = try Self.checkBuild(app)
        return try Self.info(app, executable: executable, build: build)
    }

    /// The app is untrusted until it's signed: it's refused when anything in it leads outside it, and when it isn't
    /// for iPhone and iPad, before anything is changed.
    public func package(_ app: URL, version: IOSVersion, signing: DeviceSigning, icon: URL?) async throws -> DeviceAppInfo {
        try PortPackager.checkContained(app, allowing: [:])
        let (executable, build) = try Self.checkBuild(app)
        // Upstream may ship read-only files, which this changes and signs in place.
        try FileOperations.makeWritable(app)
        try PortPackager.setBundleIdentifier(signing.bundleId, plist: "Info.plist", in: app)
        for path in ["_CodeSignature", "embedded.mobileprovision", "SC_Info"] + version.view.strip {
            try remove(try PortPackager.location(path, in: app))
        }
        if let icon { try DeviceIcon.replace(in: app, with: icon) }
        try PortPackager.checkContained(app, allowing: [:])
        try Task.checkCancellation()

        try await sign(app, signing: signing)
        return try Self.info(app, executable: executable, build: build)
    }

    /// Only the Provisioning Profile and the signatures change, and only for the bundle ID the app has: another Apple
    /// Team's is an install of its own.
    ///
    /// Signing changes the app in place, so a clone of it, beside it, takes its place again when signing or verifying
    /// fails: the app keeps the signature the Installation's record describes.
    public func resign(_ app: URL, signing: DeviceSigning) async throws -> DeviceAppInfo {
        try PortPackager.checkContained(app, allowing: [:])
        let (executable, build) = try Self.checkBuild(app)
        let bundleId = Self.infoPlist(of: app)?["CFBundleIdentifier"] as? String
        guard bundleId == signing.bundleId else {
            throw FrontportError.signingFailed(
                "\(app.lastPathComponent) has the bundle ID \(bundleId ?? "nothing"), not \(signing.bundleId).")
        }
        let kept = app.deletingLastPathComponent()
            .appending(path: ".\(app.lastPathComponent).resigning", directoryHint: .isDirectory)
        try remove(kept)
        try FileOperations.clone(app, to: kept)
        do {
            try await sign(app, signing: signing)
        } catch {
            // `kept` then holds the app that failed, removed with it. When the swap fails, `kept` stays: it's the one
            // copy whose signature matches the record.
            if (try? FileOperations.swap(kept, app)) != nil { try? remove(kept) }
            throw error
        }
        try? remove(kept)
        return try Self.info(app, executable: executable, build: build)
    }

    // MARK: Steps

    /// The main executable, relative to the app, and what it was built for. Refuses a Mac app, one for the Simulator
    /// or another platform, one without an arm64 slice, and one the App Store encrypted, which can't be signed again.
    static func checkBuild(_ app: URL) throws -> (executable: String, build: MachO.Build) {
        let name = app.lastPathComponent
        guard !FileOperations.exists(app.appending(path: "Contents")) else {
            throw FrontportError.notForDevice("\(name) is laid out as a Mac app.")
        }
        guard let executable = CodeLayout.mainExecutable(of: app, relativeTo: app, layout: .flat),
            !executable.contains("/")
        else {
            throw FrontportError.notForDevice("\(name) has no executable at its top that its Info.plist names.")
        }
        guard let build = MachO.build(of: app.appending(path: executable)) else {
            throw FrontportError.notForDevice("\(name)’s executable isn’t built for arm64 with a platform it names.")
        }
        switch build.platform {
        case .iOS: break
        case .iOSSimulator: throw FrontportError.notForDevice("\(name) is built for the iOS Simulator.")
        case .macOS, .macCatalyst: throw FrontportError.notForDevice("\(name) is built for the Mac.")
        default: throw FrontportError.notForDevice("\(name) isn’t built for iOS.")
        }
        guard !build.isEncrypted else {
            throw FrontportError.notForDevice("\(name) is encrypted by the App Store, so it can’t be signed again.")
        }
        return (executable, build)
    }

    /// Embeds the Provisioning Profile and signs inside-out: each framework and library, then the app with the
    /// entitlements every Provisioning Profile grants, then checks the signature strictly, which an app without links
    /// passes. Refuses an app holding programs iOS doesn't run from a Port, which `ios.strip` may remove first.
    private func sign(_ app: URL, signing: DeviceSigning) async throws {
        let layout = try CodeLayout(app: app, layout: .flat)
        guard layout.refused.isEmpty else {
            let root = app.resolvingSymlinksInPath().path(percentEncoded: false)
            let names = layout.refused.map {
                String($0.path(percentEncoded: false).dropFirst(root.count)).trimmingCharacters(in: ["/"])
            }
            throw FrontportError.signingFailed(
                "\(app.lastPathComponent) holds code Frontport doesn’t sign for Devices: "
                    + "\(names.joined(separator: ", ")). Only frameworks and libraries may be nested.")
        }
        let profile = signing.profile
        // Only a development one grants `get-task-allow`, which the app is signed with.
        guard profile.isDevelopment else {
            throw FrontportError.provisioningFailed("\(profile.name) isn’t a development Provisioning Profile.")
        }
        guard profile.team == signing.team, signing.certificate.team == signing.team, profile.covers(signing.bundleId),
            profile.certificates.contains(where: { $0.caseInsensitiveCompare(signing.certificate.sha1) == .orderedSame })
        else {
            throw FrontportError.provisioningFailed(
                "\(profile.name) doesn’t let \(signing.certificate.name) sign \(signing.bundleId).")
        }
        guard FileOperations.isFileOrFolder(profile.file), !FileOperations.isDirectory(profile.file) else {
            throw FrontportError.provisioningFailed("\(profile.name) isn’t a file.")
        }
        let embedded = try PortPackager.location("embedded.mobileprovision", in: app)
        try remove(embedded)
        try FileOperations.clone(profile.file, to: embedded)
        try Task.checkCancellation()

        let certificate = signing.certificate.sha1
        for item in layout.nested {
            try Task.checkCancellation()
            try await signer.sign(item.url, certificate: certificate, entitlements: nil)
        }
        let entitlements = DeviceEntitlements.app(team: signing.team, bundleId: signing.bundleId)
        try await signer.sign(app, certificate: certificate, entitlements: entitlements)
        try await signer.verify(app, strictness: .strict)
    }

    /// What a Device is checked against before installing.
    private static func info(_ app: URL, executable: String, build: MachO.Build) throws -> DeviceAppInfo {
        guard let info = infoPlist(of: app), let bundleId = info["CFBundleIdentifier"] as? String else {
            throw FrontportError.signingFailed("\(app.lastPathComponent) has no readable Info.plist.")
        }
        // A plist may hold numbers as strings; iOS takes a missing UIDeviceFamily as iPhone only.
        let families: [Int] = switch info["UIDeviceFamily"] {
        case let list as [Any]: list.compactMap { ($0 as? Int) ?? ($0 as? String).flatMap { Int($0) } }
        case let one as Int: [one]
        case let one as String: Int(one).map { [$0] } ?? []
        default: []
        }
        return DeviceAppInfo(
            bundleId: bundleId, executable: executable, minimumOS: build.minimumOS.description,
            sdk: build.sdk.packed == 0 ? nil : build.sdk.description, families: families.isEmpty ? [1] : families)
    }

    private static func infoPlist(of app: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: app.appending(path: "Info.plist")) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private func remove(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
        } catch {
            throw FrontportError.fileOperation("Couldn’t remove \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
