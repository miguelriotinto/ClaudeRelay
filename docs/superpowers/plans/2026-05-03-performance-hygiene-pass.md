# Performance & Hygiene Pass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce Homebrew release build footprint, cut avoidable work in the PTY/activity hot path, stop re-authenticating every 15 s just to check "is the server up", tighten a handful of client caches/timers, and speed tests — without changing observable protocol/UX behavior.

**Architecture:** Ten targeted, independently-reviewable tasks. Each keeps the existing `@MainActor`/actor boundaries the coordinator relies on for recovery correctness, and each ships with tests where behavior changes. We deliberately avoid large refactors (no splitting up `ActiveTerminalView`, `SharedSessionCoordinator`, `RelayMessageHandler`) and anything that might perturb recovery — those are separate plans.

**Tech Stack:** Swift 5.9, SwiftPM, NIO, Swift Concurrency (actors), URLSession, SwiftUI, WhisperKit, Homebrew Ruby Formula DSL, XCTest, XcodeGen (`project.yml`).

---

## Pre-flight

- [ ] **Step 0: Verify the baseline is green**

Run: `swift build && swift test`
Expected: build succeeds; all tests pass. If not, stop and fix before touching anything else.

Also run: `du -sh "$(pwd)/.build" "$(pwd)/build" 2>/dev/null || true`
(Informational: we're not trying to shrink this as part of the plan, but note the starting size.)

---

## Task 1: Homebrew release — build only server+CLI, pin LLM.swift reproducibly

**Why this matters:** `Formula/clauderelay.rb:13` currently runs `swift build -c release` (no `--product`), which makes SwiftPM resolve and build every product in `Package.swift` — including `ClaudeRelaySpeech`, which drags in WhisperKit + LLM.swift. The formula installs only the two binaries it needs. Building the other products is pure waste on every Homebrew install/upgrade. Separately, `Package.swift:20` tracks LLM.swift on `branch: "main"`; the root `Package.resolved` and the Xcode `Package.resolved` are pinned to different revisions (`c2144e1a…` vs. `f1e1e119…`). Pinning by revision makes builds reproducible.

**Files:**
- Modify: `Formula/clauderelay.rb:12-19`
- Modify: `Package.swift:20`
- Regenerate: `Package.resolved` and `ClaudeRelay.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`

- [ ] **Step 1: Pin LLM.swift by revision in `Package.swift`**

Choose the revision currently in root `Package.resolved` (this is what `swift build`/`swift test` actually use today; staying on this revision is the no-risk move):

```swift
// Before (Package.swift:20)
.package(url: "https://github.com/obra/LLM.swift.git", branch: "main"),
```

```swift
// After
.package(url: "https://github.com/obra/LLM.swift.git", revision: "c2144e1a0e29c280ec6080b7da85e876d51f8509"),
```

Verify the revision matches today's root `Package.resolved`:

```bash
grep -A3 'LLM.swift' Package.resolved
```

If the revision in `Package.resolved` differs from the one you wrote, replace the one above with whatever `Package.resolved` says (it is source of truth for "what currently builds green").

- [ ] **Step 2: Resolve packages + confirm build still works**

```bash
swift package resolve
swift build
swift test
```

Expected: build + tests pass. Root `Package.resolved` now shows `"revision" : "c2144e1a…"` and no `"branch"` key for LLM.swift.

- [ ] **Step 3: Update the Xcode-side Package.resolved to match**

```bash
xcodebuild -resolvePackageDependencies -project ClaudeRelay.xcodeproj -scheme ClaudeRelay
```

Verify both resolved files agree:

```bash
grep -A3 LLM.swift Package.resolved
grep -A3 LLM.swift ClaudeRelay.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
```

Expected: identical `"revision"` on both and no `"branch"` field.

- [ ] **Step 4: Narrow the formula build to just the two binaries**

Replace the `def install` block at `Formula/clauderelay.rb:12-19`:

```ruby
  def install
    system "swift", "build",
           "-c", "release",
           "--disable-sandbox",
           "-Xswiftc", "-cross-module-optimization",
           "--product", "claude-relay-server"
    system "swift", "build",
           "-c", "release",
           "--disable-sandbox",
           "-Xswiftc", "-cross-module-optimization",
           "--product", "claude-relay"
    bin.install ".build/release/claude-relay"
    bin.install ".build/release/claude-relay-server"
  end
```

We invoke `swift build` twice with `--product` instead of once without. Swift's build graph will skip everything not reachable from those two products — in particular `ClaudeRelaySpeech`, which transitively pulls WhisperKit + LLM.swift. The second call is near-free because the first populated the shared `.build` cache.

Do NOT drop `ClaudeRelaySpeech` from `Package.swift` — the iOS/macOS apps still link it. We are only fixing what the formula compiles.

- [ ] **Step 5: Smoke-test the formula build path**

```bash
rm -rf .build
swift build -c release --disable-sandbox -Xswiftc -cross-module-optimization --product claude-relay-server
swift build -c release --disable-sandbox -Xswiftc -cross-module-optimization --product claude-relay
ls -la .build/release/claude-relay .build/release/claude-relay-server
```

Expected: both binaries exist. `.build` should be smaller than a full release build would have been (because no WhisperKit/LLM.swift compilation products).

Sanity check that neither binary actually links to WhisperKit/LLM.swift:

```bash
otool -L .build/release/claude-relay-server | grep -iE 'whisper|LLM' || echo "OK: no speech deps in server"
otool -L .build/release/claude-relay        | grep -iE 'whisper|LLM' || echo "OK: no speech deps in CLI"
```

Expected: both print "OK: …".

- [ ] **Step 6: Commit**

```bash
git add Package.swift Package.resolved \
        ClaudeRelay.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved \
        Formula/clauderelay.rb
git commit -m "build: pin LLM.swift revision and narrow brew build to server+CLI"
```

---

## Task 2: Gate the ANSI regex in SessionActivityMonitor to Claude-only paths

**Why this matters:** Every PTY output chunk runs a comprehensive ANSI/VT escape-sequence regex (`SessionActivityMonitor.swift:51` + `:82`). The result is only actually *used* inside `if isClaudeRunning`. When Claude is not running, we decode UTF-8 and apply a regex just to throw the result away. For a busy shell that's one full Unicode decode + one regex match per read — and reads are small (8 KB default), so this runs constantly.

This is a pure correctness-preserving change: same output, less work when Claude isn't the foreground process.

**Files:**
- Modify: `Sources/ClaudeRelayServer/Actors/SessionActivityMonitor.swift:68-100`
- Test: `Tests/ClaudeRelayServerTests/SessionActivityMonitorTests.swift` (new or existing — check first)

- [ ] **Step 1: Check existing test coverage**

```bash
ls Tests/ClaudeRelayServerTests/ | grep -i activity
```

If `SessionActivityMonitorTests.swift` exists, read it so new tests match its style. If not, you'll create one.

- [ ] **Step 2: Write a failing test for the non-Claude fast path**

Add to `Tests/ClaudeRelayServerTests/SessionActivityMonitorTests.swift` (create if needed):

```swift
import XCTest
@testable import ClaudeRelayServer
import ClaudeRelayKit

final class SessionActivityMonitorFastPathTests: XCTestCase {

    /// Non-Claude output with no visible content (just escape sequences) should
    /// still transition to .active — the fast path must not change observable behavior.
    func testEscapeOnlyOutputTransitionsToActiveWhenNotClaude() {
        let exp = expectation(description: "state change")
        exp.assertForOverFulfill = false
        var lastState: ActivityState = .idle
        let monitor = SessionActivityMonitor(
            silenceThreshold: 10,
            claudeSilenceThreshold: 10,
            onChange: { state in
                lastState = state
                exp.fulfill()
            }
        )
        // Pure escape sequence: cursor-up 2 times. No visible text.
        monitor.processOutput(Data([0x1B, 0x5B, 0x32, 0x41]))
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(lastState, .active)
        monitor.cancel()
    }

    /// When Claude IS running, escape-only output must NOT count as activity.
    /// This preserves the existing Claude-path behaviour.
    func testEscapeOnlyOutputDoesNotCountAsActivityWhenClaudeRunning() {
        var states: [ActivityState] = []
        let monitor = SessionActivityMonitor(
            silenceThreshold: 10,
            claudeSilenceThreshold: 10,
            onChange: { states.append($0) }
        )
        monitor.updateForegroundProcess(isClaude: true) // enter Claude
        states.removeAll()
        // Pure escape sequence while Claude is running.
        monitor.processOutput(Data([0x1B, 0x5B, 0x32, 0x41]))
        XCTAssertTrue(states.isEmpty, "escape-only output must not transition while Claude is running")
        monitor.cancel()
    }
}
```

- [ ] **Step 3: Run the tests to see current state**

```bash
swift test --filter SessionActivityMonitorFastPathTests
```

Expected: the first test passes already (current code transitions on any output when `!isClaudeRunning`); the second test passes already (escape-only is filtered). If both pass, good — our refactor must not break them. If either fails, stop and understand why before continuing.

- [ ] **Step 4: Refactor `processOutput` to skip regex when not Claude**

Replace the whole `processOutput(_:)` body at `Sources/ClaudeRelayServer/Actors/SessionActivityMonitor.swift:68-100`:

```swift
    /// Analyze a chunk of PTY output. Called from `PTYSession.handleOutput()`.
    public func processOutput(_ data: Data) {
        guard !cancelled else { return }

        // Always scan for OSC title so Claude-entry detection still works.
        detectTitleChange(in: data)

        // Fast path: when Claude isn't running, *any* output is activity. We
        // don't need UTF-8 decoding or ANSI stripping — that work is only
        // needed to distinguish meaningful output from ink/React redraws
        // while Claude is running.
        if !isClaudeRunning {
            transition(to: .active)
            resetSilenceTimer()
            return
        }

        // Claude path: only count visible content (skip pure escape-sequence
        // redraws). Decode + ANSI-strip only in this branch.
        var hasVisibleContent = true
        if let raw = String(data: data, encoding: .utf8) {
            let clean = raw.replacing(Self.ansiEscapePattern, with: "")
            hasVisibleContent = !clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if hasVisibleContent {
            transition(to: .claudeActive)
            resetSilenceTimer()
        }
    }
```

Observable behavior preserved:
- Non-Claude: transitions to `.active`, resets silence timer (same as before).
- Claude: same visibility-filtered logic as before.
- Title detection still runs on every chunk (needed for Claude entry).

- [ ] **Step 5: Run both new tests + the full server suite**

```bash
swift test --filter ClaudeRelayServerTests
```

Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeRelayServer/Actors/SessionActivityMonitor.swift \
        Tests/ClaudeRelayServerTests/SessionActivityMonitorTests.swift
git commit -m "perf(server): skip ANSI regex on hot path when Claude is not running"
```

---

## Task 3: Back off foreground-process polling for detached sessions

**Why this matters:** `PTYSession.swift:172` starts a 1 s `DispatchSourceTimer` per session and walks process ancestry up to 5 hops on every tick. CLAUDE.md explicitly says activity monitoring must continue for detached sessions (so background iOS tabs reflect Claude state). We can't pause the timer on detach — but we CAN slow it down. 1 s is tuned for responsive entry detection on the *attached* session the user is looking at; detached sessions don't need that responsiveness. 5 s is plenty.

**Files:**
- Modify: `Sources/ClaudeRelayServer/Actors/PTYSession.swift:172-188` + add attach/detach hooks
- Modify: `Sources/ClaudeRelayServer/Actors/PTYSession.swift:7-20` (protocol surface)
- Modify: `Sources/ClaudeRelayServer/Actors/SessionManager.swift` attach/detach call sites
- Test: `Tests/ClaudeRelayServerTests/PTYSessionTests.swift` (if present) or manual check

- [ ] **Step 1: Add `setPollCadence` on `PTYSessionProtocol`**

In `Sources/ClaudeRelayServer/Actors/PTYSession.swift`, extend the protocol at the top:

```swift
public protocol PTYSessionProtocol: Actor {
    var sessionId: UUID { get }
    func startReading()
    func setOutputHandler(_ handler: @escaping @Sendable (Data) -> Void)
    func setExitHandler(_ handler: @escaping @Sendable () -> Void)
    func clearOutputHandler()
    func write(_ data: Data)
    func resize(cols: UInt16, rows: UInt16)
    func readBuffer() -> Data
    func terminate()
    func getActivityState() -> ActivityState
    func setActivityHandler(_ handler: @escaping @Sendable (ActivityState) -> Void)
    func recordInput()
    /// 1.0 for attached (responsive entry detection); 5.0 for detached.
    func setPollCadence(_ seconds: TimeInterval)
}
```

- [ ] **Step 2: Implement `setPollCadence` on `PTYSession`**

Add after `startForegroundPoll()` in `Sources/ClaudeRelayServer/Actors/PTYSession.swift`:

```swift
    /// Adjust the foreground-process polling interval. Attached sessions use
    /// 1.0 s for responsive Claude-entry detection; detached sessions use 5.0 s
    /// so many-session deployments don't pay the full poll cost per second.
    public func setPollCadence(_ seconds: TimeInterval) {
        guard let timer = foregroundPollTimer else { return }
        timer.schedule(deadline: .now() + seconds, repeating: seconds)
    }
```

`DispatchSourceTimer.schedule(deadline:repeating:)` is safe to call on an already-resumed timer and takes effect on the next tick — no need to cancel/recreate.

- [ ] **Step 3: Wire attach/detach in `SessionManager` to drive cadence**

In `Sources/ClaudeRelayServer/Actors/SessionManager.swift` `attachSession` (around line 141), right before `return (newInfo, pty)`:

```swift
        // Attached: bump to 1 s poll for responsive Claude entry/exit.
        Task { await pty.setPollCadence(1.0) }
```

And in `detachSession` (around line 187, after the "Clear output handler" Task block), add:

```swift
        // Detached: slow the poll to 5 s — we still need activity for background
        // iOS tabs, but 1 s resolution is only needed for the user's foreground session.
        if let pty = managed.ptySession {
            Task { await pty.setPollCadence(5.0) }
        }
```

(The existing `clearOutputHandler` Task is already there; add this as a second Task block right after it.)

- [ ] **Step 4: Mock-protocol conformance fix**

Any test mocks conforming to `PTYSessionProtocol` will now fail to compile. Find them:

```bash
grep -rn "PTYSessionProtocol" Tests/
```

For each mock found, add the minimal stub:

```swift
    func setPollCadence(_ seconds: TimeInterval) {}
```

- [ ] **Step 5: Build + test**

```bash
swift build
swift test --filter ClaudeRelayServerTests
```

Expected: green. (Attach/detach flows are exercised by the existing session-lifecycle tests; an explicit cadence test would require a clock abstraction — skip for now, the behavior is observable only as a performance characteristic.)

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeRelayServer/Actors/PTYSession.swift \
        Sources/ClaudeRelayServer/Actors/SessionManager.swift \
        Tests/
git commit -m "perf(server): slow foreground-process poll to 5s while detached"
```

---

## Task 4: Cache activity state in SessionManager — make listing zero-await

**Why this matters:** `SessionManager.listSessionsForToken` and `listAllSessionsForToken` at lines 350 and 374 each `await pty.getActivityState()` once per session — crossing the actor hop serially. `SessionInfo.activity` already exists; `reportActivityChange` (line 421) already receives every change. We can maintain the latest activity on `ManagedSession` and serve listing from the manager's own state with zero awaits.

**Files:**
- Modify: `Sources/ClaudeRelayServer/Actors/SessionManager.swift` (ManagedSession struct + list methods + reportActivityChange + createSession seeding)
- Test: `Tests/ClaudeRelayServerTests/SessionManagerTests.swift` (check first)

- [ ] **Step 1: Extend `ManagedSession` with an activity cache**

In `Sources/ClaudeRelayServer/Actors/SessionManager.swift:29-33`:

```swift
    struct ManagedSession {
        var info: SessionInfo
        var ptySession: (any PTYSessionProtocol)?
        var terminalSince: Date?
        /// Latest activity reported by the PTY's monitor. Updated from
        /// `reportActivityChange` so `listSessionsForToken` can return a
        /// snapshot without hopping into each PTY actor.
        var latestActivity: ActivityState = .active
    }
```

- [ ] **Step 2: Update `reportActivityChange` to cache the state**

Replace `reportActivityChange` (line 421):

```swift
    public func reportActivityChange(sessionId: UUID, activity: ActivityState) {
        guard var managed = sessions[sessionId] else { return }
        guard !managed.info.state.isTerminal else { return }
        managed.latestActivity = activity
        sessions[sessionId] = managed
        let tokenId = managed.info.tokenId
        for (_, observer) in activityObservers where observer.tokenId == tokenId {
            observer.callback(sessionId, activity)
        }
    }
```

- [ ] **Step 3: Seed the cache in `createSession`**

In `createSession`, right after `let managed = ManagedSession(info: activeInfo, ptySession: pty)` (line 72):

```swift
        var managed = ManagedSession(info: activeInfo, ptySession: pty)
        managed.latestActivity = .active
```

(Change `let` → `var` for that declaration. `.active` is the correct initial state — it matches `SessionActivityMonitor.state`'s default at line 20.)

- [ ] **Step 4: Convert list methods to synchronous + zero-await**

Replace `listSessionsForToken` (line 350):

```swift
    /// List sessions for a specific token. Uses the cached activity state
    /// maintained via `reportActivityChange` — no PTY actor hops.
    public func listSessionsForToken(tokenId: String) -> [SessionInfo] {
        var results: [SessionInfo] = []
        for managed in sessions.values where managed.info.tokenId == tokenId {
            let info = managed.info
            results.append(SessionInfo(
                id: info.id, name: info.name, state: info.state,
                tokenId: info.tokenId, createdAt: info.createdAt,
                cols: info.cols, rows: info.rows,
                activity: managed.latestActivity
            ))
        }
        return results
    }
```

And `listAllSessions` (line 374) the same way, without the `tokenId` filter:

```swift
    public func listAllSessions() -> [SessionInfo] {
        var results: [SessionInfo] = []
        for managed in sessions.values {
            let info = managed.info
            results.append(SessionInfo(
                id: info.id, name: info.name, state: info.state,
                tokenId: info.tokenId, createdAt: info.createdAt,
                cols: info.cols, rows: info.rows,
                activity: managed.latestActivity
            ))
        }
        return results
    }
```

Both drop the `async` keyword. (Actor methods are awaited from outside either way; this is a minor source-compat change for any non-test callers — see next step.)

- [ ] **Step 5: Callers of list methods**

`RelayMessageHandler.swift:445` and `:457` already `await` these — `await` against a non-async actor method is fine, the compiler will just drop the async semantics where not needed. No change required.

Also fix `addActivityObserver` (line 399-413): the initial-state push currently awaits `pty.getActivityState()`. Use the cache:

```swift
    @discardableResult
    public func addActivityObserver(
        tokenId: String,
        callback: @escaping ActivityObserver
    ) -> UUID {
        let observerId = UUID()
        activityObservers[observerId] = (tokenId: tokenId, callback: callback)

        // Push current (cached) activity state for this token's sessions so the
        // client doesn't wait for a change event to render correct state.
        for managed in sessions.values where managed.info.tokenId == tokenId {
            guard !managed.info.state.isTerminal else { continue }
            callback(managed.info.id, managed.latestActivity)
        }
        return observerId
    }
```

Note the function is no longer async.

Fix the one async call site at `RelayMessageHandler.swift:211`: `await manager.addActivityObserver(...)` — drop the `await` if the compiler warns; otherwise leave (harmless).

- [ ] **Step 6: Build + test**

```bash
swift build
swift test --filter ClaudeRelayServerTests
```

Expected: green. The existing tests cover list content; the activity field will now be served from the cache.

- [ ] **Step 7: Commit**

```bash
git add Sources/ClaudeRelayServer/Actors/SessionManager.swift \
        Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift
git commit -m "perf(server): serve session listings from cached activity, no actor hops"
```

---

## Task 5: Lightweight ping-only ServerStatusChecker probe

**Why this matters:** `Sources/ClaudeRelayClient/ViewModels/ServerStatusChecker.swift:61` currently opens a WebSocket, authenticates, lists sessions, and disconnects — every 15 s, for every saved server. The only thing the server list UI actually needs from this is `isLive` (a dot indicator). The session count is a nice-to-have, and it's the same as what `fetchSessions` provides when you actually connect to a server. Dropping session-list from the probe removes an auth + roundtrip from every poll.

We keep the 5 s timeout and the per-server `TaskGroup` fan-out — those are already fine.

**Files:**
- Modify: `Sources/ClaudeRelayClient/ViewModels/ServerStatusChecker.swift`
- UI call sites: search for `.sessionCount` to make sure this doesn't break displayed UI

- [ ] **Step 1: Check how `ServerStatus.sessionCount` is consumed**

```bash
grep -rn "sessionCount" Sources/ ClaudeRelayApp/ ClaudeRelayMac/ Tests/
```

Read each hit. If `sessionCount` is displayed in the server list UI, we need to keep it. If it's unused (no UI reads it), drop it entirely.

- [ ] **Step 2: Update the probe**

If `sessionCount` is in use in UI, keep `ServerStatus` as-is and just change the probe body. If it isn't used, drop `sessionCount` from the struct. Either way, replace `probe(config:)`:

```swift
    @MainActor
    static func probe(config: ConnectionConfig) async -> ServerStatus {
        guard let token = try? AuthManager.shared.loadToken(for: config.id),
              !token.isEmpty else {
            return ServerStatus()
        }

        let connection = RelayConnection()
        let controller = SessionController(connection: connection)

        let result = await withTaskGroup(of: ServerStatus.self) { group -> ServerStatus in
            group.addTask { @MainActor in
                do {
                    try await connection.connect(config: config, token: token)
                    // Auth proves the server is live, the token is valid, and
                    // the protocol version matches. We skip listSessions — it
                    // costs an extra round-trip and the session list UI hits
                    // the server directly when the user actually selects it.
                    try await controller.authenticate(token: token)
                    connection.disconnect()
                    return ServerStatus(isLive: true, sessionCount: 0)
                } catch {
                    connection.disconnect()
                    return ServerStatus()
                }
            }

            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return ServerStatus()
            }

            let first = await group.next() ?? ServerStatus()
            group.cancelAll()
            return first
        }

        connection.disconnect()
        return result
    }
```

If `sessionCount` isn't used anywhere, also:
  - Drop `sessionCount` from `ServerStatus` and simplify the constructors.

- [ ] **Step 3: Build + check**

```bash
swift build
swift test --filter ClaudeRelayClientTests
```

Also open both apps in Xcode and confirm the server list dot still flips live/dead on start/stop of the local server. If `sessionCount` was kept, confirm the number no longer updates on the list view — if it was displayed, this is a visible change we may need to either restore (by making the lite probe also list) or hide in the UI.

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeRelayClient/ViewModels/ServerStatusChecker.swift
# plus UI files if you touched them
git commit -m "perf(client): server status probe only does auth, skip session list"
```

---

## Task 6: LRU-bound the terminal view cache + byte-cap pendingOutput

**Why this matters:** `SharedSessionCoordinator.cachedTerminalViews` (and `terminalViewModels`) grow every time a session is attached. They're evicted only on session end / workspace teardown / stolen, not on "user is managing many sessions across hours." For a power user with 20+ sessions, we're holding 20 `TerminalView`s (with full SwiftTerm scrollback buffers) in RAM forever. Simple LRU fixes it.

Separately, `TerminalViewModel.pendingOutput` is also unbounded: if the terminal view never calls `terminalReady()` for some reason (bug, race), `pendingOutput` grows without limit. Cap it by bytes.

**Files:**
- Modify: `Sources/ClaudeRelayClient/ViewModels/SharedSessionCoordinator.swift`
- Modify: `Sources/ClaudeRelayClient/ViewModels/TerminalViewModel.swift`
- Test: `Tests/ClaudeRelayClientTests/TerminalViewModelTests.swift`, `Tests/ClaudeRelayClientTests/SharedSessionCoordinatorTests.swift` (if present)

- [ ] **Step 1: Byte-cap `pendingOutput` in `TerminalViewModel`**

Add to `Sources/ClaudeRelayClient/ViewModels/TerminalViewModel.swift:44` area:

```swift
    private var pendingOutput: [Data] = []
    private var pendingOutputBytes: Int = 0
    private static let pendingOutputByteLimit: Int = 4 * 1024 * 1024 // 4 MB
```

Replace `receiveOutput(_:)`:

```swift
    /// Receives terminal output from the coordinator's I/O routing.
    public func receiveOutput(_ data: Data) {
        if terminalSized, let handler = onTerminalOutput {
            handler(data)
        } else {
            pendingOutput.append(data)
            pendingOutputBytes += data.count
            // Cap pending buffer. If the terminal never calls terminalReady()
            // (layout stuck, bug, etc.), drop oldest chunks instead of growing
            // unboundedly. The ring buffer on the server will re-send anything
            // we drop on next attach/resume.
            while pendingOutputBytes > Self.pendingOutputByteLimit, !pendingOutput.isEmpty {
                let dropped = pendingOutput.removeFirst()
                pendingOutputBytes -= dropped.count
            }
        }
        detectInputPrompt(data)
    }
```

Keep `pendingOutput.removeAll()` sites in sync:
- `terminalReady()` (line 85): after `pendingOutput.removeAll()`, add `pendingOutputBytes = 0`.
- `prepareForSwitch()` (line 107): same.

- [ ] **Step 2: Test for the byte cap**

Add to `Tests/ClaudeRelayClientTests/TerminalViewModelTests.swift`:

```swift
    func testPendingOutputByteCapEvictsOldest() {
        let vm = makeVM()
        // Build a 5 MB payload in small chunks so we exceed the 4 MB cap.
        let chunk = Data(repeating: 0x41, count: 64 * 1024) // 64 KB
        for _ in 0..<80 { // 80 * 64 KB = 5 MB
            vm.receiveOutput(chunk)
        }

        var received = [Data]()
        vm.onTerminalOutput = { received.append($0) }
        vm.terminalReady()

        // After cap: at most ~4 MB survived, which is 64 chunks.
        let totalBytes = received.reduce(0) { $0 + $1.count }
        XCTAssertLessThanOrEqual(totalBytes, 4 * 1024 * 1024 + 64 * 1024,
            "pending buffer should have been capped to ~4MB")
        XCTAssertGreaterThan(totalBytes, 3 * 1024 * 1024,
            "cap should be at least 3MB or thereabouts")
    }
```

Run: `swift test --filter testPendingOutputByteCapEvictsOldest`
Expected: PASS.

- [ ] **Step 3: LRU for `cachedTerminalViews` / `terminalViewModels`**

In `Sources/ClaudeRelayClient/ViewModels/SharedSessionCoordinator.swift`, add near the other cache properties (around line 81):

```swift
    /// LRU order of session ids for the terminal cache. Most-recently used at the end.
    /// When `cachedTerminalViews.count` exceeds `terminalCacheLimit`, the front is evicted.
    private var terminalLRU: [UUID] = []
    /// Maximum number of cached live terminal views. Beyond this, the
    /// least-recently-used one is evicted (its SwiftTerm scrollback goes;
    /// subsequent attach replays from the server's ring buffer).
    private static let terminalCacheLimit: Int = 8
```

Replace `registerLiveTerminal`:

```swift
    public func registerLiveTerminal(for sessionId: UUID, view: AnyObject) {
        cachedTerminalViews[sessionId] = view
        sessionsWithLiveTerminal.insert(sessionId)
        touchTerminalLRU(sessionId)
        enforceTerminalCacheLimit()
    }
```

Add a helper:

```swift
    /// Records a session as recently used. Called on register and on switchTo.
    private func touchTerminalLRU(_ id: UUID) {
        terminalLRU.removeAll(where: { $0 == id })
        terminalLRU.append(id)
    }

    /// If we're over the cache limit, evict the LRU session's view/VM, but
    /// never evict the currently active one.
    private func enforceTerminalCacheLimit() {
        while cachedTerminalViews.count > Self.terminalCacheLimit,
              let victim = terminalLRU.first(where: { $0 != activeSessionId }) else {
            break
            evictTerminal(for: victim)
        }
    }
```

That's not quite right — `while` and an early `break` don't mix that way. Use this instead:

```swift
    private func enforceTerminalCacheLimit() {
        while cachedTerminalViews.count > Self.terminalCacheLimit {
            guard let victim = terminalLRU.first(where: { $0 != activeSessionId }) else { return }
            evictTerminal(for: victim)
        }
    }
```

And make `evictTerminal` keep LRU consistent:

```swift
    public func evictTerminal(for sessionId: UUID) {
        cachedTerminalViews.removeValue(forKey: sessionId)
        sessionsWithLiveTerminal.remove(sessionId)
        terminalViewModels.removeValue(forKey: sessionId)
        terminalLRU.removeAll(where: { $0 == sessionId })
    }
```

Call `touchTerminalLRU` on active switches. In `switchToSession(id:)` (around line 472), right after `activeSessionId = id`:

```swift
            touchTerminalLRU(id)
            enforceTerminalCacheLimit()
```

And in `attachRemoteSession` (line 514) same spot. And in `createNewSession` (line 429).

- [ ] **Step 4: Test LRU eviction**

Add to `Tests/ClaudeRelayClientTests/` in a new or existing coordinator test file (if there's no coordinator test file yet, create `SharedSessionCoordinatorTests.swift`):

```swift
@MainActor
final class TerminalCacheLRUTests: XCTestCase {

    func testCacheEvictsLRUBeyondLimit() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "t")

        // Register 10 fake views. Limit is 8 — expect oldest 2 to be evicted.
        var ids: [UUID] = []
        for _ in 0..<10 {
            let id = UUID()
            ids.append(id)
            coordinator.registerLiveTerminal(for: id, view: NSObject()) // AnyObject dummy
        }

        XCTAssertEqual(coordinator.cachedTerminalViews.count, 8)
        XCTAssertNil(coordinator.cachedTerminalView(for: ids[0]))
        XCTAssertNil(coordinator.cachedTerminalView(for: ids[1]))
        XCTAssertNotNil(coordinator.cachedTerminalView(for: ids[2]))
        XCTAssertNotNil(coordinator.cachedTerminalView(for: ids[9]))
    }

    func testActiveSessionNotEvictedByLRU() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "t")

        let pinned = UUID()
        coordinator.registerLiveTerminal(for: pinned, view: NSObject())
        coordinator.activeSessionId = pinned

        // Fill up and then some.
        for _ in 0..<15 {
            coordinator.registerLiveTerminal(for: UUID(), view: NSObject())
        }

        XCTAssertNotNil(coordinator.cachedTerminalView(for: pinned),
            "active session should never be evicted by LRU")
        XCTAssertLessThanOrEqual(coordinator.cachedTerminalViews.count, 8)
    }
}
```

Run: `swift test --filter TerminalCacheLRUTests`
Expected: both pass.

- [ ] **Step 5: Full client test suite + apps sanity**

```bash
swift test --filter ClaudeRelayClientTests
```

Expected: green.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeRelayClient/ViewModels/TerminalViewModel.swift \
        Sources/ClaudeRelayClient/ViewModels/SharedSessionCoordinator.swift \
        Tests/ClaudeRelayClientTests/
git commit -m "perf(client): LRU-bound terminal cache at 8; byte-cap pending terminal output"
```

