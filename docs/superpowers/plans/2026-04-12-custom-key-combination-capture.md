# Custom Key Combination Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the rigid modifier-picker + key-picker shortcut configuration with a live "press your shortcut" key capture experience, where the user taps "Set", presses any modifier+key combination on their hardware keyboard, sees the keys appear in real time, and the shortcut is saved on release.

**Architecture:** A `UIViewRepresentable` wrapping a `UIView` that becomes first responder and intercepts `pressesBegan`/`pressesEnded` to track pressed modifiers and character keys in real time. State flows up to SwiftUI via bindings. The storage model changes from a 3-case enum to raw `UIKeyModifierFlags` bitmask + optional character key string, enabling any modifier combination.

**Tech Stack:** SwiftUI, UIKit (`UIViewRepresentable`, `UIPress`, `UIKey`), `@AppStorage` (UserDefaults)

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `ClaudeRelayApp/Models/AppSettings.swift` | Modify | Replace `ShortcutModifier` enum with raw flags storage + display helpers |
| `ClaudeRelayApp/Views/Components/KeyCaptureView.swift` | Create | `UIViewRepresentable` for live key capture via `pressesBegan`/`pressesEnded` |
| `ClaudeRelayApp/Views/SettingsView.swift` | Modify | Replace pickers with "Set" button + live display + capture mode row |
| `ClaudeRelayApp/Views/ActiveTerminalView.swift` | Modify | Update `keyCommands` to use new raw flags format |

---

### Task 1: Replace ShortcutModifier Enum with Raw Flags Storage

**Files:**
- Modify: `ClaudeRelayApp/Models/AppSettings.swift`

The current `ShortcutModifier` enum only supports 3 hardcoded combinations. We replace it with a raw `Int` bitmask that can represent any combination of modifiers, plus a display helper that converts flags to symbols.

- [ ] **Step 1: Add new storage properties and display helper to AppSettings**

In `AppSettings.swift`, replace the two shortcut properties and the `ShortcutModifier` enum with:

```swift
// Replace these two lines:
//   @AppStorage("recordingShortcutModifier") var recordingShortcutModifier: ShortcutModifier = .commandShift
//   @AppStorage("recordingShortcutKey") var recordingShortcutKey = "r"
// With:
@AppStorage("recordingShortcutFlags") var recordingShortcutFlags: Int = Int(UIKeyModifierFlags([.command, .alternate]).rawValue)
@AppStorage("recordingShortcutKey") var recordingShortcutKey = ""
```

Default is `⌘⌥` (Command+Option), key is empty (modifiers-only shortcut).

Then replace the entire `ShortcutModifier` enum (lines 21-51) with these two helper constructs:

```swift
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
```

- [ ] **Step 2: Build to verify compilation**

Run: Open Xcode, Cmd+B (or `xcodebuild build` from CLI)
Expected: Build succeeds. SettingsView.swift and ActiveTerminalView.swift will have errors referencing the removed `ShortcutModifier` — that's expected, we fix those in Tasks 3 and 4.

- [ ] **Step 3: Commit**

```bash
git add ClaudeRelayApp/Models/AppSettings.swift
git commit -m "refactor: replace ShortcutModifier enum with raw flags storage

Stores modifier flags as Int bitmask, enabling any modifier combination.
Default shortcut changes from ⌘⇧R to ⌘⌥ (modifiers-only).
Adds UIKeyModifierFlags.symbolString for Apple HIG-ordered display."
```

---

### Task 2: Create KeyCaptureView

**Files:**
- Create: `ClaudeRelayApp/Views/Components/KeyCaptureView.swift`

This is the core new component — a `UIViewRepresentable` that intercepts hardware key presses and reports them in real time.

- [ ] **Step 1: Create KeyCaptureView.swift**

Create `ClaudeRelayApp/Views/Components/KeyCaptureView.swift` with this content:

