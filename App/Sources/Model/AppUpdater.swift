import Foundation
import Observation
import Sparkle

/// Frontport's own updates through Sparkle: checked in the background along with the Ports' update checks (at launch
/// and every 6 hours), and when the user asks. Sparkle's own scheduler stays off (`SUEnableAutomaticChecks`).
/// Without an EdDSA public key in Info.plist (`SUPublicEDKey`), as in development builds, Sparkle isn't started and
/// the menu item stays disabled, so it never shows an error about a feed it can't verify.
@Observable @MainActor
final class AppUpdater {
    private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init(bundle: Bundle = .main) {
        let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        guard let key, !key.isEmpty else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.updateCanCheck() }
        }
    }

    private func updateCanCheck() {
        canCheckForUpdates = controller?.updater.canCheckForUpdates ?? false
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Shows Sparkle's UI only when an update is found.
    func checkInBackground() {
        controller?.updater.checkForUpdatesInBackground()
    }
}
