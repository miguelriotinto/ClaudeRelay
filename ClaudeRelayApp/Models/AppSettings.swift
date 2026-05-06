import SwiftUI
import UIKit
import ClaudeRelayClient

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private init() {
        migrateShortcutIfNeeded()
        migrateBedrockTokenIfNeeded()
    }

    private func migrateShortcutIfNeeded() {
        let defaults = UserDefaults.standard
        // Only migrate if old format exists and new format hasn't been set
        guard defaults.string(forKey: "recordingShortcutModifier") != nil,
              defaults.object(forKey: "recordingShortcutFlags") == nil else { return }

        let oldRaw = defaults.string(forKey: "recordingShortcutModifier") ?? "commandShift"
        let flags: UIKeyModifierFlags
        switch oldRaw {
        case "commandShift": flags = [.command, .shift]
        case "commandOption": flags = [.command, .alternate]
        case "commandControl": flags = [.command, .control]
        default: flags = [.command, .shift]
        }

        recordingShortcutFlags = Int(flags.rawValue)
        defaults.removeObject(forKey: "recordingShortcutModifier")
    }

    /// One-time migration from `@AppStorage("bedrockBearerToken")` to the
    /// Keychain. If a legacy UserDefaults value exists and the Keychain is
    /// empty, copy into Keychain and scrub the plist. Idempotent — runs on
    /// every launch but is a no-op after the first successful copy.
    private func migrateBedrockTokenIfNeeded() {
        let defaults = UserDefaults.standard
        guard let legacy = defaults.string(forKey: "bedrockBearerToken"),
              !legacy.isEmpty else {
            return
        }
        if let existing = try? AuthManager.shared.loadBedrockToken(), !existing.isEmpty {
            // Keychain already populated — just clear the plaintext copy.
            defaults.removeObject(forKey: "bedrockBearerToken")
            return
        }
        do {
            try AuthManager.shared.saveBedrockToken(legacy)
            defaults.removeObject(forKey: "bedrockBearerToken")
        } catch {
            // Keep the UserDefaults copy intact so the user's token isn't lost;
            // surface through `bedrockBearerToken`'s getter below.
        }
    }

    @AppStorage("smartCleanupEnabled") var smartCleanupEnabled = true
    @AppStorage("promptEnhancementEnabled") var promptEnhancementEnabled = false
    @AppStorage("bedrockRegion") var bedrockRegion = "us-east-1"

    /// Bump this after any Bedrock token save so SwiftUI views bound to the
    /// computed `bedrockBearerToken` refresh. `@AppStorage` handles this
    /// automatically for UserDefaults-backed keys; Keychain does not, so we
    /// manually publish.
    @Published private var bedrockTokenVersion = UUID()

    /// Bedrock bearer token, persisted in the Keychain (was UserDefaults).
    /// Returns `""` when absent or on Keychain read failure — callers treat
    /// empty as "not configured" and surface the missing-token error from the
    /// enhancer itself.
    var bedrockBearerToken: String {
        get {
            _ = bedrockTokenVersion  // publish dependency
            return (try? AuthManager.shared.loadBedrockToken()) ?? ""
        }
        set {
            try? AuthManager.shared.saveBedrockToken(newValue)
            bedrockTokenVersion = UUID()
        }
    }
    @AppStorage("hapticFeedbackEnabled") var hapticFeedbackEnabled = true
    @AppStorage("autoConnectEnabled") var autoConnectEnabled = false
    @AppStorage("lastConnectedServerId") var lastConnectedServerId: String = ""
    @AppStorage("sessionNamingTheme") var sessionNamingTheme: SessionNamingTheme = .gameOfThrones
    @AppStorage("terminalFontSize") var terminalFontSize: Double = 12

    /// Max scrollback lines kept by SwiftTerm per session. Lower = less RAM,
    /// higher = more scrollback history in-client. Server's ring buffer
    /// replays anything that fell off this edge on next attach.
    @AppStorage("terminalScrollbackLines") var terminalScrollbackLines: Int = 5_000

    @AppStorage("recordingShortcutEnabled") var recordingShortcutEnabled = true
    @AppStorage("recordingShortcutFlags") var recordingShortcutFlags: Int = Int(UIKeyModifierFlags([.command, .alternate]).rawValue)
    @AppStorage("recordingShortcutKey") var recordingShortcutKey = ""
}

// MARK: - Keyboard Shortcut Helpers

extension UIKeyModifierFlags {
    /// Human-readable symbol string, e.g. "⌃⌥⇧⌘"
    /// Order follows Apple HIG: Control, Option, Shift, Command
    var symbolString: String {
        var parts: [String] = []
        if contains(.control) { parts.append("⌃") }
        if contains(.alternate) { parts.append("⌥") }
        if contains(.shift) { parts.append("⇧") }
        if contains(.command) { parts.append("⌘") }
        return parts.joined()
    }
}

extension AppSettings {
    var shortcutModifierFlags: UIKeyModifierFlags {
        get { UIKeyModifierFlags(rawValue: Int(recordingShortcutFlags)) }
        set { recordingShortcutFlags = Int(newValue.rawValue) }
    }

    /// Display string for the current shortcut, e.g. "⌘⌥" or "⌘⌥R"
    var shortcutDisplayString: String {
        let mods = shortcutModifierFlags.symbolString
        let key = recordingShortcutKey.uppercased()
        return mods + key
    }
}

// MARK: - Session Naming Themes
//
// `SessionNamingTheme` is defined in `ClaudeRelayClient` so iOS and Mac share
// the same type, raw values, and name pools.
