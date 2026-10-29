import FrontportCore
import SwiftUI

/// The sidebar's status glyph for a Port: running, update, needs ROM or ROMs not Seeded, work in progress, Blocked.
struct StatusIcon: View {
    @Environment(AppModel.self) private var model
    let port: PortID

    var body: some View {
        switch model.status(of: port).state {
        case .working(let activity):
            let text = model.activityText(activity, for: port)
            Group {
                if let fraction = activity.progress.fraction {
                    ProgressRing(fraction: fraction)
                        .frame(width: 14, height: 14)
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .help(text)
            .accessibilityLabel(text)
            .accessibilityIdentifier(identifier)
        case .running:
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)
                .background(Circle().fill(.green.opacity(0.22)).frame(width: 14, height: 14))
                .frame(width: 15, height: 15)
                .help("Running")
                .accessibilityLabel("Running")
                .accessibilityIdentifier(identifier)
        case .updateAvailable(let release):
            Image(systemName: "arrow.down.circle")
                .fontWeight(.semibold)
                .foregroundStyle(.tint)
                .help("\(release.version) available")
                .accessibilityLabel("Update available")
                .accessibilityIdentifier(identifier)
        case .needsROM:
            Image(systemName: "exclamationmark.triangle")
                .fontWeight(.semibold)
                .foregroundStyle(.orange)
                .help("Needs a ROM")
                .accessibilityLabel("Needs ROM")
                .accessibilityIdentifier(identifier)
        case .unseeded:
            Image(systemName: "exclamationmark.triangle")
                .fontWeight(.semibold)
                .foregroundStyle(.orange)
                .help("Its ROMs aren’t Seeded into its Data yet")
                .accessibilityLabel("ROMs not Seeded")
                .accessibilityIdentifier(identifier)
        case .blocked(let block):
            Image(systemName: block.severity == .stop ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(block.severity == .stop ? .red : .orange)
                .help(block.reason)
                .accessibilityLabel("Blocked")
                .accessibilityIdentifier(identifier)
        case .unsupported, .available, .needsBuildROM, .ready:
            EmptyView()
        }
    }

    private var identifier: String { "status.\(port.rawValue)" }
}

/// A determinate progress ring, for small spaces.
struct ProgressRing: View {
    let fraction: Double
    var lineWidth: CGFloat = 2.5

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, fraction)))
                .stroke(.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
    }
}