---

## Task 7: Stop refocusing the terminal on every macOS render; share the SessionTab flash timer

**Why this matters:**
- `ClaudeRelayMac/Views/TerminalContainerView.swift:128` calls `view?.window?.makeFirstResponder(view)` in every `updateNSView` — SwiftUI calls this on many triggers (size change, coordinator publish, tab switch). Refocusing when focus is already correct is wasted work and can steal focus from modals. The iOS side already guards on "only on session change".
- `ClaudeRelayApp/Views/ActiveTerminalView.swift:262` instantiates `Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()` per `SessionTab`. With 5 sessions, that's 5 fire-every-500 ms timers. Replace with a single shared `TimelineView` or state object.

**Files:**
- Modify: `ClaudeRelayMac/Views/TerminalContainerView.swift:87-131`
- Modify: `ClaudeRelayApp/Views/ActiveTerminalView.swift:243-290`

- [ ] **Step 1: Refocus only on session change (macOS)**

Add a coordinator-tracked ID to the representable:

```swift
struct TerminalContainerView: NSViewRepresentable {
    @ObservedObject var coordinator: SessionCoordinator
    var fontSize: CGFloat

    // Track which session this host currently has focused, so we only issue
    // makeFirstResponder when the active session actually changes.
    final class FocusState {
        var lastFocusedId: UUID?
    }

    func makeCoordinator() -> FocusState { FocusState() }

    func makeNSView(context: Context) -> NSView {
        let host = NSView(frame: .zero)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.black.cgColor
        return host
    }
```

