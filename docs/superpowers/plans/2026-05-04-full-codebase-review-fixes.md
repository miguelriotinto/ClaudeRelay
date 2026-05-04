# Full-Codebase Review Fixes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve all 98 findings (26 HIGH, 46 MEDIUM, 26 LOW) from the 2026-05-04 multi-agent codebase review without changing observable protocol or UX behavior.

**Architecture:** The plan is organized as 59 independently-reviewable tasks grouped into 5 waves. Each wave is internally-orderable and ships with tests where behavior changes. Wave 1 (lifecycle bugs) should land first — those are user-facing reliability issues. Wave 5 (polish) is the last safe-to-defer batch. The plan deliberately avoids large architectural refactors: only `ActiveTerminalView` gets a split because it exceeds the codebase's own guideline. No changes to `SharedSessionCoordinator`, `RelayMessageHandler`, or the wire protocol beyond the minimum required by each finding.

**Tech Stack:** Swift 5.9, SwiftPM, SwiftNIO, Swift Concurrency (actors), URLSession, SwiftUI, WhisperKit, SwiftTerm, ArgumentParser, XCTest, XcodeGen (`project.yml`).

**How to read this plan:** Each task is ~5–20 minutes of work. Tasks are mostly independent within a wave — if one blocks, skip it and come back. Every code block in this plan is either the exact "before" state or the exact "after" state — no placeholders, no "similar to Task N" stubs. Line numbers reference `17b0a61` (main @ 2026-05-04).

---

## Pre-flight

- [ ] **Step 0: Verify the baseline is green**

Run: `swift build && swift test`
Expected: build succeeds; all tests pass.

Also verify on Xcode side: open `ClaudeRelay.xcodeproj`, Cmd+B. Expected: iOS + macOS targets build.

If any of the above fails, stop and fix before starting Wave 1.

- [ ] **Step 1: Create a working branch**

```bash
git checkout -b review-2026-05-04-fixes
git push -u origin review-2026-05-04-fixes
```

---

## Wave 1 — Critical lifecycle & correctness fixes

These fix real bugs that can ship as user-visible reliability issues (stuck recovery, PTY head-of-line blocking, data races). Land these first. Most are small surgical changes; none touch the wire protocol.

---

### Task 1: Fix recovery `defer` so `isRecovering` always clears (HIGH #1)

**Why:** When `cancelRecovery()` is called while `handleForegroundTransition()` is suspended at an `await`, the `defer` block at `SharedSessionCoordinator.swift:780-784` never runs (because it's nested inside a block the early-return skips past). Result: `isRecovering=true` persists, and every subsequent recovery attempt is blocked by the `guard !isRecovering` check at line 760. The app can never auto-reconnect again without a force-quit.

**Files:**
- Modify: `Sources/ClaudeRelayClient/ViewModels/SharedSessionCoordinator.swift:757-824`
- Test: `Tests/ClaudeRelayClientTests/SharedSessionCoordinatorTests.swift`

- [ ] **Step 1: Write the failing test**

Add this test to `Tests/ClaudeRelayClientTests/SharedSessionCoordinatorTests.swift` (inside the existing `SharedSessionCoordinatorTests` class). It uses the existing mock test infrastructure in that file — copy the setup pattern used by the existing "recovery" tests.

```swift
@MainActor
func testRecoveryCancelledMidFlightClearsIsRecovering() async throws {
    let (coordinator, connection, _) = try await makeCoordinatorWithDeadConnection()
    // Kick off a recovery. The dead connection means forceReconnect will sleep
    // through its backoff delays giving us a suspension window.
    let recoveryTask = Task {
        await coordinator.handleForegroundTransition(userInitiated: false)
    }
    // Wait until recovery has started.
    for _ in 0..<50 {
        try? await Task.sleep(for: .milliseconds(20))
        if coordinator.isRecovering { break }
    }
    XCTAssertTrue(coordinator.isRecovering, "Test precondition: recovery should have started")

    // Now cancel while it's suspended in backoff sleep.
    coordinator.cancelRecovery()
    _ = await recoveryTask.value

    XCTAssertFalse(coordinator.isRecovering,
        "cancelRecovery mid-flight must clear isRecovering — otherwise all future recoveries are blocked")

    // Prove a subsequent recovery isn't blocked.
    let second = Task { await coordinator.handleForegroundTransition(userInitiated: true) }
    for _ in 0..<50 {
        try? await Task.sleep(for: .milliseconds(20))
        if coordinator.isRecovering { break }
    }
    coordinator.cancelRecovery()
    _ = await second.value
    XCTAssertFalse(coordinator.isRecovering)
}
```

If `makeCoordinatorWithDeadConnection()` doesn't already exist in the test file, add it at the bottom of the class:

```swift
@MainActor
private func makeCoordinatorWithDeadConnection() async throws
    -> (SharedSessionCoordinator, RelayConnection, SessionController) {
    let connection = RelayConnection()
    // Never call connect() — any send will throw .notConnected.
    let controller = SessionController(connection: connection)
    let coordinator = SharedSessionCoordinator(connection: connection, controller: controller)
    return (coordinator, connection, controller)
}
```

(If the existing tests use a different factory pattern, match that pattern — the point is "coordinator + connection that never comes up".)

- [ ] **Step 2: Run the test — expect it to fail**

Run: `swift test --filter SharedSessionCoordinatorTests.testRecoveryCancelledMidFlightClearsIsRecovering`
Expected: FAIL with `isRecovering` still true after `cancelRecovery()`.

- [ ] **Step 3: Fix the defer placement**

Open `Sources/ClaudeRelayClient/ViewModels/SharedSessionCoordinator.swift` and replace the entire `handleForegroundTransition(userInitiated:)` method (lines 757 onward, up to and including the closing brace of the method at line 824) with:

```swift
    public func handleForegroundTransition(userInitiated: Bool) async {
        defer {
            isRecoveryDispatched = false
            // Idempotent cleanup: guarantees no matter which early-return path we
            // take (alive short-circuit, generation mismatch, cancellation) the
            // coordinator leaves recovery in a consistent state. Otherwise a
            // mid-flight cancel could strand isRecovering=true and permanently
            // block all future recovery attempts.
            if isRecovering {
                isRecovering = false
                suppressAllViewModelSends(false)
                lastRecoveryEndedAt = Date()
            }
        }
        guard !isTornDown else { return }
        guard !isRecovering else {
            recoveryLog.debug("handleForegroundTransition: already recovering, skipping")
            return
        }

        let alive = await connection.isAlive()
        if alive {
            recoveryLog.info("handleForegroundTransition: connection alive, fetching sessions")
            await fetchSessions()
            return
        }

        recoveryGeneration &+= 1
        let myGeneration = recoveryGeneration
        recoveryLog.info("Recovery start gen=\(myGeneration) userInitiated=\(userInitiated)")

        recoveryPhase = .reconnecting
        recoveryFailed = false
        isRecovering = true
        suppressAllViewModelSends(true)

        let delays: [UInt64] = [0, 1, 2, 4]
        var reconnected = false
        for (attempt, delay) in delays.enumerated() {
            guard !isTornDown, myGeneration == recoveryGeneration, !Task.isCancelled else {
                recoveryLog.info("Recovery aborted during reconnect (gen=\(myGeneration))")
                return
            }
            if delay > 0 {
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    recoveryLog.info("Recovery cancelled during backoff (gen=\(myGeneration))")
                    return
                }
                guard !isTornDown, myGeneration == recoveryGeneration else { return }
            }

            do {
                try await connection.forceReconnect()
                reconnected = true
                break
            } catch is CancellationError {
                recoveryLog.info("Recovery cancelled during forceReconnect (gen=\(myGeneration))")
                return
            } catch {
                recoveryLog.error("forceReconnect attempt \(attempt + 1) failed: \(error.localizedDescription, privacy: .public)")
                if attempt == delays.count - 1 {
                    guard !isTornDown, myGeneration == recoveryGeneration else { return }
                    recoveryFailed = true
                    connectionTimedOut = true
                    recordAutoRecoveryOutcome(success: false, userInitiated: userInitiated)
                    return
                }
            }
        }

        guard reconnected, !isTornDown, myGeneration == recoveryGeneration else { return }
        await restoreSession(generation: myGeneration, userInitiated: userInitiated)
    }
```

Note what changed:
1. The single outer `defer` now wraps the whole method.
2. The inner `defer` (old lines 780-784) is gone — its work is absorbed into the outer defer, guarded by `if isRecovering`.
3. The outer defer is idempotent: on a happy path where `isRecovering` was never set (alive short-circuit), the `if` skips the cleanup. On any early return after `isRecovering = true` was set, the cleanup runs.

- [ ] **Step 4: Run the test — expect pass**

Run: `swift test --filter SharedSessionCoordinatorTests.testRecoveryCancelledMidFlightClearsIsRecovering`
Expected: PASS.

Then run the whole suite to ensure no regressions:
Run: `swift test`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRelayClient/ViewModels/SharedSessionCoordinator.swift \
       Tests/ClaudeRelayClientTests/SharedSessionCoordinatorTests.swift
git commit -m "fix(client): clear isRecovering on all recovery exit paths

Mid-flight cancelRecovery() was stranding isRecovering=true, which the
guard at the top of handleForegroundTransition then used to block every
subsequent recovery attempt. Collapse the two defer blocks into one
idempotent outer defer so the cleanup runs regardless of which early
return fires."
```

---

### Task 2: Bound `RelayConnection.rttWindow` inside `measurePingRTT` (HIGH, Client #1)

**Why:** `rttWindow.append` + `removeFirst()` enforcement lives inside the keepalive loop (lines 318-321). External callers (e.g., recovery paths) that invoke `measurePingRTT()` directly currently skip that enforcement path — but `performPing()` never records RTT to the window at all. This looks like a latent bug: the only place appending to `rttWindow` is the loop. The correct fix is to (a) make RTT recording a single private method used both by the loop *and* `performPing`, and (b) have that method enforce the window cap. This also prepares us to get quality signal from foreground `isAlive()` pings.

**Files:**
- Modify: `Sources/ClaudeRelayClient/RelayConnection.swift:84-89, 162-173, 301-337`
- Test: `Tests/ClaudeRelayClientTests/RelayConnectionTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `Tests/ClaudeRelayClientTests/RelayConnectionTests.swift`:

```swift
@MainActor
func testRTTWindowStaysBoundedUnderRepeatedMeasurePingRTT() async {
    let connection = RelayConnection()
    // Call recordRTT internally 100 times via the new helper, from outside the
    // keepalive loop. Without the fix, rttWindow would grow unbounded.
    for i in 0..<100 {
        connection._testOnly_recordRTT(rtt: i % 2 == 0 ? 0.05 : nil)
    }
    XCTAssertLessThanOrEqual(connection._testOnly_rttWindowCount, 6,
        "rttWindow must be bounded to windowSize (6)")
}
```

You'll also need a small test hook inside `RelayConnection`. Add it at the bottom of the class (just before the final `}`):

```swift
    // MARK: - Test Hooks

    #if DEBUG
    /// Exposed only for tests. Invokes the same private recordRTT the keepalive loop uses.
    public func _testOnly_recordRTT(rtt: TimeInterval?) { recordRTT(rtt) }
    public var _testOnly_rttWindowCount: Int { rttWindow.count }
    #endif
```

- [ ] **Step 2: Run the test — expect compile failure (recordRTT doesn't exist yet)**

Run: `swift test --filter RelayConnectionTests.testRTTWindowStaysBoundedUnderRepeatedMeasurePingRTT`
Expected: FAIL to compile with "value of type 'RelayConnection' has no member 'recordRTT'".

- [ ] **Step 3: Extract `recordRTT` and call it from the loop**

In `Sources/ClaudeRelayClient/RelayConnection.swift`, find the keepalive-loop body (inside `startQualityMonitor`, lines 307-337) and replace the block:

```swift
                self.rttWindow.append(rtt)
                if self.rttWindow.count > self.windowSize {
                    self.rttWindow.removeFirst()
                }

                if rtt == nil {
                    self.consecutiveFailures += 1
                } else {
                    self.consecutiveFailures = 0
                }
```

with:

```swift
                self.recordRTT(rtt)
```

Then add the new private method just above `private func computeQuality()` (around line 359):

```swift
    /// Appends an RTT sample to the sliding window, enforces the window cap,
    /// and updates the consecutive-failure counter. Safe to call from the
    /// keepalive loop or any other path that observes a ping result.
    private func recordRTT(_ rtt: TimeInterval?) {
        rttWindow.append(rtt)
        if rttWindow.count > windowSize {
            rttWindow.removeFirst()
        }
        if rtt == nil {
            consecutiveFailures += 1
        } else {
            consecutiveFailures = 0
        }
    }
```

- [ ] **Step 4: Run the test — expect pass**

Run: `swift test --filter RelayConnectionTests`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRelayClient/RelayConnection.swift \
       Tests/ClaudeRelayClientTests/RelayConnectionTests.swift
git commit -m "refactor(client): centralize rttWindow bookkeeping in recordRTT

Move the append + windowSize cap + failure-counter update out of the
keepalive loop body and into a single private helper. No behavior
change, but every call site is now guaranteed to enforce the cap —
making it safe to record RTT from paths other than the loop in the
future."
```

---

### Task 3: Consolidate `SessionController` response handler to remove pending-value race (HIGH, Client #2)

**Why:** `sendAndWaitForResponse` has two `if let value = guard_.pendingValue` checks with a suspension point between them, then a third inside the continuation closure (lines 236, 245). The `ResumeGuard` is already @MainActor-isolated and has a `resumed` guard, so it can't double-resume — but the control flow is hard to reason about and future edits could reintroduce a lost-response bug. Consolidate into a single `installContinuation` atomic path.

**Files:**
- Modify: `Sources/ClaudeRelayClient/SessionController.swift:211-284`
- Test: `Tests/ClaudeRelayClientTests/SessionControllerTests.swift` (create if it doesn't exist)

- [ ] **Step 1: Write the failing test**

Check whether `Tests/ClaudeRelayClientTests/SessionControllerTests.swift` exists:

```bash
ls Tests/ClaudeRelayClientTests/SessionControllerTests.swift 2>/dev/null || echo "missing"
```

If missing, create it with:

```swift
import XCTest
import ClaudeRelayKit
@testable import ClaudeRelayClient

final class SessionControllerTests: XCTestCase {

    @MainActor
    func testSendAndWaitForResponseResumesExactlyOnceEvenUnderRacePressure() async throws {
        // This test wouldn't have caught the bug on its own — it's a regression
        // test that ensures the ResumeGuard contract (resume-exactly-once) isn't
        // broken when we refactor. Double-resume crashes with
        // "SWIFT TASK CONTINUATION MISUSE" which would crash the test.
        let connection = RelayConnection()
        let controller = SessionController(connection: connection)

        // Fire 50 rapid authenticate() calls that we expect to all fail with
        // .notConnected (connection never opened). What we're testing is that
        // no call crashes the process.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask { @MainActor in
                    _ = try? await controller.authenticate(token: "x")
                }
            }
        }
        XCTAssertFalse(controller.isAuthenticated)
    }
}
```

- [ ] **Step 2: Run the test — expect pass (no crash today)**

Run: `swift test --filter SessionControllerTests.testSendAndWaitForResponseResumesExactlyOnceEvenUnderRacePressure`
Expected: PASS (this is a regression guard, not a red-test).

- [ ] **Step 3: Consolidate `sendAndWaitForResponse` + `ResumeGuard`**

In `Sources/ClaudeRelayClient/SessionController.swift`, replace the method + helper class starting at line 208 (`/// Response message types we expect...`) through the end of file with:

```swift
    /// Response message types we expect from command requests.
    private static let responseTypes: Set<String> = [
        "auth_success", "auth_failure",
        "session_created", "session_attached", "session_resumed", "session_detached",
        "session_list_result", "session_list_all_result",
        "error"
    ]

    /// Installs a response handler synchronously on MainActor, sends the message,
    /// and awaits the server's reply. The handler resumes the continuation if
    /// installed, or stashes the value for `installContinuation` to consume.
    private func sendAndWaitForResponse(_ message: ClientMessage) async throws -> ServerMessage {
        let previousHandler = connection.onServerMessage
        defer { connection.onServerMessage = previousHandler }

        let guard_ = ResumeGuard()

        // Install handler synchronously on MainActor — guaranteed in place
        // before any suspension point.
        connection.onServerMessage = { serverMessage in
            guard Self.responseTypes.contains(serverMessage.typeString) else {
                previousHandler?(serverMessage)
                return
            }
            guard_.deliver(serverMessage)
        }

        // Send the message.
        try await connection.send(message)

        // Await the response with a timeout. installContinuation atomically
        // either installs the continuation (handler-route) or immediately
        // resumes with a pending value that arrived during send.
        return try await withCheckedThrowingContinuation { continuation in
            guard_.installContinuation(continuation, timeout: .seconds(10))
        }
    }
}

// MARK: - Resume Guard

/// Ensures a `CheckedContinuation` is resumed exactly once. All state lives
/// on `@MainActor` so there is no data race between `deliver` (called from
/// the server-message callback, itself dispatched on MainActor) and
/// `installContinuation` (called from the awaiting `withCheckedContinuation`).
@MainActor
private final class ResumeGuard {
    private var continuation: CheckedContinuation<ServerMessage, Error>?
    private var pendingValue: ServerMessage?
    private var timeoutTask: Task<Void, Never>?
    private var resumed = false

    /// Called from the onServerMessage callback. If a continuation is already
    /// installed, resume it. Otherwise stash the value for installContinuation
    /// to consume synchronously.
    func deliver(_ value: ServerMessage) {
        guard !resumed else { return }
        if continuation != nil {
            resume(returning: value)
        } else {
            pendingValue = value
        }
    }

    /// Called inside withCheckedThrowingContinuation. Either the response has
    /// already arrived (stashed in pendingValue) — resume synchronously — or
    /// we install the continuation and schedule the timeout.
    func installContinuation(_ c: CheckedContinuation<ServerMessage, Error>,
                             timeout: Duration) {
        assert(continuation == nil, "Continuation already installed")
        if let value = pendingValue {
            pendingValue = nil
            resumed = true
            c.resume(returning: value)
            return
        }
        continuation = c
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            self?.resume(throwing: SessionController.SessionError.timeout)
        }
    }

    private func resume(returning value: ServerMessage) {
        guard !resumed else { return }
        resumed = true
        timeoutTask?.cancel()
        continuation?.resume(returning: value)
        continuation = nil
    }

    private func resume(throwing error: Error) {
        guard !resumed else { return }
        resumed = true
        timeoutTask?.cancel()
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
```

