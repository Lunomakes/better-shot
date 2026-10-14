import AppKit
import CoreGraphics

/// Offers a restart when macOS has not applied an earlier Screen Recording grant to this launch.
@MainActor
enum ScreenCapturePermission {
    private static let grantedKey = "bs_screenCaptureGranted"
    private static var hasOfferedRestart = false

    /// Returns false when BetterShot must restart before it can capture.
    static func isReadyToCapture() -> Bool {
        let defaults = UserDefaults.standard
        if CGPreflightScreenCaptureAccess() {
            defaults.set(true, forKey: grantedKey)
            return true
        }
        guard defaults.bool(forKey: grantedKey), !hasOfferedRestart else { return true }
        hasOfferedRestart = true
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString("Restart BetterShot to capture", comment: "")
        alert.informativeText = NSLocalizedString("macOS hasn’t applied BetterShot’s Screen Recording permission yet. This can happen when BetterShot opens at login. Restart BetterShot, then try again. If it still can’t capture, check Privacy & Security › Screen & System Audio Recording.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Restart", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        if alert.runModal() == .alertFirstButtonReturn {
            defaults.set(false, forKey: grantedKey)
            BetterShotDelegate.relaunch()
        }
        return false
    }
}