Replace the focus block at the bottom of `updateNSView`:

```swift
        if context.coordinator.lastFocusedId != activeId {
            context.coordinator.lastFocusedId = activeId
            DispatchQueue.main.async { [weak view = cached.view] in
                view?.window?.makeFirstResponder(view)
            }
        }
```

- [ ] **Step 2: Share the flash timer across tabs**

Replace `SessionTab` in `ClaudeRelayApp/Views/ActiveTerminalView.swift:243-290`:

```swift
/// Individual session tab. Receives its flash phase from a shared clock in the
/// parent so we don't spin up one Timer.publish per tab.
private struct SessionTab: View {
    let number: Int
    let isSelected: Bool
    let isClaude: Bool
    let needsAttention: Bool
    /// Shared flash phase driven by the parent's TimelineView. Tabs that don't
    /// need attention ignore this entirely.
    let flashOn: Bool

    var body: some View {
        Text("\(number)")
            .font(.system(size: 12, weight: isSelected ? .bold : .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .frame(minWidth: 26, minHeight: 22)
            .background(tabBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(selectionBorderColor, lineWidth: isSelected ? 2 : 0)
            )
            .animation(.easeInOut(duration: 0.15), value: flashOn)
    }

    private var selectionBorderColor: SwiftUI.Color { .white }

    private var tabBackground: SwiftUI.Color {
        if needsAttention {
            return flashOn ? SwiftUI.Color.orange : SwiftUI.Color.white.opacity(0.15)
        }
        if isClaude { return SwiftUI.Color.orange }
        return SwiftUI.Color.white.opacity(0.15)
    }
}
```

