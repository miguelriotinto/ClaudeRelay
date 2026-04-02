# ClaudeRelay

A remote terminal relay server and CLI over WebSocket, enabling secure terminal access with session management and authentication.

## Features

- **WebSocket-based terminal relay** - Real-time bidirectional communication
- **Session management** - Create, list, attach, and detach terminal sessions
- **Token-based authentication** - Secure access control with configurable tokens
- **PTY sessions** - Interactive shell sessions with full terminal emulation
- **Session persistence** - Detach and reattach to running sessions
- **TLS encryption** - Optional NIO-SSL support for secure WebSocket connections
- **Service management** - Run as a background service with launchd/brew services
- **iOS client** - Native iOS app with terminal emulation and speech recognition
- **Admin API** - Localhost-only HTTP API for service management and monitoring
- **Config validation** - Server-side validation of all configuration parameters

## Architecture

ClaudeRelay consists of five main components:

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
claude-relay config set wsPort 9200                  # Set WebSocket port
claude-relay config set adminPort 9100               # Set admin API port
```

## Configuration

Configuration is stored at `~/.claude-relay/config.json`:

```json
{
  "wsPort": 9200,
  "adminPort": 9100,
  "detachTimeout": 0,
  "scrollbackSize": 65536,
  "tlsCert": "~/.claude-relay/certs/cert.pem",
  "tlsKey": "~/.claude-relay/certs/key.pem",
  "logLevel": "info"
}
```

**Configuration Options:**
- `wsPort` - WebSocket server port (default: 9200)
- `adminPort` - Admin HTTP API port (default: 9100)
- `detachTimeout` - Session timeout in seconds, 0 = never expire (default: 0)
- `scrollbackSize` - Maximum scrollback buffer size in bytes (default: 65536)
- `tlsCert` - Path to TLS certificate file for WebSocket server (optional)
- `tlsKey` - Path to TLS private key file for WebSocket server (optional)
- `logLevel` - Logging verbosity: "trace", "debug", "info", "warning", "error" (default: "info")

### TLS Configuration

To enable TLS encryption for the WebSocket server (recommended for network access):

1. **Generate a self-signed certificate** (for development/testing):
   ```bash
   mkdir -p ~/.claude-relay/certs
   openssl req -x509 -newkey rsa:4096 \
     -keyout ~/.claude-relay/certs/key.pem \
     -out ~/.claude-relay/certs/cert.pem \
     -days 365 -nodes -subj "/CN=localhost"
   ```

2. **Update config to enable TLS**:
   ```bash
   claude-relay config set tlsCert "~/.claude-relay/certs/cert.pem"
   claude-relay config set tlsKey "~/.claude-relay/certs/key.pem"
   ```

3. **Restart the server**:
   ```bash
   claude-relay restart
   ```

4. **iOS App**: Enable "Use TLS" toggle in the server configuration and use `wss://` URL scheme.

**Production TLS:**
For production deployments, use a valid certificate from a trusted CA (Let's Encrypt, etc.) instead of a self-signed certificate. The iOS app will require proper certificate trust for `wss://` connections.

**Note:** TLS is only applied to the WebSocket server (port 9200). The Admin API (port 9100) remains localhost-only without TLS.

## Development

### Build

```bash
swift build
```

### Run Tests

```bash
swift test                                    # All tests (123 tests)
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
│   └── CPTYShim/               # C shim for PTY operations
├── ClaudeRelayApp/             # iOS application (SwiftUI, XcodeGen-managed)
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
- Tokens are stored securely with SHA-256 hashing (never plaintext)
- Optional TLS encryption for WebSocket connections (NIO-SSL)
- Admin API binds to localhost only (`127.0.0.1`)
- Session isolation prevents cross-session access
- IP-based rate limiting on failed authentication attempts
- Server-side config validation prevents invalid/dangerous values
- Configure firewall rules if exposing ports externally

### Folder Permissions

The service runs as a LaunchAgent in your user context with full access to your home directory and user folders. The launchd plist includes:

- **Working Directory**: Set to your home directory
- **Environment Variables**: HOME, USER, and PATH properly configured
- **User Context**: Runs under your user account with standard permissions

**For access to protected folders (Documents, Desktop, Downloads, etc.):**

If you need the service to access macOS protected folders, grant Full Disk Access:

1. Open **System Settings** → **Privacy & Security** → **Full Disk Access**
2. Click the **+** button
3. Navigate to the server binary location:
   - Homebrew: `/opt/homebrew/bin/claude-relay-server` (Apple Silicon) or `/usr/local/bin/claude-relay-server` (Intel)
   - From source: `.build/release/claude-relay-server`
4. Add the binary and toggle it on

Note: This is only required if the terminal sessions need to access protected system folders.

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
