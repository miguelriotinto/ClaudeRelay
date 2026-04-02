# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
swift build                        # Build all SPM targets
swift test                         # Run all tests (123 tests)
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

Note: Subcommands are flat (`claude-relay stop`), not nested (`claude-relay service stop`).

**iOS app**: Open `ClaudeRelay.xcodeproj` in Xcode, Cmd+R. After changing ClaudeRelayClient or ClaudeRelayKit sources, rebuild the iOS app in Xcode to pick up changes.

**Launchd**: Plist at `~/Library/LaunchAgents/com.claude.relay.plist` expects binary at `/usr/local/bin/claude-relay-server` (requires `sudo cp .build/debug/claude-relay-server /usr/local/bin/`).

## Architecture

Four SPM targets + one iOS app (XcodeGen-managed via `project.yml`):

- **ClaudeRelayKit** — Shared library: protocol models (`ClientMessage`, `ServerMessage`, `MessageEnvelope`), `SessionInfo`, `TokenInfo`, `RelayConfig`, `ConfigManager`. Used by all other targets.
- **ClaudeRelayServer** — NIO-based server: `WebSocketServer` (port 9200, optional TLS via NIO-SSL) + `AdminHTTPServer` (port 9100, localhost-only). Uses actors: `SessionManager`, `TokenStore`, `PTYSession`. Rate-limited via `RateLimiter` actor.
- **ClaudeRelayCLI** — ArgumentParser CLI (`claude-relay`): token/session/config/service/log management. Talks to admin HTTP API.
- **ClaudeRelayClient** — URLSessionWebSocketTask client: `RelayConnection` (WebSocket transport), `SessionController` (session lifecycle), `AuthManager` (auth flow).
- **ClaudeRelayApp/** — iOS SwiftUI app (not in SPM, uses Xcode project). Depends on ClaudeRelayClient + SwiftTerm.

### Wire Protocol

All WebSocket messages use `MessageEnvelope`: `{"type":"<type_string>","payload":{...}}`. The envelope decoder checks `ClientMessage.allTypeStrings` first, then `ServerMessage.allTypeStrings`. **Type strings must be unique across both sets** — the server's session list response uses `"session_list_result"` (not `"session_list"`) to avoid collision with the client's `"session_list"` request.

`ClientMessage` and `ServerMessage` cannot be decoded standalone — they must go through `MessageEnvelope`.

### Date Encoding Caveat

The WebSocket server uses default `JSONEncoder` (Double timestamps). The Admin HTTP API uses `.iso8601`. Do not mix encoders between these two paths.

### TLS Support

`WebSocketServer` supports optional TLS via NIO-SSL. When `tlsCert` and `tlsKey` are set in config, an `NIOSSLServerHandler` is inserted at the front of the channel pipeline before HTTP handlers. Without TLS config, the server runs plain WebSocket. TLS minimum version is 1.2.

### PTY Sessions

`PTYSession` is an actor that uses `forkpty` via the C shim (`CPTYShim`) to spawn an interactive zsh login shell. Output goes to a `RingBuffer` for session resume scrollback. Sessions never expire by default (`detachTimeout=0`).

**Two-phase init**: `PTYSession.init()` creates the PTY but does not start reading. Call `startReading()` after init to activate the dispatch source (required for Swift 6 actor-initializer isolation).

### NIO ↔ Swift Concurrency Bridge

`ChannelHandlerContext` is not `Sendable`. To use it inside `Task` blocks, wrap it in `UnsafeTransfer` (defined in `UnsafeTransfer.swift`) and only access `ctx.value` inside `eventLoop.execute { }`. Both `RelayMessageHandler` and `AdminHTTPHandler` use this pattern.

### Config Validation

`AdminRoutes.applyConfigValue()` validates all config updates: ports must be 1024–65535, `scrollbackSize` >= 1024, `detachTimeout` >= 0, `logLevel` must be one of trace/debug/info/warning/error. The CLI's `ConfigValue.infer(from:)` handles type coercion from string arguments.

### iOS App Architecture

- **ServerListView** — Primary screen: tap server to connect directly, swipe for edit/delete
- **AddEditServerView** — Modal sheet for server configuration (add/edit modes, with delete)
- **WorkspaceView** — NavigationSplitView: sidebar (sessions) + detail (terminal), presented as fullScreenCover
- **SessionCoordinator** — Manages auth, session lifecycle, caches TerminalViewModels, routes I/O
- **Foreground recovery** — On `scenePhase` `.active`: pings WebSocket, reconnects if dead, re-authenticates, resumes session
- **SpeechRecognizer** — Live speech-to-text using SFSpeechRecognizer, streams diff-based text to terminal

### Key Pattern: sendAndWaitForResponse

`SessionController.sendAndWaitForResponse()` installs a response handler **before** sending the message (not after) to avoid a race condition where the server response arrives before the handler is in place.

## Configuration

Config stored in `~/.claude-relay/config.json`. Default ports: WS=9200, Admin=9100. On this dev machine, admin port is configured as 9100.

**Config keys**: `wsPort`, `adminPort`, `detachTimeout`, `scrollbackSize`, `tlsCert`, `tlsKey`, `logLevel`.

## Lint

SwiftLint config in `.swiftlint.yml`. Line length warning at 140, error at 200. Identifier min length: 2 (warning).
