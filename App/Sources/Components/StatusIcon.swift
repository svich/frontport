import FrontportCore
import SwiftUI

/// The sidebar's status glyph for a Port under This Mac: running, update, needs ROM or ROMs not Seeded, work in
/// progress, Blocked.
struct StatusIcon: View {
    @Environment(AppModel.self) private var model
    let port: PortID

    var body: some View {
        switch model.status(of: port).state {
        case .working(let activity):
            ActivityIcon(activity: activity, text: model.activityText(activity, for: port))
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
        case .unsupported, .ready, .available, .needsBuildROM:
            EmptyView()
        }
    }

    private var identifier: String { "status.\(port.rawValue)" }
}

/// The sidebar's status glyph for a Port under one of the user's Devices: a change under way there, Renew due or
/// expired, ROMs not Seeded there, an Update.
struct DeviceStatusIcon: View {
    @Environment(AppModel.self) private var model
    let port: PortID
    let device: DeviceID

    var body: some View {
        if let reading = model.deviceReading(device) {
            let status = model.deviceStatus(of: port, on: reading)
            if case .working(let activity) = status.state {
                ActivityIcon(activity: activity, text: model.activityText(activity, for: port))
                    .accessibilityIdentifier(identifier)
            } else if let renew = model.renewText(status) {
                Image(systemName: reading.device.isPad ? "ipad.badge.exclamationmark" : "iphone.badge.exclamationmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(.orange)
                    .help(renew)
                    .accessibilityLabel("Renew due")
                    .accessibilityIdentifier(identifier)
            } else if status.matching?.hasUnseeded == true {
                Image(systemName: "exclamationmark.triangle")
                    .fontWeight(.semibold)
                    .foregroundStyle(.orange)
                    .help(model.seedingText(status, for: port) ?? "Its ROMs aren’t Seeded there yet")
                    .accessibilityLabel("ROMs not Seeded")
                    .accessibilityIdentifier(identifier)
            } else if let update = status.update {
                Image(systemName: "arrow.down.circle")
                    .fontWeight(.semibold)
                    .foregroundStyle(.tint)
                    .help("\(update.version) available")
                    .accessibilityLabel("Update available")
                    .accessibilityIdentifier(identifier)
            }
        }
    }

    private var identifier: String { "status.\(device.rawValue).\(port.rawValue)" }
}

/// A change under way: a ring once it reports how far it is, a spinner until then.
private struct ActivityIcon: View {
    let activity: Activity
    let text: String

    var body: some View {
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
    }
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
