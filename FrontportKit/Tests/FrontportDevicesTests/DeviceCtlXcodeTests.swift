import Foundation
import FrontportCore
import Testing
@testable import FrontportDevices

/// `devicectl` found through Xcode when first needed.
@Suite struct DeviceCtlXcodeTests {
    /// Without Xcode every call says so, and a later call looks again, so an Xcode installed meanwhile is found.
    @Test func withoutXcodeEveryCallSaysSoAndLooksAgain() async {
        let lookups = Counter()
        let missing = Xcode.Locator(
            selected: { lookups.increment(); return nil }, installed: { [] }, exists: { _ in false })
        let devicectl = DeviceCtl(locator: missing)
        await #expect(throws: FrontportError.xcodeMissing) { try await devicectl.readings() }
        await #expect(throws: FrontportError.xcodeMissing) {
            try await devicectl.uninstall("dev.frontport.port.x.a1b2c3d4e5", from: "00008110-0000000000000000")
        }
        #expect(lookups.value == 2)
    }

    /// Xcode without its iOS platform can't reach a Device either.
    @Test func withoutTheIOSPlatformEveryCallSaysSo() async {
        let developer = URL(filePath: "/Applications/Xcode.app/Contents/Developer", directoryHint: .isDirectory)
        let locator = Xcode.Locator(
            selected: { developer }, installed: { [] }, exists: { $0.standardizedFileURL == developer.standardizedFileURL })
        await #expect(throws: FrontportError.noIOSPlatform) { try await DeviceCtl(locator: locator).readings() }
    }
}

/// Counts calls from any thread.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
