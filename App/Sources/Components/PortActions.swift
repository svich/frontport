import FrontportCore
import SwiftUI

/// The one action a Port's Status calls for: Install, Play, Stop, Update, Add ROM…, Seed ROMs or Cancel, or the way
/// off a Blocked Release.
struct PortActionButton: View {
    @Environment(AppModel.self) private var model
    @Environment(ViewState.self) private var viewState
    let port: PortID
    var controlSize = ControlSize.regular
    /// Offer Play rather than Update where the update has its own card.
    var playsWhenUpdatable = false

    var body: some View {
        let status = model.status(of: port)
        let action = playsWhenUpdatable && status.main == .update && status.others.contains(.play) ? .play : status.main
        Group {
            switch action {
            case .install?:
                button(.install, status, "install")
                    .buttonStyle(.glass)
                    .tint(.accentColor)
            case .addROM? where model.isDownloadingFromSteam(for: port):
                ROMDownloadIndicator()
                    .accessibilityIdentifier(identifier("steamDownload"))
            case .addROM? where model.isDownloadingFromWeb(for: port):
                ROMDownloadIndicator()
                    .accessibilityIdentifier(identifier("webDownload"))
            case .addROM(let stage)?:
                // A Build ROM is built into the Port, so there's no installing without it.
                button(.addROM(stage), status, "addROM", help: addROMHelp(stage))
                    .buttonStyle(.addROM)
                    // One ROM downloads at a time.
                    .disabled(model.romDownload != nil
                        && (model.steamDownload(for: port) != nil || !model.webDownloads(for: port).isEmpty))
            case .cancel?:
                Button {
                    viewState.run(.cancel, for: port, in: model)
                } label: {
                    Image(systemName: "xmark")
                        .fontWeight(.semibold)
                        .accessibilityLabel("Cancel")
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("Cancel")
                .accessibilityIdentifier(identifier("cancel"))
            case .stop?:
                Button {
                    viewState.run(.stop, for: port, in: model)
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier(identifier("stop"))
            case .seed?:
                button(.seed, status, "seed", help: "Add its ROMs to its Data again")
                    .buttonStyle(.glass)
            case .update?:
                if case .blocked = status.state {
                    button(.update, status, "update").buttonStyle(.glassProminent)
                } else {
                    button(.update, status, "update")
                        .buttonStyle(.glass)
                        .tint(.accentColor)
                }
            case .installFallback?:
                button(.installFallback, status, "installOlder").buttonStyle(.glass)
            case .rollBack?:
                button(.rollBack, status, "rollback").buttonStyle(.glass)
            case .play?:
                PlayButton(port: port)
            case nil:
                if case .unsupported(let reason) = status.state {
                    Text("Unsupported")
                        .foregroundStyle(.secondary)
                        .help(reason)
                        .accessibilityIdentifier(identifier("unsupported"))
                }
            default:
                EmptyView()
            }
        }
        .controlSize(controlSize)
    }

    /// Titled, disabled with why, and run as Status says.
    private func button(_ action: Status.Action, _ status: Status, _ name: String, help: String? = nil) -> some View {
        Button(model.title(action, for: port)) { viewState.run(action, for: port, in: model) }
            .disabled(!status.allows(action))
            .help(model.help(action, for: port) ?? help ?? "")
            .accessibilityIdentifier(identifier(name))
    }

    /// "action.install.shipwright": one action per Port on screen at a time.
    private func identifier(_ action: String) -> String { "action.\(action).\(port.rawValue)" }

    private func addROMHelp(_ stage: Stage) -> String? {
        if !model.webDownloads(for: port).isEmpty, model.steamDownload(for: port) == nil, model.steamOffers(for: port).isEmpty {
            return "Frontport downloads the free game’s files the Port needs, then adds them to ROMs"
        }
        return stage == .build ? "Frontport needs the ROM to build this Port" : nil
    }
}

/// Install on iPhone or iPad…, beside the Mac's action for a Port with an iOS version, whether or not it's on this Mac:
/// downloads the iOS version, then asks which Devices to install it on. Named for the Devices Frontport knows, and
/// disabled with why on hover. While it shows, Frontport reads the Devices every 10 seconds, so one plugged in counts.
struct InstallOnDevicesButton: View {
    @Environment(AppModel.self) private var model
    let port: PortID
    /// Its accessibility identifier.
    var identifier: String

    var body: some View {
        if let status = model.deviceInstallStatus(of: port), status.availability != .unavailable {
            Button(model.installOnDevicesTitle(status)) { model.installOnDevices(port) }
                .buttonStyle(.glass)
                .disabled(!status.isAllowed)
                .help(model.installOnDevicesHelp(status, for: port) ?? "")
                .accessibilityIdentifier(identifier)
                .task(id: port) { await model.deviceUpkeep.watch() }
        }
    }
}

extension ButtonStyle where Self == AddROMButtonStyle {
    static var addROM: AddROMButtonStyle { AddROMButtonStyle() }
}

/// Add ROM…: black on yellow, like a warning sign, since the Port can't go on without its ROM. Sized like a glass
/// button of the same control size.
struct AddROMButtonStyle: ButtonStyle {
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(controlSize == .small || controlSize == .mini ? .subheadline.weight(.medium) : .body.weight(.medium))
            .foregroundStyle(.black)
            .lineLimit(1)
            .padding(.horizontal, height / 2)
            .frame(height: height)
            .background(.yellow, in: Capsule())
            .opacity(!isEnabled ? 0.5 : configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }

    private var height: CGFloat {
        switch controlSize {
        case .mini, .small: 20
        case .large, .extraLarge: 36
        default: 28
        }
    }
}

/// A ROM's download in place of the button that started it: a ring and the percent, or a spinner while Steam starts.
struct ROMDownloadIndicator: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let download = model.romDownload {
            HStack(spacing: 6) {
                ProgressView(value: download.fraction)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                Text(model.downloadPercent(download) ?? model.downloadStatus(download))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .help(model.downloadText(download))
        }
    }
}

/// Play, prominent.
struct PlayButton: View {
    @Environment(AppModel.self) private var model
    let port: PortID

    var body: some View {
        Button {
            model.play(port)
        } label: {
            Label("Play", systemImage: "play.fill")
        }
        .buttonStyle(.glassProminent)
        .accessibilityIdentifier("action.play.\(port.rawValue)")
    }
}
