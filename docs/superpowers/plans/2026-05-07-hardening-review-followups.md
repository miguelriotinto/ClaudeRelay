# Hardening Review Follow-Ups

**Date:** 2026-05-07
**Scope:** Remediation of the five "review carefully" items flagged at the close
of the v0.3.2 hardening pass PR (C-01…C-28). Each item is already on `main`;
this plan documents how to take them from "shipped with notes" to "tidy,
reviewable, and free of temporary scaffolding."

**Status of items:**

| # | Area | File(s) | Current risk | Plan delivers |
|---|------|---------|--------------|---------------|
| 1 | RelayMessageHandler concurrency | `Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift` (782 L) | `@unchecked Sendable` discipline is load-bearing; size makes audits slow | Discipline helper + split into two handlers |
| 2 | SharedSessionCoordinator shape | `Sources/ClaudeRelayClient/ViewModels/SharedSessionCoordinator.swift` (907 L) | Still over every lint ceiling; `cachedTerminalViews` shim exists only for tests | Extract `RecoveryController` + delete the shim |
| 3 | `AppSettings.bedrockBearerToken` binding | `ClaudeRelayApp/Models/AppSettings.swift`, `ClaudeRelayMac/Models/AppSettings.swift` | Every keystroke → 1 Keychain write, migration can silently drop legacy token | Debounced Keychain sink + resilient migration |
| 4 | SwiftLint `type_body_length.error: 1000` | `.swiftlint.yml` | Temporary ceiling hides future regressions | Return to `error: 500` once 1+2 land |
| 5 | `NSAllowsLocalNetworking` ATS scope | `project.yml`, both `Info.plist` | Tailscale/CGNAT users silently lose plaintext reach | Document TLS as the supported path for non-RFC1918 |

**Total effort:** ~2–3 days of focused work. Items 1 and 2 are tightly coupled —
the lint ceiling in #4 is explicitly waiting on them. Item 3 is an isolated
client-side cleanup. Item 5 is docs-only.

**Non-goals:**
- No behaviour changes to the wire protocol.
- No changes to `bindAll` defaults (already re-landed at `true` per explicit
  user preference — keep it).
- No refactor of unrelated actors (`SessionManager`, `PTYSession`) even though
  they also exceed the 500-line ceiling.
- No attempt to broaden ATS beyond what Apple's APIs support (no CIDR matching
  for CGNAT, no `NSExceptionDomains` for 100.64/10 because ATS is domain-based).

---

## Conventions

- **Call-site discipline:** When we talk about the "event loop" below, we mean
  the NIO channel's `eventLoop`. All reads/writes of handler-owned mutable
  state must happen on it; violations are silent today because the handler is
  `@unchecked Sendable`.
- **Iron law for item 1:** No post-refactor commit lands unless
  `swift test --filter ClaudeRelayServerTests` is green. We had a squash-commit
  regression in Phase 2 precisely because test-green there came from *new*
  component tests that didn't exercise the handler end-to-end. Restore the
  `WebSocketIntegrationTests` path as the canary.
- **Iron law for items 2–4:** Each task lands as its own commit with its own
  test-green evidence; no giant squash.
- **Iron law for item 5:** No plist change without a matching README update —
  the user discovers this through failed connections otherwise.

---

## Item 1 — `RelayMessageHandler` concurrency hardening

### 1.1 Issue statement

`Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift` is 782 lines,
`final class ... @unchecked Sendable`, with **twelve** mutable instance
properties that together form the connection's authoritative state:

```swift
private var isAuthenticated = false
private var authenticatedTokenId: String?
private var attachedSessionId: UUID?
private var attachedPTY: (any PTYSessionProtocol)?
private var context: ChannelHandlerContext?
private var authTimeout: Scheduled<Void>?
private var authAttempts = 0
private var remoteIP: String = "unknown"
private var activityObserverId: UUID?
private var stealObserverId: UUID?
private var renameObserverId: UUID?
private var isCleanedUp = false
private var inflightOutputBytes = 0
```

The invariant is "every read/write happens on the channel's event loop." It is
correct today — every path I traced (`handlerAdded`, `channelRead`,
`handleAuth`, `autoDetachIfNeeded`, `cleanupSession`, `sendBinaryData`)
respects this either directly (running on the event loop by NIO convention)
or by explicitly hopping back via `ctx.value.eventLoop.execute { ... }` after
a `Task { ... await ... }` suspension.

But the invariant is fragile in three specific ways:

**(a) `@unchecked Sendable` hides future slips.** A maintainer adding a new
handler who reaches for `self.attachedSessionId` inside `Task { ... }` without
hopping back onto the event loop will not see a compiler error. The next race
that burns us will look exactly like C-04 (observer ordering) or C-13
(detach-during-create) — both of which we fixed this PR. There is no cheap
way to prove we have caught all of them; we just haven't yet.

**(b) The "Task → await → eventLoop.execute writeback" boilerplate is
duplicated across ~18 handler methods.** Each one looks like:

```swift
private func handleSessionXXX(...) {
    guard let tokenId = authenticatedTokenId else { return }
    let sessionManager = self.sessionManager
    let ctx = UnsafeTransfer(context)
    Task { [weak self] in
        do {
            let x = try await sessionManager.xxxSession(...)
            ctx.value.eventLoop.execute {
                guard let self = self else { return }
                self.attachedSessionId = ...
                self.sendServerMessage(...)
            }
        } catch {
            ctx.value.eventLoop.execute {
                self?.sendServerMessage(...)
            }
        }
    }
}
```

Every one of those 18 copies is a fresh opportunity to forget the
`eventLoop.execute` wrapper and touch `self.attachedSessionId` from a Task
directly. Static review is our only defence.

**(c) 782 lines is past the SwiftLint `type_body_length` error threshold.** The
`// swiftlint:disable:next type_body_length` on line 8 currently sits next to
`type_body_length.error: 1000` in `.swiftlint.yml` — we've moved the ceiling
*around* the file, not made the file fit. Item 4 cannot revert until this is
resolved.

### 1.2 Resolution approach

Two changes, deliberately not one. They compose but can ship independently.

**Change A — Formalize event-loop isolation via a wrapper helper.**