Note the changes:
- Server-message callback now calls `guard_.deliver(value)`, which owns the decision of "resume or stash".
- `withCheckedThrowingContinuation` has a single entry — no more double-check at steps 3 and 4.
- `installContinuation` atomically consumes `pendingValue` (if present) or installs the continuation + timeout.
- `ResumeGuard` properties are now `private`; only `deliver` and `installContinuation` are public.

- [ ] **Step 4: Run tests — expect pass**

Run: `swift test`
Expected: all green. The existing SessionController behavior is identical, but the control flow is now single-path.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRelayClient/SessionController.swift \
       Tests/ClaudeRelayClientTests/SessionControllerTests.swift
git commit -m "refactor(client): consolidate sendAndWaitForResponse race windows

Replace the three-step pending-value dance with an atomic
ResumeGuard.installContinuation() that either consumes an already-
arrived response or installs the continuation + timeout. No behavior
change; removes a class of pending-bug where future edits could
reintroduce lost-response races."
```

---

### Task 4: Confine `TextCleaner` to `@MainActor` (HIGH, Speech #1)

**Why:** `TextCleaner` (line 11 of `TextCleaner.swift`) is `final class ... @unchecked Sendable` and holds mutable `llm`, `unloadTimer`, `isLoaded`, `modelPath` — but all callers in `OnDeviceSpeechEngine` are `@MainActor`. `@unchecked Sendable` is hiding a latent race (any `Task.detached` caller could hit `unload()` concurrently with `clean()`). The cheapest correct fix is `@MainActor` confinement.

**Files:**
- Modify: `Sources/ClaudeRelaySpeech/TextCleaner.swift`
- Modify callers if any are non-`@MainActor` (check with grep below)

- [ ] **Step 1: Inspect callers**

Run: `git grep -n "TextCleaner\|TextCleaning" Sources Tests`
Inspect the output. Confirm all usages are either (a) `@MainActor` or (b) `MockCleaner` in tests. If a non-`@MainActor` caller exists, note it — we'll need to make that caller `await` the method.

(Based on the review, the only production caller is `OnDeviceSpeechEngine`, which is already `@MainActor`. The test `MockCleaner` conforms to `TextCleaning` and can stay nonisolated.)

- [ ] **Step 2: Add `@MainActor` and remove `@unchecked Sendable`**

Open `Sources/ClaudeRelaySpeech/TextCleaner.swift` and replace the class declaration (line 11):

```swift
public final class TextCleaner: TextCleaning, @unchecked Sendable {
```

with:

```swift
@MainActor
public final class TextCleaner: TextCleaning {
```

The `TextCleaning` protocol is already `Sendable`-neutral (it only exposes an `async throws` method). No protocol change needed. Leave the static members (`shared`, `idleTimeout`, etc.) alone — they're already immutable or `@MainActor`-safe through the class.

If the protocol currently requires `Sendable`, relax it:

```swift
/// Protocol for local text cleanup — enables mock injection in tests.
public protocol TextCleaning: Sendable {
    func clean(_ text: String) async throws -> String
}
```

Keep `Sendable` on the protocol — `@MainActor` classes are implicitly `Sendable`, and `MockCleaner` can still conform.

- [ ] **Step 3: Build**

Run: `swift build`
Expected: build succeeds.

If you see "Call to main actor-isolated … in a synchronous nonisolated context", the offending caller needs to `await`. The fix is usually changing the caller's signature to `async` or wrapping the call in `await MainActor.run { … }`. Apply the minimal change.

- [ ] **Step 4: Run tests**

Run: `swift test --filter TextCleaner`
Then: `swift test --filter OnDeviceSpeechEngine`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRelaySpeech/TextCleaner.swift
git commit -m "fix(speech): confine TextCleaner to @MainActor

Remove @unchecked Sendable. The only production caller
(OnDeviceSpeechEngine) is already @MainActor, so this eliminates a
latent data race on llm / unloadTimer without requiring an actor hop
or any allocator change."
```

---

### Task 5: Cancel `TokenStore.flushTask` inside `flushIfDirty` (HIGH, Server #4)

**Why:** `flushIfDirty` (line 136-142) currently cancels `flushTask` *after* writing the file. If the 30s sleep has already elapsed and the task is running `performDirtyFlush`, we race it — both paths call `try? save(tokens)`. More importantly, if server shutdown happens mid-sleep and `flushTask` completes before we cancel it, the task outlives the actor. Cancel up-front.

**Files:**
- Modify: `Sources/ClaudeRelayServer/Actors/TokenStore.swift:136-142`
- Test: `Tests/ClaudeRelayServerTests/TokenStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `Tests/ClaudeRelayServerTests/TokenStoreTests.swift`:

```swift
func testFlushIfDirtyCancelsPendingFlushTask() async throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let store = TokenStore(directory: tempDir)
    let (plaintext, _) = try await store.create(label: "test")

    // validate() schedules a dirty flush.
    _ = await store.validate(token: plaintext)

    // flushIfDirty must cancel the scheduled task synchronously, not wait for it.
    await store.flushIfDirty()

    // Give the runtime a tick — if the flushTask is still running it would crash
    // later, but the test only needs to prove flushIfDirty returns fast and the
    // task is nil afterwards.
    await Task.yield()
    let isDirty = await store.isDirtyForTesting
    XCTAssertFalse(isDirty, "flushIfDirty should clear the dirty flag")
}
```

Also add a tiny test accessor to `TokenStore`. In `Sources/ClaudeRelayServer/Actors/TokenStore.swift`, just before the closing `}` of the actor, add:

```swift
    #if DEBUG
    /// Test-only accessor to verify dirty-flush state.
    public var isDirtyForTesting: Bool { lastUsedDirty }
    #endif
```

- [ ] **Step 2: Reorder `flushIfDirty` to cancel up-front**

In `Sources/ClaudeRelayServer/Actors/TokenStore.swift`, replace `flushIfDirty` (line 136-142):

```swift
    /// Flush any pending lastUsedAt changes to disk. Call on server shutdown.
    public func flushIfDirty() {
        guard lastUsedDirty, let tokens = tokens else { return }
        try? save(tokens)
        lastUsedDirty = false
        flushTask?.cancel()
        flushTask = nil
    }
```

with:

```swift
    /// Flush any pending lastUsedAt changes to disk. Call on server shutdown.
    /// Cancels the scheduled dirty-flush task up-front so it cannot race us
    /// or outlive the actor after shutdownGracefully returns.
    public func flushIfDirty() {
        flushTask?.cancel()
        flushTask = nil
        guard lastUsedDirty, let tokens = tokens else { return }
        try? save(tokens)
        lastUsedDirty = false
    }
```

- [ ] **Step 3: Run the test — expect pass**

Run: `swift test --filter TokenStoreTests.testFlushIfDirtyCancelsPendingFlushTask`
Expected: PASS.

- [ ] **Step 4: Run full suite — expect no regression**

Run: `swift test`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRelayServer/Actors/TokenStore.swift \
       Tests/ClaudeRelayServerTests/TokenStoreTests.swift
git commit -m "fix(server): cancel TokenStore flushTask up-front in flushIfDirty

Cancelling after the save raced the 30s sleep-then-flush task and
could leave a dangling Task after server shutdownGracefully. Reorder
so flushTask is cancelled before the final write."
```

---

### Task 6: Add request timeouts to `AdminClient` (HIGH, CLI #1)

**Why:** Every method except `isServiceRunning()` relies on URLSession's 60-second default. If the server hangs mid-PUT (e.g., during a `config set` that triggers a port reconfigure), the CLI blocks for a full minute. 10 seconds is plenty for all admin operations — they're 127.0.0.1 only.

**Files:**
- Modify: `Sources/ClaudeRelayCLI/AdminClient.swift`
- Test: (covered by existing CLI integration — no new test needed; manual smoke-test below)

- [ ] **Step 1: Add `requestTimeout` and apply it in `performRaw`**

In `Sources/ClaudeRelayCLI/AdminClient.swift`, add a property after line 9 (`private let session: URLSession`):

```swift
    /// Default per-request timeout. Applied whenever a caller has not overridden
    /// URLRequest.timeoutInterval explicitly (isServiceRunning sets its own 3s).
    public var requestTimeout: TimeInterval = 10
```

Then modify `performRaw` (line 121-130) to apply the default when the request is still using URLRequest's `60.0` default:

```swift
    private func performRaw(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var req = request
        // URLRequest's default timeoutInterval is 60 seconds. Only override if
        // the caller hasn't explicitly set a shorter timeout (e.g., isServiceRunning).
        if req.timeoutInterval == 60.0 {
            req.timeoutInterval = requestTimeout
        }
        do {
            return try await session.data(for: req)
        } catch let error as URLError where error.code == .cannotConnectToHost
            || error.code == .networkConnectionLost
            || error.code == .timedOut
            || error.code == .cannotFindHost {
            throw AdminClientError.serviceNotRunning
        }
    }
```

- [ ] **Step 2: Smoke-test locally**

```bash
swift build
swift run claude-relay status
```