In the parent view that renders the tabs, wrap them in `TimelineView`:

```swift
TimelineView(.periodic(from: .now, by: 0.5)) { context in
    let phaseOn = (Int(context.date.timeIntervalSinceReferenceDate * 2) % 2) == 0
    HStack(spacing: 6) {
        ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
            SessionTab(
                number: index + 1,
                isSelected: session.id == coordinator.activeSessionId,
                isClaude: coordinator.isRunningClaude(sessionId: session.id),
                needsAttention: coordinator.sessionsAwaitingInput.contains(session.id),
                flashOn: phaseOn
            )
            // ...existing onTapGesture etc.
        }
    }
}
```

Find the tab-strip container in the existing file (scroll/grep the file for `SessionTab(` to locate it) and adapt the surrounding layout accordingly. If the existing tab strip is in a scroll view or `ScrollView` wrapping the TimelineView is fine.

Note: `TimelineView(.periodic(from:by:))` only publishes updates while its view is on-screen, which is exactly what we want — off-screen cost is zero.

- [ ] **Step 3: Build + visual check**

Build and run both apps. Confirm:
- macOS: typing still works (focus is there), bringing up a modal doesn't re-steal focus.
- iOS: attention-flashing tabs still pulse at 2 Hz; non-attention tabs don't animate.

