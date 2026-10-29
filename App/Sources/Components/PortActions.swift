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
            case .addROM(let stage)?:
                // A Build ROM is built into the Port, so there's no installing without it.
                button(.addROM(stage), status, "addROM", help: stage == .build ? "Frontport needs the ROM to build this Port" : nil)
                    .buttonStyle(.addROM)
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
        Button(status.title(action)) { viewState.run(action, for: port, in: model) }
            .disabled(!status.allows(action))
            .help(model.help(action, for: port) ?? help ?? "")
            .accessibilityIdentifier(identifier(name))
    }

    /// "action.install.shipwright": one action per Port on screen at a time.
    private func identifier(_ action: String) -> String { "action.\(action).\(port.rawValue)" }
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

/// The colored status line under a Port's name in the Library.
struct PortStatusLine: View {
    @Environment(AppModel.self) private var model
    let port: PortID

    var body: some View {
        let installed = model.survey.installation(port)?.release.version
        switch model.status(of: port).state {
        case .working(let activity):
            Text(model.activityText(activity, for: port)).foregroundStyle(.secondary)
        case .running:
            HStack(spacing: 5) {
                Circle().fill(.green).frame(width: 7, height: 7)
                Text(["Running", installed].compactMap { $0 }.joined(separator: " · "))
            }
            .foregroundStyle(.green)
        case .needsROM(let requirements):
            Text("Needs \(article(requirements.first?.label ?? "")) \(requirements.first?.label ?? "") ROM")
                .foregroundStyle(.orange)
        case .unseeded(let requirements):
            Text("\(requirements.first?.label ?? "Its") ROM isn’t Seeded")
                .foregroundStyle(.orange)
        case .updateAvailable(let release):
            Text("\(installed ?? "") · \(release.version) available").foregroundStyle(.tint)
        case .blocked(let block):
            Text(block.severity == .stop ? "\(block.release) disabled by the Catalog" : "\(block.release) is Blocked")
                .foregroundStyle(block.severity == .stop ? .red : .orange)
                .help(block.reason)
        case .unsupported:
            Text("Unsupported").foregroundStyle(.secondary)
        case .needsBuildROM(let requirements):
            Text("Needs \(article(requirements.first?.label ?? "")) \(requirements.first?.label ?? "") ROM")
                .foregroundStyle(.orange)
        case .available, .ready:
            Text(installed ?? "").foregroundStyle(.secondary)
        }
    }

    private func article(_ word: String) -> String {
        guard let first = word.lowercased().first else { return "a" }
        return "aeiou".contains(first) ? "an" : "a"
    }
}