Introduce a single helper on `RelayMessageHandler` that packages the hop-to-
Task / hop-back-to-event-loop pattern, and replace every
`Task { ... eventLoop.execute { ... } }` block that currently touches `self`
mutable state with a call to it. This turns the discipline from "~18 inline
copies" into "one reviewable helper." It does not move any lines into new
files — the class still owns the state; we just name the pattern.

Proposed helper signature:

```swift
/// Runs `work` on the Swift concurrency executor, then hops back to the
/// channel's event loop to run `onSuccess` (with the awaited result) or
/// `onFailure` (with the error). Both callbacks are guaranteed to execute
/// on the event loop, so they may mutate handler-owned state safely.
///
/// The helper captures `self` weakly and the supplied `context` transferred
/// into the Task. If `self` is gone by the time the callback fires, neither
/// hand-off runs.
private func bridgeToEventLoop<T>(
    context: ChannelHandlerContext,
    work: @Sendable @escaping () async throws -> T,
    onSuccess: @escaping (_ self: RelayMessageHandler, _ ctx: ChannelHandlerContext, _ value: T) -> Void,
    onFailure: @escaping (_ self: RelayMessageHandler, _ ctx: ChannelHandlerContext, _ error: Error) -> Void
) {
    let ctx = UnsafeTransfer(context)
    Task { [weak self] in
        do {
            let value = try await work()
            ctx.value.eventLoop.execute { [weak self] in
                guard let self else { return }
                onSuccess(self, ctx.value, value)
            }
        } catch {
            ctx.value.eventLoop.execute { [weak self] in
                guard let self else { return }
                onFailure(self, ctx.value, error)
            }
        }
    }
}
```

Each current handler shrinks from ~18 lines to ~10:

```swift
private func handleSessionCreate(name: String?, context: ChannelHandlerContext) {
    guard let tokenId = authenticatedTokenId else { return }
    let mgr = self.sessionManager
    bridgeToEventLoop(
        context: context,
        work: {
            await self.autoDetachIfNeeded(ctx: /* captured separately */)
            let info = try await mgr.createSession(tokenId: tokenId, name: name)
            let (_, pty) = try await mgr.attachSession(id: info.id, tokenId: tokenId)
            return (info, pty)
        },
        onSuccess: { handler, ctx, pair in
            let (info, pty) = pair
            handler.attachedSessionId = info.id
            handler.attachedPTY = pty
            handler.sendServerMessage(.sessionCreated(sessionId: info.id, cols: info.cols, rows: info.rows), context: ctx)
            handler.wirePTYOutput(pty: pty, context: ctx)
        },
        onFailure: { handler, ctx, error in
            handler.sendServerMessage(.error(code: 500, message: "Failed to create session: \(error)"), context: ctx)
        }
    )
}
```

Trade-off: this doesn't *prove* callers won't still reach into `self.` from a
raw Task. But every PR reviewer can search for `Task { [weak self]` in
`RelayMessageHandler.swift` and flag any that aren't the helper; currently
they're the norm.

Caveat: `autoDetachIfNeeded(ctx:)` uses its own continuation-based hop and
doesn't fit the helper's shape cleanly. Keep it as-is; the goal is to remove
the 18 idiomatic copies, not to force every path through one pattern.

**Change B — Split into two types.**

Move all of the session-lifecycle request handlers (`handleSessionCreate`,
`handleSessionAttach`, `handleSessionResume`, `handleSessionDetach`,
`handleSessionTerminate`, `handleSessionList`, `handleSessionListAll`,
`handleSessionRename`, `handleResize`, `handlePasteImage`, `handleBinaryFrame`)
out of `RelayMessageHandler` into a sibling type:

```swift
// Sources/ClaudeRelayServer/Network/SessionRequestHandler.swift

/// Handles all post-auth session/IO requests routed from
/// `RelayMessageHandler`. Owns no WebSocket-protocol state — borrows the
/// connection's `attachedSessionId` / `attachedPTY` / send helpers from
/// its `RelayMessageHandler` parent so the concurrency invariants stay in
/// one place. Parent must call all methods on the channel event loop.
final class SessionRequestHandler {
    private unowned let parent: RelayMessageHandler  // never outlives parent
    private let sessionManager: SessionManager
    init(parent: RelayMessageHandler, sessionManager: SessionManager) { ... }

    func handleSessionCreate(name: String?, context: ChannelHandlerContext) { ... }
    func handleSessionAttach(sessionId: UUID, context: ChannelHandlerContext) { ... }
    // …etc
}
```

After the split, `RelayMessageHandler` keeps:
- `ChannelInboundHandler` conformance and frame-level parsing
- Connection lifecycle (`handlerAdded`, `channelInactive`, `errorCaught`)
- Auth flow (`handleAuth`, `handleUnauthenticatedMessage`, auth timer,
  rate-limit gate, observer registration — the trickiest part to split so
  we deliberately leave it in the parent)
- Send helpers (`sendServerMessage`, `sendBinaryData`, `sendChunkedBinaryData`)
- `cleanupSession`, `bridgeToEventLoop` helper
- Mutable state: `isAuthenticated`, `authenticatedTokenId`, `attachedSessionId`,
  `attachedPTY`, observer IDs, `isCleanedUp`, `inflightOutputBytes`

Target size: ~450 lines. Under the 500 limit.

`SessionRequestHandler`: ~330 lines, stateless w.r.t. the connection (borrows
state via `parent.`).

Why `unowned` and not `weak`: The parent owns the child for the lifetime of
the channel. Child-only access happens on the event loop; when
`cleanupSession` runs in `channelInactive`, it doesn't need to talk to the
child anymore. If we ever do need post-inactive access, flip to `weak`.

**Explicit alternative considered and rejected:** Making the handler an actor.
Actors inside NIO pipelines are a known footgun — the channel pipeline
callbacks (`channelRead`, `channelActive`, etc.) must be synchronous, and
any path that goes through an actor's implicit executor introduces ordering
gaps with the event loop. Existing code in this repo (see
`AdminHTTPHandler`) uses the same `UnsafeTransfer(context)` pattern
precisely to avoid actor-executor confusion. Do not change this pattern.

### 1.3 Tasks

Each task commits and tests independently.