```bash
swift build
swift test
```

- [ ] **Step 4: Commit**

```bash
git add ClaudeRelayMac/Views/TerminalContainerView.swift \
        ClaudeRelayApp/Views/ActiveTerminalView.swift
git commit -m "perf(apps): refocus only on session change; share flash timer across tabs"
```

---

## Task 8: Make TerminalViewModel's input-prompt threshold injectable (faster tests)

**Why this matters:** Three tests in `Tests/ClaudeRelayClientTests/TerminalViewModelTests.swift:93, :110, :123` sleep for 1.0 s – 2.2 s each to validate the debounced input-prompt detection. That's ~4.5 s of the test suite run time. Injecting the thresholds as a config drops it to ~400 ms without changing production behaviour.

**Files:**
- Modify: `Sources/ClaudeRelayClient/ViewModels/TerminalViewModel.swift` — extract thresholds, allow override via init.
- Modify: `Tests/ClaudeRelayClientTests/TerminalViewModelTests.swift` — use short thresholds.

- [ ] **Step 1: Extract thresholds as an init param with current defaults**

At the top of `Sources/ClaudeRelayClient/ViewModels/TerminalViewModel.swift` add:

```swift
public struct InputPromptThresholds: Sendable {
    public let normal: Duration
    public let claudeActive: Duration
    public init(normal: Duration = .milliseconds(1000),
                claudeActive: Duration = .milliseconds(2000)) {
        self.normal = normal
        self.claudeActive = claudeActive
    }
}
```

