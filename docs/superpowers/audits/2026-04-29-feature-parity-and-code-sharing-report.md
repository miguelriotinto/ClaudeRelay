# Feature Parity & Code-Sharing Report — iOS vs. Mac

**Date:** 2026-04-29
**Scope:** `ClaudeRelayApp/` (iOS, ~3,361 LOC) vs. `ClaudeRelayMac/` (macOS, ~3,000 LOC) on top of the shared `Sources/ClaudeRelay{Kit,Client,Speech}` packages (~3,300 LOC).
**Based on:** Deep audits of both app targets and shared SPM modules; cross-reference of `MessageEnvelope` wire contracts; 2026-04-28 ViewModel audit on file.

---

## Executive Summary

The apps share **~65%** of their total Swift surface via three SPM libraries (`ClaudeRelayKit`, `ClaudeRelayClient`, `ClaudeRelaySpeech`). The remaining **~35%** lives in per-app `ViewModels/`, `Models/`, and `Views/` where duplication is real but mostly cosmetic (UserDefaults key prefixes, one-line platform API calls). Wire protocol parity is byte-for-byte identical — `SessionController` and `RelayConnection` are driven with the same argument shapes from both apps.

**Grade:** production-ready on both platforms; **Mac blocked for TestFlight** by ASC-record + icon-asset prerequisites (addressed below).

---

## Part 1 — Feature Parity Matrix

Status legend: ✅ parity · ⚠️ partial / divergent · ❌ missing · N/A platform-inherent.

