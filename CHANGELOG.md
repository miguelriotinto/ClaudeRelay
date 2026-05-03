# Changelog

All notable changes to ClaudeRelay are documented in this file.

The server/CLI, iOS app, and macOS app are versioned independently. Server/CLI uses 0.x.y; iOS uses X.Y.Z; macOS starts at 0.1.0.

## [1.0] - 2026-05-03 — macOS App

### Added
- **ClaudeRelayMac** — native macOS client with full iOS feature parity
  - Single-window terminal with sidebar session list and `NavigationSplitView` layout
  - Menu bar persistent icon (`MenuBarExtra(.window)`) showing connection state and session list with activity icons
  - Keyboard shortcuts: `Cmd+T` new session, `Cmd+W` detach, `Cmd+Shift+W` terminate, `Cmd+1..9` switch by index, `Cmd+0` toggle sidebar, `Cmd+Shift+[/]` previous/next session, `Cmd+Shift+Q` scan QR code
  - Automatic foreground recovery via `NSWorkspace` sleep/wake and `NWPathMonitor` network-change observers
  - Launch-at-login via `SMAppService.mainApp` (macOS 13+) with optional menu-bar-only mode
  - Image paste: `Cmd+V` from clipboard and drag-and-drop onto terminal
  - QR code: generation for sharing sessions to mobile, camera scanning for inbound attach
  - On-device speech engine: WhisperKit (CoreML/ANE) + LLM.swift (Metal) + optional Anthropic Haiku enhancement via AWS Bedrock
  - Session naming themes shared with iOS (Game of Thrones, Viking, Star Wars, Dune, Lord of the Rings)
  - `clauderelay://session/<uuid>` deep link support
  - TLS toggle per saved server

### Shared Library Changes
- `SessionCoordinating` protocol added to `ClaudeRelayClient` and conformed by both apps — formalizes the cross-platform session-lifecycle surface
- `SessionNamingTheme` and `SessionNaming.pickDefaultName` moved to `ClaudeRelayClient` as shared types
- New `ClaudeRelayClientTests` target (SPM test count now 307)

### Infrastructure Fixes
- Fixed `ClaudeRelayAppTests` target missing Info.plist generation (pre-existing, surfaced while regression-testing the Mac work)
- `project.yml` now declares `info.path` for both iOS and Mac app targets (required by XcodeGen 2.45+)

## [0.2.2] - 2026-04-25

### Fixed
- Cross-device attach: preserve session name and fix state transition when attaching from a different token
- Allow `activeDetached` → `activeAttached` transition for cross-device list-based attach
- Send scrollback history when attaching remote sessions (not just on resume)
- Prevent observer leak when channel disconnects during auth registration
- Robust Claude Code detection with parent chain walk (up to 5 ancestors) and exit debouncing
- Replaced `libproc` with `sysctl KERN_PROCARGS2` for reliable cross-platform process detection
- Restore Claude detection state on session resume and app relaunch
- Increased WebSocket frame limits to 10 MB to support image pasting

### Fixed (iOS)
- Reset terminal before scrollback replay on foreground recovery
- Prune stale session names so thematic naming works again
- Rename sessions via alert instead of inline editing
- Match splash background to AppIcon sRGB exactly
- Resolve Swift 6 Sendable warnings in speech layer

## [0.2.0] - 2026-04-16

### Added
- Protocol version negotiation — client and server exchange `protocolVersion` during auth handshake
- Image paste support (`paste_image` client message, `paste_image_result` server response)
- Server version displayed in `claude-relay status` output

### Changed
- `minProtocolVersion` set to 0 for backward compatibility with older iOS clients

## [0.1.9] - 2026-04-15

### Added
- Server-side session name storage with `renameSession` and broadcast to all connected clients
- `sessionCreate(name:)` — clients can now assign a name when creating sessions
- `sessionRename` client message and `sessionRenamed` server broadcast
- `name` field on `SessionInfo` model
- `session_list_all` / `session_list_all_result` wire messages for cross-token session listing
- GitNexus code intelligence config and skills

## [0.1.8] - 2026-04-13

### Added
- Cross-device session attach with `sessionStolen` notification when another device takes a session
- `sessionListAll` message to list sessions across all tokens (enables cross-device attach)

### Fixed
- Robust Claude detection — removed false exit triggers, persisted activity state across detach/reattach
- Cross-device attach — sessions now listed across all tokens instead of only the current token's sessions

## [1.3.1] - 2026-04-16 (iOS)