**Task 1.1 — Add `bridgeToEventLoop` helper + unit test.**
- File: `Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift`
  (add private method; don't convert any call sites yet).
- Test: `Tests/ClaudeRelayServerTests/BridgeToEventLoopTests.swift` (new).
  - Pass: success path writes back to a local closure on the event loop.
  - Pass: failure path writes error back on the event loop.
  - Pass: torn-down handler (weak self nil) never invokes either callback.
- Verify: `swift test --filter ClaudeRelayServerTests` green.
- Target commit: `refactor(server): add bridgeToEventLoop helper for RelayMessageHandler`

**Task 1.2 — Convert request handlers to use `bridgeToEventLoop`.**
- Convert, in this order: `handleSessionList`, `handleSessionListAll`,
  `handleSessionRename`, `handleResize` (simplest, single write-back).
  Then `handleSessionDetach`, `handleSessionTerminate` (single success path).
  Then `handleSessionAttach`, `handleSessionResume`, `handleSessionCreate`
  (more nuanced, use pair returns).
- Keep `handleAuth`, `handlePasteImage`, `handleBinaryFrame` on the old
  pattern for this task — they have different shapes
  (observer registration / no response message / raw binary).
- Verify after each batch: `swift test --filter ClaudeRelayServerTests` +
  `swift test --filter WebSocketIntegrationTests`. The latter is the canary.
- Target commits: one per batch (4 commits total). Each commit message:
  `refactor(server): migrate <batch> to bridgeToEventLoop`

**Task 1.3 — Extract `SessionRequestHandler` type.**
- File: `Sources/ClaudeRelayServer/Network/SessionRequestHandler.swift` (new).
- Move the already-converted methods from Task 1.2 into it.
- `RelayMessageHandler` gains a `private let requestHandler: SessionRequestHandler`
  and `handleAuthenticatedMessage` dispatches to it.
- Keep `handleAuth`, `handlePasteImage`, `handleBinaryFrame`,
  `handleUnauthenticatedMessage` on `RelayMessageHandler`.
- Parent exposes a tightly-scoped interface:
  ```swift
  // Called by SessionRequestHandler on the event loop only.
  func setAttached(sessionId: UUID, pty: any PTYSessionProtocol) {
      assert(context?.eventLoop.inEventLoop == true)
      self.attachedSessionId = sessionId
      self.attachedPTY = pty
  }
  func clearAttached() { ... }
  func currentAttached() -> (UUID, (any PTYSessionProtocol)?)?
  var currentContext: ChannelHandlerContext? { context }
  func wirePTY(_ pty: any PTYSessionProtocol, context: ChannelHandlerContext)
  func sendServer(_ msg: ServerMessage, context: ChannelHandlerContext)
  ```
- Verify: same test suite + a new targeted
  `SessionRequestHandlerTests.swift` that spins up a fake parent and
  exercises at least `handleSessionList` and `handleSessionTerminate`.
- Target commit: `refactor(server): extract SessionRequestHandler`

**Task 1.4 — Remove the `// swiftlint:disable:next type_body_length` on
`RelayMessageHandler`.**
- File: `Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift` line 8.
- Verify: line count ≤ 500 for `class RelayMessageHandler { ... }`.
  (Use `swiftlint lint Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift`.)
- Target commit: `style(server): remove RelayMessageHandler length suppression`

**Acceptance for Item 1:**
- `swift test` green end-to-end (all 420+ tests).
- `swiftlint` clean in `Sources/ClaudeRelayServer/Network/` without
  `disable:next` pragmas on either file.
- A reviewer can open `RelayMessageHandler.swift` and see (a) ≤ 500 lines,
  (b) exactly one bridging helper that replaces the Task/execute pattern,
  (c) three remaining handlers that are intentionally not converted and
  explain why in a comment each.

### 1.4 Risk + rollback

- **Risk:** Task 1.3 is where a regression can slip in (see the squash-commit
  regression in Phase 2). Mitigation: keep each converted handler in its
  own commit, run `WebSocketIntegrationTests` after every commit, do not
  let the PR land as a single squash.
- **Rollback:** Every task is revertable in isolation. The extract in
  Task 1.3 is the only one that changes file layout — `git revert` +
  `xcodegen generate` (not applicable server-side) restores the previous
  shape.

---

## Item 2 — `SharedSessionCoordinator` follow-ups

### 2.1 Issue statement

`Sources/ClaudeRelayClient/ViewModels/SharedSessionCoordinator.swift` is 907
lines on `main`. Two distinct concerns:

**(a) Remaining `cachedTerminalViews` compatibility shim (lines 89–101).**

```swift
/// Back-compat accessor for call sites and tests that read
/// `coordinator.cachedTerminalViews`. Production code should prefer the
/// `terminalCache` API directly.
public var cachedTerminalViews: [UUID: AnyObject] {
    var out: [UUID: AnyObject] = [:]
    for id in terminalCache.cachedIds {
        if let view = terminalCache.view(for: id) { out[id] = view }
    }
    return out
}
```

Call-site inventory (`grep -rn "cachedTerminalViews" Sources ClaudeRelayApp ClaudeRelayMac Tests`):

| Site | Purpose |
|------|---------|
| `SharedSessionCoordinator.swift:90–101` | The shim itself. |
| `Tests/ClaudeRelayClientTests/SharedSessionCoordinatorTests.swift:48` | `XCTAssertTrue(coordinator.cachedTerminalViews.isEmpty)` |
| `Tests/ClaudeRelayClientTests/TerminalCacheLRUTests.swift:27,57` | Stress tests asserting `cachedTerminalViews.count == 8` |

**No production code in `ClaudeRelayApp/` or `ClaudeRelayMac/` reads this.**
All of them go through `terminalCache.*` or the thin forwarders
(`cachedTerminalView(for:)`, `registerLiveTerminal(for:view:)`,
`evictTerminal(for:)`).

The shim exists purely to keep two test files compiling. That's not a reason
to keep it — the tests can trivially port to `terminalCache.cachedIds.count`
or a freshly-added debug accessor on `TerminalCache`.

**(b) Type body is 907 lines, well past `type_body_length.error: 500`.**

Contents, grouped:

| Section | Lines | Responsibility |
|---------|-------|----------------|
| `@Published` state + ownership fields | 1–128 | Pure data |
| Init / subclass hooks / network monitor | 128–210 | Wiring |
| Auto-recovery breaker + dispatchers | 210–275 | Recovery scheduling |
| Name + ownership + persistence forwarders | 277–316 | Data delegation |
| Auth forwarders | 318–328 | Trivial (2 methods) |
| `fetchSessions` | 332–380 | Session list sync |
| Accessors | 382–408 | Derivation helpers |
| `createNewSession`, `switchToSession`, `attachRemoteSession`, `terminateSession` | 412–610 | Session lifecycle |
| Activity / Steal / Rename handlers | 613–658 | Push-event fan-in |
| `wireTerminalOutput` + terminal-cache forwarders | 662–693 | Terminal IO glue |
| `handleForegroundTransition`, `restoreSession`, `cancelRecovery` | 708–875 | The recovery state machine |
| Teardown | 879–891 | Lifecycle |
| Test hooks | 893–906 | Breaker introspection |

The recovery state machine (lines 708–875 = 168 lines) is the single biggest
cluster and has its own generation counter, phase enum, cooldown, suspend
flag, and three entry points. That's the right thing to extract next.

### 2.2 Resolution approach

Two surgical changes, no architectural upheaval:

**Change A — Delete the `cachedTerminalViews` shim and port the tests.**

Port the two test files to use either:
1. `coordinator.terminalCache.cachedIds` (which already exists, line 87), or
2. A new `TerminalCache` accessor like
   ```swift
   extension TerminalCache {
       /// For tests only. Returns the cache as a snapshot dictionary.
       public var snapshotForTesting: [UUID: AnyObject] { ... }
   }
   ```

Prefer (1) — no new API. The tests only care about count, not identities, so
`coordinator.terminalCache.cachedIds.count` is strictly better.

Lines removed from the coordinator: ~12.

**Change B — Extract `RecoveryController`.**

Create `Sources/ClaudeRelayClient/ViewModels/RecoveryController.swift`.
Move into it:

- All three fields related to the breaker circuit
  (`consecutiveAutoRecoveryFailures`, `autoRecoverySuspended`,
  `isRecoveryDispatched`, `lastRecoveryEndedAt`, `lastCancelledAt`,
  `recoveryGeneration`).
- `resetAutoRecoveryBreaker()`, `scheduleAutoRecovery()`, `triggerUserRecovery()`,
  `recordAutoRecoveryOutcome(success:userInitiated:)`, `cancelRecovery()`.
- `handleForegroundTransition(userInitiated:)` and `restoreSession(generation:userInitiated:)`.

Keep on the coordinator:
- `@Published` recovery UI state (`isRecovering`, `recoveryPhase`,
  `recoveryFailed`, `errorMessage`, `showError`, `connectionTimedOut`,
  etc. — SwiftUI binds to these and we are explicitly **not** collapsing
  them into an enum this round; that deferral from Task 3.5 is unchanged).
- `RecoveryPhase` enum (SwiftUI strings still live with the view-model).
- `recoveryTask: Task<Void, Never>?` (owned by the coordinator because
  teardown cancels it).

Sketch:

```swift
@MainActor
final class RecoveryController {
    private unowned let coordinator: SharedSessionCoordinator
    private let connection: RelayConnection

    private var recoveryGeneration: UInt64 = 0
    private var lastRecoveryEndedAt: Date = .distantPast
    private var consecutiveAutoRecoveryFailures = 0
    private let autoRecoveryCooldown: TimeInterval = 3
    private let maxAutoRecoveryFailures = 3
    private var autoRecoverySuspended = false
    private var isRecoveryDispatched = false
    private var lastCancelledAt: Date = .distantPast

    init(coordinator: SharedSessionCoordinator, connection: RelayConnection) {
        self.coordinator = coordinator
        self.connection = connection
    }

    func scheduleAutoRecovery() { ... }
    func triggerUserRecovery() { ... }
    func resetAutoRecoveryBreaker() { ... }
    func cancel() { ... }
    func handleForegroundTransition(userInitiated: Bool) async { ... }
    func restoreSession(generation: UInt64, userInitiated: Bool) async { ... }

    // Test hooks stay here, coordinator forwards.
    var _testOnly_autoRecoverySuspended: Bool { autoRecoverySuspended }
    var _testOnly_consecutiveAutoRecoveryFailures: Int { consecutiveAutoRecoveryFailures }
    func _testOnly_setAutoRecoverySuspended(_ suspended: Bool, failures: Int) { ... }
}
```

The coordinator shrinks by ~220 lines. New projected size: ~685. Still over
the 500 ceiling — which is **acceptable** because the next split
(recovery UI state → value type) is deferred (Task 3.5). A single
`// swiftlint:disable:next type_body_length` comment on the coordinator's
type header is justifiable short-term; alternatively this item ships with a
slightly-raised `error: 700` (see Item 4).

Method routing (keep the coordinator's external API unchanged):

```swift
// In SharedSessionCoordinator:
public func handleForegroundTransition() async {
    await recoveryController.handleForegroundTransition(userInitiated: true)
}
public func handleForegroundTransition(userInitiated: Bool) async {
    await recoveryController.handleForegroundTransition(userInitiated: userInitiated)
}
public func triggerUserRecovery() { recoveryController.triggerUserRecovery() }
public func cancelRecovery() { recoveryController.cancel() }
public var _testOnly_autoRecoverySuspended: Bool { recoveryController._testOnly_autoRecoverySuspended }
// …etc
```

**Alternative considered and rejected:** Making `RecoveryController` own the
`@Published` recovery state as its own `ObservableObject` and having views
bind `coordinator.recoveryController.isRecovering`. Rejected because:
(a) Views are everywhere; the chase-the-indirection cost is real.
(b) SwiftUI `@ObservedObject` nesting is fiddly — `ObservableObject` changes
on a child do not propagate through the parent's `objectWillChange` by
default.
(c) We explicitly deferred that work in Task 3.5 with user sign-off.

### 2.3 Tasks

**Task 2.1 — Port tests off `cachedTerminalViews` shim.**
- Files:
  - `Tests/ClaudeRelayClientTests/SharedSessionCoordinatorTests.swift:48`
  - `Tests/ClaudeRelayClientTests/TerminalCacheLRUTests.swift:27, 54–57`
- Replace with `coordinator.terminalCache.cachedIds.count` or `.isEmpty`.
- Verify: `swift test --filter ClaudeRelayClientTests` green.
- Target commit: `test(client): use terminalCache.cachedIds instead of cachedTerminalViews shim`

**Task 2.2 — Delete the shim.**
- File: `Sources/ClaudeRelayClient/ViewModels/SharedSessionCoordinator.swift`
  lines 89–101.
- Verify: `swift build` green (any external call site would fail here —
  we confirmed there are none).
- Target commit: `refactor(client): remove cachedTerminalViews back-compat shim`

**Task 2.3 — Extract `RecoveryController`.**
- New file: `Sources/ClaudeRelayClient/ViewModels/RecoveryController.swift`.
- Move the 12 fields + 7 methods listed above.
- `SharedSessionCoordinator` gains a `private let recoveryController:
  RecoveryController` initialized in `init`, with public methods that now
  forward.
- Keep `recoveryTask: Task<Void, Never>?` on the coordinator; assign from
  `scheduleAutoRecovery` / `triggerUserRecovery` via a setter on the
  coordinator that the controller calls back into.
- **Test preservation:** All existing recovery tests (see
  `Tests/ClaudeRelayClientTests/` recovery-related suites) must continue
  to exercise the coordinator's public API. If any test reaches into the
  previously-private recovery fields (via `@testable`), update it to go
  through the new test hooks.
- Verify: `swift test` green end-to-end (recovery tests are the canary).
- Target commit: `refactor(client): extract RecoveryController from SharedSessionCoordinator`

**Task 2.4 — (optional, only after Task 2.3) evaluate the `type_body_length`
pragma.**
- If coordinator is ≤ 500: no pragma needed.
- If coordinator is > 500 but < 700: add
  `// swiftlint:disable:next type_body_length` on the class header with a
  comment referring to this plan and the Task-3.5-deferred work.
- Target commit: `style(client): annotate SharedSessionCoordinator type_body_length exception`

**Acceptance for Item 2:**
- `cachedTerminalViews` symbol no longer exists in the codebase.
- `RecoveryController.swift` compiles and is exercised by existing tests
  (no new tests needed — same behaviour).
- Coordinator size is measurably smaller (~685 lines vs 907).

### 2.4 Risk + rollback

- **Risk:** `@MainActor` isolation of the new controller must match the
  coordinator's. Both are `@MainActor`; keep it.
- **Risk:** The `unowned` reference to the coordinator means the controller
  must not outlive the coordinator. Since the controller is owned by the
  coordinator, this is structurally safe, but verify `tearDown()` doesn't
  leak controller references.
- **Rollback:** Each task is its own commit. Task 2.3 is the riskiest — if
  recovery tests flake, revert Task 2.3 alone; tasks 2.1 and 2.2 are
  standalone.

---

## Item 3 — `AppSettings.bedrockBearerToken` SwiftUI binding

### 3.1 Issue statement

Both `ClaudeRelayApp/Models/AppSettings.swift` and
`ClaudeRelayMac/Models/AppSettings.swift` expose:

```swift
@Published private var bedrockTokenVersion = UUID()

var bedrockBearerToken: String {
    get {
        _ = bedrockTokenVersion        // publish dependency
        return (try? AuthManager.shared.loadBedrockToken()) ?? ""
    }
    set {
        try? AuthManager.shared.saveBedrockToken(newValue)
        bedrockTokenVersion = UUID()
    }
}
```

Call sites (verified):
- `ClaudeRelayApp/Views/SettingsView.swift:27` — `SecureField("Bearer Token", text: $settings.bedrockBearerToken)`
- `ClaudeRelayMac/Views/SettingsView.swift:370` — same pattern
- `ClaudeRelayApp/Views/Components/MicButton.swift:77` — read-only access for enhancer call
- `ClaudeRelayMac/Views/MainWindow.swift:302` — same

**Functionally correct**, but three practical issues:

**(a) Every keystroke writes the Keychain.** Typing a 40-character token =
40 `SecItemDelete` + 40 `SecItemAdd` calls. On iOS these block the main
thread briefly (a few ms each) and the system may prompt for access in
edge cases (e.g., first write after unlock). We observed no crashes but
the behaviour is wasteful and creates audit noise in `log stream
--predicate 'subsystem == "com.apple.securityd"'`.

**(b) `bedrockTokenVersion = UUID()` churns on every keystroke.** This
forces SwiftUI to reevaluate every view depending on `settings` on every
keystroke. Not a bug, but it propagates into MicButton renders too.

**(c) Migration silently drops the legacy token if Keychain save fails.**
In `migrateBedrockTokenIfNeeded()`:

```swift
do {
    try AuthManager.shared.saveBedrockToken(legacy)
    defaults.removeObject(forKey: "bedrockBearerToken")   // only on success
} catch {
    // Keep the UserDefaults copy intact so the user's token isn't lost;
    // surface through `bedrockBearerToken`'s getter below.
}
```

The comment says "surface through the getter," but the getter only reads
**Keychain**, never UserDefaults. So a user who hits a Keychain-save
failure on migration will see an empty field in Settings, confused about
where their token went, while it silently lives on in
`~/Library/Preferences/com.claude.relay.plist` until the next launch
retries and succeeds. The UX contract is broken: the invariant "the UI
always shows the current effective token" is violated during the partial
migration state.

**(d) Read churn on every view update.** Because the getter does a Keychain
lookup each time `_ = bedrockTokenVersion` is touched, and SwiftUI
evaluates bindings on every `objectWillChange` fire, SecureField's redraw
triggers a Keychain read. Typing into *any other* setting in the same
`AppSettings` object also triggers `objectWillChange` and causes a spurious
Keychain read for bearer. Very cheap, but wasted work and an unnecessary
audit footprint.

### 3.2 Resolution approach

One coherent refactor across both apps. Keep the Keychain as the source of
truth; introduce a published draft string that:

1. Initializes from Keychain once at `AppSettings.init`.
2. Is the binding target for SwiftUI `$settings.bedrockBearerToken`.
3. Saves back to Keychain **on an explicit trigger** — either:
   - A short Combine debounce (500 ms) inside the setter, or
   - A "Save" button click in the SettingsView.

Recommend **debounce**, not explicit Save. Rationale: the current UX is
"type and close the sheet"; adding a Save button is a UX regression that
users would have to learn. Debounce preserves the type-and-walk-away flow
while collapsing 40 keystrokes into 1 Keychain write.

### 3.3 Recommended implementation

**Step 1 — Replace the computed property with a `@Published` draft.**

```swift
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// In-memory mirror of the Bedrock bearer token. Seeded from the Keychain
    /// at init. SwiftUI binds to this via `$settings.bedrockBearerToken`.
    /// Persisted via `bedrockTokenSaveSubject` on a 500 ms debounce so rapid
    /// keystrokes collapse into a single Keychain write.
    @Published var bedrockBearerToken: String = ""

    private var bedrockTokenCancellable: AnyCancellable?
    private let bedrockTokenSaveSubject = PassthroughSubject<String, Never>()

    private init() {
        // Existing migration…
        migrateBedrockTokenIfNeeded()

        // Seed from Keychain (or legacy UserDefaults if migration failed).
        self.bedrockBearerToken = loadBedrockTokenWithFallback()

        // Debounce writes: 500 ms after the last keystroke.
        bedrockTokenCancellable = bedrockTokenSaveSubject
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { token in
                try? AuthManager.shared.saveBedrockToken(token)
            }

        // Mirror published changes into the save pipeline, but skip the
        // initial seed to avoid a no-op round-trip.
        $bedrockBearerToken
            .dropFirst()
            .sink { [weak self] in self?.bedrockTokenSaveSubject.send($0) }
            .store(in: &bedrockTokenSubscriptions)
    }

    /// Reads the Keychain, falling back to legacy UserDefaults so a failed
    /// migration doesn't vanish the user's token.
    private func loadBedrockTokenWithFallback() -> String {
        if let keychainValue = try? AuthManager.shared.loadBedrockToken(),
           !keychainValue.isEmpty {
            return keychainValue
        }
        // Legacy fallback — only hit when migration failed earlier.
        return UserDefaults.standard.string(forKey: legacyBedrockKey) ?? ""
    }

    private var legacyBedrockKey: String {
        #if os(iOS)
        "bedrockBearerToken"
        #else
        "com.clauderelay.mac.bedrockBearerToken"
        #endif
    }

    private var bedrockTokenSubscriptions = Set<AnyCancellable>()
}
```

**Step 2 — Fix the migration to read back the post-save value.**

```swift
private func migrateBedrockTokenIfNeeded() {
    let defaults = UserDefaults.standard
    guard let legacy = defaults.string(forKey: legacyBedrockKey),
          !legacy.isEmpty else { return }
    if let existing = try? AuthManager.shared.loadBedrockToken(),
       !existing.isEmpty {
        defaults.removeObject(forKey: legacyBedrockKey)
        return
    }
    do {
        try AuthManager.shared.saveBedrockToken(legacy)
        // Confirm the save actually landed before scrubbing the plist.
        if let reread = try? AuthManager.shared.loadBedrockToken(), reread == legacy {
            defaults.removeObject(forKey: legacyBedrockKey)
        }
    } catch {
        // Leave the legacy copy in place; the fallback reader above picks it up.
    }
}
```

**Step 3 — If the user clears the token, persist immediately.**

An empty string = delete the Keychain entry. Debouncing a "delete" for
500 ms is fine, but we should not end up in a state where the in-memory
value is empty while the Keychain still holds the old token after the
debounce fires (it will, because `AuthManager.saveBedrockToken("")` calls
`deleteBedrockToken()`). Verify via test.

### 3.4 Tasks

**Task 3.1 — Replace computed property with debounced `@Published` (iOS).**
- File: `ClaudeRelayApp/Models/AppSettings.swift`
- Remove `@Published private var bedrockTokenVersion` and the computed
  `bedrockBearerToken` property.
- Add stored `@Published var bedrockBearerToken: String` and debounce
  subscription.
- Add `loadBedrockTokenWithFallback()` helper.
- Fix `migrateBedrockTokenIfNeeded()` with re-read check.
- Add `import Combine`.
- Verify: open Settings, type a token, close, relaunch, confirm persistence.
  (Manual UI verification required — this is a SwiftUI behaviour change.)
- Target commit: `fix(ios): debounce Bedrock token Keychain writes`

**Task 3.2 — Same refactor for Mac app.**
- File: `ClaudeRelayMac/Models/AppSettings.swift`
- Same structural change.
- Target commit: `fix(mac): debounce Bedrock token Keychain writes`

**Task 3.3 — Add unit tests.**
- New file: `ClaudeRelayAppTests/AppSettingsBedrockTests.swift`
  (the Mac target has no equivalent test bundle so iOS coverage is
  sufficient — the logic is the same in both apps).
- Tests:
  - `testBedrockTokenSeedsFromKeychainOnInit` — pre-populate Keychain, init,
    assert `bedrockBearerToken == "xyz"`.
  - `testBedrockTokenDebouncesWrites` — mutate the published value 10 times
    in rapid succession, await 600 ms, assert Keychain contains only the
    final value.
  - `testBedrockTokenFallbackReadsLegacyUserDefaults` — set
    `UserDefaults.standard.set("legacy", forKey: "bedrockBearerToken")`,
    leave Keychain empty, simulate `AuthManager.saveBedrockToken` failure,
    assert getter returns `"legacy"`.
  - `testMigrationConfirmsSaveBeforeScrubbingPlist` — mock
    AuthManager to return an empty read after a successful save; assert
    UserDefaults key is retained (not scrubbed).
  - `testEmptyTokenDeletesKeychainEntry` — set `bedrockBearerToken = ""`,
    await debounce, assert `loadBedrockToken()` returns `nil`.
- Target commit: `test(ios): cover Bedrock token debounce + migration`

**Acceptance for Item 3:**
- Typing a 40-char token → exactly 1 Keychain write (verified by test).
- Failed migration leaves legacy UserDefaults intact and the UI still shows
  the token.
- No `UUID()` churn on every keystroke in the object graph.
- No behaviour change from the user's point of view in the happy path.

### 3.5 Risk + rollback

- **Risk:** Users with a token currently in the Keychain must continue to
  see it after the update. The init-time seed covers this. Test manually
  on both platforms: create test token pre-update, install update, confirm
  Settings shows it.
- **Risk:** Debounce scheduling on `DispatchQueue.main` must not dead-lock
  with `@MainActor` isolation. `@MainActor` already serializes on the main
  queue; this is fine.
- **Rollback:** Per-app commits are independent. Revert either or both.

---

## Item 4 — SwiftLint `type_body_length.error: 1000` ceiling

### 4.1 Issue statement

`.swiftlint.yml` currently carries:

```yaml
type_body_length:
  warning: 350
  # TEMP: raised from 500 → 1000 until C-06/C-07 split SharedSessionCoordinator
  # and RelayMessageHandler. Revert once those land (see remediation plan Task 5.1).
  error: 1000
```

This was a deliberate tradeoff to let the full PR land without blocking
on the split. Consequence: any future unrelated PR that introduces a new
900-line type will pass lint, because the ceiling is set for our specific
offenders. That's "normalised deviance" by another name.

Current files over 500 lines (from `find … | xargs wc -l`):

```
519   Sources/ClaudeRelayClient/RelayConnection.swift
540   Sources/ClaudeRelayServer/Actors/PTYSession.swift
669   Sources/ClaudeRelayServer/Actors/SessionManager.swift
782   Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift
907   Sources/ClaudeRelayClient/ViewModels/SharedSessionCoordinator.swift
```

Note these are file lengths. `type_body_length` operates on **class/struct
body** lengths, which is slightly smaller than file length (imports + top-
level helpers don't count). Per-type empirical measurements (needed at
task time; approximate from inspection):

- `RelayMessageHandler`: ~770 type body.
- `SharedSessionCoordinator`: ~895 type body.
- `SessionManager`: ~660 (still over 500 but not discussed here).
- `PTYSession`: ~530.
- `RelayConnection`: ~510.

### 4.2 Resolution approach

Restore the ceiling in a series of steps, each gated on Item 1 / Item 2
progress. Do not revert all the way back to 500 in one move — that would
block all work on `main` until every oversize type is split.

**Phase A (after Item 1 lands):** RelayMessageHandler ≤ 500. Remove its
`// swiftlint:disable:next type_body_length` comment. `.swiftlint.yml`
stays at `error: 1000`.

**Phase B (after Item 2 lands):** SharedSessionCoordinator ~685. If still
over 500, add `// swiftlint:disable:next type_body_length` on the class
with a `// TODO: Task 3.5 recovery-state enum deferral` comment that
points to this plan. Lower the global ceiling to `error: 700` — big
enough to accommodate `SessionManager`, `PTYSession`, `RelayConnection`,
and the coordinator's residual size; small enough to flag any new
1000-line monster.

**Phase C (long term, not in this plan):** Split `SessionManager` and
collapse `RelayConnection` / `PTYSession` where possible, then revert to
`error: 500`. Out of scope for this plan — noted as a follow-up in
`SessionManager` and `PTYSession` review (not part of the 5 items).

### 4.3 Tasks

**Task 4.1 — (after Item 1 Task 1.4) remove pragma on `RelayMessageHandler`.**
Already captured as Task 1.4. Repeated here for dependency tracking.

**Task 4.2 — (after Item 2 Task 2.3) lower ceiling to 700.**
- File: `.swiftlint.yml`
- Change `type_body_length.error: 1000` → `700`.
- Add a comment referencing the remaining offenders (SessionManager,
  SharedSessionCoordinator) and linking to this plan for Phase C.
- Verify: `swiftlint lint Sources/` clean.
- Target commit: `style: tighten type_body_length ceiling to 700`

**Acceptance for Item 4:**
- After both items ship, the TEMP comment on `.swiftlint.yml` is gone.
- `.swiftlint.yml` `type_body_length.error` is 700 (not 1000).
- Every remaining type over 500 has an explicit
  `// swiftlint:disable:next type_body_length` annotation with a reason.

### 4.4 Risk + rollback

- **Risk:** `swiftlint` could flag newly-added code in unrelated types.
  Run `swiftlint lint Sources/` before the commit.
- **Rollback:** One-line change in `.swiftlint.yml`.

---

## Item 5 — `NSAllowsLocalNetworking` ATS scoping

### 5.1 Issue statement

`project.yml` and both `Info.plist` files carry:

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
</dict>
```

This is the **correct** setting for our dominant use case (LAN server,
localhost dev, simulator loopback). However, it has unadvertised blast
radius:

**Apple's `NSAllowsLocalNetworking` exemption covers exactly:**
- Loopback (`127.0.0.1`, `::1`)
- `.local` mDNS hostnames
- Private IPv4 ranges (RFC 1918): `10.0.0.0/8`, `172.16.0.0/12`,
  `192.168.0.0/16`
- Link-local IPv6 (`fe80::/10`)

**What it does NOT cover:**
- **Tailscale CGNAT space (`100.64.0.0/10`)** — popular among our users
  who run the server on a work/home machine and reach it from their
  phone via Tailscale. Pre-change, `NSAllowsArbitraryLoads: true` covered
  these; post-change, plaintext ws:// to `100.x.y.z` is rejected at the
  ATS layer before the WebSocket handshake.
- **IPv6 ULA (`fc00::/7`)** — some lab setups.
- **Public IP / hostname over plaintext** — intentional, TLS is the
  answer here. This IS the behaviour we want.

Apple **does not** support CIDR matching in `NSExceptionDomains` — entries
are matched by exact hostname or second-level domain. You can't whitelist
`100.64.0.0/10` via Info.plist. So we can't keep the tightened ATS and
also transparently allow Tailscale plaintext.

### 5.2 Resolution approach

Accept the trade-off: **the answer for any non-RFC1918 network is TLS on
the server** (`tlsCert` + `tlsKey` config). This is already supported
(see `Sources/ClaudeRelayServer/Network/WebSocketServer.swift` — NIO-SSL
integration). Document the constraint prominently.

### 5.3 Tasks

**Task 5.1 — Add an ATS note to `README.md`.**
- Section placement: New subsection under `### TLS Configuration` titled
  "**When TLS is required**".
- Content (draft):

```markdown
### When TLS is required

Both the iOS and macOS apps scope App Transport Security via
`NSAllowsLocalNetworking`, which permits plaintext WebSocket (`ws://`) to:

- Loopback (`127.0.0.1`, `::1`)
- `.local` mDNS names
- RFC 1918 private IPv4 (`10/8`, `172.16/12`, `192.168/16`)
- Link-local IPv6 (`fe80::/10`)

Plaintext `ws://` to any other address — including **Tailscale CGNAT
addresses (`100.64.0.0/10`)**, IPv6 ULA, VPN overlays with non-private
IPs, and public hostnames — is refused by iOS/macOS before the WebSocket
handshake. If you access the server from a non-private network, you must
configure TLS on the server (see the [TLS Configuration](#tls-configuration)
section above) and use a `wss://` URL in the app.

This is an iOS/macOS platform requirement. The ATS entry cannot be
broadened via CIDR ranges; the supported path for non-LAN deployments is TLS.
```

- Verify: `grep -n "Tailscale" README.md` returns the new line;
  `grep -n "NSAllowsLocalNetworking" README.md` returns at least one match.
- Target commit: `docs: call out TLS requirement for non-RFC1918 deployments`

**Task 5.2 — Cross-reference from `CLAUDE.md`.**
- File: `CLAUDE.md`
- Add a single line under the "TLS Support" / architecture section:
  `> iOS/macOS apps restrict plaintext WebSocket to RFC1918 via ATS; see README "When TLS is required".`
- Target commit: squashable into Task 5.1 if both land in the same PR.

**Task 5.3 — Cross-reference from `CHANGELOG.md`.**
- Next release entry (`[Unreleased]` section) gets a line:
  `- Documented that ATS scoping refuses plaintext \`ws://\` to CGNAT/public addresses; TLS is required for non-LAN deployments.`

**Acceptance for Item 5:**
- A user who hits "connection refused with no useful error" on their
  Tailscale address can grep README for "Tailscale" and find the answer.
- No code changes.

### 5.4 Risk + rollback

- **Risk:** None — docs only.
- **Rollback:** Revert the README / CLAUDE / CHANGELOG edits.

---

## Cross-cutting execution order

Dependency graph (arrows = "must-land-first"):

```
Item 1 (RelayMessageHandler)
  ├─ Task 1.1 → 1.2 → 1.3 → 1.4
  │                         └─→ Item 4 Phase A
  └─ (parallelisable with Items 2, 3, 5)

Item 2 (SharedSessionCoordinator)
  ├─ Task 2.1 → 2.2 → 2.3 → 2.4
  │                   └─→ Item 4 Phase B
  └─ (parallelisable with Items 1, 3, 5)

Item 3 (Bedrock token)
  └─ Task 3.1 and 3.2 in parallel → 3.3

Item 4 (SwiftLint ceiling)
  ├─ Phase A depends on Item 1 Task 1.4
  └─ Phase B depends on Item 2 Task 2.3

Item 5 (ATS docs)
  └─ Task 5.1 / 5.2 / 5.3 (independent; squashable)
```

### Recommended sequencing

1. **Item 5** first (docs-only, zero risk, 30 min).
2. **Item 3** next (per-platform, isolated, half a day).
3. **Item 2** (builds up the lint-ceiling-revert, one focused day).
4. **Item 1** (biggest refactor, test-green discipline critical, one to
   two days).
5. **Item 4** last, gated on both Item 1 and Item 2.

Alternative: Items 1 and 2 run in parallel on separate branches by
different sessions/reviewers if we're worried about sequence risk; each
uses its own `swift test --filter` subset as canary.

---

## What this plan does NOT address

The following items are **explicitly deferred** and should not creep in:

- **Task 3.4 / 3.5 deferrals from the original hardening pass** — unifying
  recovery flags into a `RecoveryUIState` enum / extracting a
  `RecoveryController`-style facade for UI. Item 2 here extracts the
  *logic* for Task 3.4; the UI-state collapse stays on the backlog until
  we have a UX pass planned that justifies the view churn.
- **`SessionManager` split (669 L)** — flagged as Phase C in Item 4 but
  not planned in detail. Its shape is actor-based and splitting it needs
  its own design pass.
- **`RelayConnection` (519 L) and `PTYSession` (540 L) cleanup** —
  marginally over 500; low priority.
- **Integration tests for `$settings.bedrockBearerToken` SwiftUI binding**
  — Item 3 Task 3.3 covers unit tests for the persistence pipeline but
  not the SwiftUI binding itself. XCUITest coverage for SecureField is
  out of scope.
- **Migrating `$settings` call-sites off `@Published private var X = UUID()`
  sentinel patterns elsewhere in the app** — only `bedrockBearerToken`
  was flagged. If we find the same pattern on other computed properties
  in future review, document then.

---

## Verification plan

Before marking the whole plan complete:

```bash
# 1. Full test suite.
swift test

# 2. Lint clean with no pragmas on items 1/2's types.
swiftlint lint Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift
swiftlint lint Sources/ClaudeRelayClient/ViewModels/SharedSessionCoordinator.swift

# 3. File lengths.
wc -l Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift     # expect ≤ 500
wc -l Sources/ClaudeRelayClient/ViewModels/SharedSessionCoordinator.swift  # expect ~685

# 4. Bedrock binding manual smoke on both apps.
#    - Open Settings → enter 40-char token → close → relaunch → verify token persists.
#    - Clear token → relaunch → verify it stays cleared.
#    - Verify exactly 1 Keychain write per debounced group (use Console.app
#      with subsystem com.apple.securityd filter during typing).

# 5. ATS doc reachable.
grep -q "Tailscale" README.md && echo "README updated"
grep -q "NSAllowsLocalNetworking" README.md && echo "ATS constraint documented"
```

A PR that lands all five items should close the TEMP comments currently
present at:

- `.swiftlint.yml:43-44` — "TEMP: raised from 500 → 1000 until C-06/C-07 split"
- `Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift:8` — `swiftlint:disable:next type_body_length`
- `Sources/ClaudeRelayClient/ViewModels/SharedSessionCoordinator.swift:89-101` — `cachedTerminalViews` back-compat shim

If any of those three markers remain after the PR, the plan is not
complete.
