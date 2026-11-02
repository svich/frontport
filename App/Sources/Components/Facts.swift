import FrontportCore
import SwiftUI

/// A row of facts, as the App Store shows ratings, age and size under an app's name: each a column, divided by lines.
struct FactRow: View {
    let facts: [Fact]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(facts.enumerated()), id: \.offset) { offset, fact in
                if offset > 0 {
                    Divider().frame(height: 56)
                }
                FactColumn(fact: fact)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

/// One fact in a `FactRow`: a small caption over a large value, with a line under it.
struct Fact {
    enum Value { case text(String), symbol(String), image(String), genre(GenreID) }

    var caption: String
    var value: Value
    var detail: String
    var screen: Screen?
    var tint: Color?
    /// Shown on hover, for a detail cut short.
    var help: String?
    /// Accessibility identifiers of the value and the detail, for the UI tests.
    var valueID: String?
    var detailID: String?
}

private struct FactColumn: View {
    @Environment(AppModel.self) private var model
    let fact: Fact

    var body: some View {
        let column = VStack(spacing: 6) {
            Text(fact.caption.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            value
                .frame(height: 30)
                .accessibilityIdentifier(fact.valueID ?? "")
            Text(fact.detail)
                .font(.callout)
                .foregroundStyle(fact.tint == .orange ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityIdentifier(fact.detailID ?? "")
        }
        .padding(.horizontal, 8)
        .help(fact.help ?? "")
        if let screen = fact.screen {
            Button { model.open(screen) } label: { column.contentShape(.rect) }
                .buttonStyle(.plain)
                .help("Show \(fact.detail) in the Catalog")
        } else {
            column
        }
    }

    @ViewBuilder private var value: some View {
        switch fact.value {
        case .text(let text):
            Text(text)
                .font(.system(size: 22, weight: .bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(fact.tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(fact.tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
        case .image(let name):
            Image(name)
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
        case .genre(let genre):
            GenreBadge(genre: genre, size: 28)
        }
    }
}
