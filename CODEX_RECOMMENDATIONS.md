# Codex Recommendations

Review date: 2026-05-02

Scope: repository-level code review focused on optimization opportunities, correctness risks, maintainability, and test coverage. No source files were changed during the review.

Verification run:

```sh
swift test
```

Result: 239 tests passed, 1 test skipped, 0 failures.

## Priority Recommendations

### 1. Keep `RelayMessageHandler` State on the NIO Event Loop

File: `Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift`

The highest-risk area is mutation of connection-scoped state from mixed execution contexts. `RelayMessageHandler` is a NIO channel handler, so fields such as `attachedSessionId`, `attachedPTY`, observer IDs, `isAuthenticated`, and cleanup state should be treated as event-loop-owned.

Current risk:

- `autoDetachIfNeeded()` mutates `attachedSessionId` and `attachedPTY` from unstructured `Task`s.
- Its comment says it must be called from the event loop, but call sites invoke it inside async tasks before hopping back to `context.eventLoop`.
- Observer callbacks, session attach/resume/create completions, steal notifications, and cleanup can interleave.
- A stale async operation can wire the wrong PTY output handler or clear the current attachment after a newer attach.

Recommended approach:

- Introduce a small event-loop-owned state transition layer for handler state.
- Do async actor work off the event loop, but apply handler mutations only inside `context.eventLoop.execute`.
- Add a per-connection operation generation counter. Increment it before create/attach/resume/detach/reconnect-like operations; discard completions that return with an older generation.
- Make `autoDetachIfNeeded` either synchronous/event-loop-only or move the actor detach work out into a separate async helper that captures immutable session/PTY references.

Suggested shape:

```swift
// Event-loop only:
let previousSessionId = attachedSessionId
let previousPTY = attachedPTY
attachedSessionId = nil
attachedPTY = nil
operationGeneration &+= 1
let generation = operationGeneration

Task {
    if let previousPTY { await previousPTY.clearOutputHandler() }
    if let previousSessionId { try? await sessionManager.detachSession(id: previousSessionId) }
    let result = try await sessionManager.attachSession(...)

    context.eventLoop.execute {
        guard generation == self.operationGeneration else { return }
        self.attachedSessionId = result.id
        self.attachedPTY = result.pty
        self.wirePTYOutput(...)
    }
}
```

Tests to add:

- Start attach A, then attach B before A completes; assert B remains attached.
- Disconnect while observer registration is in flight; assert observers are removed.
- Receive steal notification while an attach is in flight; assert final state is coherent.

### 2. Make Client Ping/Pong Measurement Race-Free

File: `Sources/ClaudeRelayClient/RelayConnection.swift`

`measurePingRTT()` currently sends `.ping` before installing `pendingPongContinuation`. A fast `.pong` can arrive before the continuation exists, causing a false timeout. The class also supports only one pending pong continuation, so concurrent pings can overwrite each other.

Current risk:

- Keepalive and foreground recovery can both call `isAlive()` / `measurePingRTT()`.
- The second ping can replace the first continuation.
- A successful connection can be marked dead after three false failures.
- Recovery can be triggered while the socket is still healthy.

Recommended approach:

- Serialize ping measurement with a dedicated `Task` or state guard.
- Install the waiter before sending the ping.
- Prefer protocol-level request IDs if concurrent ping measurements are needed.
- Resume and clear pending continuations when disconnecting, reconnecting, or changing connection generation.

Minimal direction:

- Add `private var pingInFlight = false`.
- If a ping is already in flight, return the in-flight result or skip this measurement.
- Set `pendingPongContinuation` before `send(.ping)`.
- If `send(.ping)` fails, clear and resume the continuation immediately.

Tests to add:

- Pong arrives immediately after send; measurement succeeds.
- Two simultaneous measurements do not overwrite each other.
- Disconnect while ping is pending resumes the continuation.

### 3. Clarify and Enforce Session Ownership Boundaries

Files:

