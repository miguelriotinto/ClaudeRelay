import SwiftUI
import UIKit
import Combine
import ClaudeRelayClient

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private init() {
        migrateShortcutIfNeeded()
        migrateBedrockTokenIfNeeded()
        // Seed the in-memory mirror from the Keychain (or legacy UserDefaults
        // fallback if the migration above hit a Keychain failure).
        self.bedrockBearerToken = loadBedrockTokenWithFallback()
        // Debounce Keychain writes: rapid keystrokes collapse into a single
        // save 500 ms after the last change. `dropFirst()` skips the seed
        // value we just wrote above.
        $bedrockBearerToken
            .dropFirst()
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { token in
                try? AuthManager.shared.saveBedrockToken(token)
            }
            .store(in: &bedrockTokenSubscriptions)
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

    /// Legacy `UserDefaults` key that held the Bedrock token before the
    /// Keychain migration. Also read as a fallback when Keychain ops fail.
    private static let legacyBedrockKey = "bedrockBearerToken"

    /// One-time migration from `@AppStorage("bedrockBearerToken")` to the
    /// Keychain. Re-reads after save and only scrubs the legacy plist entry
    /// when the Keychain round-trip confirms the value was stored. A failed
    /// Keychain write leaves the legacy copy intact so
    /// `loadBedrockTokenWithFallback()` can still surface it.
    private func migrateBedrockTokenIfNeeded() {
        let defaults = UserDefaults.standard
        guard let legacy = defaults.string(forKey: Self.legacyBedrockKey),
              !legacy.isEmpty else {
            return
        }
        if let existing = try? AuthManager.shared.loadBedrockToken(), !existing.isEmpty {
            // Keychain already populated — just clear the plaintext copy.
            defaults.removeObject(forKey: Self.legacyBedrockKey)
            return
        }
        do {
            try AuthManager.shared.saveBedrockToken(legacy)
            if let reread = try? AuthManager.shared.loadBedrockToken(), reread == legacy {
                defaults.removeObject(forKey: Self.legacyBedrockKey)
            }
        } catch {
            // Keep the legacy copy in place — the fallback reader picks it up.
        }
    }

    /// Reads the Keychain, falling back to the legacy `UserDefaults` value so
    /// a failed migration doesn't make the token vanish from the UI.
    private func loadBedrockTokenWithFallback() -> String {
        if let keychain = try? AuthManager.shared.loadBedrockToken(),
           !keychain.isEmpty {
            return keychain
        }
        return UserDefaults.standard.string(forKey: Self.legacyBedrockKey) ?? ""
    }

    @AppStorage("smartCleanupEnabled") var smartCleanupEnabled = true
    @AppStorage("promptEnhancementEnabled") var promptEnhancementEnabled = false
    @AppStorage("bedrockRegion") var bedrockRegion = "us-east-1"

    /// Bedrock bearer token, persisted in the Keychain (was UserDefaults).
    /// The stored value is seeded from the Keychain at `init`; writes are
    /// debounced 500 ms before the Keychain save fires so rapid typing in a
    /// `SecureField` collapses into one write. Returns `""` when the Keychain
    /// is empty — callers treat empty as "not configured".
    @Published var bedrockBearerToken: String = ""

    /// Combine subscription store for the debounced Keychain save. Owned by
    /// the singleton so it lives for the process lifetime.
    private var bedrockTokenSubscriptions = Set<AnyCancellable>()

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
