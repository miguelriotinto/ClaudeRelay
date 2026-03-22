# Code Review Fix Plan

## Status Legend
- [ ] Pending
- [~] In Progress
- [x] Fixed
- [-] Skipped (with reason)

---

## Critical

### 1. PTY spawns `/bin/cat` instead of interactive shell
- **File**: `Sources/ClaudeRelayServer/Actors/SessionManager.swift:60`
- **Issue**: `command: "/bin/cat"` is passed to PTYSession. Sessions run `cat` instead of an interactive shell.
- **Solution**: The `command` parameter was dead code — child always runs `execv("/bin/zsh")`. Removed the unused parameter from PTYSession.init and the `command: "/bin/cat"` from SessionManager.
- **Status**: [x] Fixed

### 2. `isAlive()` ping can hang forever
- **File**: `Sources/ClaudeRelayClient/RelayConnection.swift:110-117`
- **Issue**: `sendPing()` has no timeout. If server is unresponsive but TCP stays up, the iOS foreground recovery hangs indefinitely.
- **Solution**: Wrapped ping in a `withTaskGroup` race against a 3-second sleep. First to complete wins; loser is cancelled.
- **Status**: [x] Fixed

### 3. No rate limiting on WebSocket auth
- **File**: `Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift`
- **Issue**: `RateLimiter` only wired to Admin HTTP. WebSocket auth has unlimited attempts.
- **Solution**: Created `RateLimiter(maxAttempts: 10, windowSeconds: 60)` in `WebSocketServer`, passed to `RelayMessageHandler`. `handleAuth()` checks `isBlocked()` before validating, records failures on invalid tokens, and closes blocked connections.
- **Status**: [x] Fixed

### 4. AuthManager uses old keychain service name
- **File**: `Sources/ClaudeRelayClient/AuthManager.swift:8`
- **Issue**: Service is `"com.coderemote.relay"` (pre-rename).
- **Solution**: Renamed to `"com.clauderelay"`. Added transparent migration in `loadToken()`: tries new service first, falls back to legacy, saves to new and deletes old on hit.
- **Status**: [x] Fixed

## High

### 5. Premature `.connected` state in RelayConnection
- **File**: `Sources/ClaudeRelayClient/RelayConnection.swift:93`
- **Issue**: `state = .connected` set before WebSocket handshake completes.
- **Solution**: After `task.resume()`, send a confirmation ping with 5s timeout. Only set `.connected` on pong success. Also added `state == .connected` guard to `send()` and `sendBinary()`.
- **Status**: [x] Fixed

### 6. `onReconnected` fires from stale reconnect attempts
- **File**: `Sources/ClaudeRelayClient/RelayConnection.swift:236`
- **Issue**: Multiple backoff attempts can succeed; callback fires without generation check.
- **Solution**: Capture `connectionGeneration` before sleep. After waking, guard that it still matches before calling `connect()`. Stale attempts bail out since `connect()` bumps the generation.
- **Status**: [x] Fixed

### 7. Admin API has no auth on session termination
- **File**: `Sources/ClaudeRelayServer/Network/AdminRoutes.swift:103`
- **Issue**: Admin HTTP endpoints are unauthenticated. Any local process can kill sessions.
- **Solution**: Intentional by design — localhost binding (`127.0.0.1`) is the security boundary. Added doc comment to `AdminHTTPServer` documenting this. Also deleted stale `Sources/ClaudeRelayCLI/main.swift` that was blocking the full build.
- **Status**: [x] Documented (by design)

### 8. CLI `--expires` has no default value
- **File**: `Sources/ClaudeRelayCLI/Commands/TokenCommands.swift:32`
- **Issue**: Omitting `--expires` causes a CLI error.
- **Solution**: Added default value `"never"` to `expires` property.
- **Status**: [x] Fixed

### 9. Force-unwrap in AdminClient URL builder
- **File**: `Sources/ClaudeRelayCLI/AdminClient.swift:19`
- **Issue**: `URL(string:)!` crashes on invalid path characters.
- **Solution**: Changed `buildURL` to throw with a guard instead of force-unwrapping. Updated all call sites.
- **Status**: [x] Fixed

