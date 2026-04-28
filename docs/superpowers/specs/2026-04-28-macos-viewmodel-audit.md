# ViewModel Audit — iOS vs Mac SessionCoordinator

**Date:** 2026-04-28
**Purpose:** Inform Phase 5 refactoring. Identify shared logic worth extracting into `ClaudeRelayClient` versus platform-specific wiring that should stay in each app target.

## Scope

- `ClaudeRelayApp/ViewModels/SessionCoordinator.swift` (iOS, ~605 lines)
- `ClaudeRelayMac/ViewModels/SessionCoordinator.swift` (Mac, ~700 lines)
- Diff: 677 lines (hybrid — substantial overlap plus platform-specific additions)

## Method inventory

### Shared (identical semantics, present in both)

Public lifecycle & session control:
- `fetchSessions() async`
- `createNewSession() async`
- `switchToSession(id: UUID) async`
- `terminateSession(id: UUID) async`
- `fetchAttachableSessions() async -> [SessionInfo]`
- `attachRemoteSession(id:serverName:) async`
- `setName(_:for:)` / `name(for:)`
- `viewModel(for:)` / `createdAt(for:)`
- `isRunningClaude(sessionId:)`
- `tearDown()`
- `handleForegroundTransition() async`

Private handlers (identical bodies):
- `handleActivityUpdate(sessionId:activity:)`
- `handleSessionStolen(sessionId:)`
- `handleSessionRenamed(sessionId:name:)`
- `restoreSession()`

Helpers with differing access modifiers but identical semantics:
- `ensureAuthenticated()` — private on iOS, internal on Mac
- `pickDefaultName()` — identical bodies once `SessionNamingTheme` is shared
- `claimSession(_:)` / `unclaimSession(_:)` — identical
- `saveOwned()` / `saveClaudeSessions()` — identical bodies (different UserDefaults keys)
- `presentError(_:)` — identical
- `wireTerminalOutput(to:)` — identical
- `handleAutoReconnect()` — identical

### iOS-only (genuine platform divergence)

- `updateTerminalTitle(_:for:)` — iOS TerminalViewModel has title tracking that triggers UI changes not needed on Mac. (Mac still tracks titles, just not as a dedicated method on the coordinator.)

### Mac-only (genuine platform divergence)

- `start() async` — Mac's entry point after connect. iOS does this work in scene transitions via the SwiftUI `.task` modifier directly in the workspace view. Mac consolidates because menu-bar persistence needs a discrete start hook.
- `detachSession(id:)` — Mac exposes an explicit menu item (`Cmd+W`); iOS doesn't have a menu.
- `resumeActiveSession()` — Mac's foreground recovery hook; iOS uses `handleForegroundTransition` directly.
- `switchToNextSession()` / `switchToPreviousSession()` / `switchToSession(atIndex:)` — Mac keyboard shortcuts (`Cmd+Shift+[/]`, `Cmd+1..9`). iOS doesn't have analogous navigation.
- `registerRecoveryObservers()` / `unregisterRecoveryObservers()` — Mac-specific `NSWorkspace` sleep/wake + `NWPathMonitor` observers. iOS uses `scenePhase` via SwiftUI environment.

### Platform-specific wiring (same intent, different API)

- **Device ID source**: iOS uses `UIDevice.current.identifierForVendor`. Mac uses `IOPlatformExpertDevice` via `IORegistryEntryCreateCFProperty`.
- **UserDefaults keys**: Mac uses `com.clauderelay.mac.*` suffix; iOS uses `com.clauderelay.*` (no platform suffix). This is intentional — keeps Mac/iOS ownership, theme, and claude-session state separate even on the same machine.

### Mac-only Published state

- `isConnected`, `isAuthenticated`, `showQRScanner` — UI state for the Mac toolbar and menu.

## Recommended extractions for Phase 5

### Extract now (Task 5.2, 5.3)

1. **`SessionCoordinating` protocol** → `ClaudeRelayClient/Protocols/SessionCoordinating.swift`. Formalize the shared surface so both apps conform. This gives us:
   - A stable contract for shared tests
   - Documentation of the core session API
   - Base for any future shared ViewModel extraction

   Members: `sessions`, `activeSessionId`, `ownedSessionIds`, `claudeSessions`, `sessionsAwaitingInput`, `name(for:)`, `setName(_:for:)`, `isRunningClaude(sessionId:)`, `fetchSessions()`, `createNewSession()`, `switchToSession(id:)`, `detachSession(id:)`, `terminateSession(id:)`, `fetchAttachableSessions()`, `attachRemoteSession(id:serverName:)`, `handleForegroundTransition()`, `tearDown()`.

