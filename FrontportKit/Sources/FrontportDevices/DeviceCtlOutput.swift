import Foundation

extension DeviceCtl {
    /// Mirrors of `devicectl`'s JSON (version 5, devicectl 651.32), only as far as Frontport reads it, every field
    /// optional.
    enum Output {
        struct Envelope<Result: Decodable>: Decodable {
            var info: Info?
            var result: Result?
            var error: Failure?

            private enum CodingKeys: String, CodingKey { case info, result, error }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                info = try? container.decodeIfPresent(Info.self, forKey: .info)
                result = try? container.decodeIfPresent(Result.self, forKey: .result)
                error = try? container.decodeIfPresent(Failure.self, forKey: .error)
            }
        }

        struct Info: Decodable {
            /// "success", "failed" or "timeout".
            var outcome: String?
            /// Such as "devicectl.device.install.app".
            var commandType: String?
            var details: String?
        }

        /// An NSError, with its `NSUnderlyingError`s.
        struct Failure: Decodable, Hashable {
            var code: Int
            var domain: String
            var description: String?
            var reason: String?
            var debugDescription: String?
            /// The underlying error, when there's one.
            var underlying: [Failure]

            private enum CodingKeys: String, CodingKey { case code, domain, userInfo }
            private enum InfoKeys: String, CodingKey {
                case description = "NSLocalizedDescription", reason = "NSLocalizedFailureReason"
                case debugDescription = "NSDebugDescription", underlying = "NSUnderlyingError"
            }
            private struct Text: Decodable { var string: String? }
            private struct Wrapped: Decodable { var error: Failure }

            init(code: Int, domain: String, description: String? = nil, reason: String? = nil, underlying: [Failure] = []) {
                self.code = code
                self.domain = domain
                self.description = description
                self.reason = reason
                self.underlying = underlying
            }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                code = (try? container.decode(Int.self, forKey: .code)) ?? 0
                domain = (try? container.decode(String.self, forKey: .domain)) ?? ""
                let info = try? container.nestedContainer(keyedBy: InfoKeys.self, forKey: .userInfo)
                description = (try? info?.decodeIfPresent(Text.self, forKey: .description))?.string
                reason = (try? info?.decodeIfPresent(Text.self, forKey: .reason))?.string
                debugDescription = (try? info?.decodeIfPresent(Text.self, forKey: .debugDescription))?.string
                underlying = (try? info?.decodeIfPresent(Wrapped.self, forKey: .underlying)).map { [$0.error] } ?? []
            }

            /// This error and the ones under it, outermost first.
            var chain: [Failure] { [self] + underlying.flatMap(\.chain) }

            /// What it says, in its own words: its description and reason, else the first reason under it.
            var text: String {
                var parts = [description, reason].compactMap { $0 }
                if reason == nil, let deeper = chain.dropFirst().lazy.compactMap({ $0.reason ?? $0.description }).first {
                    parts.append(deeper)
                }
                if parts.isEmpty, let debugDescription { parts.append(debugDescription) }
                return parts.isEmpty ? "\(domain) error \(code)." : parts.joined(separator: " ")
            }
        }

        // MARK: list devices

        struct Devices: Decodable {
            var devices: [ListedDevice]?
        }

        struct ListedDevice: Decodable {
            var identifier: String?
            var properties: Properties?
            // Deprecated in favour of `properties`, read when it lacks a field.
            var hardwareProperties: Hardware?
            var deviceProperties: LegacyState?
            var connectionProperties: Connection?
        }

        struct Properties: Decodable {
            var connection: Connection?
            var hardware: Hardware?
            var software: Software?
            var state: State?
        }

        struct Connection: Decodable {
            /// "wired" or "localNetwork"; none while it isn't reachable.
            var transportType: String?
            var pairingState: String?
            /// The tunnel's state in `properties`, such as "disconnected", which `tunnelState` says in the deprecated
            /// `connectionProperties`.
            var state: String?
            var tunnelState: String?
        }

        struct Hardware: Decodable {
            var udid: String?
            var marketingName: String?
            /// "iPhone", "iPad", "appleWatch", …
            var deviceType: String?
            /// "physical" or "virtual".
            var reality: String?
            var supportedDeviceFamilies: [Int]?
        }

        struct Software: Decodable {
            var osVersionNumber: Version?
        }

        struct Version: Decodable {
            var stringValue: String?
        }

        struct State: Decodable {
            var name: String?
            var developerModeStatus: DeveloperMode?
        }

        struct LegacyState: Decodable {
            var name: String?
            var osVersionNumber: String?
            /// "enabled" or "disabled".
            var developerModeStatus: String?
        }

        /// `{"enabled": {...}}` in `properties`: the one key is the state.
        struct DeveloperMode: Decodable {
            var state: String?

            private struct Key: CodingKey {
                var stringValue: String
                var intValue: Int? { nil }
                init(stringValue: String) { self.stringValue = stringValue }
                init?(intValue: Int) { nil }
            }

            init(from decoder: any Decoder) throws {
                if let text = try? decoder.singleValueContainer().decode(String.self) {
                    state = text
                } else {
                    state = try? decoder.container(keyedBy: Key.self).allKeys.first?.stringValue
                }
            }
        }

        // MARK: device info

        struct LockState: Decodable {
            var passcodeRequired: Bool?
            var unlockedSinceBoot: Bool?
        }

        struct Apps: Decodable {
            var apps: [App]?
        }

        struct App: Decodable {
            var bundleIdentifier: String?
            var name: String?
            var builtByDeveloper: Bool?
            var containerAccessible: Bool?
            var version: String?
        }

        struct Files: Decodable {
            var files: [File]?
        }

        struct File: Decodable {
            var name: String?
            var relativePath: String?
            var metadata: Metadata?
            var resources: Resources?
        }

        struct Metadata: Decodable {
            var size: Int64?
            var lastModDate: String?
        }

        struct Resources: Decodable {
            var isDirectory: Bool?
            var isSymbolicLink: Bool?
        }

        struct Processes: Decodable {
            var runningProcesses: [Process]?
        }

        struct Process: Decodable {
            var executable: String?
            var processIdentifier: Int32?
        }

        // MARK: install, uninstall, copy, process

        struct Installed: Decodable {
            var installedApplications: [Application]?
        }

        struct Uninstalled: Decodable {
            var uninstalledApplications: [Application]?
        }

        struct Application: Decodable {
            var bundleID: String?
        }

        struct Copied: Decodable {
            var destination: String?
            var file: File?
        }

        struct Launched: Decodable {
            var process: Process?
            var terminationResult: Termination?
        }

        struct Termination: Decodable {
            var exitCode: Int32?
        }

        struct Signalled: Decodable {
            var process: Process?
            var signal: Signal?
        }

        struct Signal: Decodable {
            var name: String?
            var value: Int32?
        }
    }
}
