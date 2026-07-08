import Sparkle

/// Wraps Sparkle's standard updater. Automatic background checks are driven by the
/// `SU*` keys in Info.plist (feed URL, public EdDSA key, daily interval);
/// `checkForUpdates()` backs the menu item. Sparkle presents its own update UI
/// (progress, release notes, "Install and Relaunch") and verifies each download's
/// EdDSA signature against `SUPublicEDKey` — so this works without an Apple Developer
/// ID.
final class AppUpdater {
    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
