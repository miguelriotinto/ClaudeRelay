import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private init() {}

    /// UUID string of the last-used server, for auto-reconnect on launch.
    @AppStorage("com.clauderelay.mac.lastServerId") var lastServerId: String = ""

    /// Haptic feedback is iOS-only; flag kept for cross-platform ViewModel parity.
    /// On Mac this is a no-op.
    @AppStorage("com.clauderelay.mac.hapticFeedbackEnabled") var hapticFeedbackEnabled = false

    /// Show main window on launch (false when launched-at-login with menu-bar-only mode).
    @AppStorage("com.clauderelay.mac.showWindowOnLaunch") var showWindowOnLaunch = true
}
