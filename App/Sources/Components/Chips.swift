import FrontportCore
import SwiftUI

/// A small capsule label, such as a Release version or "Needs Mario Kart 64 ROM".
struct Pill: View {
    enum Style { case neutral, positive, warning }

    let text: String
    var systemImage: String?
    var style = Style.neutral

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).imageScale(.small).fontWeight(.bold)
            }
            Text(text).monospacedDigit()
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .foregroundStyle(foreground)
        .background(background, in: Capsule())
    }

    private var foreground: AnyShapeStyle {
        switch style {
        case .neutral: AnyShapeStyle(.secondary)
        case .positive: AnyShapeStyle(.green)
        case .warning: AnyShapeStyle(.orange)
        }
    }

    private var background: AnyShapeStyle {
        switch style {
        case .neutral: AnyShapeStyle(.quaternary.opacity(0.6))
        case .positive: AnyShapeStyle(.green.opacity(0.14))
        case .warning: AnyShapeStyle(.orange.opacity(0.14))
        }
    }
}

/// The Pills a Catalog card shows: Release, ROM state, Network, Builds from source.
struct EntryPills: View {
    @Environment(AppModel.self) private var model
    let entry: CatalogEntry
    var showsPermissions = false

    var body: some View {
        FlowLayout(spacing: 6) {
            if let release = model.survey.latestRelease(for: entry.id) {
                Pill(text: release.version)
            }
            if let reason = entry.unsupported {
                Pill(text: "Unsupported", systemImage: "nosign", style: .warning).help(reason)
            } else if model.survey.matching(for: entry.id).missing().isEmpty {
                Pill(text: "ROM ready", systemImage: "checkmark", style: .positive)
            } else {
                Pill(text: "Needs \(model.gameName(for: entry)) ROM")
            }
            if showsPermissions {
                ForEach(Permission.allCases.filter { entry.permissions[$0] }, id: \.self) { Pill(text: $0.name) }
            } else if entry.permissions.network {
                Pill(text: "Network")
            }
            if entry.isSourceBuilt {
                Pill(text: "Builds from source")
            }
        }
    }
}

/// "DECOMP" over artwork.
struct KindBadge: View {
    let kind: Kind

    var body: some View {
        Text(kind.name.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(0.7)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Lays out children left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
