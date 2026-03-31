# Review Findings

Date: 2026-03-31

## Summary

The package test suite passes (`swift test`: 110/110), but the review found several high-impact design and correctness issues in the admin/config surfaces, plus a few important concurrency and maintainability risks.

## Findings

1. `P1` The admin HTTP API is effectively unauthenticated full-control access.
   - `Sources/ClaudeRelayServer/Network/AdminHTTPServer.swift:44` binds the admin server to `127.0.0.1`, but there is no credential check anywhere in `Sources/ClaudeRelayServer/Network/AdminRoutes.swift`.
   - Any local process can create tokens, terminate sessions, rewrite config, and read logs.
   - If localhost is intended to be the only boundary, this should be documented explicitly and ideally replaced with a stronger same-user mechanism such as a Unix domain socket, launchd-scoped IPC, or an admin secret.

2. `P1` The config update endpoint accepts values that can crash the service.
   - `Sources/ClaudeRelayServer/Network/AdminRoutes.swift:251` converts user-controlled values into `UInt16` without explicit range validation.
   - `Sources/ClaudeRelayServer/Network/AdminRoutes.swift:263` stores `scrollbackSize` without checking that it is positive.
   - `Sources/ClaudeRelayServer/Services/RingBuffer.swift:17` uses `precondition(capacity > 0)`, so a zero or negative scrollback value can turn into a runtime crash on the next session creation.

3. `P2` `SessionController` is race-prone when more than one async operation shares a connection.
   - `Sources/ClaudeRelayClient/SessionController.swift:139` swaps a single global `connection.onServerMessage` handler per request.
   - Because `Sources/ClaudeRelayApp/ViewModels/SessionCoordinator.swift` has multiple async entry points (`fetchSessions`, create, switch, recovery), overlapping operations can steal each other's responses and produce timeouts or `unexpectedResponse` failures.
   - This should be serialized or redesigned around request-specific continuations / message correlation.

4. `P2` TLS is exposed in the app and config model but never enabled by the server.
   - `Sources/ClaudeRelayClient/ConnectionConfig.swift:12` can generate `wss://` URLs.
   - `ClaudeRelayApp/Views/AddEditServerView.swift:42` exposes a "Use TLS" toggle.
   - `Sources/ClaudeRelayServer/Network/AdminRoutes.swift:268` stores `tlsCert` and `tlsKey`.
   - But `Sources/ClaudeRelayServer/Network/WebSocketServer.swift` and `Sources/ClaudeRelayServer/Network/AdminHTTPServer.swift` never install an SSL handler or read those settings.
   - Today this is a misleading configuration surface and can create a false sense of transport security.

5. `P2` `claude-relay config set` is broken for numeric settings.
   - `Sources/ClaudeRelayCLI/Commands/ConfigCommands.swift:68` always sends `value` as a string.
   - `Sources/ClaudeRelayServer/Network/AdminRoutes.swift:253` expects integers for ports / timeout / scrollback.
   - That means normal commands for `wsPort`, `adminPort`, `detachTimeout`, and `scrollbackSize` fail even before considering the README mismatch.
   - The documentation is also stale: `README.md:120` documents `ws-port` / `admin-port` and a snake_case config schema that the current code does not implement.

## Lint And Compiler Notes

- `swiftlint lint --quiet --no-cache` reports three warnings:
  - `ClaudeRelayApp/Views/ActiveTerminalView.swift:258` trailing comma
  - `Sources/ClaudeRelayCLI/Commands/TokenCommands.swift:259` trailing newline
  - `Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift:7` type body length

- `swift test` also emitted concurrency warnings that matter more than the style issues:
  - `Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift` captures non-Sendable `self` / `ChannelHandlerContext` in `@Sendable` closures multiple times.
  - `Sources/ClaudeRelayServer/Network/AdminHTTPServer.swift:97` and `:117` do the same inside the admin handler.
  - `Sources/ClaudeRelayServer/Actors/PTYSession.swift:103` triggers an actor-initializer isolation warning that becomes an error in Swift 6 language mode.

## Testing Gaps

- `Package.swift` has no `ClaudeRelayClientTests` target, so `RelayConnection` and `SessionController` are not covered directly.
- `Tests/ClaudeRelayServerTests/ClaudeRelayServerTests.swift` is empty.
- `Tests/ClaudeRelayCLITests/ClaudeRelayCLITests.swift` is empty.
- The most risky paths still lack focused tests: `AdminRoutes`, `RelayMessageHandler`, reconnect/recovery logic, and the TLS configuration surface.

## Performance Opportunities

- `Sources/ClaudeRelayServer/Actors/TokenStore.swift:55` linearly scans every token hash on authentication. If token count grows, an in-memory hash index would remove that hot-path linear lookup.
- `Sources/ClaudeRelayServer/Network/AdminHTTPServer.swift:78` trusts `Content-Length` for initial body allocation. A capped body size check would avoid oversized allocations on malformed requests.
- `ClaudeRelayApp/ViewModels/ServerStatusChecker.swift:25` polls every server by opening a fresh WebSocket and authenticating every 15 seconds. That is simple and correct, but it will scale poorly for many saved servers and is likely battery-expensive on iOS.