- `Sources/ClaudeRelayServer/Actors/SessionManager.swift`
- `Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift`
- `Sources/ClaudeRelayClient/ViewModels/SharedSessionCoordinator.swift`

The server currently supports cross-token session attach and exposes `sessionListAll` to any authenticated client. This may be intentional for cross-device handoff, but it means every valid token is effectively in the same trust domain.

Current risk:

- Any authenticated token can list sessions owned by other tokens.
- Any authenticated token can attach to and take ownership of another token's non-terminal session.
- The old owner receives a steal notification, but there is no authorization gate before transfer.

Recommended approach:

- Decide whether tokens are device credentials for one user or independent security principals.
- If tokens are one-user devices, document this clearly in `README.md` and protocol comments.
- If tokens should isolate users/devices, add an explicit authorization model.

Potential authorization options:

- Add token scopes such as `admin`, `device`, `transfer`.
- Add a shared account/group ID to `TokenInfo` and require matching group for cross-token attach.
- Require an explicit short-lived transfer code generated by the current owner.
- Restrict `sessionListAll` to admin or same-group tokens.

Tests to add:

- Cross-token attach is denied without permission.
- Admin or same-group attach still works when intended.
- `sessionListAll` filters or rejects based on scope.

### 4. Avoid PID Reuse Risk in PTY Termination

File: `Sources/ClaudeRelayServer/Actors/PTYSession.swift`

`terminate()` sends `SIGTERM`, then schedules a delayed `SIGKILL` if `kill(pid, 0)` succeeds five seconds later. If the child exits and the PID is reused quickly, the delayed kill could target an unrelated process.

Recommended approach:

- Track process exit and cancel the delayed kill when EOF/exit is observed.
- Prefer creating and killing a process group/session for the PTY child.
- Validate the process identity before sending delayed `SIGKILL`.
- Store the delayed kill work item so it can be cancelled from `handleExit()`.

Tests to add:

- `terminate()` cancels delayed kill when exit is observed.
- `terminate()` is idempotent.
- Failed `SIGTERM` does not schedule unsafe follow-up behavior.

### 5. Harden Image Paste Handling

File: `Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift`

`handlePasteImage` decodes base64 data and writes it to `NSPasteboard.general`. This is a powerful server-side side effect triggered by an authenticated client.

Current risk:

- The server clipboard is global mutable state.
- Decoded data is not validated as PNG beyond base64 decode.
- The operation runs synchronously in the handler path.
- Large base64 text frames are capped at 10 MB, but decoded image constraints are not explicit.

Recommended approach:

- Add an explicit decoded image size limit.
- Validate PNG magic bytes and reject non-PNG data.
- Move pasteboard access onto the main thread if AppKit expectations require it.
- Consider a server config flag for remote clipboard mutation.
- Log paste failures without exposing sensitive payload details.

Tests to add:

- Invalid base64 returns `pasteImageResult(success: false)`.
- Non-PNG base64 is rejected.
- Oversized decoded image is rejected.

### 6. Avoid Shared `JSONEncoder` / `JSONDecoder` Instances in Concurrent Paths

Files:

- `Sources/ClaudeRelayServer/Network/AdminHTTPServer.swift`
- `Sources/ClaudeRelayKit/Services/ConfigManager.swift`

`AdminResponse` uses a static shared `JSONEncoder`. Foundation encoders are mutable reference types. Even if current usage is simple, a shared encoder in a concurrent NIO request path is unnecessary risk.

Recommended approach:

- Replace shared encoders/decoders in concurrent paths with small factories.
- Keep output formatting and date strategies centralized without sharing the instance.

Example:

```swift
private static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}
```

`ConfigManager` is lower risk because config load/save is not obviously hot or highly concurrent, but the same factory pattern would make it simpler to reason about.

## Maintainability Opportunities

### Split `RelayMessageHandler` by Responsibility

File: `Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift`

