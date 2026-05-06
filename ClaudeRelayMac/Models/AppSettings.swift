import SwiftUI
import ClaudeRelayClient

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private init() {
        migrateBedrockTokenIfNeeded()
    }

    /// One-time migration from `@AppStorage("com.clauderelay.mac.bedrockBearerToken")`
    /// to the Keychain. If a legacy UserDefaults value exists and the Keychain
    /// is empty, copy over and scrub the plist. Idempotent after first run.
    private func migrateBedrockTokenIfNeeded() {
        let defaults = UserDefaults.standard
        let legacyKey = "com.clauderelay.mac.bedrockBearerToken"
        guard let legacy = defaults.string(forKey: legacyKey), !legacy.isEmpty else { return }
        if let existing = try? AuthManager.shared.loadBedrockToken(), !existing.isEmpty {
            defaults.removeObject(forKey: legacyKey)
            return
        }
        do {
            try AuthManager.shared.saveBedrockToken(legacy)
            defaults.removeObject(forKey: legacyKey)
        } catch {
            // Keep legacy copy so the user's token isn't lost.
        }
    }

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
    @AppStorage("com.clauderelay.mac.bedrockRegion") var bedrockRegion = "us-east-1"

    @Published private var bedrockTokenVersion = UUID()

    /// Bedrock bearer token, persisted in the Keychain. Returns `""` when
    /// absent or on Keychain read failure; callers treat empty as "not
    /// configured" and surface the missing-token error from the enhancer.
    var bedrockBearerToken: String {
        get {
            _ = bedrockTokenVersion
            return (try? AuthManager.shared.loadBedrockToken()) ?? ""
        }
        set {
            try? AuthManager.shared.saveBedrockToken(newValue)
            bedrockTokenVersion = UUID()
        }
    }

    @AppStorage("com.clauderelay.mac.terminalFontSize") var terminalFontSize: Double = 12

    /// Max scrollback lines kept by SwiftTerm per session. Lower = less RAM,
    /// higher = more scrollback history in-client. Server's ring buffer
    /// replays anything that fell off this edge on next attach.
    @AppStorage("com.clauderelay.mac.terminalScrollbackLines") var terminalScrollbackLines: Int = 5_000

    @AppStorage("com.clauderelay.mac.recordingShortcutEnabled") var recordingShortcutEnabled = true
    @AppStorage("com.clauderelay.mac.recordingShortcutModifiers")
    var recordingShortcutModifiers: Int = Int(NSEvent.ModifierFlags([.command, .option]).rawValue)
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
