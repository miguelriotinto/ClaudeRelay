# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
swift build                        # Build all SPM targets
swift test                         # Run all tests
swift test --filter ClaudeRelayKitTests        # Run a single test suite
swift test --filter testTokenGeneration        # Run a single test by name
```

**Server management** (always use CLI, never run server binary directly or pkill):
```bash
swift run claude-relay load --ws-port 9200     # Install + start launchd service
swift run claude-relay unload                  # Remove launchd service
swift run claude-relay start|stop|restart      # Manage running service
swift run claude-relay status                  # Check service status
swift run claude-relay health                  # Health check
swift run claude-relay logs show               # View logs
swift run claude-relay token create --port 9100 --label "dev"  # Create auth token
```

Note: Service commands are top-level (`claude-relay stop`), while token/session/config/log commands are grouped (`claude-relay token create`, `claude-relay session list`, etc.).

**iOS app**: Open `ClaudeRelay.xcodeproj` in Xcode, Cmd+R. After changing ClaudeRelayClient, ClaudeRelaySpeech, or ClaudeRelayKit sources, rebuild the iOS app in Xcode to pick up changes.

**Launchd**: Plist at `~/Library/LaunchAgents/com.claude.relay.plist`. The `load` command locates the server binary via a fallback chain: sibling of the CLI binary, `/opt/homebrew/bin/`, `/usr/local/bin/`, `~/.claude-relay/bin/`.

## Architecture

Six SPM targets + iOS app + macOS app (both XcodeGen-managed via `project.yml`):

- **CPTYShim** — C shim for `forkpty` used by PTYSession.
- **ClaudeRelayKit** — Shared library: protocol models (`ClientMessage`, `ServerMessage`, `MessageEnvelope`), `SessionInfo`, `TokenInfo`, `RelayConfig`, `ConfigManager`, `ConnectionQuality`, `ActivityState`, `SessionState`, `CodingAgent` (pluggable agent registry). Used by all other targets.
- **ClaudeRelayServer** — NIO-based server: `WebSocketServer` (port 9200, optional TLS via NIO-SSL) + `AdminHTTPServer` (port 9100, localhost-only, 64 KB body cap → 413). Uses actors: `SessionManager`, `TokenStore`, `PTYSession`. Rate-limited via `RateLimiter` actor (LRU-capped at 10 k IPs). Shared static `JSONEncoder`/`JSONDecoder` in `RelayMessageHandler` (single pair across all connections).
- **ClaudeRelayCLI** — ArgumentParser CLI (`claude-relay`): token/session/config/service/log management. Talks to admin HTTP API. `AdminClient` requests timeout at 10 s (127.0.0.1-only).
- **ClaudeRelayClient** — URLSessionWebSocketTask client: `RelayConnection` (WebSocket transport + connection quality monitoring), `SessionController` (session lifecycle), `SharedSessionCoordinator` (cross-platform coordinator with recovery), `AuthManager` (auth flow). Also hosts `SessionCoordinating` protocol, `SessionNaming` helpers, `NetworkMonitor`, `DeviceIdentifier`, `ConnectionConfig`, and shared UI atoms (`ConnectionQualityDot`, `ActivityDot`, `AgentColorPalette` under `Views/`) used by both apps.
- **ClaudeRelaySpeech** — Cross-platform on-device speech pipeline shared by both apps: `OnDeviceSpeechEngine`, `WhisperTranscriber` (WhisperKit), `TextCleaner` (LLM.swift), `CloudPromptEnhancer` (Bedrock Haiku), `AudioCaptureSession`, `SpeechModelStore`, `SpeechEngineState`. iOS-only APIs (`AVAudioSession`, `UIApplication` memory-warning observer) are guarded by `#if canImport(UIKit)`; storage paths/keys are `#if os(iOS)`-branched to preserve existing user downloads.
- **ClaudeRelayApp/** — iOS SwiftUI app (not in SPM, uses Xcode project). Depends on ClaudeRelayClient + ClaudeRelaySpeech + SwiftTerm.
- **ClaudeRelayMac/** — macOS SwiftUI app (not in SPM, uses Xcode project). Depends on ClaudeRelayClient + ClaudeRelaySpeech + SwiftTerm. Menu-bar persistent, single-window with sidebar + native tab support, full iOS feature parity.

### Wire Protocol

All WebSocket messages use `MessageEnvelope`: `{"type":"<type_string>","payload":{...}}`. The envelope decoder checks `ClientMessage.allTypeStrings` first, then `ServerMessage.allTypeStrings`. **Type strings must be unique across both sets** — the server's session list response uses `"session_list_result"` (not `"session_list"`) to avoid collision with the client's `"session_list"` request.

`ClientMessage` and `ServerMessage` cannot be decoded standalone — they must go through `MessageEnvelope`. Terminal I/O (`input`/`output`) uses raw binary WebSocket frames, not the envelope protocol.

**Protocol versioning**: Client sends `protocolVersion` in `auth_request`; server responds with `protocolVersion` in `auth_success`. `minProtocolVersion` is 0 for backward compatibility with older clients.

### Date Encoding Caveat

The WebSocket server uses default `JSONEncoder` (Double timestamps). The Admin HTTP API uses `.iso8601`. Do not mix encoders between these two paths.

### TLS Support

`WebSocketServer` supports optional TLS via NIO-SSL. When `tlsCert` and `tlsKey` are set in config, an `NIOSSLServerHandler` is inserted at the front of the channel pipeline before HTTP handlers. Without TLS config, the server runs plain WebSocket. TLS minimum version is 1.2.

### PTY Sessions

`PTYSession` is an actor that uses `forkpty` via the C shim (`CPTYShim`) to spawn an interactive zsh login shell. Output goes to a `RingBuffer` for session resume scrollback (zero-copy writes via `withUnsafeMutableBytes`). Sessions never expire by default (`detachTimeout=0`).

**Two-phase init**: `PTYSession.init()` creates the PTY but does not start reading. Call `startReading()` after init to activate the dispatch source (required for Swift 6 actor-initializer isolation).

**Non-blocking writes**: The master FD is set to `O_NONBLOCK`. A `DispatchSourceWrite` drains a 4 MB pending queue when the FD becomes writable. Overflow drops oldest bytes with a once-per-session warning. This prevents paste/rapid-input workloads from EAGAIN-spinning inside the actor and starving resize/output dispatch.

**Output backpressure**: `RelayMessageHandler` caps inflight WebSocket-write bytes per session at 2 MB (`maxInflightOutputBytes`). When the cap is hit the server skips frames until writes drain — the `RingBuffer` holds the authoritative copy and clients replay from it on resume.

**Per-token session cap**: `SessionManager.createSession` enforces `config.maxSessionsPerToken` (default 50, 0 = unlimited) and throws `SessionError.sessionLimitExceeded` when exceeded. Prevents runaway clients from fork-bombing the server.

### NIO ↔ Swift Concurrency Bridge

`ChannelHandlerContext` is not `Sendable`. To use it inside `Task` blocks, wrap it in `UnsafeTransfer` (defined in `UnsafeTransfer.swift`) and only access `ctx.value` inside `eventLoop.execute { }`. Both `RelayMessageHandler` and `AdminHTTPHandler` use this pattern.

### Config Validation

Two-layer validation:
- **CLI client-side** (`ConfigSetCommand`): rejects unknown keys, bad port ranges, non-numeric values, invalid log levels, and negative `maxSessionsPerToken` before shipping to the admin API. `claude-relay config validate` runs the same checks against the saved file without touching the server.
- **Server-side** (`AdminRoutes.applyConfigValue()`): ports must be 1024–65535, `scrollbackSize` >= 1024, `detachTimeout` >= 0, `maxSessionsPerToken` >= 0, `logLevel` one of trace/debug/info/warning/error.

The CLI's `ConfigValue.infer(from:)` handles type coercion from string arguments. `ConfigManager.load()` returns `RelayConfig.default` (logging to stderr) when `config.json` is corrupt, so a bad edit never takes launchd down.

### App Architecture (iOS + macOS)

Both apps share `SharedSessionCoordinator` (in ClaudeRelayClient) for session lifecycle, recovery, naming, and ownership. Platform subclasses add only platform-specific glue (e.g., macOS registers `SleepWakeObserver`; iOS uses `scenePhase`).

- **ServerListView** — Primary screen: tap/click server to connect, swipe/right-click for edit/delete
- **AddEditServerView** — Modal sheet for server configuration (add/edit modes, with delete)
- **WorkspaceView** (iOS) / **MainWindow** (macOS) — NavigationSplitView: sidebar (sessions) + detail (terminal)
- **SharedSessionCoordinator** — Cross-platform: manages auth, session lifecycle, caches TerminalViewModels, routes I/O, handles recovery
- **SessionCoordinator** (per platform) — Thin subclass: iOS uses default; macOS adds sleep/wake recovery and tab navigation
- **OnDeviceSpeechEngine** — Offline speech-to-text via WhisperKit (CoreML/ANE), with LLM-based text cleanup and optional cloud prompt enhancement via Anthropic Haiku

### Connection Health & Quality Monitoring

`RelayConnection` maintains connection health via application-level ping/pong (`ClientMessage.ping` → `ServerMessage.pong`) on a 10-second interval. This exercises the full JSON message path rather than relying on WebSocket-level pings (opcode 0x9), which are silently dropped by some network configurations.

- **RTT tracking**: Sliding window of 6 measurements → `ConnectionQuality` enum (excellent/good/poor/veryPoor/disconnected) based on median RTT + success rate. All RTT append + window-cap + failure-counter bookkeeping is centralized in the private `recordRTT` helper — every call site is guaranteed to enforce the cap
- **Death detection**: 3 consecutive ping failures triggers `onSendFailed`, which the coordinator handles via `handleForegroundTransition`
- **Recovery ownership**: Only the coordinator (`SharedSessionCoordinator`) drives recovery. `forceReconnect()` deliberately does NOT enable auto-reconnect to prevent competing recovery loops
- **Recovery defer idempotency**: `handleForegroundTransition` uses a single outer `defer` guarded by `if isRecovering`. A mid-flight cancellation at any `await` (e.g., inside backoff sleep) still clears `isRecovering`, `suppressAllViewModelSends`, and `lastRecoveryEndedAt`. Without this, a cancelled recovery could strand `isRecovering=true` and permanently block future recoveries
- **Alive short-circuit**: If the connection is already alive when foreground fires (scenePhase `.active`, rotation, notification), transition skips the recovery path entirely and only calls `fetchSessions()`
- **Pong routing**: Pongs are intercepted via a dedicated `pendingPongContinuation` in `handleWebSocketMessage`, not through `onServerMessage`, so they don't conflict with `SessionController.sendAndWaitForResponse`

### Server-Side Activity Monitoring

The server monitors all PTY output continuously (even for detached sessions) via `SessionActivityMonitor`. It detects coding agent entry/exit and output silence, maintaining an `ActivityState` per session. Agents are identified via the `CodingAgent` registry (process-name matching + OSC title keywords); currently ships with Claude Code and Codex. State changes are pushed to clients via `sessionActivity` WebSocket messages. This ensures background tabs correctly reflect agent running/idle state even when the client is attached to a different session.

**Performance**: The foreground-process poll runs at 2 s when an agent is active and slows to 5 s when the session is detached. ANSI regex processing is skipped on the hot output path when no agent is running. `CodingAgent.processNames` is pre-lowercased at init so polling doesn't re-allocate strings on every tick.

### Observer Cleanup (Server)

`SessionManager`'s observer dictionaries (`stateObservers`, `activityObservers`) are normally cleaned by `cleanupSession()`. A background task in `main.swift` purges entries older than 1 h every 30 min as a safety net for handlers that die without cleanup (crash, panic, network partition). Without this, observer entries grew unbounded.

### Graceful Shutdown

`main.swift` races `sessionManager.shutdown()` against a 10 s timer and force-exits with a log line on timeout rather than hanging on a stuck PTY. Final `wsServer`/`adminServer`/`eventLoopGroup` teardown uses `try?` so timeouts propagate to exit. `TokenStore.flushIfDirty()` cancels its 30 s sleep-then-flush task up-front (before writing) to avoid leaving a dangling Task after shutdown.

### Memory Bounds

Named caps across the stack:
- `RelayMessageHandler.maxInflightOutputBytes` — 2 MB inflight WebSocket-write per session (backpressure)
- `RelayMessageHandler.maxTextFrameSize` / `maxBinaryFrameSize` — 10 MB each (images are base64-in-JSON)
- `RingBuffer` — `scrollbackSize` bytes (config, default 512 KB)
- `PTYSession` pending-write queue — 4 MB
- `RateLimiter.maxTrackedIPs` — 10 k (LRU-evicts oldest 10 % on overflow)
- `LogStore` — compacts at 5 % overshoot above `maxEntries` (not +1000)
- `AdminHTTPServer.maxRequestBodyBytes` — 64 KB (returns 413)
- `TerminalViewModel.pendingOutputByteLimit` — 4 MB client-side (logs once-per-session on first drop)
- `AudioCaptureSession.maximumDuration` — 300 s (5 min) auto-stop to cap `Float`-sample memory growth
- `SharedSessionCoordinator` terminal-cache — LRU-bounded at 8 sessions

### Key Pattern: sendAndWaitForResponse

`SessionController.sendAndWaitForResponse()` installs a response handler **before** sending the message (not after) to avoid a race condition where the server response arrives before the handler is in place.

### Speech Layer Concurrency

`TextCleaner` is `@MainActor`-isolated (not `@unchecked Sendable`). All real callers (`OnDeviceSpeechEngine`, `ClaudeRelayApp.preloadSpeechModels`, macOS `AppDelegate.applicationWillTerminate`) are or must be main-actor-isolated. This enforces "no concurrent `clean()`/`unload()`" at compile time instead of by convention.

`CloudPromptEnhancer` takes an optional `modelId` at init (defaults to the current Haiku inference profile; override for newer models). Error bodies are JSON-parsed for clean messages, and free-form bodies have `Bearer <token>` redacted before logging.

## Configuration

Config stored in `~/.claude-relay/config.json`. Default ports: WS=9200, Admin=9100. On this dev machine, admin port is configured as 9100.

**Config keys**: `wsPort`, `adminPort`, `detachTimeout`, `scrollbackSize`, `tlsCert`, `tlsKey`, `logLevel`, `maxSessionsPerToken` (default 50, 0 = unlimited), `bindAll` (default `false` — WebSocket server binds `127.0.0.1`. Set `true` to bind `0.0.0.0` for LAN access; pair with `tlsCert`/`tlsKey` unless you trust the network).

App-side (not in `config.json`, stored via `@AppStorage`): `terminalScrollbackLines` (per-app, default 5000, max 25000). The server's `RingBuffer` still replays anything that falls off this edge on reattach.

## Lint

SwiftLint config in `.swiftlint.yml`. Line length warning at 140, error at 200. Identifier min length: 2 (warning).

<!-- code-review-graph MCP tools -->
## MCP Tools: code-review-graph

**IMPORTANT: This project has a knowledge graph. ALWAYS use the
code-review-graph MCP tools BEFORE using Grep/Glob/Read to explore
the codebase.** The graph is faster, cheaper (fewer tokens), and gives
you structural context (callers, dependents, test coverage) that file
scanning cannot.

### When to use graph tools FIRST

- **Exploring code**: `semantic_search_nodes` or `query_graph` instead of Grep
- **Understanding impact**: `get_impact_radius` instead of manually tracing imports
- **Code review**: `detect_changes` + `get_review_context` instead of reading entire files
- **Finding relationships**: `query_graph` with callers_of/callees_of/imports_of/tests_for
- **Architecture questions**: `get_architecture_overview` + `list_communities`

Fall back to Grep/Glob/Read **only** when the graph doesn't cover what you need.

### Key Tools

| Tool | Use when |
|------|----------|
| `detect_changes` | Reviewing code changes — gives risk-scored analysis |
| `get_review_context` | Need source snippets for review — token-efficient |
| `get_impact_radius` | Understanding blast radius of a change |
| `get_affected_flows` | Finding which execution paths are impacted |
| `query_graph` | Tracing callers, callees, imports, tests, dependencies |
| `semantic_search_nodes` | Finding functions/classes by name or keyword |
| `get_architecture_overview` | Understanding high-level codebase structure |
| `refactor_tool` | Planning renames, finding dead code |

### Workflow

1. The graph auto-updates on file changes (via hooks).
2. Use `detect_changes` for code review.
3. Use `get_affected_flows` to understand impact.
4. Use `query_graph` pattern="tests_for" to check coverage.