### 10. Stale `CodeRelay*` test directories
- **Location**: `Tests/CodeRelayKitTests/`, `Tests/CodeRelayServerTests/`, `Tests/CodeRelayCLITests/`
- **Issue**: 10 leftover files from the rename with old imports.
- **Solution**: Deleted `Tests/CodeRelayKitTests/`, `Tests/CodeRelayServerTests/`, `Tests/CodeRelayCLITests/` (10 files).
- **Status**: [x] Fixed

## Medium

### 11. DispatchSourceRead cleanup on PTYSession dealloc
- **File**: `Sources/ClaudeRelayServer/Actors/PTYSession.swift:76-183`
- **Issue**: If actor deallocates without `terminate()`, read source and child process leak.
- **Solution**: Extracted cleanup into `PTYResourceGuard` class with its own `deinit`. The guard holds the read source and child PID, cleans up on dealloc. `terminate()` now delegates to the guard.
- **Status**: [x] Fixed

### 12. Log tail compares count instead of content
- **File**: `Sources/ClaudeRelayCLI/Commands/LogCommands.swift:64-81`
- **Issue**: If logs are cleared between polls, new entries are missed.
- **Solution**: Handle count decrease (log cleared) by printing all current entries and resetting lastCount.
- **Status**: [x] Fixed

### 13. JSON escaping in log tail output
- **File**: `Sources/ClaudeRelayCLI/Commands/LogCommands.swift:75`
- **Issue**: String interpolation into JSON without escaping.
- **Solution**: Replaced string interpolation with `JSONEncoder().encode(["log": entry])` for proper escaping.
- **Status**: [x] Fixed (combined with #12)

### 14. No bounds check on terminal resize
- **File**: `Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift:319-330`
- **Issue**: Allows 0×0 or 65535×65535 resize.
- **Solution**: Clamped cols/rows to 1–500 in `handleResize()` before passing to PTY and ack.
- **Status**: [x] Fixed

### 15. Silent Keychain failures in ConnectionViewModel
- **File**: `ClaudeRelayApp/ViewModels/ConnectionViewModel.swift:67,84,94`
- **Issue**: All `try?` with no logging.
- **Solution**: Replaced `try?` with `do/catch` + `print()` logging on all three Keychain operations.
- **Status**: [x] Fixed

### 16. Notification observer double-registration in ActiveTerminalView
- **File**: `ClaudeRelayApp/Views/ActiveTerminalView.swift:159-168`
- **Issue**: If `makeUIView()` called twice, observers are duplicated.
- **Solution**: Added `removeObserver` calls before re-registering in `makeUIView()`.
- **Status**: [x] Fixed

## Low

### 17. CLI error handling only catches `.serviceNotRunning`
- **Files**: All CLI command files
- **Issue**: Other `AdminClientError` variants propagate as raw Swift errors.
- **Solution**: Added default `catch` with `print("Error: ...")` to all 14 catch sites across 5 CLI command files.
- **Status**: [x] Fixed

### 18. Empty placeholder test classes
- **Files**: `Tests/ClaudeRelayServerTests/ClaudeRelayServerTests.swift`, `Tests/ClaudeRelayCLITests/ClaudeRelayCLITests.swift`
- **Issue**: Contain only class declarations, no tests.
- **Solution**: Deleted both placeholder files.
- **Status**: [x] Fixed

### 19. `OutputFormatter` returns `"{}"` on encode failure
- **File**: `Sources/ClaudeRelayCLI/Formatters/OutputFormatter.swift:8-16`
- **Issue**: Silent fallback hides encoding errors.
- **Solution**: Added `FileHandle.standardError.write()` on encode failure before returning `"{}"`.
- **Status**: [x] Fixed

### 20. No test coverage for RelayConnection, SessionController, PTYSession
- **Issue**: Only unit-level coverage for models/stores; no integration tests.
- **Solution**: Out of scope for this fix pass. Note for future work.
- **Status**: [-] Deferred — requires architectural test harness

### 21. Duplicate TokenGenerator doc comment
- **File**: `Sources/ClaudeRelayKit/Security/TokenGenerator.swift:32-41`
- **Issue**: Documentation block appears twice.
- **Solution**: Removed duplicate doc comment block.
- **Status**: [x] Fixed