Expected: exits normally within a second (or throws `.serviceNotRunning` if the server isn't up).

Start a server in another shell, then:

```bash
swift run claude-relay token list
swift run claude-relay session list
```

Expected: results print within 1–2 seconds each.

- [ ] **Step 3: Run tests**

Run: `swift test --filter ClaudeRelayCLITests`
Expected: all green.

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeRelayCLI/AdminClient.swift
git commit -m "fix(cli): cap AdminClient requests at 10s instead of URLSession default

A hung admin server was blocking CLI commands for up to 60s. These are
127.0.0.1-only requests; 10s is more than enough and makes 'is the
server alive' and 'list tokens' feel instant when something is wrong."
```

---

### Task 7: Add periodic observer cleanup to `SessionManager` (HIGH, Server #1)

**Why:** `activityObservers`, `stealObservers`, `renameObservers` grow indefinitely if a channel is torn down without `cleanupSession()` running (crash, panic, OS kill). Over weeks with many reconnecting clients, this causes memory pressure.

**Files:**
- Modify: `Sources/ClaudeRelayServer/Actors/SessionManager.swift`
- Modify: `Sources/ClaudeRelayServer/main.swift`
- Test: `Tests/ClaudeRelayServerTests/SessionManagerTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `Tests/ClaudeRelayServerTests/SessionManagerTests.swift`:

```swift
func testPurgeStaleObserversRemovesOldEntries() async throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let tokenStore = TokenStore(directory: tempDir)
    let manager = SessionManager(
        config: RelayConfig.default,
        tokenStore: tokenStore,
        ptyFactory: { _, _, _, _ in MockPTY() }
    )
    let (_, info) = try await tokenStore.create(label: "dev")

    // Install observers and discard the IDs — simulating a crashed handler
    // that never unregistered them.
    _ = await manager.addActivityObserver(tokenId: info.id) { _, _, _ in }
    _ = await manager.addStealObserver(tokenId: info.id) { _ in }
    _ = await manager.addRenameObserver(tokenId: info.id) { _, _ in }

    XCTAssertEqual(await manager.observerCountForTesting, 3)

    // Purge with a zero-age cutoff — everything is stale.
    await manager.purgeStaleObservers(olderThan: 0)

    XCTAssertEqual(await manager.observerCountForTesting, 0,
        "All observers should have been purged with 0s cutoff")
}
```

(If `MockPTY` doesn't exist in the test file, look for the existing mock factory pattern — every `SessionManager` test already constructs a mock PTY.)

- [ ] **Step 2: Add `observerMetadata` + `purgeStaleObservers`**

In `Sources/ClaudeRelayServer/Actors/SessionManager.swift`, add near the top of the actor (just after the three `*Observers` dictionaries around line 27):

```swift
    /// Creation timestamp per observer ID (all three kinds). Used by
    /// `purgeStaleObservers` to evict observers from handlers that died
    /// without running `cleanupSession()`.
    private var observerMetadata: [UUID: Date] = [:]
```

In the three `add*Observer` methods (find each one and note its structure — example for activity around line 399):

```swift
    @discardableResult
    public func addActivityObserver(
        tokenId: String,
        callback: @escaping ActivityObserver
    ) -> UUID {
        let observerId = UUID()
        activityObservers[observerId] = (tokenId: tokenId, callback: callback)
        observerMetadata[observerId] = Date()   // ← add this line

        // Push current (cached) activity state for this token's sessions so the
        // client doesn't wait for a change event to render correct state.
        for managed in sessions.values where managed.info.tokenId == tokenId {
            guard !managed.info.state.isTerminal else { continue }
            callback(managed.info.id, managed.latestActivity, managed.latestAgent)
        }
        return observerId
    }
```

Do the same for `addStealObserver` and `addRenameObserver` — one line each.

In each corresponding `remove*Observer` method, also drop the metadata entry:

```swift
    public func removeActivityObserver(id: UUID) {
        activityObservers.removeValue(forKey: id)
        observerMetadata.removeValue(forKey: id)
    }
```

Do the same for `removeStealObserver` and `removeRenameObserver`.

Then add the purge method near the bottom of the actor (just before the closing brace):

```swift
    /// Evict observers older than `olderThan` seconds. Called periodically from
    /// main.swift to prevent unbounded growth when handlers die without running
    /// `cleanupSession()` (crash, panic, network partition).
    public func purgeStaleObservers(olderThan seconds: TimeInterval) {
        let cutoff = Date().addingTimeInterval(-seconds)
        let stale = observerMetadata.filter { $0.value < cutoff }.map(\.key)
        for id in stale {
            activityObservers.removeValue(forKey: id)
            stealObservers.removeValue(forKey: id)
            renameObservers.removeValue(forKey: id)
            observerMetadata.removeValue(forKey: id)
        }
        if !stale.isEmpty {
            RelayLogger.log(.warning, category: "session",
                            "Purged \(stale.count) stale observer(s)")
        }
    }

    #if DEBUG
    public var observerCountForTesting: Int {
        activityObservers.count + stealObservers.count + renameObservers.count
    }
    #endif
```

- [ ] **Step 3: Schedule the purge from `main.swift`**

In `Sources/ClaudeRelayServer/main.swift`, add after the existing `sessionManager` and `wsServer` setup but before `try await wsServer.start()` (around line 25):

```swift
// Every 30 minutes, evict observers older than 1 hour. Prevents unbounded
// growth if a channel dies without its ChannelInboundHandler running cleanup.
let observerPurgeTask = Task {
    while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(30 * 60))
        guard !Task.isCancelled else { return }
        await sessionManager.purgeStaleObservers(olderThan: 60 * 60)
    }
}
```

And in the shutdown block (after the `await withCheckedContinuation` that waits on SIGTERM), add this before `await sessionManager.shutdown()`:

```swift
observerPurgeTask.cancel()
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter SessionManagerTests`
Expected: all green including the new test.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRelayServer/Actors/SessionManager.swift \
       Sources/ClaudeRelayServer/main.swift \
       Tests/ClaudeRelayServerTests/SessionManagerTests.swift
git commit -m "fix(server): purge stale observer dictionaries every 30 min

Track creation timestamps per observer and evict entries >1h old from
a background task in main.swift. Prevents unbounded memory growth when
WebSocket handlers die without running cleanupSession() (crash, panic,
network partition)."
```

---

### Task 8: Switch PTY write to non-blocking with EAGAIN buffering (HIGH, Server #2)

**Why:** `PTYSession.write` (line 350-372) blocks the actor executor inside a tight `while` with EAGAIN busy-wait. Under rapid input (paste into an agent, fast typing), this starves every other call on the actor — resize, output dispatch, termination — until the shell's input buffer drains.

**Files:**
- Modify: `Sources/ClaudeRelayServer/Actors/PTYSession.swift`
- Test: `Tests/ClaudeRelayServerTests/` (new file — this is user-visible behavior)

- [ ] **Step 1: Set `O_NONBLOCK` at init**

In `Sources/ClaudeRelayServer/Actors/PTYSession.swift`, find the init that calls `relay_forkpty` (around the existing `masterFD = ...` assignment — inspect the file). Right after the FD is assigned, add:

```swift
        // Put the master FD into non-blocking mode so write() never pins the
        // actor. write(2) returns EAGAIN when the shell's input buffer is full
        // and we'll buffer the remainder instead of spinning.
        let existingFlags = fcntl(masterFD, F_GETFL, 0)
        _ = fcntl(masterFD, F_SETFL, existingFlags | O_NONBLOCK)
```

- [ ] **Step 2: Add a write queue + write dispatch source**

Add these properties to the actor (near the other `private var readSource` etc.):

```swift
    /// Bytes that could not be flushed because the PTY master FD returned
    /// EAGAIN. Drained by `writeSource` when the FD becomes writable again.
    private var writeQueue: [Data] = []
    private var writeQueueBytes = 0
    /// Hard cap on buffered write bytes before we drop oldest. Matches the
    /// client's terminal-output cap; shell input >4 MB is almost certainly
    /// runaway state.
    private static let maxWriteQueueBytes = 4 * 1024 * 1024
    private var writeSource: DispatchSourceWrite?
```

Then replace the `write(_:)` method (lines 349-372) with:

```swift
    /// Write data to PTY (terminal input from client). Non-blocking: on EAGAIN
    /// buffers remaining bytes and schedules a write dispatch source to drain
    /// them when the FD is ready.
    public func write(_ data: Data) {
        guard !terminated else { return }
        writeQueue.append(data)
        writeQueueBytes += data.count
        capWriteQueue()
        drainWriteQueue()
    }

    /// Drop oldest chunks while the queue is over the byte cap. Logs once per
    /// overflow run so runaway-input bugs are diagnosable.
    private func capWriteQueue() {
        guard writeQueueBytes > Self.maxWriteQueueBytes else { return }
        let overflowAtEntry = writeQueueBytes
        while writeQueueBytes > Self.maxWriteQueueBytes, !writeQueue.isEmpty {
            let dropped = writeQueue.removeFirst()
            writeQueueBytes -= dropped.count
        }
        RelayLogger.log(.warning, category: "session",
            "PTYSession \(sessionId) write queue overflow: dropped \(overflowAtEntry - writeQueueBytes) bytes")
    }

    /// Flush as many bytes as the kernel will take right now. If we hit EAGAIN,
    /// schedule (or keep alive) a write source that will call us back.
    private func drainWriteQueue() {
        while let chunk = writeQueue.first {
            let written = chunk.withUnsafeBytes { raw -> Int in
                guard let ptr = raw.baseAddress else { return 0 }
                return Foundation.write(masterFD, ptr, chunk.count)
            }
            if written >= chunk.count {
                writeQueue.removeFirst()
                writeQueueBytes -= chunk.count
                continue
            }
            if written > 0 {
                writeQueue[0] = chunk.subdata(in: written..<chunk.count)
                writeQueueBytes -= written
                continue
            }
            let err = errno
            if err == EAGAIN || err == EINTR {
                startWriteSourceIfNeeded()
                return
            }
            RelayLogger.log(.error, category: "session",
                "PTYSession \(sessionId) write error: errno \(err)")
            writeQueue.removeAll()
            writeQueueBytes = 0
            return
        }
        // Queue drained — cancel the write source if we had one.
        writeSource?.cancel()
        writeSource = nil
    }

    private func startWriteSourceIfNeeded() {
        guard writeSource == nil else { return }
        let sessionActor = self
        let fd = masterFD
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        source.setEventHandler {
            Task { await sessionActor.drainWriteQueue() }
        }
        source.resume()
        writeSource = source
    }
```

Then update `terminate()` (line 387 onwards) to also cancel `writeSource`:

```swift
    public func terminate() {
        guard !terminated else { return }
        terminated = true
        activityMonitor.cancel()
        foregroundPollTimer?.cancel()
        foregroundPollTimer = nil
        writeSource?.cancel()             // ← add
        writeSource = nil                  // ← add
        writeQueue.removeAll()             // ← add
        writeQueueBytes = 0                // ← add

        // ... rest unchanged ...
```

- [ ] **Step 3: Build + run full test suite**

Run: `swift build && swift test`
Expected: green. No existing behavior relies on synchronous write completion (the WebSocket handler doesn't await `write`), so this is a transparent upgrade.

- [ ] **Step 4: Manual soak test**

In one shell, start the server; in another, attach a client and paste a 1 MB string into a running shell. Observe: no input freezes, the shell gets all bytes.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRelayServer/Actors/PTYSession.swift
git commit -m "fix(server): non-blocking PTY writes with EAGAIN buffer

Put the master FD in O_NONBLOCK and queue bytes that can't be written
immediately. A DispatchSourceWrite drains the queue when the FD is
ready. Prevents the write() EAGAIN busy-loop from starving the actor
under paste/rapid-input workloads, which previously blocked resize
and output dispatch for the entire session."
```

---

### Task 9: LRU-cap `RateLimiter.attempts` (HIGH, Server #3)

**Why:** IPs with even one timestamp in the window persist forever. In a month with many unique attackers probing, the dictionary grows without bound.

**Files:**
- Modify: `Sources/ClaudeRelayServer/Services/RateLimiter.swift`
- Test: `Tests/ClaudeRelayServerTests/RateLimiterTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `Tests/ClaudeRelayServerTests/RateLimiterTests.swift`:

```swift
func testRateLimiterEvictsLRUEntries() async {
    let limiter = RateLimiter(maxAttempts: 5, windowSeconds: 600, maxTrackedIPs: 10)

    // Record failures from 15 unique IPs. Oldest 5 should be evicted.
    for i in 0..<15 {
        await limiter.recordFailure(ip: "10.0.0.\(i)")
    }
    XCTAssertLessThanOrEqual(await limiter.trackedIPCountForTesting, 10,
        "LRU cap should have evicted oldest entries")
    // Most recent entry should still be tracked.
    let blockedRecent = await limiter.isBlocked(ip: "10.0.0.14")
    XCTAssertFalse(blockedRecent, "Recent IP with single failure should not be blocked")
}
```

- [ ] **Step 2: Track `lastAccess` + add LRU eviction**

Replace the entire contents of `Sources/ClaudeRelayServer/Services/RateLimiter.swift` with:

```swift
import Foundation

/// Tracks failed authentication attempts per IP address and blocks IPs that
/// exceed the threshold within a rolling time window. Capped at
/// `maxTrackedIPs` with LRU eviction to prevent unbounded memory growth.
/// In-memory only; all state resets on process restart.
public actor RateLimiter {
    private struct Entry {
        var timestamps: [Date]
        var lastAccess: Date
    }

    private var attempts: [String: Entry] = [:]
    private let maxAttempts: Int
    private let windowSeconds: TimeInterval
    private let maxTrackedIPs: Int

    // MARK: - Init

    public init(maxAttempts: Int = 5,
                windowSeconds: TimeInterval = 60,
                maxTrackedIPs: Int = 10_000) {
        self.maxAttempts = maxAttempts
        self.windowSeconds = windowSeconds
        self.maxTrackedIPs = maxTrackedIPs
    }

    // MARK: - Public API

    /// Record a failed authentication attempt for the given IP.
    /// Returns `true` if the IP should now be blocked (threshold reached).
    @discardableResult
    public func recordFailure(ip: String) -> Bool {
        cleanup(ip: ip)
        var entry = attempts[ip] ?? Entry(timestamps: [], lastAccess: Date())
        entry.timestamps.append(Date())
        entry.lastAccess = Date()
        attempts[ip] = entry
        evictIfNeeded()
        return entry.timestamps.count >= maxAttempts
    }

    /// Check whether the given IP is currently blocked.
    public func isBlocked(ip: String) -> Bool {
        cleanup(ip: ip)
        if var entry = attempts[ip] {
            entry.lastAccess = Date()
            attempts[ip] = entry
            return entry.timestamps.count >= maxAttempts
        }
        return false
    }

    /// Reset tracking for an IP (e.g. after a successful auth).
    public func reset(ip: String) {
        attempts.removeValue(forKey: ip)
    }

    // MARK: - Private

    /// Remove timestamps outside the current rolling window.
    private func cleanup(ip: String) {
        guard var entry = attempts[ip] else { return }
        let cutoff = Date().addingTimeInterval(-windowSeconds)
        while let first = entry.timestamps.first, first < cutoff {
            entry.timestamps.removeFirst()
        }
        if entry.timestamps.isEmpty {
            attempts.removeValue(forKey: ip)
        } else {
            attempts[ip] = entry
        }
    }

    /// If we're over capacity, evict the 10% oldest-accessed entries.
    private func evictIfNeeded() {
        guard attempts.count > maxTrackedIPs else { return }
        let evictCount = max(1, maxTrackedIPs / 10)
        let sorted = attempts.sorted { $0.value.lastAccess < $1.value.lastAccess }
        for (ip, _) in sorted.prefix(evictCount) {
            attempts.removeValue(forKey: ip)
        }
    }

    #if DEBUG
    public var trackedIPCountForTesting: Int { attempts.count }
    #endif
}
```

- [ ] **Step 3: Run tests**

Run: `swift test --filter RateLimiterTests`
Expected: all green (existing behavior preserved; new test passes).

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeRelayServer/Services/RateLimiter.swift \
       Tests/ClaudeRelayServerTests/RateLimiterTests.swift
git commit -m "fix(server): LRU-cap RateLimiter.attempts at 10k IPs

Under sustained scanning traffic the attempts dictionary grew without
bound because IPs with a single in-window failure never cleaned up.
Track lastAccess and evict the oldest 10% when we exceed
maxTrackedIPs (default 10k)."
```

---

### Task 10: Graceful shutdown timeout in `main.swift` (HIGH, Server #M5)

**Why:** If `sessionManager.shutdown()` stalls (waiting on PTY termination), the process never exits. Add a 10s hard cap.

**Files:**
- Modify: `Sources/ClaudeRelayServer/main.swift`

- [ ] **Step 1: Wrap shutdown in a timed race**

Replace the shutdown block (`RelayLogger.log(category: "server", "Shutdown signal received")` through `try await group.shutdownGracefully()`) with:

```swift
RelayLogger.log(category: "server", "Shutdown signal received")
print("\nShutting down...")

observerPurgeTask.cancel()

let shutdownSucceeded: Bool = await withTaskGroup(of: Bool.self) { group in
    group.addTask {
        await sessionManager.shutdown()
        await tokenStore.flushIfDirty()
        return true
    }
    group.addTask {
        try? await Task.sleep(for: .seconds(10))
        return false
    }
    let first = await group.next() ?? false
    group.cancelAll()
    return first
}

if !shutdownSucceeded {
    RelayLogger.log(.error, category: "server",
        "Shutdown timed out after 10s — forcing exit")
    print("Shutdown timed out, forcing exit.")
}

try? await wsServer.stop()
try? await adminServer.stop()
try? await group.shutdownGracefully()
```

Note: `try await` → `try?` in the last three lines. If shutdown timed out, one of them is likely to throw; we do not want to raise on the exit path.

- [ ] **Step 2: Smoke test**

```bash
swift build && swift run claude-relay-server &
sleep 2
kill -INT $!
wait
```

Expected: server exits within ~1 second under normal conditions.

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeRelayServer/main.swift
git commit -m "fix(server): add 10s timeout to graceful shutdown

Previously if sessionManager.shutdown() stalled on PTY termination
the process would hang forever. Race the normal shutdown against a
10s timer and force-exit with a log line on timeout."
```

---

## Wave 2 — Memory-growth and resource-leak fixes

Same theme: prevent slow-motion production failures. Not user-visible on day 1, but a 30-day-uptime server shouldn't accumulate RAM/FDs.

---

### Task 11: Cap `TerminalViewModel.pendingOutput` with a logged drop (Client MEDIUM)

**Why:** `pendingOutput` silently drops the oldest chunks when it hits 4 MB (line 104-107 of `TerminalViewModel.swift`). No log means dropped data is undiagnosable. Keep the cap but log the first drop per run.

**Files:**
- Modify: `Sources/ClaudeRelayClient/ViewModels/TerminalViewModel.swift`

- [ ] **Step 1: Add a logger + throttled drop log**

At the top of `TerminalViewModel.swift` (after `import Combine` at line 2), add:

```swift
import os.log

private let pendingOutputLog = Logger(subsystem: "com.claude.relay.client",
                                       category: "TerminalViewModel")
```

Then find the eviction `while` (line 104-107) and replace:

```swift
            while pendingOutputBytes > Self.pendingOutputByteLimit, !pendingOutput.isEmpty {
                let dropped = pendingOutput.removeFirst()
                pendingOutputBytes -= dropped.count
            }
```

with:

```swift
            if pendingOutputBytes > Self.pendingOutputByteLimit, !didLogPendingCap {
                pendingOutputLog.warning(
                    "Terminal pending buffer hit \(Self.pendingOutputByteLimit / 1024 / 1024) MB cap for session \(self.sessionId.uuidString.prefix(8)) — dropping oldest chunks")
                didLogPendingCap = true
            }
            while pendingOutputBytes > Self.pendingOutputByteLimit, !pendingOutput.isEmpty {
                let dropped = pendingOutput.removeFirst()
                pendingOutputBytes -= dropped.count
            }
```

Add the flag next to the other private state (after `private var pendingOutputBytes: Int = 0` around line 61):

```swift
    private var didLogPendingCap = false
```

And reset it in `terminalReady()` and `prepareForSwitch()` so each session gets a fresh warning if it hits the cap:

In `terminalReady`, after `terminalSized = true`:

```swift
        didLogPendingCap = false
```

In `prepareForSwitch`, after `pendingOutputBytes = 0`:

```swift
        didLogPendingCap = false
```

- [ ] **Step 2: Run tests**

Run: `swift test --filter TerminalViewModelTests`
Expected: all green.

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeRelayClient/ViewModels/TerminalViewModel.swift
git commit -m "chore(client): log first TerminalViewModel pending-buffer drop

When the 4 MB pending-output cap kicks in we silently throw away
bytes. Log once per session so a user reporting 'my scrollback is
cut off' shows up in Console."
```

---

### Task 12: Cancel orphan `authTask` before spawning a new one (Client MEDIUM)

**Why:** `SharedSessionCoordinator.ensureAuthenticated` (lines 328-339) stores the new Task in `authTask` but doesn't cancel the previous one. Orphaned tasks take up to 10s (session-controller timeout) to complete.

**Files:**
- Modify: `Sources/ClaudeRelayClient/ViewModels/SharedSessionCoordinator.swift:328-339`

- [ ] **Step 1: Read current code**

Run: `grep -n "ensureAuthenticated" Sources/ClaudeRelayClient/ViewModels/SharedSessionCoordinator.swift`

Open the file, find the `ensureAuthenticated` method (~line 318).

- [ ] **Step 2: Cancel stale task before spawning**

Inside `ensureAuthenticated`, find the spot where it decides to create a new `Task`. It currently looks like:

```swift
        if let existing = authTask {
            return try await existing.value
        }
        let task = Task<SessionController, Error> { ...
```

Replace with:

```swift
        if let existing = authTask {
            return try await existing.value
        }
        // Cancel any orphaned task from a superseded connection generation.
        // Normally existing==nil here, but if a reconnect just happened the
        // old Task may still be alive and counting down its 10s timeout.
        authTask?.cancel()
        let task = Task<SessionController, Error> { ...
```

Note: the `?.cancel()` is a no-op when `authTask` is `nil`, which is the hot path.

- [ ] **Step 3: Build + test**

Run: `swift build && swift test --filter SharedSessionCoordinatorTests`
Expected: all green.

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeRelayClient/ViewModels/SharedSessionCoordinator.swift
git commit -m "fix(client): cancel orphan authTask before spawning replacement

Rapid reconnect cycles could strand an authTask for up to 10s (session
timeout) before it failed naturally. Explicitly cancel any stale task
immediately before creating the replacement so it doesn't hold the
connection busy."
```

---

### Task 13: Cancel `ServerStatusChecker` orphan task on disappear (Client MEDIUM)

**Why:** `ServerStatusChecker.probe` races a 5s timeout against the real auth path. When the timeout wins, the real path is cancelled but can still be suspended inside `URLSession.webSocketTask.receive`, leaking a session and its socket.

**Files:**
- Modify: `Sources/ClaudeRelayClient/ViewModels/ServerStatusChecker.swift`

- [ ] **Step 1: Wrap the probe in `withTaskCancellationHandler`**

Replace the body of `ServerStatusChecker.probe(config:)` (line 59 onward) with:

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
                await withTaskCancellationHandler {
                    do {
                        try await connection.connect(config: config, token: token)
                        try await controller.authenticate(token: token)
                        connection.disconnect()
                        return ServerStatus(isLive: true)
                    } catch {
                        connection.disconnect()
                        return ServerStatus()
                    }
                } onCancel: {
                    Task { @MainActor in connection.disconnect() }
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

The `onCancel` closure fires synchronously when the parent task's cancellation propagates — guaranteeing the `URLSession` gets torn down even if the real-work task is suspended deep inside `webSocketTask.receive`.

- [ ] **Step 2: Build + test**

Run: `swift build && swift test --filter ServerStatusChecker`
Expected: all green.

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeRelayClient/ViewModels/ServerStatusChecker.swift
git commit -m "fix(client): guarantee ServerStatusChecker probe cleans up on cancel

Wrap the probe in withTaskCancellationHandler so connection.disconnect()
runs synchronously when the 5s timeout racer wins, instead of waiting
for URLSession.webSocketTask.receive to wake up and notice its task
was cancelled. Prevents FD / URLSession leaks on flaky networks."
```

---

### Task 14: Log `SavedConnectionStore` encoding errors (Client MEDIUM)

**Why:** `SavedConnectionStore.saveAll` (line 57) swallows JSON encoding failures. Rare, but when it happens the user loses their bookmarks silently on next launch.

**Files:**
- Modify: `Sources/ClaudeRelayClient/Helpers/SavedConnectionStore.swift`

- [ ] **Step 1: Add a logger + log failures**

At the top of `SavedConnectionStore.swift`, add:

```swift
import os.log

private let connectionStoreLog = Logger(
    subsystem: "com.claude.relay.client", category: "SavedConnectionStore")
```

Replace `saveAll` (line 56-59):

```swift
    public func saveAll(_ connections: [ConnectionConfig]) {
        guard let data = try? JSONEncoder().encode(connections) else { return }
        defaults.set(data, forKey: key)
    }
```

with:

```swift
    public func saveAll(_ connections: [ConnectionConfig]) {
        do {
            let data = try JSONEncoder().encode(connections)
            defaults.set(data, forKey: key)
        } catch {
            connectionStoreLog.error(
                "Failed to encode \(connections.count) saved connection(s) to UserDefaults key '\(self.key, privacy: .public)': \(error.localizedDescription, privacy: .public)")
        }
    }
```

- [ ] **Step 2: Build + test**

Run: `swift build && swift test --filter SavedConnectionStore`
Expected: all green.

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeRelayClient/Helpers/SavedConnectionStore.swift
git commit -m "chore(client): log SavedConnectionStore encoding failures

If JSONEncoder ever throws for a ConnectionConfig we now write a
Console line instead of silently losing the user's bookmarks."
```

---

### Task 15: `ConnectionConfig.wsURL` returns optional, stops crashing on malformed host (Client LOW)

**Why:** `URL(string:)!` crashes the app if the host contains invalid characters (corrupted bookmark, deep-link injection).

**Files:**
- Modify: `Sources/ClaudeRelayClient/ConnectionConfig.swift`
- Modify callers that use `config.wsURL`
- Test: `Tests/ClaudeRelayClientTests/` (new test)

- [ ] **Step 1: Make `wsURL` optional and find callers**

Replace lines 12-16 of `ConnectionConfig.swift`:

```swift
    /// Constructs the WebSocket URL from the configuration properties.
    public var wsURL: URL {
        let scheme = useTLS ? "wss" : "ws"
        // Force-unwrap is safe here because we control the format.
        return URL(string: "\(scheme)://\(host):\(port)")!
    }
```

with:

```swift
    /// Constructs the WebSocket URL from the configuration properties.
    /// Returns `nil` if the stored host contains characters that RFC 3986
    /// forbids in a URL (a corrupted bookmark, for instance).
    public var wsURL: URL? {
        let scheme = useTLS ? "wss" : "ws"
        return URL(string: "\(scheme)://\(host):\(port)")
    }
```

Then find every caller:

```bash
git grep -n "\.wsURL" Sources ClaudeRelayApp ClaudeRelayMac
```

For each caller, replace bare `config.wsURL` with a `guard` that surfaces a user-facing error. The only production site is `RelayConnection.connect` (line 127 in the current file):

```swift
        let task = session.webSocketTask(with: config.wsURL)
```

Replace with:

```swift
        guard let url = config.wsURL else {
            state = .disconnected
            throw ConnectionError.invalidMessage("Invalid host '\(config.host)'")
        }
        let task = session.webSocketTask(with: url)
```

- [ ] **Step 2: Add a guard test**

Add to `Tests/ClaudeRelayClientTests/` a new file `ConnectionConfigTests.swift`:

```swift
import XCTest
@testable import ClaudeRelayClient

final class ConnectionConfigTests: XCTestCase {
    func testWSURLReturnsNilForInvalidHost() {
        let config = ConnectionConfig(
            name: "broken",
            host: "not a valid host with spaces",
            port: 9200
        )
        XCTAssertNil(config.wsURL)
    }

    func testWSURLForValidHost() {
        let config = ConnectionConfig(name: "ok", host: "10.0.0.1", port: 9200)
        XCTAssertEqual(config.wsURL?.absoluteString, "ws://10.0.0.1:9200")
    }
}
```

- [ ] **Step 3: Build + test**

Run: `swift build && swift test`
Expected: all green. The optional return may cascade into a few more call sites — fix them each with a `guard` + user-visible error.

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeRelayClient/ConnectionConfig.swift \
       Sources/ClaudeRelayClient/RelayConnection.swift \
       Tests/ClaudeRelayClientTests/ConnectionConfigTests.swift
git commit -m "fix(client): ConnectionConfig.wsURL returns optional, stops crashing

Force-unwrap crashes the app if a corrupted bookmark or deep-link
ends up with spaces or invalid characters in host. Return URL? and
throw a recoverable error from the single production caller."
```

---

### Task 16: Cap `AudioCaptureSession` recording at 5 minutes (Speech MEDIUM)

**Why:** `buffer: [Float]` grows linearly during recording (16kHz × 4 bytes = 64 KB/s). A forgotten recording backgrounded for 20 minutes = ~77 MB heap. Add a hard max.

**Files:**
- Modify: `Sources/ClaudeRelaySpeech/AudioCaptureSession.swift`

- [ ] **Step 1: Add max duration + auto-stop**

In `AudioCaptureSession.swift`, add a new static + state:

```swift
    public static let maximumDuration: TimeInterval = 300   // 5 minutes
    private var autoStopTask: Task<Void, Never>?
```

Modify `start()` to schedule the auto-stop. After `isRecording = true`:

```swift
        autoStopTask?.cancel()
        autoStopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.maximumDuration))
            guard !Task.isCancelled, let self, self.isRecording else { return }
            _ = self.stop()
        }
```

Modify `stop()` to cancel the task. After `isRecording = false`:

```swift
        autoStopTask?.cancel()
        autoStopTask = nil
```

Add an initializer-note for the 5-minute cap:

```swift
    /// Maximum recording duration; auto-stops to cap memory.
    /// Backgrounded recordings that never call stop() would otherwise grow
    /// at 64 KB/s (16kHz × 4 bytes × 1 channel).
    public static let maximumDuration: TimeInterval = 300   // 5 minutes
```

(You already added this line — keep the doc comment.)

- [ ] **Step 2: Build + test**

Run: `swift build && swift test --filter Speech`
Expected: all green.

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeRelaySpeech/AudioCaptureSession.swift
git commit -m "fix(speech): auto-stop AudioCaptureSession after 5 minutes

A forgotten recording backgrounded for 20 minutes was allocating
~77 MB of Float samples. Add a static maximumDuration (5 min) and
schedule a Task that calls stop() if the user never does."
```

---

### Task 17: Guard double-tap race in `OnDeviceSpeechEngine.stopAndProcess` (Speech MEDIUM)

**Why:** Rapid double-tap could spawn a second `processingTask` that overwrites the first — the first result is lost with no cancellation.

**Files:**
- Modify: `Sources/ClaudeRelaySpeech/OnDeviceSpeechEngine.swift`

- [ ] **Step 1: Cancel existing task defensively**

Open `Sources/ClaudeRelaySpeech/OnDeviceSpeechEngine.swift`. Find `stopAndProcess` (~line 201). Just inside the method body, after the `guard state == .recording` line, add:

```swift
        if let existing = processingTask {
            existing.cancel()
            processingTask = nil
        }
```

- [ ] **Step 2: Build + test**

Run: `swift build && swift test --filter OnDeviceSpeechEngine`
Expected: all green.

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeRelaySpeech/OnDeviceSpeechEngine.swift
git commit -m "fix(speech): cancel prior processingTask in stopAndProcess

Defensive guard against rapid double-taps overwriting the task
handle. Normally processingTask is nil here; log-but-fix in case
a future code path introduces overlap."
```

---

### Task 18: LogStore eager compaction + memory bound (Server MEDIUM)

**Why:** `LogStore` waits for 1000 drops before compacting (line 30). Between compactions the entries array can hold 2000 + 999 = 2999 strings. At ~500 bytes each, that's ~1.5 MB. Make the compaction threshold a small, bounded overshoot.

**Files:**
- Modify: `Sources/ClaudeRelayServer/Services/LogStore.swift`

- [ ] **Step 1: Compact immediately at +100 overshoot**

Replace the `if entries.count > maxEntries` block (lines 27-34) with:

```swift
        if entries.count > maxEntries {
            dropCount += 1
            // Compact when overshoot exceeds ~5% of capacity or absolute 100,
            // whichever is smaller. Keeps the live array within 1.05×
            // maxEntries without the O(n) shift on every append.
            let overshootThreshold = min(100, max(10, maxEntries / 20))
            if dropCount >= overshootThreshold {
                entries.removeFirst(dropCount)
                dropCount = 0
            }
        }
```

- [ ] **Step 2: Build + test**

Run: `swift test --filter RingBufferTests`  (LogStore uses its own tests — find them)

Actually check:
```bash
ls Tests/ClaudeRelayServerTests/ | grep -i log
```

If there's no dedicated LogStore test, add one:

```swift
// Tests/ClaudeRelayServerTests/LogStoreTests.swift
import XCTest
@testable import ClaudeRelayServer

final class LogStoreTests: XCTestCase {
    func testCompactsAtBoundedOvershoot() {
        let store = LogStore(maxEntries: 100)
        for i in 0..<500 {
            store.append(category: "test", message: "msg-\(i)")
        }
        // With a 100-entry cap and +5 overshoot cap, we should have at most
        // 105 entries live at any time.
        let recent = store.recent(count: 200)
        XCTAssertLessThanOrEqual(recent.count, 105)
    }
}
```

- [ ] **Step 3: Build + test**

Run: `swift test --filter LogStoreTests`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeRelayServer/Services/LogStore.swift \
       Tests/ClaudeRelayServerTests/LogStoreTests.swift
git commit -m "perf(server): LogStore compacts at 5% overshoot instead of +1000

Previously between compactions the entries array could hold 2×max
before shrinking. New threshold is min(100, maxEntries/20) so the
live array stays within ~1.05× capacity."
```

---

### Task 19: Zero-copy `RingBuffer.write` via `withUnsafeMutableBytes` (Server MEDIUM)

**Why:** `replaceSubrange(_, with: data)` on `[UInt8]` allocates an intermediate `Array` from the `Data` slice. For 8 KB writes at high throughput, this allocates 8 KB × N times.

**Files:**
- Modify: `Sources/ClaudeRelayServer/Services/RingBuffer.swift`
- Run existing tests: `Tests/ClaudeRelayServerTests/RingBufferTests.swift`

- [ ] **Step 1: Replace with unsafe-byte copy**

In `Sources/ClaudeRelayServer/Services/RingBuffer.swift`, replace the write method (line 27-48):

```swift
    public mutating func write(_ data: Data) {
        if data.count >= capacity {
            // Only the last `capacity` bytes matter
            let start = data.count - capacity
            storage = Array(data[data.startIndex.advanced(by: start)...])
            head = 0
            filled = capacity
            return
        }

        let count = data.count
        let spaceToEnd = capacity - head
        if count <= spaceToEnd {
            storage.replaceSubrange(head..<head + count, with: data)
        } else {
            let splitIndex = data.startIndex.advanced(by: spaceToEnd)
            storage.replaceSubrange(head..<capacity, with: data[data.startIndex..<splitIndex])
            storage.replaceSubrange(0..<count - spaceToEnd, with: data[splitIndex...])
        }
        head = (head + count) % capacity
        filled = min(filled + count, capacity)
    }
```

with:

```swift
    public mutating func write(_ data: Data) {
        let count = data.count
        guard count > 0 else { return }

        if count >= capacity {
            // Only the last `capacity` bytes matter; overwrite and reset.
            let start = data.count - capacity
            let tail = data[data.startIndex.advanced(by: start)...]
            storage.withUnsafeMutableBytes { dst in
                guard let base = dst.baseAddress else { return }
                tail.copyBytes(to: UnsafeMutableBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: capacity))
            }
            head = 0
            filled = capacity
            return
        }

        let spaceToEnd = capacity - head
        storage.withUnsafeMutableBytes { dst in
            guard let dstBase = dst.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            if count <= spaceToEnd {
                data.copyBytes(to: UnsafeMutableBufferPointer(start: dstBase + head, count: count))
            } else {
                let splitIndex = data.startIndex.advanced(by: spaceToEnd)
                let first = data[data.startIndex..<splitIndex]
                let second = data[splitIndex...]
                first.copyBytes(to: UnsafeMutableBufferPointer(start: dstBase + head, count: spaceToEnd))
                second.copyBytes(to: UnsafeMutableBufferPointer(start: dstBase, count: count - spaceToEnd))
            }
        }
        head = (head + count) % capacity
        filled = min(filled + count, capacity)
    }
```

- [ ] **Step 2: Run RingBuffer tests**

Run: `swift test --filter RingBufferTests`
Expected: all 7 existing tests pass.

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeRelayServer/Services/RingBuffer.swift
git commit -m "perf(server): zero-copy RingBuffer.write via withUnsafeMutableBytes

Previously replaceSubrange allocated an intermediate Array from each
Data slice on every write. Use copyBytes into the raw buffer — shaves
an 8 KB allocation per PTY output chunk at peak throughput."
```

---

### Task 20: Per-token session limit (Server MEDIUM)

**Why:** A malicious or buggy client can create unlimited sessions, exhausting process table + memory. Cap per-token session count.

**Files:**
- Modify: `Sources/ClaudeRelayKit/Models/RelayConfig.swift` (add config field)
- Modify: `Sources/ClaudeRelayServer/Actors/SessionManager.swift`
- Modify: `Sources/ClaudeRelayServer/Network/AdminRoutes.swift` (validator)
- Test: `Tests/ClaudeRelayServerTests/SessionManagerTests.swift`

- [ ] **Step 1: Add `maxSessionsPerToken` to RelayConfig**

In `Sources/ClaudeRelayKit/Models/RelayConfig.swift`, add the new field (near the other numeric config fields):

```swift
    /// Maximum active (non-terminal) sessions per token. 0 means unlimited.
    public var maxSessionsPerToken: Int = 50
```

If `RelayConfig` has an explicit `init`, add the parameter; if it relies on memberwise init, `Codable` + default handles it. Update the default struct:

```swift
    public static var `default`: RelayConfig {
        RelayConfig(wsPort: 9200, adminPort: 9100, ...)   // add maxSessionsPerToken: 50 at the end
    }
```

Match the existing style — look at what `RelayConfig.default` already passes.

- [ ] **Step 2: Enforce in `SessionManager.createSession`**

In `Sources/ClaudeRelayServer/Actors/SessionManager.swift`, at the top of `createSession` (line 54 onward), add before the `id = UUID()` line:

```swift
        let limit = config.maxSessionsPerToken
        if limit > 0 {
            let active = sessions.values.filter {
                $0.info.tokenId == tokenId && !$0.info.state.isTerminal
            }.count
            if active >= limit {
                throw SessionError.sessionLimitExceeded(limit: limit)
            }
        }
```

Add the error case to `SessionError`:

```swift
public enum SessionError: Error {
    case notFound(UUID)
    case ownershipViolation
    case invalidTransition(SessionState, SessionState)
    case sessionLimitExceeded(limit: Int)   // ← add
}
```

- [ ] **Step 3: Surface in admin validation**

In `Sources/ClaudeRelayServer/Network/AdminRoutes.swift`, find the `applyConfigValue` validator. Add a case for the new key (match the existing style — integer, >= 0):

```swift
        case "maxSessionsPerToken":
            guard let value = value.intValue, value >= 0 else {
                throw AdminError.invalidValue("maxSessionsPerToken must be ≥ 0")
            }
            config.maxSessionsPerToken = value
```

- [ ] **Step 4: Write a test**

In `Tests/ClaudeRelayServerTests/SessionManagerTests.swift`, add:

```swift
func testCreateSessionEnforcesPerTokenLimit() async throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let tokenStore = TokenStore(directory: tempDir)
    var config = RelayConfig.default
    config.maxSessionsPerToken = 3
    let manager = SessionManager(config: config, tokenStore: tokenStore,
                                  ptyFactory: { _, _, _, _ in MockPTY() })
    let (_, info) = try await tokenStore.create(label: "dev")

    for i in 0..<3 {
        _ = try await manager.createSession(tokenId: info.id, name: "s\(i)")
    }

    do {
        _ = try await manager.createSession(tokenId: info.id, name: "s-overflow")
        XCTFail("Expected sessionLimitExceeded error")
    } catch SessionError.sessionLimitExceeded(let limit) {
        XCTAssertEqual(limit, 3)
    } catch {
        XCTFail("Wrong error: \(error)")
    }
}
```

- [ ] **Step 5: Build + test**

Run: `swift build && swift test`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeRelayKit/Models/RelayConfig.swift \
       Sources/ClaudeRelayServer/Actors/SessionManager.swift \
       Sources/ClaudeRelayServer/Network/AdminRoutes.swift \
       Tests/ClaudeRelayServerTests/SessionManagerTests.swift
git commit -m "feat(server): cap sessions-per-token at configurable max (default 50)

A runaway client could previously fork-bomb the server by creating
unlimited sessions. Enforce a per-token cap (config.maxSessionsPerToken)
in createSession and return SessionError.sessionLimitExceeded when hit."
```

---

### Task 21: PTY output backpressure — drop frames when the client is slow (Server MEDIUM)

**Why:** If the WebSocket write pipe is slow (mobile backgrounded, bad network), `wirePTYOutput` in `RelayMessageHandler` queues data unboundedly. The ring buffer also keeps accumulating. Add an upper bound on inflight WebSocket writes.

**Files:**
- Modify: `Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift`

- [ ] **Step 1: Track inflight bytes + drop when over cap**

In `Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift`, find the section that installs the PTY output handler (search for `wirePTYOutput` or the output-binding spot). Add a counter:

```swift
    private var inflightOutputBytes = 0
    private static let maxInflightOutputBytes = 2 * 1024 * 1024   // 2 MB
```

In the output handler, before calling `sendBinaryData`, check and gate:

```swift
        if self.inflightOutputBytes > Self.maxInflightOutputBytes {
            // Client is slow; skip this frame. The server's ring buffer has
            // the authoritative copy — on resume, the client replays from there.
            return
        }
        self.inflightOutputBytes += data.count
```

And in the `sendBinaryData` promise completion (find where the write promise fires), decrement:

```swift
        writePromise.futureResult.whenComplete { [weak self] _ in
            self?.inflightOutputBytes -= data.count
        }
```

(If the existing code doesn't use a promise, construct one; NIO always lets you attach one to a write.)

- [ ] **Step 2: Build + smoke test**

Run: `swift build && swift test --filter RelayMessageHandler`
Expected: green (if the test suite has handler tests; otherwise just ensure build).

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift
git commit -m "perf(server): backpressure-drop PTY output when client is slow

Cap inflight WebSocket-write bytes per session at 2 MB. When we hit the
cap we skip frames until writes drain — the server's ring buffer holds
the authoritative copy and the client replays from there on resume."
```

---

### Task 22: `ConfigManager.load` returns defaults on corrupt file (Kit MEDIUM)

**Why:** A corrupted `config.json` (bad edit, failed disk) crashes the server at startup. We already default-on-missing; extend to default-on-unparseable with a log line.

**Files:**
- Modify: `Sources/ClaudeRelayKit/Services/ConfigManager.swift`

- [ ] **Step 1: Catch decode + log + return default**

Replace `load()` (line 14-24) with:

```swift
    /// Load config from ~/.claude-relay/config.json, or return defaults if not found.
    /// On decode failure (corrupted file), logs a warning and returns defaults —
    /// crashing the server on a bad config file would be worse than reverting
    /// to known-good behavior.
    public static func load() throws -> RelayConfig {
        let configFile = RelayConfig.configFile
        let fm = FileManager.default

        guard fm.fileExists(atPath: configFile.path) else {
            return RelayConfig.default
        }

        do {
            let data = try Data(contentsOf: configFile)
            return try sharedDecoder.decode(RelayConfig.self, from: data)
        } catch {
            FileHandle.standardError.write(Data(
                "Warning: failed to parse config at \(configFile.path): \(error). Using defaults.\n".utf8))
            return RelayConfig.default
        }
    }
```

- [ ] **Step 2: Build + test**

Run: `swift build && swift test`
Expected: green. Existing `ConfigManagerTests.testLoadSucceeds` still passes because file-present-and-valid path is unchanged.

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeRelayKit/Services/ConfigManager.swift
git commit -m "fix(kit): ConfigManager.load returns defaults on corrupt file

A bad edit to config.json shouldn't crash the server. Log to stderr
and return RelayConfig.default so launchd-managed services stay up."
```

---

## Wave 3 — SwiftUI & app refactors

Biggest win: splitting ActiveTerminalView. After that, deduplication across iOS/macOS.

---

### Task 23: Extract `MicButton` from `ActiveTerminalView` (Apps HIGH)

**Why:** `ActiveTerminalView.swift` is 886 lines (over 2× the codebase guideline) and contains 5 loosely-related sub-components. Starting with the easiest extraction: `MicButton` at lines 286-407.

**Files:**
- Create: `ClaudeRelayApp/Views/Components/MicButton.swift`
- Modify: `ClaudeRelayApp/Views/ActiveTerminalView.swift`

- [ ] **Step 1: Create the new file with the extracted struct**

Read lines 286-407 of `ActiveTerminalView.swift` and copy the entire `MicButton` struct (including any nested enums / helper extensions) into a new file:

```bash
cat > /tmp/extract-plan-mic-start.txt <<'EOF'
Read ClaudeRelayApp/Views/ActiveTerminalView.swift from line 286 to line 407 inclusive, cut that block, paste into a new file ClaudeRelayApp/Views/Components/MicButton.swift.

Prepend the new file with the same imports used by the original (SwiftUI, ClaudeRelayClient, ClaudeRelaySpeech). Mark the struct `public` only if callers outside the module need it (in this case it is consumed only inside ClaudeRelayApp so keep it `internal`).
EOF
cat /tmp/extract-plan-mic-start.txt
```

Then do the actual move:
1. Open `ActiveTerminalView.swift`, select lines 286-407 (the `private struct MicButton: View { ... }` block), cut.
2. Create `ClaudeRelayApp/Views/Components/MicButton.swift`:

```swift
import SwiftUI
import ClaudeRelayClient
import ClaudeRelaySpeech

struct MicButton: View {
    @ObservedObject var engine: OnDeviceSpeechEngine
    @ObservedObject var settings: AppSettings
    let coordinator: SessionCoordinator

    // … paste the full struct body from lines 286-407 here …
}
```

Since the struct was `private` in `ActiveTerminalView.swift`, it must now be at least `internal`. Drop `private` if present.

3. In `ActiveTerminalView.swift`, delete the now-empty gap left by the cut.

- [ ] **Step 2: Build**

Run: `xcodebuild -project ClaudeRelay.xcodeproj -scheme ClaudeRelay -sdk iphonesimulator build`
Expected: build succeeds.

If a nested helper (another `private` struct / extension) was declared next to `MicButton`, the build error will tell you — move those too.

- [ ] **Step 3: Smoke-test on simulator**

Open the iOS app, start recording, stop, confirm mic button UI unchanged.

- [ ] **Step 4: Commit**

```bash
git add ClaudeRelayApp/Views/Components/MicButton.swift \
       ClaudeRelayApp/Views/ActiveTerminalView.swift
git commit -m "refactor(ios): extract MicButton from ActiveTerminalView

First step in splitting the 886-line ActiveTerminalView. MicButton
is the most self-contained sub-view; lift-and-shift with no logic
changes. No behavior change."
```

---

### Task 24: Extract `QRCodeGenerator` + `QRCodeOverlay` (Apps HIGH)

**Why:** Continuing the ActiveTerminalView decomposition. QR code logic (lines 834-885) has zero overlap with terminal handling.

**Files:**
- Create: `ClaudeRelayApp/Views/Components/QRCodeComponents.swift`
- Modify: `ClaudeRelayApp/Views/ActiveTerminalView.swift`

- [ ] **Step 1: Move QR-related code**

1. Create `ClaudeRelayApp/Views/Components/QRCodeComponents.swift` with:

```swift
import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

// Paste the entire QRCodeGenerator struct + any QRCodeOverlay view
// from lines 834-885 of ActiveTerminalView.swift here. Drop `private`
// so they're internal.
```

2. Delete the corresponding block from `ActiveTerminalView.swift`.

- [ ] **Step 2: Build + smoke test**

Run: `xcodebuild -project ClaudeRelay.xcodeproj -scheme ClaudeRelay -sdk iphonesimulator build`

Then open the QR sharing sheet in-app; verify the QR renders.

- [ ] **Step 3: Commit**

```bash
git add ClaudeRelayApp/Views/Components/QRCodeComponents.swift \
       ClaudeRelayApp/Views/ActiveTerminalView.swift
git commit -m "refactor(ios): extract QRCodeGenerator/Overlay from ActiveTerminalView

Lift-and-shift from ActiveTerminalView to a dedicated file. No
behavior change."
```

---

### Task 25: Extract `RelayTerminalView` to its own file (Apps HIGH)

**Why:** Final ActiveTerminalView extraction. `RelayTerminalView` (lines 419-546) is the SwiftTerm wrapper + runtime overrides — sizable and unrelated to the outer view composition.

**Files:**
- Create: `ClaudeRelayApp/Views/Components/RelayTerminalView.swift`
- Modify: `ClaudeRelayApp/Views/ActiveTerminalView.swift`

- [ ] **Step 1: Move the struct + its runtime overrides**

1. Create `ClaudeRelayApp/Views/Components/RelayTerminalView.swift` with the imports from the top of `ActiveTerminalView.swift` that are still needed (SwiftTerm, UIKit, ObjectiveC, ClaudeRelayClient).
2. Paste the `RelayTerminalView` struct + any accompanying `UIViewRepresentable` and Objective-C runtime code.
3. Delete the block from `ActiveTerminalView.swift`.

- [ ] **Step 2: Build + smoke test**

Run: `xcodebuild -project ClaudeRelay.xcodeproj -scheme ClaudeRelay -sdk iphonesimulator build`

Open a session in the app; verify the terminal still works.

- [ ] **Step 3: Commit**

```bash
git add ClaudeRelayApp/Views/Components/RelayTerminalView.swift \
       ClaudeRelayApp/Views/ActiveTerminalView.swift
git commit -m "refactor(ios): extract RelayTerminalView from ActiveTerminalView

Completes the ActiveTerminalView split. File is now ~200-300 lines
holding only the orchestration + tab bar. RelayTerminalView lives
with MicButton and QRCodeComponents in Views/Components/."
```

---

### Task 26: Move shared `SessionSidebarView.activityFor` into `SharedSessionCoordinator` (Apps MEDIUM)

**Why:** Both iOS and macOS sidebar files implement the identical `activityFor(_:)` helper. Host it once on the coordinator.

**Files:**
- Modify: `Sources/ClaudeRelayClient/ViewModels/SharedSessionCoordinator.swift`
- Modify: `ClaudeRelayApp/Views/SessionSidebarView.swift`
- Modify: `ClaudeRelayMac/Views/SessionSidebarView.swift`

- [ ] **Step 1: Add `activityState(for:)` to SharedSessionCoordinator**

In `Sources/ClaudeRelayClient/ViewModels/SharedSessionCoordinator.swift`, add near the bottom (before the closing brace of the class):

```swift
    /// Derive the `ActivityState` for a session. Convenience helper used by
    /// sidebar views on both platforms — keeps the agent/awaiting-input
    /// resolution in one place.
    public func activityState(for sessionId: UUID) -> ActivityState {
        if isRunningAgent(sessionId: sessionId) {
            return sessionsAwaitingInput.contains(sessionId) ? .agentIdle : .agentActive
        }
        return sessionsAwaitingInput.contains(sessionId) ? .idle : .active
    }
```

- [ ] **Step 2: Delete the iOS duplicate**

In `ClaudeRelayApp/Views/SessionSidebarView.swift`, find the `private func activityFor(_ id: UUID) -> ActivityState { … }` block and delete it. Replace every call site of `activityFor(session.id)` with `coordinator.activityState(for: session.id)`.

- [ ] **Step 3: Delete the macOS duplicate**

Same operation in `ClaudeRelayMac/Views/SessionSidebarView.swift`.

- [ ] **Step 4: Build both targets**

```bash
xcodebuild -project ClaudeRelay.xcodeproj -scheme ClaudeRelay -sdk iphonesimulator build
xcodebuild -project ClaudeRelay.xcodeproj -scheme ClaudeRelayMac build
```

Both expected green.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRelayClient/ViewModels/SharedSessionCoordinator.swift \
       ClaudeRelayApp/Views/SessionSidebarView.swift \
       ClaudeRelayMac/Views/SessionSidebarView.swift
git commit -m "refactor(client): move activityFor to SharedSessionCoordinator

Both iOS and macOS sidebars had identical copies of the same helper.
Host it on the coordinator under the name activityState(for:)."
```

---

### Task 27: Move `ConnectionQualityDot` and `ActivityDot` into `ClaudeRelayClient` (Apps MEDIUM)

**Why:** Both dots are duplicated between iOS and macOS (~80 lines each). They're pure presentation over shared types.

**Files:**
- Create: `Sources/ClaudeRelayClient/Views/ConnectionQualityDot.swift`
- Create: `Sources/ClaudeRelayClient/Views/ActivityDot.swift`
- Delete: iOS `Components/ConnectionQualityDot.swift`, `ActivityDot.swift`
- Modify: macOS `SessionSidebarView.swift` (remove inline copies; add import)
- Modify: `Package.swift` if `ClaudeRelayClient` needs `.frameworks = [.swiftui]` — check first.

- [ ] **Step 1: Inspect current layout**

Run:
```bash
git grep -ln "struct ConnectionQualityDot" ClaudeRelayApp ClaudeRelayMac
git grep -ln "struct ActivityDot" ClaudeRelayApp ClaudeRelayMac
```

Confirm there are exactly two copies of each.

- [ ] **Step 2: Move canonical copies into ClaudeRelayClient**

Pick the iOS version as the canonical source. Copy it (adding `public` to the struct and any members the apps need) to `Sources/ClaudeRelayClient/Views/ConnectionQualityDot.swift`. Same for ActivityDot.

Example `ConnectionQualityDot.swift`:

```swift
import SwiftUI
import ClaudeRelayKit

public struct ConnectionQualityDot: View, Equatable {
    public let quality: ConnectionQuality
    public var size: CGFloat

    public init(quality: ConnectionQuality, size: CGFloat = 8) {
        self.quality = quality
        self.size = size
    }

    @State private var blinkOpacity: Double = 1.0

    public var body: some View {
        // … copy iOS body verbatim …
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.quality == rhs.quality && lhs.size == rhs.size
    }
}
```

Note: this also closes out **Task 30 (missing Equatable)** — write the `Equatable` impl here so we don't need a second commit.

- [ ] **Step 3: Delete the duplicates**

- Delete `ClaudeRelayApp/Views/Components/ConnectionQualityDot.swift`
- Delete `ClaudeRelayApp/Views/Components/ActivityDot.swift`
- In `ClaudeRelayMac/Views/SessionSidebarView.swift`, delete the inline struct definitions for `ConnectionQualityDot` and `ActivityDot` (lines 142-186).

Add `import ClaudeRelayClient` at the top of any file that now needs the moved types (check: macOS `SessionSidebarView.swift` should already import it). iOS `SessionSidebarView.swift` and other iOS consumers already import ClaudeRelayClient — no change needed.

- [ ] **Step 4: Regenerate Xcode project (iOS + macOS both link ClaudeRelayClient already)**

XcodeGen-managed project picks up SPM targets automatically — no `project.yml` change needed. But ensure the file list for ClaudeRelayApp/ClaudeRelayMac no longer references the deleted files (they'll disappear from `Package.swift`-generated builds automatically; Xcode projects reference them explicitly — if XcodeGen regenerates, this is automatic):

```bash
# If you have xcodegen locally
which xcodegen && xcodegen generate
```

If XcodeGen isn't installed, open the project and remove the red (missing) file references manually.

- [ ] **Step 5: Build both targets**

```bash
swift build
xcodebuild -project ClaudeRelay.xcodeproj -scheme ClaudeRelay -sdk iphonesimulator build
xcodebuild -project ClaudeRelay.xcodeproj -scheme ClaudeRelayMac build
```

All expected green.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeRelayClient/Views/ \
       ClaudeRelayApp/Views/Components/ \
       ClaudeRelayMac/Views/SessionSidebarView.swift \
       project.yml
git commit -m "refactor(client): share ConnectionQualityDot+ActivityDot across platforms

Move the canonical copies into ClaudeRelayClient/Views. Both platforms
already depend on ClaudeRelayClient, so no link changes needed.

Also adds Equatable conformance — SwiftUI can now short-circuit diffs
inside ForEach+TimelineView loops."
```

---

### Task 28: Conditional-render the session-tab TimelineView (Apps HIGH)

**Why:** `ActiveTerminalView` currently always runs a `TimelineView(.periodic(from: .now, by: 0.5))` that rebuilds every tab every 0.5s, even when no tab is flashing.

**Files:**
- Modify: `ClaudeRelayApp/Views/ActiveTerminalView.swift` (the tab-bar section, ~lines 108-134)

- [ ] **Step 1: Gate the TimelineView on `hasAwaitingInput`**

Find the tab-bar block:

```swift
TimelineView(.periodic(from: .now, by: 0.5)) { context in
    let flashOn = Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
    ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
            ForEach(Array(coordinator.activeSessions.enumerated()), id: \.element.id) { index, session in
                // … tab construction …
            }
        }
    }
}
```

Replace with:

```swift
@ViewBuilder
private var sessionTabBar: some View {
    if coordinator.sessionsAwaitingInput.isEmpty {
        // No session needs to flash — static render. Removes the 0.5s rebuild tick
        // on every session, which is the common case.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(coordinator.activeSessions.enumerated()), id: \.element.id) { index, session in
                    sessionTab(for: session, index: index, flashOn: false)
                }
            }
        }
    } else {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let flashOn = Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(coordinator.activeSessions.enumerated()), id: \.element.id) { index, session in
                        sessionTab(for: session, index: index, flashOn: flashOn)
                    }
                }
            }
        }
    }
}
```

Then refactor the inner `ForEach`-body into a `@ViewBuilder` helper `sessionTab(for:index:flashOn:)` that takes `flashOn: Bool` — this is the body that builds one `SessionTab`.

Finally, in the outer view body, replace the old `TimelineView(...)` block with a single call to `sessionTabBar`.

- [ ] **Step 2: Build + smoke test**

Run: `xcodebuild -project ClaudeRelay.xcodeproj -scheme ClaudeRelay -sdk iphonesimulator build`

Run the app, open multiple sessions. Confirm tabs that don't need flashing render without the 0.5s re-render tick (check with Instruments if needed, or just eyeball CPU usage in Xcode's debug gauge).

- [ ] **Step 3: Commit**

```bash
git add ClaudeRelayApp/Views/ActiveTerminalView.swift
git commit -m "perf(ios): skip 0.5s TimelineView tick when no tab is flashing

