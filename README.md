# ClaudeRelay

A remote terminal relay server and CLI over WebSocket, enabling secure terminal access with session management and authentication.

## Features

- **WebSocket-based terminal relay** - Real-time bidirectional communication
- **Session management** - Create, list, attach, and detach terminal sessions
- **Token-based authentication** - Secure access control with configurable tokens
- **PTY sessions** - Interactive shell sessions with full terminal emulation
- **Session persistence** - Detach and reattach to running sessions
- **Service management** - Run as a background service with launchd/brew services
- **iOS client** - Native iOS app with terminal emulation and speech recognition
- **Admin API** - HTTP API for service management and monitoring

## Architecture

ClaudeRelay consists of four main components:

- **ClaudeRelayServer** - WebSocket server (port 9200) and Admin HTTP API (port 9100)
- **ClaudeRelayCLI** - Command-line interface for managing tokens, sessions, and service
- **ClaudeRelayKit** - Shared library with protocol definitions and utilities
- **ClaudeRelayClient** - Swift client library for building custom clients
- **ClaudeRelayApp** - iOS application with terminal emulation

## Installation

### Homebrew (macOS)

```bash
brew install miguelriotinto/clauderelay/clauderelay
```

### From Source

Requires Xcode 15.0+ and macOS 14+:

```bash
git clone https://github.com/miguelriotinto/ClaudeRelay.git
cd ClaudeRelay
swift build -c release
```

Binaries will be in `.build/release/`:
- `claude-relay` - CLI tool
- `claude-relay-server` - Server daemon

## Quick Start

### 1. Start the Server

Using Homebrew services:
```bash
brew services start clauderelay
```

Or manually:
```bash
claude-relay load --ws-port 9200
```

### 2. Create an Authentication Token

```bash
claude-relay token create --label "my-device"
```

Copy the generated token - you'll need it to authenticate clients.

### 3. Check Service Status

```bash
claude-relay status
claude-relay health
```

### 4. View Logs

```bash
claude-relay logs show
claude-relay logs follow
```

## CLI Commands

### Service Management
```bash
claude-relay load          # Install and start launchd service
claude-relay unload        # Remove launchd service
claude-relay start         # Start the service
claude-relay stop          # Stop the service
claude-relay restart       # Restart the service
claude-relay status        # Check service status
claude-relay health        # Health check
```

### Token Management
```bash
claude-relay token create --label "device-name"     # Create new token
claude-relay token list                              # List all tokens
claude-relay token revoke <token-id>                 # Revoke a token
```

### Session Management
```bash
claude-relay session list                            # List active sessions
claude-relay session attach <session-id>             # Attach to session
claude-relay session close <session-id>              # Close session
```

### Logs
```bash
claude-relay logs show                               # Show recent logs
claude-relay logs follow                             # Tail logs
claude-relay logs clear                              # Clear logs
```

### Configuration
```bash
claude-relay config show                             # Show current config
claude-relay config set ws-port 9200                 # Set WebSocket port
claude-relay config set admin-port 9100              # Set admin API port
```

## Configuration

Configuration is stored at `~/.claude-relay/config.json`:

```json
{
  "ws_port": 9200,
  "admin_port": 9100,
  "bind_address": "127.0.0.1",
  "detach_timeout": 0
}
```

**Configuration Options:**
- `ws_port` - WebSocket server port (default: 9200)
- `admin_port` - Admin HTTP API port (default: 9100)
- `bind_address` - IP address to bind to (default: 127.0.0.1)
- `detach_timeout` - Session timeout in seconds, 0 = never expire (default: 0)

## Development

### Build

```bash
swift build
```

### Run Tests

```bash
swift test                                    # All tests
swift test --filter ClaudeRelayKitTests      # Specific suite
swift test --filter testTokenGeneration       # Specific test
```

### iOS App

Open `ClaudeRelay.xcodeproj` in Xcode and press Cmd+R to build and run the iOS app.

After modifying `ClaudeRelayClient` or `ClaudeRelayKit` sources, rebuild the iOS app in Xcode to pick up changes.

### Project Structure

```
ClaudeRelay/
├── Sources/
│   ├── ClaudeRelayKit/         # Shared protocol models and utilities
│   ├── ClaudeRelayServer/      # WebSocket + HTTP server (NIO-based)
│   ├── ClaudeRelayCLI/         # Command-line interface (ArgumentParser)
│   ├── ClaudeRelayClient/      # Swift client library
│   ├── CPTYShim/               # C shim for PTY operations
│   └── ClaudeRelayApp/         # iOS application (SwiftUI)
├── Tests/
│   ├── ClaudeRelayKitTests/
│   ├── ClaudeRelayServerTests/
│   └── ClaudeRelayCLITests/
├── Formula/
│   └── clauderelay.rb          # Homebrew formula
└── Package.swift
```

## Wire Protocol

All WebSocket messages use `MessageEnvelope` with JSON encoding:

```json
{
  "type": "message_type",
  "payload": { ... }
}
```

**Client Messages:**
- `auth` - Authenticate with token
- `session_create` - Create new session
- `session_list` - List sessions
- `session_attach` - Attach to session
- `session_detach` - Detach from session
- `session_close` - Close session
- `input` - Send terminal input

**Server Messages:**
- `auth_success` / `auth_failed` - Authentication result
- `session_created` - Session creation result
- `session_list_result` - List of sessions
- `session_attached` - Attachment confirmation
- `output` - Terminal output
- `error` - Error message

## Security

- All WebSocket connections require token-based authentication
- Tokens are stored securely with SHA-256 hashing
- Admin API binds to localhost by default
- Session isolation prevents cross-session access
- Configure firewall rules if exposing ports externally

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

### Development Guidelines

1. Follow existing code style
2. Add tests for new features
3. Update documentation
4. Run `swift test` before submitting
5. Ensure `swiftlint` passes (see `.swiftlint.yml`)

## License

MIT License - see [LICENSE](LICENSE) for details.

## Links

- **GitHub**: https://github.com/miguelriotinto/ClaudeRelay
- **Homebrew Tap**: https://github.com/miguelriotinto/homebrew-clauderelay
- **Issues**: https://github.com/miguelriotinto/ClaudeRelay/issues
