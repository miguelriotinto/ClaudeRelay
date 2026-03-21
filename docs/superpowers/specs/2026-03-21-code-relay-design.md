# CodeRemote — Mac Mini Claude Code Relay Service + iOS Terminal Client

## Design Specification

**Date:** 2026-03-21
**Status:** Approved

---

## 1. Product Goal

A system where an iOS device remotely attaches to and controls a persistent Claude Code terminal session running on a Mac mini. This is an authenticated, PTY-backed, resumable remote terminal system — not a chat proxy.

### User Flow

1. Install service on Mac mini via CLI (`claude-relay load`)
2. Generate token via CLI (`claude-relay token create`)
3. Configure iOS app with host + token
4. Connect, choose new or resume session
5. Full interactive terminal appears
6. Disconnect does not kill session
7. Resume restores state

---

## 2. Key Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Language | All Swift | Unified codebase, shared protocol types |
| Server framework | Raw SwiftNIO + NIOWebSocket | Maximum control over WebSocket + PTY relay |
| Package structure | Monorepo with shared CodeRelayKit | Shared types across server, CLI, iOS |
| iOS terminal | SwiftTerm | Battle-tested xterm emulation |
| CLI ↔ Service comms | Local HTTP API (127.0.0.1:9100) | Curl-friendly, easy to debug |
| Token storage | JSON file (SHA-256 hashed, file-locked) | Simple, zero dependencies |
| Internal architecture | Actor-based (Swift concurrency) | Thread-safe by construction |

---

## 3. System Components

### 3.1 Package Structure

```
CodeRelay/
├── Package.swift
├── Sources/
│   ├── CodeRelayKit/           # Shared: protocol types, models, crypto
│   │   ├── Protocol/           # Message types (Codable enums)
│   │   ├── Models/             # Session, Token, Config models
│   │   ├── PTY/                # C shim for forkpty + Swift wrapper
│   │   └── Security/           # Token generation, hashing
│   ├── CodeRelayServer/        # macOS service binary
│   │   ├── Actors/             # SessionManager, PTYManager, TokenStore
│   │   ├── Network/            # NIO WebSocket + Admin HTTP server
│   │   └── main.swift
│   ├── CodeRelayCLI/           # CLI binary (claude-relay)
│   │   ├── Commands/           # Argument Parser command tree
│   │   └── main.swift
│   └── CodeRelayClient/        # iOS client library
│       ├── RelayConnection.swift
│       ├── AuthManager.swift
│       ├── SessionController.swift
│       ├── TerminalBridge.swift
│       └── ConnectionConfig.swift
└── CodeRelayApp/               # iOS Xcode project
    └── (SwiftUI app importing CodeRelayClient)
```

### 3.2 macOS Service (CodeRelayServer)

Persistent background service. Owns PTY lifecycle, session state, and network endpoints.

**Actors:**
- `SessionManager` — session lifecycle state machine, maps session IDs to PTY instances
- `PTYManager` — forkpty, read/write master fd, resize, child process monitoring
- `TokenStore` — load/save/validate tokens from JSON file with file locking

**Network listeners:**
- WebSocket server (configurable port, default 9200) — client-facing
- Admin HTTP server (127.0.0.1:9100) — CLI-facing, localhost-only

### 3.3 CLI Tool (claude-relay)

Built with Swift Argument Parser. Primary operational interface.

### 3.4 iOS App (CodeRelayApp)

SwiftUI + MVVM. Three screens: Connection, Session List, Terminal.

---

## 4. Protocol Specification

### 4.1 Transport

- WebSocket over TCP (or TLS)
- **Text frames** → JSON control messages
- **Binary frames** → raw terminal I/O (PTY data)

### 4.2 Message Envelope

```json
{ "type": "message_type", "payload": { ... } }
```

### 4.3 Message Types

**Client → Server:**