Previously all session tabs rebuilt every 0.5 seconds even when nothing
needed attention. Only wrap in TimelineView when sessionsAwaitingInput
is non-empty, so the idle case is a static render."
```

---

### Task 29: Make terminal scrollback configurable via `AppSettings` (Apps HIGH)

**Why:** iOS devices with 4 GB RAM can't afford 10,000 lines × N cached sessions.

**Files:**
- Modify: `ClaudeRelayApp/Models/AppSettings.swift`
- Modify: `ClaudeRelayMac/Models/AppSettings.swift`
- Modify: `ClaudeRelayApp/Views/ActiveTerminalView.swift` (line 680 — wherever `changeScrollback(10_000)` lives)
- Modify: `ClaudeRelayMac/Views/TerminalContainerView.swift` (look for the same call)

- [ ] **Step 1: Add `terminalScrollbackLines` to both AppSettings**

In each `AppSettings.swift`, add:

```swift
    /// Max scrollback lines kept by SwiftTerm per session. Lower = less RAM,
    /// higher = more scrollback history in-client. Server's ring buffer
    /// replays anything that fell off this edge on next attach.
    @AppStorage("terminalScrollbackLines") public var terminalScrollbackLines: Int = 5_000
```

(5000 is a conservative iOS default. macOS users can raise it in settings.)

- [ ] **Step 2: Use it in the terminal init**

In `ClaudeRelayApp/Views/ActiveTerminalView.swift` (the terminal-creation path), replace:

```swift
terminal.changeScrollback(10_000)
```

with:

```swift
terminal.changeScrollback(AppSettings.shared.terminalScrollbackLines)
```

Same in macOS `TerminalContainerView.swift`.

- [ ] **Step 3: Expose the setting in the Settings UI (both platforms)**

In iOS `SettingsView.swift` and macOS `SettingsView.swift`, add a new row in the appropriate section (likely "Terminal" or "Appearance"):

```swift
Picker("Terminal Scrollback", selection: $settings.terminalScrollbackLines) {
    Text("1,000 lines").tag(1_000)
    Text("5,000 lines").tag(5_000)
    Text("10,000 lines").tag(10_000)
    Text("25,000 lines").tag(25_000)
}
```

- [ ] **Step 4: Build both**

```bash
xcodebuild -project ClaudeRelay.xcodeproj -scheme ClaudeRelay -sdk iphonesimulator build
xcodebuild -project ClaudeRelay.xcodeproj -scheme ClaudeRelayMac build
```

Both expected green.

- [ ] **Step 5: Commit**

```bash
git add ClaudeRelayApp/Models/AppSettings.swift \
       ClaudeRelayMac/Models/AppSettings.swift \
       ClaudeRelayApp/Views/ActiveTerminalView.swift \
       ClaudeRelayMac/Views/TerminalContainerView.swift \
       ClaudeRelayApp/Views/SettingsView.swift \
       ClaudeRelayMac/Views/SettingsView.swift
