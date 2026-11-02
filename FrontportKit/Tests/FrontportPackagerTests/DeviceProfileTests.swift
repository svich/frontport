import Foundation
import FrontportCore
import Testing
@testable import FrontportPackager

/// The app is signed with `get-task-allow`, which only a development Provisioning Profile grants: a Store or Ad Hoc
/// one would make the install fail on the Device, so it's refused before anything is signed.
@Suite struct DeviceProfileTests {
    @Test func refusesAProfileThatIsntForDevelopment() async throws {
        let tmp = try TemporaryDirectory()
        var signing = try deviceSigning(profile: tmp.url.appending(path: "store.mobileprovision"))
        signing.profile.isDevelopment = false
        signing.profile.name = "Store"
        let app = try DeviceApp.make(in: tmp.url.appending(path: "app"))
        let signer = RecordingDeviceSigner()

        await #expect(throws: FrontportError.provisioningFailed("Store isn’t a development Provisioning Profile.")) {
            try await DevicePackager(signer: signer).package(app, version: deviceVersion(), signing: signing)
        }
        #expect(signer.signed.withLock { $0 }.isEmpty)
        #expect(!FileOperations.exists(app.appending(path: "embedded.mobileprovision")), "nor is it embedded")
    }

    /// Renew too: the app keeps the signature and Provisioning Profile it had.
    @Test func resignRefusesAProfileThatIsntForDevelopment() async throws {
        let tmp = try TemporaryDirectory()
        let app = try DeviceApp.make(in: tmp.url.appending(path: "Devices"))
        let first = try deviceSigning(profile: tmp.url.appending(path: "first"), contents: "first")
        _ = try await DevicePackager(signer: RecordingDeviceSigner()).package(app, version: deviceVersion(), signing: first)
        var store = try deviceSigning(profile: tmp.url.appending(path: "store"), contents: "store")
        store.profile.isDevelopment = false
        let signer = RecordingDeviceSigner()

        await #expect(throws: FrontportError.self) {
            try await DevicePackager(signer: signer).resign(app, signing: store)
        }
        #expect(signer.signed.withLock { $0 }.isEmpty)
        #expect(try read(app.appending(path: "embedded.mobileprovision")) == "first")
    }
}