| Type | Payload | Description |
|---|---|---|
| `auth_request` | `{ token }` | Authenticate with token |
| `session_create` | `{}` | Create new session |
| `session_attach` | `{ sessionId }` | Attach to existing session |
| `session_resume` | `{ sessionId }` | Resume detached session |
| `session_detach` | `{}` | Graceful detach |
| `resize` | `{ cols, rows }` | Terminal resize |
| `ping` | `{}` | Keepalive |
| *(binary frame)* | raw bytes | Terminal input (keystrokes) |

**Server → Client:**

| Type | Payload | Description |
|---|---|---|
| `auth_success` | `{}` | Authentication succeeded |
| `auth_failure` | `{ reason }` | Authentication failed |
| `session_created` | `{ sessionId, cols, rows }` | Session created |
| `session_attached` | `{ sessionId, state }` | Attached to session |
| `session_resumed` | `{ sessionId }` | Session resumed |
| `session_detached` | `{}` | Detach confirmed |
| `session_terminated` | `{ sessionId, reason }` | Session terminated |
| `session_expired` | `{ sessionId }` | Session expired (timeout) |
| `session_state` | `{ sessionId, state }` | State change notification |
| `resize_ack` | `{ cols, rows }` | Resize confirmed |
| `pong` | `{}` | Keepalive response |
| `error` | `{ code, message }` | Error |
| *(binary frame)* | raw bytes | Terminal output (PTY data) |

### 4.4 Connection Flow

```
1. WebSocket connects
2. Server starts 10-second auth timer
3. Client sends auth_request
4. Server validates token (SHA-256 hash comparison)
5. On success → auth_success, timer cancelled
6. On failure → auth_failure, connection closed
7. Client sends session_create or session_attach/session_resume
8. Server allocates PTY (only after auth) or attaches to existing
9. Bidirectional terminal streaming begins
```

---

## 5. Session Model

### 5.1 ExecutionSession (Server-Owned)

- Owns PTY fd + Claude Code child process
- Long-lived, survives client disconnects
- Identified by UUIDv4 session ID
- Bound to the token that created it

### 5.2 ClientAttachment (Transient)

- Represents authenticated WebSocket → ExecutionSession binding
- One active attachment per session
- New attachment replaces stale connection (same token required)

### 5.3 Session States

```
created → starting → active-attached ⇄ active-detached → expired
                         │                    │
                         │                    └→ resuming → active-attached
                         ├→ exited
                         ├→ failed (from any active state)
                         └→ terminated (via CLI/admin)
```

Terminal states: `exited`, `failed`, `expired`, `terminated` — no recovery.

### 5.4 Detach Timeout

- Default: **30 minutes**
- Configurable via `config set detach-timeout <seconds>`
- Timer starts when client disconnects
- Timer resets on reattach
- On expiry: session moves to `expired`, PTY + process cleaned up

### 5.5 Output Buffering (Detached)

- Ring buffer, default 64KB (configurable via `scrollback-size`)
- While detached: server reads PTY output into buffer
- On resume: buffer flushed to client, then live streaming resumes

---

## 6. PTY Management

### 6.1 Implementation

Swift lacks direct `forkpty()`. A C shim is used:

```c
// Sources/CodeRelayKit/PTY/pty_shim.c
#include <util.h>
int relay_forkpty(int *master, struct winsize *ws) {
    return forkpty(master, NULL, NULL, ws);
}
```

Exposed via a C target in `Package.swift`.

### 6.2 PTY Actor Responsibilities

- Call `forkpty()` to create real pseudo-terminal
- Spawn Claude Code (`claude`) as child process
- Read master fd → push to attached client or ring buffer
- Write to master fd ← receive from attached client
- Handle resize via `ioctl(fd, TIOCSWINSZ, &winsize)`
- Detect child exit via master fd EOF
- Clean shutdown: SIGTERM → wait 5s → SIGKILL

### 6.3 Environment

- `TERM=xterm-256color`
- `LANG=en_US.UTF-8`
- Inherit `PATH` from service environment
- Working directory: configurable per session (default: user home)

---

## 7. Server Architecture

### 7.1 NIO Channel Pipeline (WebSocket)