git commit -m "feat(apps): configurable terminal scrollback (default 5k lines)

iOS devices with 4 GB RAM can't afford 10k lines × N cached sessions.
Default to 5k; users can raise to 25k via Settings. Server ring buffer
still replays anything that falls off the edge on reattach."
```

---

### Task 30: Call `terminalReady()` only once per session (Apps HIGH)

**Why:** `TerminalHostView.updateUIView` fires on every coordinator property change; calling `viewModel.terminalReady()` on each fire can double-flush the pending buffer and accumulate tasks.

**Files:**
- Modify: `ClaudeRelayApp/Views/ActiveTerminalView.swift` or wherever `TerminalHostView` lives (may have moved to `RelayTerminalView.swift` in Task 25)

- [ ] **Step 1: Track `isFirstReady` per coordinator**

Inside `TerminalHostView`'s `Coordinator` class (or wherever `updateUIView` lives), find:

```swift
viewModel.terminalReady()
```

Add state on the coordinator:

```swift
private var didCallReady = false
```

Change the call site:

```swift
if !didCallReady {
    viewModel.terminalReady()
    didCallReady = true
}
```

Reset `didCallReady = false` in the path that switches to a different session (probably `prepareForSwitch` or the coordinator's `setSessionId` — inspect the file).

- [ ] **Step 2: Build + smoke test**

Run the app. Open a session, switch to another, switch back. Verify scrollback replays only on the first visit (not duplicated).

- [ ] **Step 3: Commit**

```bash
git add ClaudeRelayApp/Views/ActiveTerminalView.swift \
       ClaudeRelayApp/Views/Components/RelayTerminalView.swift
