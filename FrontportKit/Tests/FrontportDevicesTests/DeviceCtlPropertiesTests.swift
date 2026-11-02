import Foundation
import FrontportCore
import Testing
@testable import FrontportDevices

/// `devicectl list devices` without the fields it says it will remove, and local paths as the spikes passed them.
@Suite struct DeviceCtlPropertiesTests {
    /// The listing with `hardwareProperties`, `deviceProperties` and `connectionProperties` gone, as
    /// `--omit-deprecated-fields-in-json` writes it, and its `properties.connection` edited.
    static func withoutDeprecatedFields(connection edit: (inout [String: Any]) -> Void) throws -> Data {
        var root = try #require(try JSONSerialization.jsonObject(with: Fixtures.data("devices-network-connected")) as? [String: Any])
        var result = try #require(root["result"] as? [String: Any])
        var devices = try #require(result["devices"] as? [[String: Any]])
        for index in devices.indices {
            for key in ["hardwareProperties", "deviceProperties", "connectionProperties", "_deprecationNotice"] {
                devices[index][key] = nil
            }
            var properties = try #require(devices[index]["properties"] as? [String: Any])
            var connection = try #require(properties["connection"] as? [String: Any])
            edit(&connection)
            properties["connection"] = connection
            devices[index]["properties"] = properties
        }
        result["devices"] = devices
        root["result"] = result
        return try JSONSerialization.data(withJSONObject: root)
    }

    @Test func readsADeviceFromItsPropertiesAlone() async throws {
        let fake = try FakeDeviceCtl([
            .init(json: Self.withoutDeprecatedFields { _ in }), .init(json: Fixtures.data("lockstate-unlocked")),
        ])
        #expect(try await fake.devicectl.readings() == [
            DeviceReading(
                device: Device(id: Fixtures.udid, name: "Test User’s iPhone", model: "iPhone 13", osVersion: "27.0.1", families: [1]),
                connection: .network, isLocked: false, developerMode: true)
        ])
    }

    @Test func awayWhenItsPropertiesSayTheTunnelIsUnavailable() async throws {
        let fake = try FakeDeviceCtl([.init(json: Self.withoutDeprecatedFields { $0["state"] = "unavailable" })])
        let readings = try await fake.devicectl.readings()
        #expect(readings.map(\.connection) == [.away])
        #expect(fake.calls.count == 1)
    }

    @Test func passesAFoldersPathWithoutItsTrailingSlash() async throws {
        let fake = try FakeDeviceCtl(fixtures: ["copy-to-folder", "install-app"])
        let folder = URL(filePath: "/tmp/x", directoryHint: .isDirectory)
        #expect(folder.path(percentEncoded: false) == "/tmp/x/")
        try await fake.devicectl.copy(folder, to: "Documents/x", of: "b", on: Fixtures.udid)
        try await fake.devicectl.install(URL(filePath: "/tmp/Spike.app", directoryHint: .isDirectory), on: Fixtures.udid)
        let copy = try #require(fake.calls.first)
        #expect(copy.firstIndex(of: "--source").map { copy[$0 + 1] } == "/tmp/x")
        #expect(fake.calls.last?.last == "/tmp/Spike.app")
        #expect(DeviceCtl.argument(URL(filePath: "/", directoryHint: .isDirectory)) == "/")
    }
}