### Added
- QR code overlay on terminal view for session sharing
- QR code scanner via AVFoundation camera for session attach
- "Scan QR Code" button in attach session sheet
- Deep link handler for `clauderelay://` URL scheme
- Session name sync with server (renames broadcast to all clients)
- Configurable keyboard shortcut for speech recording
- Live key capture UI (replaced shortcut pickers with `KeyCaptureView`)
- 10,000-line scrollback buffer (up from default)
- Black terminal chrome and keyboard accessory bar

### Changed
- Migrated `ShortcutModifier` enum to raw modifier flags
- LLM.swift switched from local path to remote Git dependency

### Fixed
- Restore tab activity state after returning from background
- False Claude detection on tab switch caused by scrollback replay
- QR code rendering via CIContext for SwiftUI compatibility
- QR overlay dismisses on session change
- Push activity state on session attach
- Swift 6 Sendable warnings in speech layer silenced
- Guard against empty key string in UIKeyCommand registration
- NSCameraUsageDescription added to Info.plist

## [0.1.7] - 2026-04-12

### Fixed
- Idle detection: escape-only TUI output no longer breaks `claudeIdle` state
- Tab flash visibility in iOS app when Claude awaits input

## [0.1.6] - 2026-04-11

### Added
- Server-side session activity monitoring via `SessionActivityMonitor`
- Push-based `sessionActivity` WebSocket messages broadcast to all connected clients
- Initial activity sync on client attach
- Activity observer registry in `SessionManager`

### Changed
- Claude running/idle detection moved from iOS client to server (monitors PTY output continuously, even for detached sessions)

## [1.3.0] - 2026-04-11 (iOS)

### Added
- Session tab bar with numbered tabs and Claude Code detection
- Tab flash notification when Claude Code awaits user input
- Star Wars, Dune, and Lord of the Rings naming themes for sessions
- Clear-line special key
- Haptic feedback with settings toggle
- Scrollable tab zone in status bar
- Consumes server-pushed activity state for background tab updates

### Changed
- Single-line compact status bar (replaced two-line layout)
- Removed stroke borders from status bar icons
- Reorganized header layout: chevron → servers → sessions → function keys → connectivity → time → tabs → name
- Standardized toolbar icons with capitalized key labels

### Fixed
- Backspace key repeat behavior
- Idle detection tab flash not visible due to state timing

## [1.2.0] - 2026-04-10 (iOS)

### Added
- On-device speech engine using WhisperKit (CoreML/ANE) for transcription
- LLM-based text cleanup via LLM.swift (Metal GPU)
- Cloud prompt enhancement via Anthropic Haiku (`CloudPromptEnhancer`)
- Settings page with Prompt Improvement toggle
- Model download manager with progress UI
- Silence hallucination filtering for Whisper
- Speech pipeline: `AudioCaptureSession`, `WhisperTranscriber`, `TextCleaner`, `OnDeviceSpeechEngine`, `SpeechModelStore`

### Changed
- Replaced `SFSpeechRecognizer` with WhisperKit for fully offline speech-to-text
- Model loading shows modal progress bar instead of hourglass

### Removed
- `SpeechRecognizer` (replaced by `OnDeviceSpeechEngine`)

## [1.1.0] - 2026-03-28 (iOS)

### Added
- Hardware keyboard support: Cmd+C (copy), Cmd+V (paste), Cmd+X (cut)
- App version display on splash screen

## [1.0.0] - 2026-03-27 (iOS)

### Added
- Server list with status indicators and swipe actions (edit/delete)
- Add/edit server modal configuration
- Terminal emulation via SwiftTerm
- Session sidebar with named sessions
- Speech-to-text input via SFSpeechRecognizer
- Splash screen with animated logo
- Auto-reconnection and session resume on foreground return
- Session uptime display in toolbar
- Fn key toolbar with special keys
- Hardware keyboard detection (auto-hide software keyboard toggle)

## [0.1.5] - 2026-03-29

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
- Refactored connection flow: removed intermediate detail view
- Updated stale markdown documentation

### Fixed
- Reduced spurious timeout alerts during active terminal sessions
- Flattened connection flow — tap server to connect directly
- NIO buffer binding mutability (`var` → `let` for `frameData`, `data`)
- Trailing comma lint issue in `ActiveTerminalView.swift`

### Removed
- `AGENTS.md` (stale Codex-branded duplicate of CLAUDE.md)
- `REVIEW.md` (findings tracked, no longer needed)
- Duplicate `UnsafeTransfer` definitions (consolidated to single file)

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