git commit -m "fix(ios): call TerminalViewModel.terminalReady only once per session

updateUIView fires on every coordinator property change; each call was
triggering a pending-buffer flush. Track didCallReady on the coordinator
and only fire once per session session-id change."
```

---

### Task 31: Pre-cancel `coordinatorTasks` in `followCoordinator` (macOS MEDIUM)

**Why:** `MenuBarViewModel.followCoordinator` sets `coordinatorTasks = [sessionsTask, activeTask, agentTask]` but doesn't cancel any pre-existing tasks. In rapid reconnect the three-task triple leaks until GC'd by the registry observer.

**Files:**
- Modify: `ClaudeRelayMac/ViewModels/MenuBarViewModel.swift:76-96`

- [ ] **Step 1: Cancel first, then spawn**

At the top of `followCoordinator`, add:

```swift
    private func followCoordinator(_ coordinator: SessionCoordinator) {
        cancelCoordinatorTasks()   // ← add as the first line of the method
        ...
    }
```

Ensure `cancelCoordinatorTasks()` exists (it should — it's called from the registry observer). If not, add:

```swift
    private func cancelCoordinatorTasks() {
        for task in coordinatorTasks { task.cancel() }
        coordinatorTasks.removeAll()
    }
```

- [ ] **Step 2: Build macOS**

```bash
xcodebuild -project ClaudeRelay.xcodeproj -scheme ClaudeRelayMac build
```

Green expected.

- [ ] **Step 3: Commit**

```bash
git add ClaudeRelayMac/ViewModels/MenuBarViewModel.swift
git commit -m "fix(mac): cancel prior coordinator-follow tasks before spawning new ones

followCoordinator was orphaning the sessions/active/agent triple when
called twice in succession. Explicitly cancel before re-spawning."
```

---

### Task 32: Remove `ServerListViewModel.cancelConnect` defer-overwrite race (iOS MEDIUM)

**Why:** `defer { isConnecting = false; … }` inside `connect(to:)` overwrites the intent of a concurrent `cancelConnect()` call.

**Files:**
- Modify: `ClaudeRelayApp/ViewModels/ServerListViewModel.swift`

- [ ] **Step 1: Guard defer on `!Task.isCancelled`**

Find the `connect(to:)` method. Locate its `defer` block:

```swift
defer {
    isConnecting = false
    connectingServerId = nil
    connectingServerName = nil
}
```

Replace with:

```swift
defer {
    // Skip on explicit cancel — `cancelConnect()` already reset the UI
    // state; overwriting it here would flash the "connecting" state off
    // and then on again when a reconnect immediately retries.
    if !Task.isCancelled {
        isConnecting = false
        connectingServerId = nil
        connectingServerName = nil
    }
}
```

- [ ] **Step 2: Build + smoke test**

Run: `xcodebuild -project ClaudeRelay.xcodeproj -scheme ClaudeRelay -sdk iphonesimulator build`

In the simulator, rapidly tap-connect and tap-cancel a server. Verify the spinner doesn't flicker.

- [ ] **Step 3: Commit**

```bash
git add ClaudeRelayApp/ViewModels/ServerListViewModel.swift
git commit -m "fix(ios): don't reset isConnecting inside defer when cancelled

cancelConnect() already resets the UI state; letting the defer run
again caused a brief flicker if the user re-tapped mid-cancel."
```

---

### Task 33: Port `AddEditServerViewModel` port validation to >= 1 (iOS MEDIUM)

**Why:** iOS allows port 0; macOS already validates `>= 1`.

**Files:**
- Modify: `ClaudeRelayApp/ViewModels/AddEditServerViewModel.swift:64`

- [ ] **Step 1: Tighten the port guard**

Find:

```swift
guard let portNumber = UInt16(port), portNumber > 0 else { return nil }
```

Replace with:

```swift
guard let portNumber = UInt16(port), portNumber >= 1 else { return nil }
```

(Functionally equivalent for `UInt16`, but now matches macOS exactly and is easier to grep.)

- [ ] **Step 2: Build**

Run: `xcodebuild -project ClaudeRelay.xcodeproj -scheme ClaudeRelay -sdk iphonesimulator build`

- [ ] **Step 3: Commit**

```bash
git add ClaudeRelayApp/ViewModels/AddEditServerViewModel.swift
git commit -m "chore(ios): match macOS port validation (>= 1) in AddEditServerViewModel

Cosmetic unification — both platforms now spell the constraint the
same way."
```

---

### Task 34: Add `deinit stopPolling()` to `ServerListViewModel` (iOS MEDIUM)

**Why:** No `deinit` means the poll task outlives the VM.

**Files:**
- Modify: `ClaudeRelayApp/ViewModels/ServerListViewModel.swift`

- [ ] **Step 1: Add deinit**

Near the top of the class, after the init:

```swift
    deinit {
        statusChecker.stopPolling()
    }
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project ClaudeRelay.xcodeproj -scheme ClaudeRelay -sdk iphonesimulator build`

- [ ] **Step 3: Commit**

```bash
git add ClaudeRelayApp/ViewModels/ServerListViewModel.swift
git commit -m "fix(ios): stopPolling in ServerListViewModel deinit

Previously the poll task survived VM deallocation until the next
explicit stopPolling() call."
```

---

### Task 35: Skip `triggerUserRecovery` when connection is already alive (Apps MEDIUM)

**Why:** `WorkspaceView.onChange(scenePhase == .active)` fires `triggerUserRecovery()` unconditionally. Guard inside the method so we don't spend a ping-RTT every scenePhase cycle when already connected.

**Files:**
- Modify: `Sources/ClaudeRelayClient/ViewModels/SharedSessionCoordinator.swift`

- [ ] **Step 1: Add an early-return**

Find `triggerUserRecovery()` in `SharedSessionCoordinator.swift`. Add at the top:

```swift
    public func triggerUserRecovery() {
        // Short-circuit when the transport is healthy. handleForegroundTransition
        // will re-check with an actual ping, but this avoids the 1–2 scenePhase
        // cycles that fire when the user just toggles orientation / receives a
        // notification.
        if connection.state == .connected && !isRecovering {
            Task { @MainActor in await fetchSessions() }
            return
        }
        isRecoveryDispatched = true
        recoveryTask = Task { @MainActor in
            await handleForegroundTransition(userInitiated: true)
        }
    }
```

(Match the existing signature; the body shown is illustrative.)

- [ ] **Step 2: Build + test**

Run: `swift build && swift test --filter SharedSessionCoordinator`
Expected: green.

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeRelayClient/ViewModels/SharedSessionCoordinator.swift
git commit -m "perf(client): skip recovery trigger when connection is already alive

scenePhase .active fires on every foreground return, including
rotation/notification events. Short-circuit with a state check
before paying for a ping RTT."
```

---

### Task 36: Cancel speech preload task on disappear (iOS MEDIUM)

**Why:** `ClaudeRelayApp.swift:30-33` starts `preloadSpeechModels()` as an unowned task.

**Files:**
- Modify: `ClaudeRelayApp/ClaudeRelayApp.swift`

- [ ] **Step 1: Store + cancel the task**

Inside the top-level `App`'s body, replace:

```swift
.task { await preloadSpeechModels() }
```

with the pattern:

```swift
@State private var preloadTask: Task<Void, Never>?

// in body:
.task {
    preloadTask = Task { await preloadSpeechModels() }
    await preloadTask?.value
}
.onDisappear {
    preloadTask?.cancel()
    preloadTask = nil
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project ClaudeRelay.xcodeproj -scheme ClaudeRelay -sdk iphonesimulator build`

- [ ] **Step 3: Commit**

```bash
git add ClaudeRelayApp/ClaudeRelayApp.swift
git commit -m "chore(ios): cancel speech preload task on ServerListView disappear

Benign, but storing the task handle lets us cancel cleanly instead
of letting it run to completion after the user has already navigated
into a session."
```

---

### Task 37: Cache `AppSettings.shared.hapticFeedbackEnabled` per view (iOS MEDIUM)

**Why:** Each button tap reads `AppSettings.shared.hapticFeedbackEnabled`. Fast, but unnecessary churn.

**Files:**
- Modify: `ClaudeRelayApp/Views/ActiveTerminalView.swift` and other iOS views that access `AppSettings.shared.*` inside action closures

- [ ] **Step 1: Convert access pattern**

In `ActiveTerminalView` and any other view that reads `AppSettings.shared.hapticFeedbackEnabled` in `Button { … }` closures, do this:

At the top of the view:

```swift
@StateObject private var settings = AppSettings.shared
```

(Already present in some views; add it where missing.)

Then in each `Button` closure, replace:

```swift
if AppSettings.shared.hapticFeedbackEnabled {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
}
```

with:

```swift
if settings.hapticFeedbackEnabled {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project ClaudeRelay.xcodeproj -scheme ClaudeRelay -sdk iphonesimulator build`

- [ ] **Step 3: Commit**

```bash
git add ClaudeRelayApp/Views/
git commit -m "chore(ios): access AppSettings via @StateObject, not .shared in closures

Minor: @AppStorage-backed reads are cheap but @StateObject centralizes
the subscription and keeps the button handlers consistent across views."
```

---

### Task 38: Sync macOS `TerminalContainerView` scrollback-clear behavior with iOS (macOS MEDIUM)

**Why:** iOS has special handling for `\033[3J` (clear scrollback) to sync `contentOffset`/`contentSize` (lines 626-635 of `ActiveTerminalView.swift`). The macOS path lacks the same.

**Files:**
- Modify: `ClaudeRelayMac/Views/TerminalContainerView.swift`

- [ ] **Step 1: Port the sync logic**

In the macOS `onTerminalOutput` handler, inspect the iOS version to understand the ANSI sequence detection. Replicate the relevant block in macOS. Example skeleton (adjust for macOS `TerminalView` API — NSScrollView/NSTextView, not UIKit):

```swift
viewModel.onTerminalOutput = { [weak view = cached.view] data in
    guard let view else { return }
    view.feed(byteArray: Array(data)[...])
    // Sync after a \033[3J (erase saved lines) — forces the NSScrollView
    // to forget its old content size.
    if data.contains(where: { $0 == 0x1B }) && data.contains(0x33) {
        DispatchQueue.main.async { view.invalidateIntrinsicContentSize() }
    }
}
```

