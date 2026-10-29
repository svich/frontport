import SwiftUI

// Accessibility identifiers the UI tests (App/UITests) find screens and controls by.

extension View {
    /// One container element with this identifier around the view, its children kept as they are: a screen or a
    /// section the UI tests look inside.
    func testContainer(_ identifier: String) -> some View {
        accessibilityElement(children: .contain).accessibilityIdentifier(identifier)
    }

    /// Marks text that comes from the Catalog or upstream (summaries, descriptions, reasons, release notes)
    /// rather than Frontport's own wording, so the UI tests' glossary check skips it.
    func catalogContent(_ name: String) -> some View {
        accessibilityIdentifier("content.\(name)")
    }
}