Add a stored property and extend the initializer:

```swift
    private let promptThresholds: InputPromptThresholds

    public init(
        sessionId: UUID,
        connection: RelayConnection,
        promptThresholds: InputPromptThresholds = InputPromptThresholds()
    ) {
        self.sessionId = sessionId
        self.connection = connection
        self.connectionState = connection.state
        self.promptThresholds = promptThresholds
        // ...existing body unchanged...
    }
```

Use in `detectInputPrompt`:

```swift
    private func detectInputPrompt(_ data: Data) {
        promptDebounceTask?.cancel()
        promptDebounceTask = nil

        if awaitingInput { setAwaitingInput(false) }

        let threshold = isClaudeActive ? promptThresholds.claudeActive : promptThresholds.normal
        promptDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: threshold)
            guard !Task.isCancelled else { return }
            self?.setAwaitingInput(true)
        }
    }
```

- [ ] **Step 2: Update existing tests to use short thresholds**

Replace `makeVM` in `Tests/ClaudeRelayClientTests/TerminalViewModelTests.swift`:

```swift
    private func makeVM(normal: Duration = .milliseconds(80),
                       claudeActive: Duration = .milliseconds(160)) -> TerminalViewModel {
        let connection = RelayConnection()
        return TerminalViewModel(
            sessionId: UUID(),
            connection: connection,
            promptThresholds: InputPromptThresholds(
                normal: normal,
                claudeActive: claudeActive
            )
        )
    }
```