```swift
import SwiftUI
import UIKit

/// A transparent UIView that captures hardware keyboard presses and reports
/// modifier flags + character key in real time via bindings.
/// Becomes first responder when `isCapturing` is true.
struct KeyCaptureView: UIViewRepresentable {
    @Binding var capturedFlags: UIKeyModifierFlags
    @Binding var capturedKey: String
    @Binding var isCapturing: Bool
    var onCommit: (UIKeyModifierFlags, String) -> Void

    func makeUIView(context: Context) -> KeyCaptureUIView {
        let view = KeyCaptureUIView()
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: KeyCaptureUIView, context: Context) {
        if isCapturing && !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !isCapturing && uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, KeyCaptureDelegate {
        let parent: KeyCaptureView
        private var lastFlags: UIKeyModifierFlags = []
        private var lastKey: String = ""

        init(_ parent: KeyCaptureView) {
            self.parent = parent
        }

        func keysChanged(flags: UIKeyModifierFlags, key: String) {
            lastFlags = flags
            lastKey = key
            parent.capturedFlags = flags
            parent.capturedKey = key
        }

        func allKeysReleased() {
            // Only commit if at least one modifier was held
            guard !lastFlags.isEmpty else {
                parent.isCapturing = false
                return
            }
            parent.onCommit(lastFlags, lastKey)
            parent.isCapturing = false
        }
    }
}

// MARK: - Delegate Protocol

protocol KeyCaptureDelegate: AnyObject {
    func keysChanged(flags: UIKeyModifierFlags, key: String)
    func allKeysReleased()
}

// MARK: - UIView Subclass

final class KeyCaptureUIView: UIView {
    weak var delegate: KeyCaptureDelegate?

    private var heldModifiers: UIKeyModifierFlags = []
    private var heldKey: String = ""

    override var canBecomeFirstResponder: Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let uiKey = press.key else { continue }
            let mod = uiKey.modifierFlags.intersection([.command, .alternate, .shift, .control])
            if !mod.isEmpty {
                heldModifiers.formUnion(mod)
                handled = true
            }
            let chars = uiKey.charactersIgnoringModifiers
            if let ch = chars, !ch.isEmpty, !isModifierOnlyKey(uiKey) {
                heldKey = ch.lowercased()
                handled = true
            }
        }
        if handled {
            delegate?.keysChanged(flags: heldModifiers, key: heldKey)
        } else {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var anyEnded = false
        for press in presses {
            guard let uiKey = press.key else { continue }
            let mod = uiKey.modifierFlags.intersection([.command, .alternate, .shift, .control])
            if !mod.isEmpty {
                // When a modifier key is released, its flag is already absent from the key's
                // modifierFlags — so we detect release by checking the overall event modifiers.
                anyEnded = true
            }
            if !isModifierOnlyKey(uiKey) {
                heldKey = ""
                anyEnded = true
            }
        }
        if anyEnded {
            // Check remaining modifiers from the event
            let remaining = event?.modifierFlags.intersection([.command, .alternate, .shift, .control]) ?? []
            heldModifiers = remaining
            if remaining.isEmpty && heldKey.isEmpty {
                delegate?.allKeysReleased()
                heldModifiers = []
                heldKey = ""
            } else {
                delegate?.keysChanged(flags: heldModifiers, key: heldKey)
            }
        } else {
            super.pressesEnded(presses, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        heldModifiers = []
        heldKey = ""
        delegate?.allKeysReleased()
    }

    /// Returns true if the press is a modifier-only key (no character output).
    private func isModifierOnlyKey(_ key: UIKey) -> Bool {
        switch key.keyCode {
        case .keyboardLeftShift, .keyboardRightShift,
             .keyboardLeftControl, .keyboardRightControl,
             .keyboardLeftAlt, .keyboardRightAlt,
             .keyboardLeftGUI, .keyboardRightGUI:
            return true
        default:
            return false
        }
    }
}
```

- [ ] **Step 2: Add the file to the Xcode project**

The project uses XcodeGen (`project.yml`) with a glob source pattern. Verify the new file is under `ClaudeRelayApp/Views/Components/` — if the glob is `ClaudeRelayApp/**`, it will be picked up automatically. If not, regenerate: `xcodegen generate`.

- [ ] **Step 3: Build to verify compilation**

Run: Cmd+B in Xcode
Expected: Build succeeds. `KeyCaptureView` compiles standalone.

- [ ] **Step 4: Commit**

```bash
git add ClaudeRelayApp/Views/Components/KeyCaptureView.swift
git commit -m "feat: add KeyCaptureView for live hardware keyboard shortcut capture

UIViewRepresentable that intercepts pressesBegan/pressesEnded to track
modifier flags and character keys in real time. Commits on full release.
Requires at least one modifier key to accept the combination."
```

---

### Task 3: Update SettingsView with Set Button and Capture Mode

**Files:**
- Modify: `ClaudeRelayApp/Views/SettingsView.swift`

Replace the two Pickers (Modifier + Key) with a display row showing the current shortcut and a "Set" button that enters capture mode with live key feedback.

- [ ] **Step 1: Add capture state properties**

At the top of `SettingsView`, add these `@State` properties alongside the existing ones:

```swift
@State private var isCapturing = false
@State private var capturedFlags: UIKeyModifierFlags = []
@State private var capturedKey: String = ""
```

- [ ] **Step 2: Replace the Keyboard Shortcuts section**

Replace the entire `Section` block for Keyboard Shortcuts (currently lines 45-65 in SettingsView.swift) with:

```swift
Section {
    Toggle("Recording Shortcut", isOn: $settings.recordingShortcutEnabled)
    if settings.recordingShortcutEnabled {
        if isCapturing {
            VStack(spacing: 8) {
                Text("Press your shortcut...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(capturedFlags.isEmpty && capturedKey.isEmpty
                     ? "Waiting..."
                     : capturedFlags.symbolString + capturedKey.uppercased())
                    .font(.system(.title, design: .rounded, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
                KeyCaptureView(
                    capturedFlags: $capturedFlags,
                    capturedKey: $capturedKey,
                    isCapturing: $isCapturing,
                    onCommit: { flags, key in
                        settings.shortcutModifierFlags = flags
                        settings.recordingShortcutKey = key
                    }
                )
                .frame(width: 0, height: 0)
                Button("Cancel") {
                    isCapturing = false
                }
                .font(.subheadline)
            }
            .padding(.vertical, 4)
        } else {
            HStack {
                Text("Key Combination")
                Spacer()
                Text(settings.shortcutDisplayString)
                    .foregroundStyle(.secondary)
                    .font(.system(.body, design: .rounded))
                Button("Set") {
                    capturedFlags = []
                    capturedKey = ""
                    isCapturing = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
} header: {
    Text("Keyboard Shortcuts")
} footer: {
    if settings.recordingShortcutEnabled && !isCapturing {
        Text("Press \(settings.shortcutDisplayString) to toggle speech recording when a hardware keyboard is connected.")
    }
}
```

- [ ] **Step 3: Add UIKit import**

At the top of `SettingsView.swift`, add `import UIKit` if not already present (needed for `UIKeyModifierFlags`).

- [ ] **Step 4: Build to verify compilation**

Run: Cmd+B in Xcode
Expected: Build succeeds.

- [ ] **Step 5: Commit**

```bash
git add ClaudeRelayApp/Views/SettingsView.swift
git commit -m "feat: replace shortcut pickers with live key capture UI

Settings now shows current shortcut with a 'Set' button. Tapping Set
enters capture mode where pressed keys appear in real time. Combination
is saved on release. Cancel button to abort without changes."
```

---

### Task 4: Update ActiveTerminalView to Use Raw Flags

**Files:**
- Modify: `ClaudeRelayApp/Views/ActiveTerminalView.swift:506-514`

The `keyCommands` property currently reads `ShortcutModifier` from UserDefaults and calls `.flags`. Update it to read the raw Int directly.

- [ ] **Step 1: Replace the shortcut key-command construction**

In `RelayTerminalView`'s `keyCommands` property, replace the block inside `if enabled {` (lines 507-514):

```swift
// Old:
//     let key = UserDefaults.standard.string(forKey: "recordingShortcutKey") ?? "r"
//     let modRaw = UserDefaults.standard.string(forKey: "recordingShortcutModifier") ?? ShortcutModifier.commandShift.rawValue
//     let modifier = ShortcutModifier(rawValue: modRaw) ?? .commandShift
//     let cmd = UIKeyCommand(input: key, modifierFlags: modifier.flags,
//                            action: #selector(handleRecordingShortcut))
//     cmd.discoverabilityTitle = "Toggle Recording"
//     commands.append(cmd)

// New:
let key = UserDefaults.standard.string(forKey: "recordingShortcutKey") ?? ""
let flagsRaw = UserDefaults.standard.integer(forKey: "recordingShortcutFlags")
let flags: UIKeyModifierFlags = flagsRaw != 0
    ? UIKeyModifierFlags(rawValue: flagsRaw)
    : [.command, .alternate]
let cmd = UIKeyCommand(input: key, modifierFlags: flags,
                       action: #selector(handleRecordingShortcut))
cmd.discoverabilityTitle = "Toggle Recording"
commands.append(cmd)
```

Key differences:
- Reads `recordingShortcutFlags` (Int) instead of `recordingShortcutModifier` (String)
- Default key is `""` (empty) instead of `"r"`
- Default flags are `[.command, .alternate]` instead of going through the enum
- No dependency on `ShortcutModifier` enum at all

- [ ] **Step 2: Build the full project**

Run: Cmd+B in Xcode
Expected: Build succeeds with zero errors. No remaining references to `ShortcutModifier`.

- [ ] **Step 3: Verify no stale references**

Search the project for any remaining `ShortcutModifier` references:
```bash
grep -r "ShortcutModifier" ClaudeRelayApp/
```
Expected: No results.

- [ ] **Step 4: Commit**

```bash
git add ClaudeRelayApp/Views/ActiveTerminalView.swift
git commit -m "refactor: update keyCommands to use raw modifier flags

Reads recordingShortcutFlags (Int bitmask) directly from UserDefaults
instead of going through the removed ShortcutModifier enum."
```

---

### Task 5: Handle Migration from Old Settings Format

