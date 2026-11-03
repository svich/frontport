import SwiftUI

/// The row of a screen's sections and actions: on the left, in the center and on the right, in the page rather than
/// the toolbar. Adding and removing toolbar items as screens change made the toolbar lay itself out again, which took
/// longer than drawing the screen.
struct PageBar<Leading: View, Center: View, Trailing: View>: View {
    let leading: Leading
    let center: Center
    let trailing: Trailing
    let controlSize: ControlSize

    init(
        controlSize: ControlSize = .large, @ViewBuilder leading: () -> Leading, @ViewBuilder center: () -> Center,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.controlSize = controlSize
        self.leading = leading()
        self.center = center()
        self.trailing = trailing()
    }

    var body: some View {
        // The sides share what the center leaves, so the center stays in the middle whatever they hold.
        HStack(spacing: 10) {
            HStack(spacing: 10) { leading }
                .frame(maxWidth: .infinity, alignment: .leading)
            center
            HStack(spacing: 10) { trailing }
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .controlSize(controlSize)
    }
}

extension PageBar where Center == EmptyView {
    init(
        controlSize: ControlSize = .large, @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(controlSize: controlSize, leading: leading, center: { EmptyView() }, trailing: trailing)
    }
}

extension PageBar where Leading == EmptyView, Center == EmptyView {
    init(controlSize: ControlSize = .large, @ViewBuilder trailing: () -> Trailing) {
        self.init(controlSize: controlSize, leading: { EmptyView() }, center: { EmptyView() }, trailing: trailing)
    }
}

/// A screen's sections as a segmented control, for the left of its `PageBar`.
struct SectionPicker<Section: Hashable & CaseIterable>: View where Section.AllCases: RandomAccessCollection {
    @Binding var selection: Section
    let title: (Section) -> String
    /// Prefixes each segment's accessibility identifier, and names the control with "<prefix>s".
    let identifier: String

    var body: some View {
        Picker("Section", selection: $selection) {
            ForEach(Section.allCases, id: \.self) { section in
                Text(title(section))
                    .accessibilityIdentifier("\(identifier).\(String(describing: section))")
                    .tag(section)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityIdentifier("\(identifier)s")
    }
}