2. **`SessionNamingTheme` + `SessionNaming`** → `ClaudeRelayClient/Helpers/SessionNaming.swift`. The enum and name lists are currently duplicated verbatim between iOS (`AppSettings.swift` inline enum) and Mac (`Models/SessionNamingTheme.swift`). Extract to shared library; both apps' `AppSettings` and `pickDefaultName()` use the shared type.

### Defer (not worth extracting)

- **`handleActivityUpdate`, `handleSessionStolen`, `handleSessionRenamed`** — bodies identical but each is small enough (<20 lines) that extraction requires a base class or mixin protocol with default implementations. Not worth the complexity; code duplication is tolerable and each platform may diverge in error handling as the apps mature.
- **`createNewSession`, `switchToSession`, `attachRemoteSession`, `terminateSession`** — these interleave `SessionController` calls with platform-specific state updates (`@Published` properties). Extraction would require a generic base class with associated types for the UI-facing state — high abstraction cost for modest deduplication.
- **Device ID generation** — could share an enum `DeviceIdentifier { case ios(String); case mac(String) }` but the callers already abstract this via the UserDefaults key selection. Not worth a dedicated type.

## Wire protocol parity notes

Both apps use the same `ClaudeRelayClient` `SessionController` and `RelayConnection`. Because the wire encoding lives in `ClaudeRelayKit.MessageEnvelope` (shared), there cannot be protocol-level divergence between the two apps — only call-site differences (e.g., Mac sends `sessionRename` from keyboard-shortcut context; iOS sends it from alert context).

### Verification (Task 5.4, 2026-04-28)

Grep'd every wire-relevant API across both apps. All signatures match byte-for-byte:

| API | iOS call sites | Mac call sites | Signature |
|-----|---------------|----------------|-----------|
| `controller.authenticate(token:)` | 2 | 1 | identical |
| `controller.createSession(name:)` | 1 | 1 | identical |
| `controller.attachSession(id:)` | 1 | 1 | identical |
| `controller.resumeSession(id:)` | 3 | 2 | identical |
| `controller.detach()` | 4 | 1 | identical |
| `controller.listSessions()` | 2 | 1 | identical |
| `controller.listAllSessions()` | 1 | 1 | identical |
| `controller.renameSession(id:name:)` | 2 | 2 | identical |
| `connection.send(.sessionTerminate(sessionId:))` | 1 | 1 | identical |
| `connection.sendResize(cols:rows:)` | 2 | 2 | identical |
| `connection.sendPasteImage(base64Data:)` | 2 | 2 | identical |

**Conclusion:** No call-site divergence found. Both platforms drive the server through the exact same `ClaudeRelayClient` methods with the same argument shapes. All protocol evolution already happens in `ClaudeRelayKit` and propagates to both apps automatically.

**Differences worth noting** (behavioral, not protocol-level):
- iOS calls `controller.detach()` from more contexts (scene transitions, session switches, recovery) — 4 sites vs Mac's 1 site in `tearDown`. Mac's detach happens through a different path (explicit detachSession method + switchToSession internal detach), so the total number of detaches per session lifecycle is comparable.
- iOS `resumeSession` is called from 3 sites (switch, attach-failure rollback, recovery); Mac from 2 (attach-failure rollback, switch). Mac's recovery path uses the same `resumeSession` call inside `restoreSession()`.

No action needed.

## Implementation risk

**High-regression path**: Task 5.3 moves `SessionNamingTheme` out of iOS `AppSettings.swift`. iOS `@AppStorage("sessionNamingTheme")` references the enum, so we must:
1. Keep the raw-value `String` representation identical (`"gameOfThrones"`, `"viking"`, etc.).
2. Preserve the name list contents verbatim — the iOS list has MORE entries than the Mac list (see `gotNames` below). Use the iOS list as the canonical source.
3. Verify iOS build + tests after the move.

iOS `gotNames` count: ~70. Mac plan version: 40. We should use iOS's fuller lists as the source of truth.

## Outcome

Phase 5 will extract the two items above and leave the rest alone. The two coordinators remain 95% the same shape but are free to diverge where platforms need it (menu handling, sleep/wake observers, keyboard shortcuts).