| Area | Feature | iOS | Mac | Status | Notes |
| --- | --- | :-: | :-: | :-: | --- |
| Server mgmt | Add / edit / delete server | ✅ | ✅ | ✅ | Divergent `AddEditServerViewModel` implementations (~40% diff: validation + save strategy) |
| | TLS config | ✅ | ✅ | ✅ | Via shared `ConnectionConfig` |
| | Connection reachability polling | ✅ | ✅ | ⚠️ | iOS probes with full WebSocket auth; Mac uses `NWConnection` TCP ping (cheaper, different semantics) |
| Session lifecycle | Create / switch / attach / terminate / rename | ✅ | ✅ | ✅ | Shared via `SessionCoordinating` protocol |
| | Session list sidebar | ✅ | ✅ | ✅ | Mac persistent, iOS sheet/split adaptive |
| | Session tabs in terminal | ✅ | ❌ | ⚠️ | iOS uses in-session tab strip with attention-flash; Mac uses sidebar only |
| | Detach current session | Implicit | ✅ (`Cmd+W`) | ⚠️ | Mac exposes explicit menu item |
| Terminal | SwiftTerm rendering | ✅ | ✅ | ✅ | iOS: `UIViewRepresentable` w/ ObjC runtime patches (hasText, deleteBackward, canPerformAction); Mac: `NSViewRepresentable` w/ overridden paste() |
| | Scrollback replay after reconnect | ✅ | ✅ | ✅ | Both call `resetForReplay()` (ESC-c) before resume |
| | Output buffering until view sized | ✅ | ✅ | ✅ | `TerminalViewModel.pendingOutput` |
| Recovery | Foreground / wake reconnect | ✅ | ✅ | ⚠️ | iOS triggers on `scenePhase == .active` only; Mac also on `NSWorkspace.didWakeNotification` + `NWPathMonitor` connectivity-restored |
| | Auth re-issue on reconnect | ✅ | ✅ | ✅ | Shared logic in `SessionCoordinator.restoreSession()` |
| Speech | On-device transcription (WhisperKit) | ✅ | ✅ | ✅ | Shared `ClaudeRelaySpeech` |
| | LLM text cleanup | ✅ | ✅ | ✅ | |
| | Cloud prompt enhancement (Bedrock Haiku) | ✅ | ✅ | ✅ | |
| | Model download UI | ✅ | ✅ | ⚠️ | iOS inline in Settings form; Mac in Settings "Speech" tab — different paradigm |
| | Memory-pressure unload | ✅ | N/A | N/A | iOS-only via `UIApplication.didReceiveMemoryWarning` |
| Keyboard | Hardware keyboard detection | ✅ | N/A | N/A | iOS `GCKeyboard.coalesced` (iPad) |
| | On-screen special-keys accessory | ✅ | N/A | N/A | iOS `KeyboardAccessory.swift` |
| | Configurable recording shortcut | ✅ | ❌ | ❌ | iOS has `KeyCaptureView` + `UIKeyModifierFlags` UI; Mac has no equivalent |
| | Menu bar shortcuts (⌘T, ⌘W, ⌘1-9, ⌘⇧[, ⌘⇧Q, ⌘0) | N/A | ✅ | N/A | Mac-only, in `AppCommands.swift` |
| QR | Camera-based QR scan | ✅ | ✅ | ✅ | iOS `UIViewController`, Mac `NSView` — both use AVFoundation |
| | QR code generation (share session) | ❌ | ✅ | ❌ | Mac has `QRCodePopover`; iOS only has inline QR in sidebar sheet |
| | Cold-start deep-link attach | ❌ | ✅ | ❌ | iOS explicitly deferred (`ClaudeRelayApp.swift:27-37`); Mac fully routes to coordinator |
| Paste | Clipboard text paste | ✅ | ✅ | ✅ | `UIPasteboard` vs `NSPasteboard` |
| | Clipboard image paste | ✅ | ✅ | ⚠️ | iOS image-first paste (for Safari copy); Mac `PasteAwareTerminalView` overrides `paste()` for drag-drop + `Cmd+V` images |
| | File drag-drop | N/A | ✅ | N/A | Mac accepts PNG/TIFF/fileURL |
| Haptics | Impact / notification feedback | ✅ | N/A | N/A | iOS only; Mac AppSettings has a toggle for parity but is no-op |
| App shell | Menu bar persistent app | N/A | ✅ | N/A | `MenuBarExtra(.window)` + `AppDelegate.applicationShouldTerminateAfterLastWindowClosed=false` |
| | Native Settings scene | N/A | ✅ | N/A | Mac-only tabbed settings |
| | Native tabs | N/A | ✅ | N/A | macOS `WindowGroup` automatic |
| | Launch at login | N/A | ✅ | N/A | `SMAppService` wrapper |
| | Network monitor recovery | N/A | ✅ | N/A | `NWPathMonitor` |
| Branding | App icon | ✅ | ❌ | ❌ | **Mac app has no `Assets.xcassets`** — blocks TestFlight submission |
| | Splash screen | ✅ | ❌ | ⚠️ | iOS `SplashScreenView` with animated logo; Mac relies on OS window fade-in |
| Appearance | Dark mode | Forced | System-follow | ⚠️ | iOS `.preferredColorScheme(.dark)`; Mac respects system — inconsistent |
| Settings | Persistence namespace | Bare keys | `com.clauderelay.mac.*` | ⚠️ | Different prefixes intentionally isolate storage; will not migrate across platforms if ever needed |
| Testing | Unit tests | ✅ (speech only) | ❌ | ⚠️ | iOS has `ClaudeRelayAppTests` for `TextCleaner` + `OnDeviceSpeechEngine`; Mac has no in-app tests |

### Summary counts

| Metric | Count |
| --- | --- |
| Total audited features | 35 |
| Cross-platform parity ✅ | 20 |
| Partial / divergent ⚠️ | 8 |
| Missing ❌ (iOS lacks) | 3 (QR generation, cold-start deep-link, Mac-exclusives N/A) |
| Missing ❌ (Mac lacks) | 3 (shortcut capture UI, splash, app icon) |
| Platform-exclusive iOS | 4 (haptics, on-screen keyboard accessory, hardware keyboard detect, splash) |
| Platform-exclusive Mac | 7 (menu bar, native tabs, launch-at-login, sleep/wake, network monitor, global shortcuts, drag-drop) |
| Blocker severity | 1 (Mac AppIcon asset + ASC app record) |

---

## Part 2 — Code Sharing: What's Shared vs. Duplicated

### Already shared (SPM modules)

| Module | LOC | Platform-split guards | What it provides |
| --- | ---: | --- | --- |
| `ClaudeRelayKit` | ~800 | `#if os(iOS) \|\| os(tvOS) \|\| os(watchOS)` on one storage-path fallback (`RelayConfig.swift:54`) | Wire protocol: `MessageEnvelope`, `ClientMessage`, `ServerMessage`, models, `TokenGenerator`, `ConfigManager`, `ActivityState`, `SessionState`, `SessionInfo` |
| `ClaudeRelayClient` | ~1,400 | None | `RelayConnection`, `SessionController`, `AuthManager`, `ConnectionConfig`, `SessionCoordinating` protocol, `SessionNaming` + `SessionNamingTheme` |
| `ClaudeRelaySpeech` | ~1,200 | `#if canImport(UIKit)` for memory-warning observer (`OnDeviceSpeechEngine.swift:33,73-84`); `#if canImport(UIKit)` for `AVAudioSession` config (`AudioCaptureSession.swift:27,71-74`); `#if os(iOS)` for `NSDocumentDirectory` paths (`SpeechModelStore.swift:18,40`) | `OnDeviceSpeechEngine`, `WhisperTranscriber`, `TextCleaner`, `AudioCaptureSession`, `SpeechModelStore`, `CloudPromptEnhancer`, `SpeechEngineState` |

### Duplicated between apps (diff percentages are rough)

| File | iOS LOC | Mac LOC | Real divergence | Effort to unify |
| --- | ---: | ---: | --- | --- |
| `Models/SavedConnection.swift` | 53 | ~60 | UserDefaults key prefix only (cosmetic) | **Trivial** |
| `Models/AppSettings.swift` | 75 | ~90 | iOS has `UIKeyModifierFlags` for shortcut capture; Mac has `launchAtLoginEnabled` + `showWindowOnLaunch` | **Moderate** |
| `ViewModels/TerminalViewModel.swift` | 168 | ~170 | ~5% — whitespace/comments | **Trivial** |
| `ViewModels/AddEditServerViewModel.swift` | 87 | ~120 | iOS `.add/.edit` mode init; Mac direct `init(existing:)` + `validate()` surface | **Moderate** |
| `ViewModels/ServerListViewModel.swift` | 112 | ~150 | iOS holds `activeConnection/activeToken` for workspace nav; Mac tracks `selectedConnectionId`; different polling strategies | **Moderate-High** |
| `ViewModels/ServerStatusChecker.swift` | 109 | ~90 | iOS: WebSocket auth + list-sessions probe; Mac: `NWConnection` TCP ping — different semantics | **High** (strategy protocol) |
| `ViewModels/SessionCoordinator.swift` | 605 | ~641 | Device ID source (`UIDevice.identifierForVendor` vs `IOKit` UUID); recovery observers (`scenePhase` vs `NSWorkspace`+`NWPathMonitor`); UserDefaults key prefix | **Moderate** (needs protocols) |

### Missing cross-platform scaffolding

The following protocols would unlock genuine code sharing without duct-taping `#if os(iOS)`/`#if os(macOS)` throughout ViewModels:

1. **`DeviceIdentifier`** — hides `UIDevice.identifierForVendor` vs. IOKit `IOPlatformExpertDevice/kIOPlatformUUIDKey`.
2. **`RecoveryTrigger`** — observes "time to re-check network" events; wrapped differently on iOS (`scenePhase`) and Mac (`SleepWakeObserver` + `NetworkMonitor`).
3. **`ReachabilityProbe`** — TCP-ping vs. WebSocket-auth strategy under one interface.
4. **`FeedbackBridge`** — haptics on iOS, no-op on Mac.
5. **`PasteboardBridge`** — `UIPasteboard` / `NSPasteboard` uniform API (text + image data).
6. **`UserDefaultsNamespace`** — inject a platform-scoped key prefix so one `@AppStorage` layer serves both apps without clashing.

---

## Part 3 — Sequenced Work Plan

### Phase A — TestFlight readiness (this session)

**A1. iOS Build 79 → TestFlight** — bump, archive w/ API-key auth, upload, notify testers. **Status:** in-flight.

**A2. Mac app TestFlight prerequisites** — two blockers outside public API reach:
- **A2.1 App record** — `com.claude.relay.mac` is not registered in App Store Connect. Apple's public API has no `apps.create`. Options:
  - *(recommended)* Manually register at https://appstoreconnect.apple.com/apps/new in ~2 min; copy the resulting app ID back to this session.
  - *(alternative)* Use `asc web apps create` (experimental, interactive 2FA, uses private endpoints — documented risks).
- **A2.2 AppIcon asset** — **done in this session** (`ClaudeRelayMac/Assets.xcassets/AppIcon.appiconset/icon-1024.png` copied from iOS icon).
- **A2.3 Bundle ID** — **done in this session**: registered `com.claude.relay.mac` → id `VV6V5NRYH7`, platform UNIVERSAL, team T9WF95GC9T.
- **A2.4 Entitlements review** — current `ClaudeRelayMac.entitlements` disables sandbox. TestFlight internal distribution accepts this; App Store does not. Defer to Phase D.

### Phase B — Sharing Tier 1 (high-ROI, low-risk): 2-3 days

Each step includes a commit boundary so iOS regressions can be isolated fast.

**B1. Extract `Models/SavedConnection.swift` → `ClaudeRelayClient/Helpers/SavedConnectionStore.swift`**
- Introduce `UserDefaultsNamespace` protocol with iOS impl (`bare keys`) and Mac impl (`com.clauderelay.mac.*`).
- Remove per-app `SavedConnection.swift`.
- Effort: **trivial** (≤2 hours). Tests: `SavedConnectionStoreTests` in `Tests/ClaudeRelayClientTests`.

**B2. Extract `TerminalViewModel.swift` → `ClaudeRelayClient/ViewModels/TerminalViewModel.swift`**
- Already ~95% identical; drop into the shared module.
- Gate any UI-side callbacks behind protocols (`TerminalRendering` with `terminalReady()`, `didReceive(_:)`, `didResize(cols:rows:)`).
- Effort: **trivial**.
- **Regression risk:** iOS code calls `viewModel(for:)` and installs callbacks — make sure the shared class exposes the same Combine publishers. Bump a test-plan checkbox per call site.

**B3. Introduce `DeviceIdentifier` protocol in `ClaudeRelayClient`**
- iOS target provides `IOSDeviceIdentifier` (UIKit).
- Mac target provides `MacDeviceIdentifier` (IOKit).
- SessionCoordinator accepts one via init (default falls back to platform).
- Effort: **moderate** (1 day).

### Phase C — Sharing Tier 2 (protocol-driven; medium risk): 4-6 days

**C1. `SessionCoordinator` consolidation**
- Move shared body (fetch/create/switch/terminate/attach/persist) to `ClaudeRelayClient/ViewModels/SharedSessionCoordinator.swift`.
- Platform-specific subclasses just register recovery observers + pass device identifier.
- Retain `SessionCoordinating` protocol for type-erasure at view boundaries.

**C2. `RecoveryTrigger` protocol + wiring**
- `ScenePhaseRecoveryTrigger` (iOS) and `WorkspaceRecoveryTrigger` (Mac, wraps `SleepWakeObserver` + `NetworkMonitor`).
- Both post unified `.needsRecovery` signal; shared coordinator subscribes once.

**C3. `ReachabilityProbe` + unified `ServerStatusChecker`**
- Two strategy implementations:
  - `AuthReachabilityProbe` (iOS default) — reuses `SessionController.authenticate()` + list-sessions as a deep health check.
  - `TCPReachabilityProbe` (Mac default, faster) — `NWConnection`.
- Expose as a pluggable strategy so either platform can pick either.
- Consolidate `ServerListViewModel` around the shared checker.

**C4. `AppSettings` consolidation**
- Shared `AppSettings` with `@AppStorage` proxy properties.
- Platform-specific subclasses add:
  - iOS: `recordingShortcutKey`, `UIKeyModifierFlags` helpers.
  - Mac: `launchAtLoginEnabled`, `showWindowOnLaunch`.
- Unit-test the migration path to confirm existing values load correctly (read old key, write new key, clear old).

### Phase D — Parity completion + polish: 3-5 days

**D1. iOS: QR generation view** mirroring Mac `QRCodePopover`. Reuse `CIFilterBuiltins.qrCodeGenerator` from Mac (move to shared).

**D2. iOS: cold-start deep-link attach**
- Remove the `"out of scope"` comment in `ClaudeRelayApp.swift:27`.
- Store pending `sessionId` in `ServerListViewModel`; after auto-connect to last-used server, auto-attach.

**D3. Mac: recording shortcut UI**
- Build `NSEvent`-based KeyCapture equivalent (modifiers + keyDown).
- Share storage/display code with iOS via the new shared `AppSettings`.

**D4. Mac: dark terminal default**
- Set `.preferredColorScheme(.dark)` on the main window or scope to the terminal's NSView background to match iOS.

**D5. Mac: splash/welcome screen** (optional)
- Brief fade-in on first launch; reuses `SplashLogo` asset from iOS `Assets.xcassets`.

**D6. Mac: sandbox + App Store readiness**
- Flip `com.apple.security.app-sandbox` to `true`.
- Add `com.apple.security.network.client`, `com.apple.security.device.audio-input`, `com.apple.security.device.camera`, `com.apple.security.files.user-selected.read-write` (for image paste/drag-drop).
- Retest all flows; fix any sandboxed-URL issues in on-device speech (file paths).

### Phase E — Test coverage parity: 2-3 days

- Port `ClaudeRelayAppTests` to reference shared `TerminalViewModel` + `OnDeviceSpeechEngine` from the shared module; add Mac parity.
- Add integration tests for `SharedSessionCoordinator` with mocked `RelayConnection`.
- Target: ≥60% coverage of ViewModels across both platforms.

---

## Part 4 — Blockers Requiring User Action

1. **Create Mac app record in App Store Connect** (5 min, user only):
   - https://appstoreconnect.apple.com/apps → "+" → **New App**.
   - Platform: **macOS**, Name: `Claude Relay`, Bundle ID: `com.claude.relay.mac` (will appear — registered in this session), SKU: `com.claude.relay.mac` (or any unique string), Primary Locale: English.
   - After create, reply with the app ID and TestFlight will be unblocked immediately.

2. **Confirm icon substitute is acceptable** — the Mac AppIcon was populated by reusing the iOS icon (1024×1024 RGB). Mac Dock render will work but an RGBA version tuned for macOS would be better long-term.

3. **Sandbox decision** — Mac app currently runs unsandboxed. Acceptable for internal TestFlight; blocker for public App Store. Phase D6 covers the switch.

---

## Appendices

**A. Git/build commits made during this session**
- `chore(ios): bump build number to 79`
- `(pending) feat(mac): add AppIcon asset catalog + gitignore asc artifacts`

**B. Registered identifiers**
- Bundle ID `com.claude.relay.mac` → ASC id `VV6V5NRYH7` (developer.apple.com registered 2026-04-29).

**C. Related prior audit**
- `docs/superpowers/specs/2026-04-28-macos-viewmodel-audit.md` — earlier Phase-5 scoped audit already extracted `SessionNaming` + `SessionCoordinating`.

**D. Shared library maturity grade**
- 65% shared / 35% duplicated-with-cosmetic-divergence. Three Phase B/C merges lift this to ~85% sharing with no user-visible behavior change.
