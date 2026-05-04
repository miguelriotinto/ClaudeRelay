import SwiftUI
import ClaudeRelayClient

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

    @AppStorage("com.clauderelay.mac.sessionNamingTheme") var sessionNamingTheme: SessionNamingTheme = .gameOfThrones

    @AppStorage("com.clauderelay.mac.launchAtLogin") var launchAtLoginEnabled = false

    @AppStorage("com.clauderelay.mac.autoConnectEnabled") var autoConnectEnabled = false

    @AppStorage("com.clauderelay.mac.smartCleanupEnabled") var smartCleanupEnabled = true
    @AppStorage("com.clauderelay.mac.promptEnhancementEnabled") var promptEnhancementEnabled = false
    @AppStorage("com.clauderelay.mac.bedrockBearerToken") var bedrockBearerToken = ""
    @AppStorage("com.clauderelay.mac.bedrockRegion") var bedrockRegion = "us-east-1"

    @AppStorage("com.clauderelay.mac.terminalFontSize") var terminalFontSize: Double = 12

    /// Max scrollback lines kept by SwiftTerm per session. Lower = less RAM,
    /// higher = more scrollback history in-client. Server's ring buffer
    /// replays anything that fell off this edge on next attach.
    @AppStorage("com.clauderelay.mac.terminalScrollbackLines") var terminalScrollbackLines: Int = 5_000

    @AppStorage("com.clauderelay.mac.recordingShortcutEnabled") var recordingShortcutEnabled = true
    @AppStorage("com.clauderelay.mac.recordingShortcutModifiers") var recordingShortcutModifiers: Int = Int(NSEvent.ModifierFlags([.command, .option]).rawValue)
    @AppStorage("com.clauderelay.mac.recordingShortcutKey") var recordingShortcutKey = ""
}

extension NSEvent.ModifierFlags {
    var symbolString: String {
        var parts: [String] = []
        if contains(.control) { parts.append("⌃") }
        if contains(.option) { parts.append("⌥") }
        if contains(.shift) { parts.append("⇧") }
        if contains(.command) { parts.append("⌘") }
        return parts.joined()
    }
}

extension AppSettings {
    var shortcutModifierFlags: NSEvent.ModifierFlags {
        get { NSEvent.ModifierFlags(rawValue: UInt(recordingShortcutModifiers)) }
        set { recordingShortcutModifiers = Int(newValue.rawValue) }
    }

    var shortcutDisplayString: String {
        let mods = shortcutModifierFlags.symbolString
        let key = recordingShortcutKey.uppercased()
        return mods + key
    }
}