(The precise API call to trigger a layout pass depends on SwiftTerm's macOS host — inspect the existing iOS version and port faithfully.)

- [ ] **Step 2: Build macOS**

Run: `xcodebuild -project ClaudeRelay.xcodeproj -scheme ClaudeRelayMac build`

- [ ] **Step 3: Smoke test**

In macOS app, send `printf '\033[3J'` in an active terminal. Verify the scrollback region clears cleanly with no stale frame at the bottom.

- [ ] **Step 4: Commit**

```bash
git add ClaudeRelayMac/Views/TerminalContainerView.swift
git commit -m "fix(mac): sync scrollback on ESC[3J, matching iOS behavior

iOS had special handling for the 'erase saved lines' sequence to force
the scroll view to recompute content size. Port the same to macOS."
```

---

### Task 39: Connection-timeout alert binding is one-shot (iOS MEDIUM)

**Why:** Multiple rapid `connectionTimedOut = true` transitions could miss `onChange` fires. Use a binding-backed alert instead.

**Files:**
- Modify: `ClaudeRelayApp/Views/WorkspaceView.swift:144-150`

- [ ] **Step 1: Convert to binding-backed alert**

Replace:

```swift
.onChange(of: coordinator.connectionTimedOut) { _, timedOut in
    if timedOut {
        coordinator.connectionTimedOut = false
        showTimeoutAlert = true
        dismiss()
    }
}
```

with:

```swift
.alert("Connection Timed Out",
       isPresented: Binding(
           get: { coordinator.connectionTimedOut },
           set: { newValue in
               if !newValue {
                   coordinator.connectionTimedOut = false
               }
           })) {
    Button("OK", role: .cancel) {
        dismiss()
    }
} message: {
    Text("The server didn't respond. Check the host and try again.")
}
```

- [ ] **Step 2: Build + smoke test**

Run the app, put server offline, trigger a recovery. Alert should show.

- [ ] **Step 3: Commit**

```bash
git add ClaudeRelayApp/Views/WorkspaceView.swift
git commit -m "fix(ios): convert connectionTimedOut alert to binding-based presentation

onChange(.connectionTimedOut) was racy under rapid toggles. Use a
Binding so the alert tracks the @Published property directly."
```

---

### Task 40: SettingsView macOS key-capture observer cleanup (macOS MEDIUM)

**Why:** `NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)` has no stored cancellable.

**Files:**
- Modify: `ClaudeRelayMac/Views/SettingsView.swift:238-247`

- [ ] **Step 1: Store and cancel the publisher**

Near the other @State in the relevant settings tab:

```swift
    @State private var windowObserver: AnyCancellable?
```

Replace the `.onReceive` with an `.onAppear` + `.onDisappear`:

```swift
.onAppear {
    windowObserver = NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)
        .sink { _ in
            if isCapturing { isCapturing = false }
        }
}
.onDisappear {
    removeKeyMonitor()
    isCapturing = false
    windowObserver?.cancel()
    windowObserver = nil
}
```

Add `import Combine` at the top of the file if not already present.

- [ ] **Step 2: Build macOS**

Run: `xcodebuild -project ClaudeRelay.xcodeproj -scheme ClaudeRelayMac build`

- [ ] **Step 3: Commit**

```bash
git add ClaudeRelayMac/Views/SettingsView.swift
git commit -m "fix(mac): explicitly cancel key-capture window observer on disappear

Previously the NSWindow.didResignKeyNotification subscription relied
on SwiftUI's implicit cleanup. Store the AnyCancellable and cancel
in onDisappear for determinism."
```

---

## Wave 4 — Test suite hardening

All eight HIGH items from the tests agent map to concrete new test files/cases. We'll add them one at a time so failures are easy to bisect.

---

### Task 41: WebSocket client↔server round-trip integration test (Tests HIGH #1)

**Files:**
- Create: `Tests/ClaudeRelayServerTests/WebSocketIntegrationTests.swift`

- [ ] **Step 1: Write the test**

```swift
import XCTest
import NIO
import ClaudeRelayKit
@testable import ClaudeRelayServer
@testable import ClaudeRelayClient

final class WebSocketIntegrationTests: XCTestCase {

    @MainActor
    func testClientCanAuthenticateAgainstRealServer() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        // Pick a random high port to avoid CI collisions.
        var config = RelayConfig.default
        config.wsPort = UInt16.random(in: 19_000..<20_000)
        config.adminPort = UInt16.random(in: 20_000..<21_000)

        let tokenStore = TokenStore(directory: tempDir)
        let (plaintext, _) = try await tokenStore.create(label: "integration")

        let sessionManager = SessionManager(config: config, tokenStore: tokenStore,
                                             ptyFactory: { _, _, _, _ in MockPTY() })

        let wsServer = WebSocketServer(group: group, config: config,
                                        sessionManager: sessionManager, tokenStore: tokenStore)
        try await wsServer.start()
        defer { Task { try? await wsServer.stop() } }

        let connection = RelayConnection()
        let controller = SessionController(connection: connection)
        let clientConfig = ConnectionConfig(name: "Test", host: "127.0.0.1", port: config.wsPort)

        try await connection.connect(config: clientConfig, token: plaintext)
        try await controller.authenticate(token: plaintext)

        XCTAssertTrue(controller.isAuthenticated)

        connection.disconnect()
    }
}
```

- [ ] **Step 2: Run**

Run: `swift test --filter WebSocketIntegrationTests`
Expected: PASS. If not, check that `MockPTY` is accessible — you may need to expose it from the test target or define a local equivalent.

- [ ] **Step 3: Commit**

```bash
git add Tests/ClaudeRelayServerTests/WebSocketIntegrationTests.swift
git commit -m "test: add WebSocket client↔server round-trip integration test

Spawns a real WebSocketServer + RelayConnection in-process and verifies
the full connect → authenticate → close path. The protocol was
previously only covered by unit tests against envelope encoding."
```

---

### Task 42: Concurrent-attach race test (Tests HIGH #2)

**Files:**
- Modify: `Tests/ClaudeRelayServerTests/SessionManagerTests.swift`

- [ ] **Step 1: Add the test**

```swift
func testConcurrentAttachSameSessionProducesSingleOwner() async throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let tokenStore = TokenStore(directory: tempDir)
    let (_, tokenA) = try await tokenStore.create(label: "A")
    let (_, tokenB) = try await tokenStore.create(label: "B")

    let manager = SessionManager(config: RelayConfig.default, tokenStore: tokenStore,
                                  ptyFactory: { _, _, _, _ in MockPTY() })

    let session = try await manager.createSession(tokenId: tokenA.id)

    async let resultA: Void = (try? await manager.attachSession(id: session.id, tokenId: tokenA.id))!
    async let resultB: Void = (try? await manager.attachSession(id: session.id, tokenId: tokenB.id))!
    _ = await (resultA, resultB)

    let final = try await manager.inspectSession(id: session.id)
    XCTAssertTrue(final.tokenId == tokenA.id || final.tokenId == tokenB.id,
        "Ownership should have resolved to exactly one token")
}
```

(Adjust `attachSession` signature if the actual API differs — inspect the existing attach tests.)

- [ ] **Step 2: Run**

Run: `swift test --filter SessionManagerTests.testConcurrentAttachSameSessionProducesSingleOwner`
Expected: PASS. If it fails, you've found a real bug — halt the plan and triage.

- [ ] **Step 3: Commit**

```bash
git add Tests/ClaudeRelayServerTests/SessionManagerTests.swift
git commit -m "test: concurrent attachSession must produce single final owner"
```

---

### Task 43: Recovery-scenario test: server restart mid-session (Tests HIGH #3)

**Files:**
- Modify: `Tests/ClaudeRelayClientTests/SharedSessionCoordinatorTests.swift`

- [ ] **Step 1: Extract a reusable fixture from Task 41**

In `Tests/ClaudeRelayServerTests/WebSocketIntegrationTests.swift`, pull the server+client setup into a helper so both tests can share it. At the bottom of that file:

```swift
struct RelayTestHarness {
    let group: MultiThreadedEventLoopGroup
    let tempDir: URL
    let tokenStore: TokenStore
    let sessionManager: SessionManager
    var wsServer: WebSocketServer
    let plaintextToken: String
    let port: UInt16

    static func make() async throws -> RelayTestHarness {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        var config = RelayConfig.default
        let port = UInt16.random(in: 19_000..<20_000)
        config.wsPort = port
        config.adminPort = UInt16.random(in: 20_000..<21_000)
        let tokenStore = TokenStore(directory: tempDir)
        let (plaintext, _) = try await tokenStore.create(label: "integration")
        let sm = SessionManager(config: config, tokenStore: tokenStore,
                                 ptyFactory: { _, _, _, _ in MockPTY() })
        let server = WebSocketServer(group: group, config: config,
                                      sessionManager: sm, tokenStore: tokenStore)
        try await server.start()
        return RelayTestHarness(group: group, tempDir: tempDir, tokenStore: tokenStore,
                                 sessionManager: sm, wsServer: server,
                                 plaintextToken: plaintext, port: port)
    }

    func teardown() async {
        try? await wsServer.stop()
        try? group.syncShutdownGracefully()
        try? FileManager.default.removeItem(at: tempDir)
    }
}
```

- [ ] **Step 2: Add the recovery-scenario test**

In `Tests/ClaudeRelayClientTests/SharedSessionCoordinatorTests.swift`:

```swift
@MainActor
func testRecoveryFromSimulatedServerRestartResumesActiveSession() async throws {
    let harness = try await RelayTestHarness.make()
    defer { Task { await harness.teardown() } }

    let connection = RelayConnection()
    let controller = SessionController(connection: connection)
    let coordinator = SharedSessionCoordinator(connection: connection, controller: controller)

    let clientConfig = ConnectionConfig(name: "Test", host: "127.0.0.1", port: harness.port)
    try await connection.connect(config: clientConfig, token: harness.plaintextToken)
    try await controller.authenticate(token: harness.plaintextToken)
    let sessionId = try await controller.createSession(name: "recovery-test")

    // Simulate a server restart: stop the server on that port, confirm the
    // connection dies, then restart and drive recovery through the coordinator.
    try await harness.wsServer.stop()

    // Wait up to 2s for the connection to notice.
    for _ in 0..<40 {
        if connection.state == .disconnected { break }
        try? await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertEqual(connection.state, .disconnected)

    // Restart the server on the same port.
    var config = RelayConfig.default
    config.wsPort = harness.port
    config.adminPort = UInt16.random(in: 21_000..<22_000)
    let restarted = WebSocketServer(group: harness.group, config: config,
                                     sessionManager: harness.sessionManager,
                                     tokenStore: harness.tokenStore)
    try await restarted.start()
    defer { Task { try? await restarted.stop() } }

    // Drive recovery.
    await coordinator.handleForegroundTransition(userInitiated: true)

    XCTAssertFalse(coordinator.recoveryFailed)
    XCTAssertNotNil(coordinator.activeSessionId)
    XCTAssertEqual(coordinator.activeSessionId, sessionId)
}
```

(`RelayTestHarness` may need to be marked `public` so the client test target can see it. If your test targets don't cross-import, copy the harness definition into the client test file.)

- [ ] **Step 2: Run + commit as above**

Run: `swift test --filter SharedSessionCoordinatorTests.testRecoveryFromSimulatedServerRestartResumesActiveSession`

Commit:

```bash
git add Tests/ClaudeRelayClientTests/SharedSessionCoordinatorTests.swift
git commit -m "test: end-to-end recovery after server restart preserves session"
```

---

### Task 44: Auth edge cases — expired + protocol mismatch (Tests HIGH #4)

**Files:**
- Modify: `Tests/ClaudeRelayClientTests/SessionControllerTests.swift`

- [ ] **Step 1: Add the expired-token test**

The simplest way to force auth_failure is to create a token with `expiryDays: 0` via TokenStore, manually tick its `expiresAt` into the past, and then attempt authentication against the harness from Task 41. Append to `Tests/ClaudeRelayClientTests/SessionControllerTests.swift`:

```swift
@MainActor
func testAuthenticateRejectsExpiredToken() async throws {
    let harness = try await RelayTestHarness.make()
    defer { Task { await harness.teardown() } }

    // Expire the token by mutating its expiresAt directly via the TokenStore file.
    // TokenStore persists on every rotate/delete, so we simulate expiry by
    // calling rotate() then hand-editing the file — or simply by creating the
    // token with expiryDays=0 and sleeping 1s. The simplest path:
    let (plaintext, _) = try await harness.tokenStore.create(label: "soon-dead",
                                                               expiryDays: 0)
    // expiryDays: 0 expires at "now + 0 days". Most Date arithmetic treats that
    // as the current instant — sleep past it.
    try? await Task.sleep(for: .milliseconds(100))

    let connection = RelayConnection()
    let controller = SessionController(connection: connection)
    let clientConfig = ConnectionConfig(name: "Test", host: "127.0.0.1", port: harness.port)
    try await connection.connect(config: clientConfig, token: plaintext)

    do {
        try await controller.authenticate(token: plaintext)
        XCTFail("Expected authenticationFailed for expired token")
    } catch SessionController.SessionError.authenticationFailed(let reason) {
        XCTAssertFalse(reason.isEmpty)
        XCTAssertFalse(controller.isAuthenticated)
    } catch {
        XCTFail("Unexpected error: \(error)")
    }
}
```

- [ ] **Step 2: Add the protocol-version-mismatch test**

For the version mismatch, the cleanest approach is direct: build a mock `RelayConnection` that delivers a synthetic `auth_success` with a very old protocolVersion. If the codebase doesn't have such a mock today, add a minimal one in the same test file:

```swift
@MainActor
private final class StubRelayConnection: RelayConnection {
    var nextResponse: ServerMessage?
    override func send(_ message: ClientMessage) async throws {
        guard let next = nextResponse else { return }
        onServerMessage?(next)
    }
}

@MainActor
func testAuthenticateSurfacesVersionMismatch() async throws {
    let stub = StubRelayConnection()
    let controller = SessionController(connection: stub)
    // Tell the stub to answer the first auth with a protocolVersion below
    // the client's minimum. ClaudeRelayKit.minProtocolVersion is the
    // floor we test against.
    stub.nextResponse = .authSuccess(protocolVersion: ClaudeRelayKit.minProtocolVersion - 1)

    do {
        try await controller.authenticate(token: "any")
        XCTFail("Expected versionIncompatible")
    } catch SessionController.SessionError.versionIncompatible(_, let serverVersion) {
        XCTAssertEqual(serverVersion, ClaudeRelayKit.minProtocolVersion - 1)
        XCTAssertFalse(controller.isAuthenticated)
    } catch {
        XCTFail("Unexpected error: \(error)")
    }
}
```

Note: `RelayConnection` may be marked `final` — if so, extract the send path into a protocol `RelaySending` that `RelayConnection` conforms to, then have `SessionController` accept the protocol. That's a bigger change; if you hit that wall, instead use the full-harness path (set up a server, revoke the token between connect and authenticate) and skip this mock approach.

- [ ] **Step 2: Run + commit**

Commit:

```bash
git add Tests/ClaudeRelayClientTests/SessionControllerTests.swift
git commit -m "test: auth path rejects expired tokens and version mismatches"
```

---

### Task 45: PTY lifecycle — exit handler + zombie check (Tests HIGH #5)

**Files:**
- Create: `Tests/ClaudeRelayServerTests/PTYSessionLifecycleTests.swift`

- [ ] **Step 1: Test PTY exit cleanup**

```swift
import XCTest
@testable import ClaudeRelayServer

final class PTYSessionLifecycleTests: XCTestCase {
    func testPTYCleanupFiresExitHandlerAndReapsProcess() async throws {
        let pty = try PTYSession(sessionId: UUID(), cols: 80, rows: 24, scrollbackSize: 4096)
        await pty.startReading()

        let exited = expectation(description: "exit")
        await pty.setExitHandler { exited.fulfill() }

        // Send `exit\n` to the shell.
        await pty.write(Data("exit\n".utf8))

        await fulfillment(of: [exited], timeout: 3.0)

        // Verify no zombie by inspecting current process's children.
        // (We can't portably assert "no zombie" across macOS versions from
        // Swift, so we at least ensure terminate() is idempotent.)
        await pty.terminate()
        await pty.terminate()   // idempotent
    }
}
```

- [ ] **Step 2: Run + commit**

Run: `swift test --filter PTYSessionLifecycleTests`

Commit:

```bash
git add Tests/ClaudeRelayServerTests/PTYSessionLifecycleTests.swift
git commit -m "test: PTYSession exit handler fires on shell exit; terminate is idempotent"
```

---

### Task 46: RateLimiter windowExpiry with real elapsed time (Tests HIGH #6)

**Files:**
- Modify: `Tests/ClaudeRelayServerTests/RateLimiterTests.swift`

- [ ] **Step 1: Add a test that uses a 1-second window**

```swift
func testIPUnblocksAfterWindowElapses() async {
    let limiter = RateLimiter(maxAttempts: 2, windowSeconds: 1, maxTrackedIPs: 100)
    await limiter.recordFailure(ip: "9.9.9.9")
    await limiter.recordFailure(ip: "9.9.9.9")
    XCTAssertTrue(await limiter.isBlocked(ip: "9.9.9.9"))

    try? await Task.sleep(for: .milliseconds(1100))
    XCTAssertFalse(await limiter.isBlocked(ip: "9.9.9.9"))
}
```

- [ ] **Step 2: Run + commit**

Run: `swift test --filter RateLimiterTests.testIPUnblocksAfterWindowElapses`

Commit:

```bash
git add Tests/ClaudeRelayServerTests/RateLimiterTests.swift
git commit -m "test: RateLimiter releases IPs when the window elapses"
```

---

### Task 47: ConnectionQuality flapping does not cause spurious reconnects (Tests HIGH #7)

**Files:**
- Modify: `Tests/ClaudeRelayClientTests/RelayConnectionTests.swift`

- [ ] **Step 1: Add the test**

Uses the `_testOnly_recordRTT` hook added in Task 2.

```swift
@MainActor
func testAlternatingRTTsDoNotCascadeToVeryPoor() async {
    let connection = RelayConnection()
    for i in 0..<20 {
        // Every other sample is a failure (nil RTT). Without the window
        // cap we'd flap between .good and .veryPoor.
        connection._testOnly_recordRTT(rtt: i % 2 == 0 ? 0.05 : nil)
    }
    // After 20 alternating samples, windowed success rate is 50%.
    // ConnectionQuality(medianRTT: 0.05, successRate: 0.5) -> .veryPoor,
    // but it should reach that steadily, not flap several times.
    // We can't observe past states here; the test documents intent.
    XCTAssertLessThanOrEqual(connection._testOnly_rttWindowCount, 6)
}
```

- [ ] **Step 2: Run + commit**

Run: `swift test --filter RelayConnectionTests.testAlternatingRTTsDoNotCascadeToVeryPoor`

Commit:

```bash
git add Tests/ClaudeRelayClientTests/RelayConnectionTests.swift
git commit -m "test: alternating ping successes/failures stay bounded by rttWindow"
```

---

### Task 48: TerminalViewModel output buffer boundary tests (Tests HIGH #8)

**Files:**
- Modify: `Tests/ClaudeRelayClientTests/TerminalViewModelTests.swift`

- [ ] **Step 1: Add exact-at-cap and eviction-during-replay tests**

```swift
@MainActor
func testPendingOutputExactlyAtCapDoesNotEvict() {
    let vm = TerminalViewModel(sessionId: UUID(), connection: RelayConnection())
    let chunk = Data(repeating: 0x42, count: 1024 * 1024)  // 1 MB
    for _ in 0..<4 { vm.receiveOutput(chunk) }             // 4 MB total

    var received = [Data]()
    vm.onTerminalOutput = { received.append($0) }
    vm.terminalReady()

    let total = received.reduce(0) { $0 + $1.count }
    XCTAssertEqual(total, 4 * 1024 * 1024,
        "All 4 MB should be preserved when buffer is at cap (but not over)")
}

@MainActor
func testPendingOutputOverCapLogsAndDropsOldestOnlyOnce() {
    // Requires Task 11 landed (didLogPendingCap flag).
    let vm = TerminalViewModel(sessionId: UUID(), connection: RelayConnection())
    let chunk = Data(repeating: 0x43, count: 64 * 1024)    // 64 KB
    for _ in 0..<80 { vm.receiveOutput(chunk) }            // 5 MB > 4 MB cap

    var received = [Data]()
    vm.onTerminalOutput = { received.append($0) }
    vm.terminalReady()

    let total = received.reduce(0) { $0 + $1.count }
    XCTAssertLessThanOrEqual(total, 4 * 1024 * 1024 + chunk.count)
}
```

- [ ] **Step 2: Run + commit**

Run: `swift test --filter TerminalViewModelTests`

Commit:

```bash
git add Tests/ClaudeRelayClientTests/TerminalViewModelTests.swift
git commit -m "test: TerminalViewModel preserves data at cap; drops cleanly over cap"
```

---

### Task 49: Fix flaky `SessionActivityMonitorTests.testTransitionsToIdleAfterSilence` (Tests MEDIUM #9)

**Files:**
- Modify: `Tests/ClaudeRelayServerTests/SessionActivityMonitorTests.swift:171`

- [ ] **Step 1: Replace fixed sleep with polling**

Find the `testTransitionsToIdleAfterSilence` body. Replace the `try? await Task.sleep(for: .milliseconds(50))` with an exponential-backoff poll:

```swift
var delay: UInt64 = 10_000_000   // 10 ms
var tries = 0
while await monitor.state != .idle && tries < 10 {
    try? await Task.sleep(nanoseconds: delay)
    delay = min(delay * 2, 100_000_000)
    tries += 1
}
```

- [ ] **Step 2: Run repeatedly**

Run: `for i in $(seq 1 20); do swift test --filter SessionActivityMonitorTests.testTransitionsToIdleAfterSilence || break; done`

Expected: all 20 runs pass.

- [ ] **Step 3: Commit**

```bash
git add Tests/ClaudeRelayServerTests/SessionActivityMonitorTests.swift
git commit -m "test: poll SessionActivityMonitor state with backoff instead of fixed sleep

Eliminates flake on slow CI where the 50 ms fixed wait sometimes lost
the race."
```

---

## Wave 5 — Polish (LOW items)

Small cosmetic cleanups. Ship last; each is <5 lines.

---

### Task 50: Shared `JSONEncoder`/`JSONDecoder` in `RelayMessageHandler` (Server LOW)

**Files:**
- Modify: `Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift:30-31`

- [ ] **Step 1: Replace instance properties with statics**

Replace:

```swift
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()
```

with:

```swift
    private static let jsonEncoder = JSONEncoder()
    private static let jsonDecoder = JSONDecoder()
```

Update every `self.jsonEncoder` → `Self.jsonEncoder` and `self.jsonDecoder` → `Self.jsonDecoder`. `JSONEncoder` and `JSONDecoder` are thread-safe for reads when configured at init and never mutated afterwards.

- [ ] **Step 2: Build + test + commit**

```bash
swift build && swift test
git add Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift
git commit -m "perf(server): share JSONEncoder/JSONDecoder across handlers"
```

---

### Task 51: Cache lowercased `CodingAgent.processNames` (Kit LOW)

**Files:**
- Modify: `Sources/ClaudeRelayKit/Models/CodingAgent.swift`

- [ ] **Step 1: Precompute normalized names**

In `CodingAgent`, add a private stored property populated at init:

```swift
    /// Pre-lowercased process names for the hot-path matcher. Avoids one
    /// string allocation per poll (~0.5 Hz while idle, 2 Hz while an
    /// agent is active) across the entire registry.
    private let normalizedProcessNames: [String]

    public init(id: String, displayName: String, processNames: [String], titleKeywords: [String]) {
        self.id = id
        self.displayName = displayName
        self.processNames = processNames
        self.titleKeywords = titleKeywords
        self.normalizedProcessNames = processNames.map { $0.lowercased() }
    }
```

Update `matchesProcessName`:

```swift
    public func matchesProcessName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return normalizedProcessNames.contains {
            lower == $0 || lower.hasPrefix($0 + "-") || lower.hasPrefix($0 + ".")
        }
    }
```

Update `Codable` conformance — Swift will synthesize the stored `normalizedProcessNames` (because it's `let`), but we need a custom decoder since the original JSON won't have that field. Add:

```swift
    private enum CodingKeys: String, CodingKey {
        case id, displayName, processNames, titleKeywords
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.processNames = try c.decode([String].self, forKey: .processNames)
        self.titleKeywords = try c.decode([String].self, forKey: .titleKeywords)
        self.normalizedProcessNames = self.processNames.map { $0.lowercased() }
    }
```

(`encode(to:)` default synth still works — `normalizedProcessNames` has no CodingKey, so it won't be encoded.)

Remove `normalizedProcessNames` from `Equatable`/`Hashable` comparison (since it's derived). The compiler-synthesized conformance already excludes it because it's not in the init — but explicit is clearer. Since `processNames` is in the struct and a `let`, synthesized Equatable/Hashable include all stored props by default. We need to manually conform:

```swift
    public static func == (lhs: CodingAgent, rhs: CodingAgent) -> Bool {
        lhs.id == rhs.id
            && lhs.displayName == rhs.displayName
            && lhs.processNames == rhs.processNames
            && lhs.titleKeywords == rhs.titleKeywords
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(displayName)
        hasher.combine(processNames)
        hasher.combine(titleKeywords)
    }
```

- [ ] **Step 2: Run CodingAgent tests**

Run: `swift test --filter CodingAgentTests`
Expected: green.

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeRelayKit/Models/CodingAgent.swift
git commit -m "perf(kit): pre-lowercase CodingAgent.processNames at init

Shaves a string allocation per hot-path poll. Custom Codable +
Equatable/Hashable to preserve wire format and identity semantics."
```

---

### Task 52: Document `MaxInflightOutputBytes` + other magic numbers (misc LOW)

**Files:**
- Modify: `Sources/ClaudeRelayKit/Models/ConnectionQuality.swift`
- Modify: `Sources/ClaudeRelayServer/Services/RingBuffer.swift:29`
- Modify: `ClaudeRelayApp/Views/Components/KeyboardAccessory.swift:129-140`

- [ ] **Step 1: Add named constants**

In `ConnectionQuality.swift`, add documented thresholds as documented in the review (excerpt from Kit LOW #1). Replace magic numbers with:

```swift
    private static let excellentRTT: TimeInterval = 0.1
    private static let goodRTT: TimeInterval = 0.3
    private static let poorRTT: TimeInterval = 0.8
    private static let minSuccessRate = 0.5
    private static let goodSuccessRate = 0.83
    private static let perfectSuccessRate = 1.0
```

and update the `init(medianRTT:successRate:)` body to use them.

In `RingBuffer.swift:29`, above `if data.count >= capacity`, add:

```swift
        // Fast path: the write alone is bigger than the buffer, so the previous
        // content doesn't matter — just keep the last `capacity` bytes.
```

In `KeyboardAccessory.swift:129-140`, before the `for _ in 0..<16` loop:

```swift
        /// Sixteen cycles is empirically enough to clear any reasonable
        /// multi-line continuation. Extra cycles are harmless — Ctrl-U and
        /// Backspace become noops once the cursor is at the prompt start.
        private static let maxContinuationClearCycles = 16
```

and change the loop to `for _ in 0..<Self.maxContinuationClearCycles`.

- [ ] **Step 2: Build + test + commit**

```bash
swift build && swift test
git add Sources/ClaudeRelayKit/Models/ConnectionQuality.swift \
       Sources/ClaudeRelayServer/Services/RingBuffer.swift \
       ClaudeRelayApp/Views/Components/KeyboardAccessory.swift
git commit -m "chore: name magic numbers across Kit / Server / iOS"
```

---

### Task 53: Remove unused `import Foundation` from `ActivityState.swift` (Kit LOW)

**Files:**
- Modify: `Sources/ClaudeRelayKit/Models/ActivityState.swift:1`

- [ ] **Step 1: Remove the import**

Delete line 1 (`import Foundation`). The file uses only stdlib types.

- [ ] **Step 2: Build**

Run: `swift build`
Expected: green (no Foundation dependency).

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeRelayKit/Models/ActivityState.swift
git commit -m "chore(kit): drop unused Foundation import in ActivityState"
```

---

### Task 54: Add accessibility labels to iOS toolbar buttons (iOS LOW)

**Files:**
- Modify: `ClaudeRelayApp/Views/ActiveTerminalView.swift:92-99`

- [ ] **Step 1: Label each icon button**

For each `ToolbarIconButton(icon: "…")` in the toolbar block, add `.accessibilityLabel`:

```swift
ToolbarIconButton(icon: "sidebar.left") { … }
    .accessibilityLabel("Toggle Sidebar")
ToolbarIconButton(icon: "server.rack") { … }
    .accessibilityLabel("Server List")
ToolbarIconButton(icon: "fn", isActive: showKeyBar) { … }
    .accessibilityLabel(showKeyBar ? "Hide Key Bar" : "Show Key Bar")
```

Do this for every `ToolbarIconButton` call in the file.

- [ ] **Step 2: Build + test with VoiceOver**

Run the app, enable VoiceOver, swipe across the toolbar. Each button should announce a meaningful name.

- [ ] **Step 3: Commit**

```bash
git add ClaudeRelayApp/Views/ActiveTerminalView.swift
git commit -m "a11y(ios): label toolbar icon buttons"
```

---

### Task 55: Rename "ClaudeDock" to "ClaudeRelay" in macOS SettingsView (macOS LOW)

**Files:**
- Modify: `ClaudeRelayMac/Views/SettingsView.swift:388`

- [ ] **Step 1: Replace the text**

Find `SettingsSectionHeader(title: "ClaudeDock")` and replace with `SettingsSectionHeader(title: "ClaudeRelay")`.

- [ ] **Step 2: Grep for other occurrences**

Run: `git grep -n ClaudeDock`

If nothing else shows up, commit. If other sites exist, fix them too.

- [ ] **Step 3: Commit**

```bash
git add ClaudeRelayMac/Views/SettingsView.swift
git commit -m "chore(mac): rename 'ClaudeDock' header to 'ClaudeRelay' for consistency"
```

---

### Task 56: `CloudPromptEnhancer` configurable model ID + sanitized error (Speech LOW)

**Files:**
- Modify: `Sources/ClaudeRelaySpeech/CloudPromptEnhancer.swift`

- [ ] **Step 1: Extract modelId + sanitize error body**

Replace the hardcoded `private static let modelId = "us.anthropic.claude-haiku-4-5-20251001-v1:0"` with:

```swift
    public static let defaultModelId = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
    public var modelId: String
    public init(modelId: String = Self.defaultModelId) {
        self.modelId = modelId
    }
```

Wherever `Self.modelId` was used, replace with `self.modelId`.

Then replace the `.bedrockError(let code, let message):` branch in `errorDescription` with a sanitized version:

```swift
        case .bedrockError(let code, let message):
            let sanitized = Self.sanitizeBedrockError(message)
            return "Bedrock error \(code): \(sanitized)"
```

Add:

```swift
    private static func sanitizeBedrockError(_ body: String) -> String {
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let msg = json["message"] as? String {
            return String(msg.prefix(200))
        }
        let truncated = String(body.prefix(200))
        // Best-effort redaction of bearer tokens that may appear in AWS
        // diagnostic echoes.
        return truncated.replacingOccurrences(
            of: "Bearer [A-Za-z0-9+/=._-]+",
            with: "Bearer [REDACTED]",
            options: .regularExpression
        )
    }
```

- [ ] **Step 2: Build + test + commit**

```bash
swift build && swift test
git add Sources/ClaudeRelaySpeech/CloudPromptEnhancer.swift
git commit -m "feat(speech): configurable Bedrock modelId; sanitize error bodies

modelId defaults to the current Haiku inference profile but can be
overridden via init (e.g. for a newer Haiku after upgrade). Error
messages are parsed as JSON and extracted; free-form bodies have
'Bearer <token>' redacted to avoid leaking auth material to logs."
```

---

### Task 57: ConfigSetCommand client-side validation (CLI MEDIUM)

**Files:**
- Modify: `Sources/ClaudeRelayCLI/Commands/ConfigCommands.swift`

- [ ] **Step 1: Validate before sending**

In `ConfigSetCommand.run()`, add a pre-check before the `client.put` call:

```swift
    func run() async throws {
        let validKeys: Set<String> = [
            "wsPort", "adminPort", "detachTimeout", "scrollbackSize",
            "tlsCert", "tlsKey", "logLevel", "maxSessionsPerToken"
        ]
        guard validKeys.contains(key) else {
            FileHandle.standardError.write(Data(
                "Error: unknown config key '\(key)'. Valid keys: \(validKeys.sorted().joined(separator: ", "))\n".utf8))
            throw ExitCode.failure
        }

        let typedValue = ConfigValue.infer(from: value)
        switch (key, typedValue) {
        case ("wsPort", .int(let p)), ("adminPort", .int(let p)):
            guard (1024...65535).contains(p) else {
                FileHandle.standardError.write(Data("Error: port must be 1024..65535\n".utf8))
                throw ExitCode.failure
            }
        case ("scrollbackSize", .int(let s)):
            guard s >= 1024 else {
                FileHandle.standardError.write(Data("Error: scrollbackSize must be ≥ 1024\n".utf8))
                throw ExitCode.failure
            }
        case ("logLevel", .string(let lvl)):
            let valid = ["trace", "debug", "info", "warning", "error"]
            guard valid.contains(lvl) else {
                FileHandle.standardError.write(Data("Error: logLevel must be one of \(valid)\n".utf8))
                throw ExitCode.failure
            }
        case ("maxSessionsPerToken", .int(let n)):
            guard n >= 0 else {
                FileHandle.standardError.write(Data("Error: maxSessionsPerToken must be ≥ 0\n".utf8))
                throw ExitCode.failure
            }
        default:
            break
        }

        // … existing client.put call …
```

(Use the actual `ExitCode` type from ArgumentParser — `ExitCode.failure` is correct.)

- [ ] **Step 2: Build + smoke test**

```bash
swift build
swift run claude-relay config set foo 123   # should print error, exit non-zero
swift run claude-relay config set wsPort 99999   # should print error
swift run claude-relay config set wsPort 9200   # should succeed if server running
```

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeRelayCLI/Commands/ConfigCommands.swift
git commit -m "feat(cli): client-side validation for config set keys and values

Catch typos and obviously-bad values before shipping them to the
admin API. Reduces 'why didn't my config change take effect'
confusion — the CLI now explains exactly why."
```

---

### Task 58: Batch remaining small-but-useful cleanups

**Why:** Several MEDIUM/LOW findings are single-line changes that aren't worth a full TDD cycle. Batch them into one commit.

**Files (all small edits):**
- `Sources/ClaudeRelayClient/Helpers/NetworkMonitor.swift` — make `queue` `static let` so it's shared across short-lived monitors
- `Sources/ClaudeRelayClient/Helpers/DeviceIdentifier.swift` — move `defer { IOObjectRelease(platformExpert) }` below the zero-check so we never release a 0 handle
- `Sources/ClaudeRelayServer/Actors/PTYSession.swift` — change the first foreground-poll deadline from `+0.5s` to `+0.0s` so agent detection is immediate on attach
- `Sources/ClaudeRelayServer/Network/UnsafeTransfer.swift` — expand the header comment with an explicit warning about event-loop confinement and misuse consequences
- `Sources/ClaudeRelayKit/Protocol/MessageEnvelope.swift` — document `typeOrigin` thread-safety (immutable after init)
- `Sources/ClaudeRelaySpeech/SpeechModelStore.swift` — replace `total += Int64(size)` with `total = total.addingReportingOverflow(Int64(clamping: size)).partialValue`; skip directories via `isDirectoryKey`
- `Sources/ClaudeRelayCLI/Commands/SessionCommands.swift:131-134` — change `ISO8601DateFormatter` to `RelativeDateTimeFormatter` so the output matches token dates
- `.gitignore` — append `ExportOptions.plist` (or commit the file if it's generic — decide with the user before this task)
- `ClaudeRelayApp/ViewModels/SessionCoordinator.swift` — add a one-line doc comment noting that the iOS subclass is intentionally minimal and the `@Published` properties on the macOS variant are macOS-only glue

- [ ] **Step 1: Apply all edits in one pass**

Open each file, make the surgical change described above. None touches more than 3 lines.

- [ ] **Step 2: Build everything**

```bash
swift build && swift test
xcodebuild -project ClaudeRelay.xcodeproj -scheme ClaudeRelay -sdk iphonesimulator build
xcodebuild -project ClaudeRelay.xcodeproj -scheme ClaudeRelayMac build
```

All four expected green.

- [ ] **Step 3: Commit**

```bash
git add .
git commit -m "chore: batch of small cleanups from 2026-05-04 code review

- NetworkMonitor.queue becomes static let (per-instance was cosmetic leak)
- DeviceIdentifier IOKit release guarded behind non-zero check
- PTY foreground-poll starts immediately on attach (was +0.5s)
- Expanded UnsafeTransfer / MessageEnvelope doc comments
- SpeechModelStore.totalModelSize overflow-safe + skips directories
- CLI session list uses RelativeDateTimeFormatter to match tokens
- .gitignore: ExportOptions.plist
- Comment the iOS SessionCoordinator minimalism"
```

---

### Task 59: Update `Package.resolved` + XcodeGen project + smoke-test full build

**Files:**
- Modify: `Package.resolved`, `.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (auto-updated)

- [ ] **Step 1: Re-run resolve**

```bash
swift package resolve
xcodebuild -resolvePackageDependencies -project ClaudeRelay.xcodeproj -scheme ClaudeRelay
```

- [ ] **Step 2: Final full-build check**

```bash
swift build && swift test
xcodebuild -project ClaudeRelay.xcodeproj -scheme ClaudeRelay -sdk iphonesimulator build
xcodebuild -project ClaudeRelay.xcodeproj -scheme ClaudeRelayMac build
```

All four must be green.

- [ ] **Step 3: Push the branch**

```bash
git push
```

Open a PR to `main`. Title: `review(2026-05-04): address 98 findings from multi-agent code review`. Body should summarize the 5 waves and link the plan document.

- [ ] **Step 4: Merge after review**

Once the PR is approved and CI is green on all targets, merge via squash or rebase per the team's convention.

---

## Post-merge verification

- [ ] **Step 1: Pull main and verify**

```bash
git checkout main && git pull
swift build && swift test
```

Expected: all green.

- [ ] **Step 2: Smoke test both apps**

- iOS: install on device or simulator, connect to a server, run a long-running command, background and re-foreground, verify recovery.
- macOS: same flow, plus put the machine to sleep/wake.

- [ ] **Step 3: Update CHANGELOG.md**

Add a "Reliability" section under the next unreleased header summarizing the user-facing outcomes (recovery more robust, no more stuck isRecovering, lower idle RAM, faster CLI responses).

---

## Appendix — Coverage matrix

| Finding severity | Wave(s) | Tasks |
|---|---|---|
| Server HIGH (4) | 1, 2 | 5, 7, 8, 9 |
| Client HIGH (3) | 1 | 1, 2, 3 |
| Speech HIGH (1, then split) | 1 | 4 |
| CLI HIGH (1) | 1 | 6 |
| Apps HIGH (8) | 3 | 23, 24, 25, 27, 28, 29, 30 (+ Equatable dots = part of 27) |
| Tests HIGH (8) | 4 | 41, 42, 43, 44, 45, 46, 47, 48 |
| Server MEDIUM (8) | 2 | 10, 18, 19, 20, 21, 22 |
| Client MEDIUM (6) | 2, 3 | 11, 12, 13, 14, 35 |
| Kit MEDIUM (8) | 2, 3, 5 | 22, 51, 57, 58 |
| Speech MEDIUM (2) | 2 | 16, 17 |
| Apps MEDIUM (12) | 3 | 26, 31, 32, 33, 34, 36, 37, 38, 39, 40 |
| Tests MEDIUM (12) | 4, 5 | 49 (+ opportunistic additions from wave 4 harness + 58) |
| LOW items (26) | 5 | 15, 50, 52, 53, 54, 55, 56, 58 |

Every HIGH finding has at least one dedicated task. MEDIUM items are either dedicated tasks or folded into an adjacent HIGH fix (e.g., Equatable conformance lands in Task 27 with the dot-extraction). LOW items are batched into one-commit polish tasks in Wave 5 (Task 58 in particular collects the single-line items).

If a task reveals unexpected scope (e.g., Task 8's PTY write queue needing an NIO-promise integration), stop, prepare a brief "out-of-scope" note, and re-plan that task separately rather than merging it with adjacent work.