```
ByteToMessageHandler (HTTP)
  → HTTPServerUpgradeHandler (→ WebSocket)
    → WebSocketFrameDecoder
      → RelayMessageHandler (bridges to actors)
```

`RelayMessageHandler`:
- Text frames → decode JSON → dispatch to SessionManager actor
- Binary frames → forward to PTYManager for attached session
- Close frames → trigger detach
- Backpressure: if client is slow, pause PTY reads

### 7.2 Admin HTTP API

Bound to `127.0.0.1:9100`. Simple NIO HTTP1 server.

| Method | Path | Description |
|---|---|---|
| GET | `/health` | Health check |
| GET | `/status` | Service status + uptime |
| GET | `/sessions` | List sessions |
| GET | `/sessions/:id` | Inspect session |
| DELETE | `/sessions/:id` | Terminate session |
| POST | `/tokens` | Create token |
| GET | `/tokens` | List tokens (hashes only) |
| DELETE | `/tokens/:id` | Delete token |
| POST | `/tokens/:id/rotate` | Rotate token |
| GET | `/config` | Show config |
| PUT | `/config/:key` | Set config value |
| GET | `/logs` | Recent logs |

### 7.3 TLS

- Optional, configured via config
- When enabled: `NIOSSLServerHandler` added to WebSocket pipeline
- Admin API always plaintext (localhost-only)
- Supports self-signed certs

---

## 8. CLI Design (claude-relay)

Built with Swift Argument Parser.

### 8.1 Command Tree

```
claude-relay
├── load                        # Install launchd plist + start
├── unload                      # Stop + remove launchd plist
├── start                       # Start service
├── stop                        # Stop service
├── restart                     # Stop + start
├── status                      # Service status
├── health                      # Quick health check
├── token
│   ├── create [--label]        # Generate token (printed once)
│   ├── list                    # List tokens (no secrets)
│   ├── delete <id>             # Delete token
│   ├── rotate <id>             # Rotate token (new value printed once)
│   └── inspect <id>            # Token metadata
├── session
│   ├── list                    # List sessions
│   ├── inspect <id>            # Session details
│   └── terminate <id>          # Kill session
├── config
│   ├── show                    # Print config
│   ├── set <key> <value>       # Update config
│   └── validate                # Validate config
└── logs
    ├── tail                    # Stream logs
    └── show [--lines N]        # Recent logs
```

### 8.2 Global Flags

- `--json` — machine-readable JSON output
- `--quiet` — suppress non-essential output

### 8.3 Key Behaviors

- `token create`: generates 32 random bytes (base64url, 43 chars), prints to stdout once, stores SHA-256 hash
- `load`: generates `~/Library/LaunchAgents/com.coderemote.relay.plist`, calls `launchctl load`
- `status`: shows running/stopped, PID, uptime, port, active sessions, version
- All commands handle "connection refused" gracefully ("Service is not running")

### 8.4 Configuration

File: `~/.claude-relay/config.json`

```json
{
  "wsPort": 9200,
  "adminPort": 9100,
  "detachTimeout": 1800,
  "scrollbackSize": 65536,
  "tlsCert": null,
  "tlsKey": null,
  "logLevel": "info"
}
```

---

## 9. iOS App Design

### 9.1 Architecture

SwiftUI + MVVM. Three screens.

### 9.2 Screens

1. **Connection Screen** — host, port, token fields. Saved connections list. Connect button.
2. **Session List Screen** — existing sessions (resumable) + "New Session" button.
3. **Terminal Screen** — full-screen SwiftTerm view with custom keyboard accessory.

### 9.3 CodeRelayClient Package

- `RelayConnection` — WebSocket lifecycle via `URLSessionWebSocketTask`
- `AuthManager` — iOS Keychain token storage
- `SessionController` — attach/detach/resume logic
- `TerminalBridge` — bridges RelayConnection ↔ SwiftTerm TerminalView
- `ConnectionConfig` — host/port/token model (Codable)

### 9.4 Key Decisions

