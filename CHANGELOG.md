# Changelog

All notable changes to ClaudeRelay are documented in this file.

## [Unreleased]

### Added
- TLS support for WebSocket server via NIO-SSL (`tlsCert`/`tlsKey` config)
- Server-side config validation (port ranges, scrollback size, log levels)
- `UnsafeTransfer` helper for NIO ↔ Swift concurrency bridging
- `ConfigValue.infer(from:)` for CLI config type coercion
- `ConfigValidationTests` — 11 tests exercising `AdminRoutes.applyConfigValue`
- TLS server tests (cert/key loading, plain fallback)

### Changed
- `WebSocketServer` now accepts `RelayConfig` instead of just a port
- `PTYSession.startReading()` separated from `init` for Swift 6 actor isolation
- `RelayMessageHandler` and `AdminHTTPHandler` use `[weak self]` + `UnsafeTransfer` pattern
- `var` → `let` fixes for NIO buffer bindings (`frameData`, `data`)

### Fixed
- Trailing comma lint issue in `ActiveTerminalView.swift`
- SwiftLint line length violation in TLS test skip message

### Removed
- `AGENTS.md` (stale Codex-branded duplicate of CLAUDE.md)
- `REVIEW.md` (findings tracked, no longer needed)
- Empty `docs/` directory
- Duplicate `UnsafeTransfer` definitions (consolidated to single file)

## [0.1.5] - 2026-03-29

### Fixed
- Reduced spurious timeout alerts during active terminal sessions
- Flattened connection flow — tap server to connect directly

### Changed
- Refactored connection flow: removed intermediate detail view
- Updated stale markdown documentation

## [0.1.4] - 2026-03-26

### Added
- Server management redesign: `ServerListView` as primary screen
- `AddEditServerView` modal for server configuration
- Unique default session names

### Changed
- Replaced `ConnectionView` with `ServerListView` entry point
- Match saved connections by UUID instead of host+port

### Removed
- Quick Connect feature (superseded by server list)

## [0.1.3] - 2026-03-24

### Fixed
- Filter escape sequence responses from scrollback on session resume

## [0.1.2] - 2026-03-23

### Fixed
- Use login shell for proper folder permissions

## [0.1.1] - 2026-03-22

### Added
- Full user folder permissions for launchd service
- README and MIT License

## [0.1.0] - 2026-03-21

Initial release.

### Added
- WebSocket relay server (NIO-based, port 9200)
- Admin HTTP API (port 9100, localhost-only)
- Token-based authentication with SHA-256 hashing
- PTY session management with `forkpty` via CPTYShim
- Session persistence: detach, reattach, scrollback replay
- CLI tool (`claude-relay`) with service/token/session/config/log commands
- iOS app with SwiftUI terminal emulation (SwiftTerm)
- Speech-to-text microphone input (SFSpeechRecognizer)
- Hardware keyboard support (Cmd+C/V/X)
- Session sidebar with named sessions
- Foreground recovery (reconnect + re-auth on wake)
- Server status indicators and health checks
- IP-based rate limiting on auth failures
- In-memory log store with structured logging
- Token expiry support
- Homebrew formula and GitHub Actions release workflow
- 110 tests across Kit, Server, and CLI targets

### Security
- Token hashing (never stored plaintext)
- WebSocket frame size limits (1MB text, 1MB binary)
- Auth attempt rate limiting (3 per connection)
- SIGCHLD auto-reap to prevent zombie processes
- Channel activity guards before WebSocket writes
- EAGAIN/EINTR handling in PTY write loop