**Files:**
- Modify: `ClaudeRelayApp/Models/AppSettings.swift`

Users upgrading from the old version will have `recordingShortcutModifier` (String) and `recordingShortcutKey` (String "r") in UserDefaults but not `recordingShortcutFlags`. We need a one-time migration.

- [ ] **Step 1: Add migration logic to AppSettings.init()**

Add a private init and migration method to `AppSettings`:

```swift
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // ... existing @AppStorage properties ...

    private init() {
        migrateShortcutIfNeeded()
    }

    private func migrateShortcutIfNeeded() {
        let defaults = UserDefaults.standard
        // If old format exists and new format hasn't been set
        guard defaults.string(forKey: "recordingShortcutModifier") != nil,
              defaults.object(forKey: "recordingShortcutFlags") == nil else { return }

        // Map old enum raw value to flags
        let oldRaw = defaults.string(forKey: "recordingShortcutModifier") ?? "commandShift"
        let flags: UIKeyModifierFlags
        switch oldRaw {
        case "commandShift": flags = [.command, .shift]
        case "commandOption": flags = [.command, .alternate]
        case "commandControl": flags = [.command, .control]
        default: flags = [.command, .shift]
        }

        recordingShortcutFlags = Int(flags.rawValue)
        // Keep the old key as-is (recordingShortcutKey storage key didn't change)
        defaults.removeObject(forKey: "recordingShortcutModifier")
    }
}
```

- [ ] **Step 2: Build and verify**

Run: Cmd+B in Xcode
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add ClaudeRelayApp/Models/AppSettings.swift
git commit -m "feat: migrate old ShortcutModifier enum to raw flags on upgrade

One-time migration reads the old recordingShortcutModifier string,
converts to UIKeyModifierFlags bitmask, and removes the old key."
```

---

### Task 6: Manual Testing and Polish

**Files:**
- No file changes — testing only

- [ ] **Step 1: Test default state (fresh install)**

1. Delete app from simulator/device
2. Install and open
3. Go to Settings > Keyboard Shortcuts
4. Verify: Recording Shortcut is ON, Key Combination shows "⌘⌥", Set button is visible
5. Verify footer text says "Press ⌘⌥ to toggle speech recording..."

- [ ] **Step 2: Test capture mode**

1. Connect a hardware keyboard (use Simulator with Mac keyboard, or iPad with Magic Keyboard)
2. Tap "Set"
3. Verify: Row changes to "Press your shortcut..." with "Waiting..." display
4. Press and hold Command — verify display shows "⌘"
5. While holding Command, press Option — verify display shows "⌘⌥"
6. While holding both, press R — verify display shows "⌘⌥R" (or "⌃⌥⇧⌘R" with all modifiers, following Apple HIG order)
7. Release all keys — verify capture mode exits and row shows the new combination

- [ ] **Step 3: Test cancel**

1. Tap "Set"
2. Press some keys
3. Tap "Cancel"
4. Verify: Original shortcut is preserved, not changed

- [ ] **Step 4: Test validation — modifier required**

1. Tap "Set"
2. Press only a letter key (e.g., "R") without any modifier
3. Release
4. Verify: Capture mode exits without saving (requires at least one modifier)

- [ ] **Step 5: Test the shortcut works in terminal**

1. Set a shortcut (e.g., ⌘⌥)
2. Go back to terminal
3. Press the shortcut
4. Verify: Speech recording toggles on/off

- [ ] **Step 6: Test migration from old format**

1. In Simulator, set UserDefaults manually:
   ```
   defaults write com.yourapp.bundleid recordingShortcutModifier -string "commandOption"
   defaults write com.yourapp.bundleid recordingShortcutKey -string "r"
   ```
2. Launch app
3. Go to Settings
4. Verify: Shows "⌥⌘R" (the migrated combination)

- [ ] **Step 7: Final commit with build number bump**

```bash
git add -A
git commit -m "feat(ios): custom key combination capture for recording shortcut (build XX)

Replace rigid modifier picker + key picker with live key capture:
- Tap 'Set' to enter capture mode
- Press any modifier+key combination on hardware keyboard
- Keys appear in real time as pressed
- Saved on release, cancel to abort
- Migrates old ShortcutModifier enum format on upgrade
- Default shortcut: ⌘⌥ (Command+Option)"
```

---

## Conflict Guard

These existing terminal shortcuts must NOT be capturable (or at minimum, warn):
- `⌘C` (copy)
- `⌘V` (paste)
- `⌘X` (cut)

The current implementation doesn't enforce this — the last-registered `UIKeyCommand` wins. If the user sets `⌘C` as their recording shortcut, it would shadow copy. Consider adding a check in `onCommit` that rejects these three combinations. This is a nice-to-have that can be added as a follow-up.