- **URLSessionWebSocketTask** for WebSocket (native iOS API, proper app lifecycle)
- **Keychain** for token storage (never UserDefaults)
- **SwiftTerm TerminalView** with custom `TerminalDelegate` routing I/O through WebSocket
- **Custom keyboard accessory bar**: Ctrl, Tab, Esc, arrows, |, /, ~

### 9.5 Reconnect Logic

- On network loss: "Reconnecting..." overlay
- Exponential backoff: 1s, 2s, 4s, 8s, max 30s
- On reconnect: sends `session_resume` with stored session ID

### 9.6 Connection State Visibility

- Status bar: green (connected), yellow (reconnecting), red (disconnected)
- Toast notifications for session events (expired, terminated)

---

## 10. Security Model

### 10.1 Authentication

1. WebSocket connects → 10-second auth timer starts
2. Client sends `auth_request` with plaintext token
3. Server hashes SHA-256, compares against stored hashes
4. Match → `auth_success`. No match → `auth_failure`, close.
5. **No PTY allocated until auth succeeds.**

### 10.2 Brute-Force Protection

- 5 failed attempts per IP per minute
- After limit: connection closed immediately (no response)
- Tracked in-memory (resets on restart)

### 10.3 Token Design

- Generated: 32 bytes via `SecRandomCopyBytes`, base64url-encoded (43 chars)
- Stored: SHA-256 hash + metadata (id, label, created_at, last_used_at)
- Displayed: only on `token create` and `token rotate`

### 10.4 Session Isolation

- Sessions bound to creating token
- Resume requires same token
- Session IDs are UUIDv4 (unguessable, validated against token ownership)

### 10.5 Logging

- Tokens never logged
- Terminal I/O never logged
- Session IDs, IPs, state transitions logged

### 10.6 TLS

- Required for non-LAN use
- Self-signed certs supported
- `wss://` when enabled

---

## 11. Implementation Phases

### Phase 1: Foundation
- Package structure + shared types (CodeRelayKit)
- Protocol message types (Codable enums)
- PTY C shim + Swift wrapper
- Basic NIO WebSocket server (no TLS)
- Session manager actor (state machine)
- Local relay: connect and stream terminal I/O

### Phase 2: CLI + Service Management
- CLI skeleton with Swift Argument Parser
- Admin HTTP API
- Token management (create/list/delete/rotate)
- Session management commands
- Config file management
- launchd integration (load/unload)

### Phase 3: iOS App
- CodeRelayClient package
- Connection screen + Keychain storage
- Session list screen
- Terminal screen with SwiftTerm
- Custom keyboard accessory
- Reconnect + resume logic

### Phase 4: Hardening
- TLS support
- Brute-force protection
- Output buffering for detached sessions
- Structured logging (os_log)
- Health checks
- Config validation
- Detach timeout enforcement

---

## 12. Future Enhancements (Out of Scope)

- Multi-session per client
- Multi-client per session (shared view)
- Session persistence across service restart
- File transfer
- Clipboard sync
- IP allowlist
- mTLS
- Per-device tokens

---

## 13. Acceptance Criteria

### Functional
- [ ] iOS connects securely to Mac mini service
- [ ] Claude Code runs in real PTY (detects TTY)
- [ ] Terminal is fully interactive (colors, cursor, alternate buffer)
- [ ] Resize works end-to-end
- [ ] Reconnect resumes session with buffered output

### Session
- [ ] Disconnect does not terminate session
- [ ] Resume is reliable within 30-minute timeout
- [ ] Session ownership enforced (token binding)

### CLI
- [ ] Full service lifecycle via CLI (load/unload/start/stop/restart/status)
- [ ] Token CRUD via CLI
- [ ] Session inspection and termination via CLI
- [ ] All commands support --json output

### Security
- [ ] No PTY before auth
- [ ] Tokens never logged or persisted in plaintext
- [ ] TLS supported for non-LAN use

### Quality
- [ ] Modular actor-based architecture
- [ ] Testable components
- [ ] Production-ready error handling
