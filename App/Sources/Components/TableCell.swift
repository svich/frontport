import SwiftUI

extension View {
    /// Gives a Table cell the app's objects itself. AppKit keeps a removed row's cells for its animation, and
    /// SwiftUI can still update them once they've lost the Table's environment, where a view reading either
    /// object with `@Environment` would trap.
    func cellEnvironment(_ model: AppModel, _ viewState: ViewState) -> some View {
        environment(model).environment(viewState)
    }
}