Shrink sleeps in the three time-sensitive tests. Replace the bodies:

```swift
    func testSendInputClearsAwaitingInput() async throws {
        let vm = makeVM()
        var received = [Data]()
        vm.onTerminalOutput = { received.append($0) }
        vm.terminalReady()

        vm.receiveOutput(Data([0x24, 0x20]))
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(vm.awaitingInput)

        vm.sendInput(Data([0x0A]))
        XCTAssertFalse(vm.awaitingInput)
    }

    func testAwaitingInputCallbackFires() async throws {
        let vm = makeVM()
        var received = [Data]()
        vm.onTerminalOutput = { received.append($0) }
        vm.terminalReady()

        var transitions = [Bool]()
        vm.onAwaitingInputChanged = { transitions.append($0) }

        vm.receiveOutput(Data([0x24, 0x20]))
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(transitions, [true])
    }

    func testClaudeActiveUsesLongerThreshold() async throws {
        let vm = makeVM()
        var received = [Data]()
        vm.onTerminalOutput = { received.append($0) }
        vm.terminalReady()
        vm.isClaudeActive = true

        vm.receiveOutput(Data([0x24, 0x20]))
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(vm.awaitingInput, "Should not trigger before claudeActive threshold")

        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(vm.awaitingInput, "Should trigger after claudeActive threshold elapses")
    }
```

Production callers pass nothing (default = 1.0 s / 2.0 s, same as today), so there's no behavior change for users.

- [ ] **Step 3: Run tests**

```bash
swift test --filter TerminalViewModelTests
```

Expected: all pass, and the filter completes in well under a second.

Also run the full suite — you haven't broken any other callers:

