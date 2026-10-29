import SwiftUI

/// A titled box of rows with dividers between them, like a grouped section in System Settings.
struct GroupedSection<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.headline)
                    .padding(.leading, 4)
            }
            Group(subviews: content) { rows in
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        row
                        if row.id != rows.last?.id {
                            Divider().padding(.leading, 14)
                        }
                    }
                }
            }
            .groupedBackground()
            if let footer {
                Text(footer)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// One row of a GroupedSection: a label on the left and a value or control on the right.
struct GroupedRow<Label: View, Trailing: View>: View {
    @ViewBuilder var label: Label
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 38)
    }
}

extension GroupedRow where Label == Text, Trailing == Text {
    /// A label with a secondary value.
    init(_ label: String, value: String) {
        self.label = Text(label)
        self.trailing = Text(value).foregroundStyle(.secondary)
    }
}

extension GroupedRow where Label == Text {
    init(_ label: String, @ViewBuilder trailing: () -> Trailing) {
        self.label = Text(label)
        self.trailing = trailing()
    }
}

extension View {
    /// The fill and hairline of grouped boxes and cards.
    func groupedBackground(cornerRadius: CGFloat = 12) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(.background.secondary, in: shape)
            .overlay(shape.strokeBorder(.separator.opacity(0.6), lineWidth: 1))
    }

    /// A tinted callout box, such as the update card or a Needed ROM.
    func calloutBackground(_ tint: Color, cornerRadius: CGFloat = 14) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(tint.opacity(0.08), in: shape)
            .overlay(shape.strokeBorder(tint.opacity(0.22), lineWidth: 1))
    }
}

/// A page section heading with an optional count or subtitle.
struct SectionHeader: View {
    let title: String
    var count: Int?
    var subtitle: String?
    /// For the UI tests: names the count "<identifier>.count".
    var identifier: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.title2.bold())
                if let count {
                    Text("\(count)").font(.title2).foregroundStyle(.secondary)
                        .accessibilityIdentifier(identifier.map { "\($0).count" } ?? "")
                }
            }
            if let subtitle {
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