This file is doing authentication, observer registration, session lifecycle, terminal binary I/O, pasteboard integration, frame encoding, and escape filtering. It is workable, but changes in one area can easily disturb another.

Recommended decomposition:

- Keep the NIO handler as the protocol boundary and event-loop state owner.
- Move session command handling into a small helper that returns actions/results.
- Move observer registration cleanup into a dedicated connection observer registry.
- Move paste image handling into a service with clear validation.
- Move escape filtering into a tested utility.

This would also make race-focused tests easier to write.

### Reduce Unstructured `Task {}` at Boundaries

Several components use unstructured tasks to bridge from callbacks into actors or the main actor. That is sometimes necessary, but the current code would benefit from explicit ownership rules:

- NIO handler mutable state: event loop only.
- UI/view model state: `@MainActor` only.
- Session/PTY state: actor only.
- Long-running or delayed work: store and cancel task handles.

This is more important than style cleanup because most subtle bugs in this codebase will come from stale async completions and callback races.

### Decompose Large UI Files

Large files:

- `ClaudeRelayApp/Views/ActiveTerminalView.swift`
- `ClaudeRelayMac/Views/SettingsView.swift`
- `Sources/ClaudeRelayClient/ViewModels/SharedSessionCoordinator.swift`

Recommended direction:

- Extract small view components only where there is a real state boundary or repeated UI.
- Keep terminal lifecycle and session recovery logic out of SwiftUI views.
- Add focused tests around `SharedSessionCoordinator` recovery behavior before large refactors.

### Improve Recovery State Tests

`SharedSessionCoordinator` owns important recovery behavior, but the most failure-prone paths are hard to validate without deterministic connection fakes.

Recommended approach:

- Introduce a protocol for the subset of `RelayConnection` used by coordinator logic.
- Use a fake connection to test recovery phases, failed reconnects, successful reconnects, session resume, and teardown cancellation.
- Keep `RelayConnection` integration tests separate from coordinator state-machine tests.

## Performance Opportunities

### Ring Buffer Copy Optimization

File: `Sources/ClaudeRelayServer/Services/RingBuffer.swift`

The implementation is simple and covered by tests. For normal scrollback sizes it is probably fine. If terminal output volume becomes a bottleneck, the main copy points are:

- `write(_:)` converts large `Data` slices into arrays when data exceeds capacity.
- `read()` always allocates a new `[UInt8]` and then a `Data`.

Recommended approach only if profiling shows this is hot:

- Store `Data` or `ContiguousArray<UInt8>` and use `withUnsafeBytes`.
- Add a read API that writes into an existing buffer or returns two contiguous slices.
- Keep current implementation until profiling proves terminal replay is costly.

### Foreground Process Polling

File: `Sources/ClaudeRelayServer/Actors/PTYSession.swift`

Each PTY polls foreground process state every second. This is probably acceptable for a small number of sessions, but it can scale poorly with many detached sessions.

Recommended approach:

- Consider pausing or reducing polling frequency for detached sessions.
- Poll more aggressively only for the active attached session.
- Track whether the activity monitor actually needs foreground detection while idle.

## Testing Gaps

Existing package tests are healthy and fast. The next useful tests are concurrency and protocol-boundary tests rather than more codable round trips.

High-value additions:

- Relay handler operation ordering: stale attach/create/resume completions are ignored.
- Observer cleanup when auth succeeds after channel close.
- Ping/pong race and concurrent ping behavior.
- Session authorization boundaries for cross-token attach/list.
- Paste image validation.
- PTY termination delayed-kill cancellation.

## Suggested Implementation Order

1. Fix `RelayConnection.measurePingRTT()` serialization and waiter ordering.
2. Add generation-based state protection to `RelayMessageHandler`.
3. Decide and document/enforce token/session trust boundaries.
4. Harden PTY termination delayed kill.
5. Add paste image validation and pasteboard isolation.
6. Replace shared encoder instances in concurrent paths.
7. Decompose large files only after the race-prone behavior has tests.