```bash
swift test
```

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeRelayClient/ViewModels/TerminalViewModel.swift \
        Tests/ClaudeRelayClientTests/TerminalViewModelTests.swift
git commit -m "test(client): make input-prompt thresholds injectable; shrink test sleeps"
```

---

## Task 9: Cap AdminHTTPServer request body size

**Why this matters:** `Sources/ClaudeRelayServer/Network/AdminHTTPServer.swift:80` appends every body byte into `requestBody` without a maximum. The admin API is localhost-only, so the blast radius is small, but it's still free hygiene to cap at a sane value (64 KB is an order of magnitude more than any legitimate admin request).

**Files:**
- Modify: `Sources/ClaudeRelayServer/Network/AdminHTTPServer.swift:72-124`
- Test: `Tests/ClaudeRelayServerTests/AdminHTTPServerTests.swift` (if present) — check first

- [ ] **Step 1: Check existing admin-server tests**

```bash
ls Tests/ClaudeRelayServerTests/ | grep -i admin
grep -rln "AdminHTTPHandler" Tests/
```

If tests exist, note their style. If not, we'll skip a unit test for this one (the change is defensive and has a visible 413 response path; tested end-to-end via `curl`).

- [ ] **Step 2: Add the cap**

Replace the handler class fields and `channelRead` opening:

```swift
    private static let maxRequestBodyBytes: Int = 64 * 1024

    private var requestHead: HTTPRequestHead?
    private var requestBody: ByteBuffer?
    private var requestBodyOverflow: Bool = false
```

Replace the `case .body` / `case .head` handling:

```swift
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head(let head):
            self.requestHead = head
            self.requestBodyOverflow = false
            let contentLength = head.headers.first(name: "content-length").flatMap(Int.init) ?? 256
            if contentLength > Self.maxRequestBodyBytes {
                self.requestBodyOverflow = true
                self.requestBody = nil
            } else {
                self.requestBody = context.channel.allocator.buffer(
                    capacity: min(contentLength, Self.maxRequestBodyBytes))
            }
        case .body(var body):
            if requestBodyOverflow { return }
            let current = requestBody?.readableBytes ?? 0
            if current + body.readableBytes > Self.maxRequestBodyBytes {
                requestBodyOverflow = true
                requestBody = nil
                return
            }
            self.requestBody?.writeBuffer(&body)
        case .end:
            if requestBodyOverflow {
                let response = AdminResponse.error("Request body too large", status: 413)
                writeResponse(response, context: context)
                self.requestHead = nil
                self.requestBody = nil
                self.requestBodyOverflow = false
                return
            }
            guard let head = requestHead else { return }
            // ...rest of the existing .end handling unchanged...
```

Leave everything else in `case .end` as-is.

- [ ] **Step 3: Smoke-test manually**

Start the server locally (use the CLI as CLAUDE.md mandates, not the binary):

```bash
swift run claude-relay load --ws-port 9200
swift run claude-relay status
# Normal request: fine
curl -s -X GET http://127.0.0.1:9100/sessions | head
# Oversized request: rejected with 413
curl -s -X POST --data-binary "$(printf 'A%.0s' {1..100000})" http://127.0.0.1:9100/token/create
swift run claude-relay unload
```

Expected: normal works; the oversized POST returns `{"error":"Request body too large"}` with HTTP 413.

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeRelayServer/Network/AdminHTTPServer.swift
git commit -m "chore(server): cap admin HTTP request body at 64KB with 413 on overflow"
```

---

## Task 10: Final regressions & local-artifact note

- [ ] **Step 1: Full test run from a clean build**

```bash
swift package clean
swift build
swift test
```

Expected: all green. (If `.build` was holding stale artifacts from earlier iterations, the clean catches it.)

- [ ] **Step 2: Manual smoke on both apps**

- iOS: build, attach to the local server, open 2 sessions, kill the server, restart it, confirm recovery UI flow and that both sessions come back.
- macOS: same checklist. Also confirm focus behaves (Task 7) — bring up a sheet, confirm focus isn't stolen back into the terminal while it's showing.

These aren't things `swift test` can catch — you have to eyeball them.

- [ ] **Step 3: Note on `.build`/`build` sizes (do NOT delete)**

Current working-tree artifact sizes:

```
.build  5.0G
build   1.6G
```

This isn't something to "fix" in this pass. The formula change in Task 1 will meaningfully shrink future `.build` on release-only builds (no WhisperKit/LLM.swift objects) — but a developer running `swift build` locally without `--product` flags will still pay the full cost, which is expected. If you want to reclaim space, `swift package clean` or just `rm -rf .build` is always safe (SwiftPM rebuilds from caches).

Also worth a follow-up ticket (out of scope here): `ClaudeRelayAppTests` target exists in the Xcode project but is not registered in `Package.swift`, so `swift test` skips it. Add it to Package.swift as a test target if it should run in CI.

- [ ] **Step 4: Final commit if you made any last-mile notes, otherwise nothing to commit**

---

## Self-review notes (recorded during drafting)

- **Spec coverage:** Covered items 1, 2, 4, 5, 6, 7, 9, 10, 12 from the findings list. Deliberately deferred: item 3 (client actor isolation) because the risk of perturbing recovery is high and there's no evidence of UI jank today; item 8 (audio allocation) because the allocations are tiny and infrequent; item 11 (token-store hash map) because scale doesn't justify it; item 13 (large-file refactor) because each is its own plan. Local artifact sizes (final note) acknowledged in Task 10.
- **Type consistency:** `ServerStatus` either keeps or drops `sessionCount` depending on UI usage — Task 5 Step 1 enforces the check before the code change.
- **Placeholder scan:** No "TBD", "add appropriate error handling", or similar placeholders.
- **Risk shape:** Every task is independently revertable. Tasks 2, 4, 5, 6, 8 ship tests. Tasks 1, 3, 7, 9, 10 have explicit manual/shell verification steps.
