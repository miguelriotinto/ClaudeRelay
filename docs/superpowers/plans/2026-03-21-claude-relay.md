# CodeRemote Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a PTY-backed remote terminal relay system enabling an iOS device to securely control Claude Code sessions on a Mac mini.

**Architecture:** All-Swift monorepo. Raw SwiftNIO WebSocket server with actor-based concurrency. Shared `ClaudeRelayKit` for protocol types. CLI via Swift Argument Parser. iOS app with SwiftTerm terminal emulation.

**Tech Stack:** Swift 5.9+, SwiftNIO 2, NIOWebSocket, Swift Argument Parser, SwiftTerm, SwiftUI

**Spec:** `docs/superpowers/specs/2026-03-21-code-relay-design.md`

---

## File Structure

```
ClaudeRelay/
├── Package.swift
├── Sources/
│   ├── CPTYShim/                           # C target for forkpty
│   │   ├── include/
│   │   │   └── pty_shim.h
│   │   └── pty_shim.c
│   ├── ClaudeRelayKit/                       # Shared library
│   │   ├── Protocol/
│   │   │   ├── ClientMessage.swift         # Client→Server message enum
│   │   │   ├── ServerMessage.swift         # Server→Client message enum
│   │   │   └── MessageEnvelope.swift       # JSON envelope wrapper
│   │   ├── Models/
│   │   │   ├── SessionState.swift          # Session state enum
│   │   │   ├── SessionInfo.swift           # Session metadata struct
│   │   │   ├── TokenInfo.swift             # Token metadata struct
│   │   │   └── RelayConfig.swift           # Configuration model
│   │   └── Security/
│   │       └── TokenGenerator.swift        # Token generation + hashing
│   ├── ClaudeRelayServer/                    # macOS service binary
│   │   ├── main.swift                      # Entry point, starts both servers
│   │   ├── Actors/
│   │   │   ├── SessionManager.swift        # Session lifecycle state machine
│   │   │   ├── PTYSession.swift            # Single PTY session (forkpty + I/O)
│   │   │   └── TokenStore.swift            # JSON file token persistence
│   │   ├── Network/
│   │   │   ├── WebSocketServer.swift       # NIO WebSocket listener
│   │   │   ├── RelayMessageHandler.swift   # WS frame → actor dispatch
│   │   │   ├── AdminHTTPServer.swift       # NIO HTTP1 listener (localhost)
│   │   │   └── AdminRoutes.swift           # HTTP route handlers
│   │   └── Services/
│   │       ├── RingBuffer.swift            # Circular buffer for detached output
│   │       └── ConfigManager.swift         # Config file read/write
│   ├── ClaudeRelayCLI/                       # CLI binary
│   │   ├── main.swift                      # Entry point
│   │   ├── CLIRoot.swift                   # Root command + global flags
│   │   ├── Commands/
│   │   │   ├── ServiceCommands.swift       # load/unload/start/stop/restart/status/health
│   │   │   ├── TokenCommands.swift         # token create/list/delete/rotate/inspect
│   │   │   ├── SessionCommands.swift       # session list/inspect/terminate
│   │   │   ├── ConfigCommands.swift        # config show/set/validate
│   │   │   └── LogCommands.swift           # logs tail/show
│   │   ├── Formatters/
│   │   │   └── OutputFormatter.swift       # JSON vs human-readable output
│   │   └── AdminClient.swift              # HTTP client for admin API
│   └── ClaudeRelayClient/                    # iOS client library
│       ├── RelayConnection.swift           # URLSessionWebSocketTask lifecycle
│       ├── AuthManager.swift               # iOS Keychain token storage
│       ├── SessionController.swift         # Session attach/detach/resume
│       ├── TerminalBridge.swift            # RelayConnection ↔ SwiftTerm bridge
│       └── ConnectionConfig.swift          # Host/port/token model
├── Tests/
│   ├── ClaudeRelayKitTests/
│   │   ├── ProtocolMessageTests.swift      # Encode/decode all message types
│   │   ├── SessionStateTests.swift         # State transition validation
│   │   └── TokenGeneratorTests.swift       # Token gen + hash round-trip
│   ├── ClaudeRelayServerTests/
│   │   ├── RingBufferTests.swift           # Ring buffer overflow + flush
│   │   ├── TokenStoreTests.swift           # CRUD + file locking
│   │   ├── SessionManagerTests.swift       # State machine transitions
│   │   └── AdminRoutesTests.swift          # HTTP endpoint responses
│   └── ClaudeRelayCLITests/
│       └── OutputFormatterTests.swift      # JSON + human format
└── ClaudeRelayApp/                           # iOS Xcode project
    ├── ClaudeRelayApp.xcodeproj/
    └── ClaudeRelayApp/
        ├── ClaudeRelayApp.swift           # App entry point
        ├── Views/
        │   ├── ConnectionView.swift        # Host/token config screen
        │   ├── SessionListView.swift       # Session picker screen
        │   ├── TerminalContainerView.swift # Terminal + keyboard accessory
        │   └── Components/
        │       ├── StatusIndicator.swift   # Connection status dot
        │       └── KeyboardAccessory.swift # Ctrl/Tab/Esc/arrows bar
        ├── ViewModels/
        │   ├── ConnectionViewModel.swift   # Connection logic
        │   ├── SessionListViewModel.swift  # Session list logic
        │   └── TerminalViewModel.swift     # Terminal I/O logic
        └── Info.plist
```

---

## Task 1: Package.swift + Project Scaffold

**Files:**
- Create: `Package.swift`

**Dependencies:** None (this unblocks everything)

- [ ] **Step 1: Create Package.swift with all targets and dependencies**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeRelay",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "code-relay-server", targets: ["ClaudeRelayServer"]),
        .executable(name: "claude-relay", targets: ["ClaudeRelayCLI"]),
        .library(name: "ClaudeRelayKit", targets: ["ClaudeRelayKit"]),
        .library(name: "ClaudeRelayClient", targets: ["ClaudeRelayClient"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        // C shim for forkpty
        .target(
            name: "CPTYShim",
            path: "Sources/CPTYShim",
            publicHeadersPath: "include"
        ),
        // Shared library
        .target(
            name: "ClaudeRelayKit",
            dependencies: [
                "CPTYShim",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/ClaudeRelayKit"
        ),
        // macOS server
        .executableTarget(
            name: "ClaudeRelayServer",
            dependencies: [
                "ClaudeRelayKit",
                "CPTYShim",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ],
            path: "Sources/ClaudeRelayServer"
        ),
        // CLI tool
        .executableTarget(
            name: "ClaudeRelayCLI",
            dependencies: [
                "ClaudeRelayKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Sources/ClaudeRelayCLI"
        ),
        // iOS client library
        .target(
            name: "ClaudeRelayClient",
            dependencies: ["ClaudeRelayKit"],
            path: "Sources/ClaudeRelayClient"
        ),
        // Tests
        .testTarget(
            name: "ClaudeRelayKitTests",
            dependencies: ["ClaudeRelayKit"],
            path: "Tests/ClaudeRelayKitTests"
        ),
        .testTarget(
            name: "ClaudeRelayServerTests",
            dependencies: ["ClaudeRelayServer", "ClaudeRelayKit"],
            path: "Tests/ClaudeRelayServerTests"
        ),
        .testTarget(
            name: "ClaudeRelayCLITests",
            dependencies: ["ClaudeRelayCLI", "ClaudeRelayKit"],
            path: "Tests/ClaudeRelayCLITests"
        ),
    ]
)
```

- [ ] **Step 2: Create directory structure and placeholder files**

Create all directories and minimal placeholder `.swift` files so the package compiles:
- `Sources/CPTYShim/include/pty_shim.h` — empty header with include guard
- `Sources/CPTYShim/pty_shim.c` — empty C file including header
- `Sources/ClaudeRelayKit/ClaudeRelayKit.swift` — `// placeholder`
- `Sources/ClaudeRelayServer/main.swift` — `@main struct Server { static func main() {} }`
- `Sources/ClaudeRelayCLI/main.swift` — `import ArgumentParser; @main struct CLI: ParsableCommand { func run() {} }`
- `Sources/ClaudeRelayClient/ClaudeRelayClient.swift` — `// placeholder`
- All test files with empty `import XCTest` + `final class XTests: XCTestCase {}`

- [ ] **Step 3: Verify package resolves and builds**

Run: `swift build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: scaffold Package.swift with all targets and dependencies"
```

---

## Task 2: Protocol Message Types (ClaudeRelayKit)

**Files:**
- Create: `Sources/ClaudeRelayKit/Protocol/ClientMessage.swift`
- Create: `Sources/ClaudeRelayKit/Protocol/ServerMessage.swift`
- Create: `Sources/ClaudeRelayKit/Protocol/MessageEnvelope.swift`
- Test: `Tests/ClaudeRelayKitTests/ProtocolMessageTests.swift`

**Dependencies:** Task 1

- [ ] **Step 1: Write tests for message encode/decode**

```swift
import XCTest
@testable import ClaudeRelayKit

final class ProtocolMessageTests: XCTestCase {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    // MARK: - Client Messages

    func testAuthRequestEncoding() throws {
        let msg = ClientMessage.authRequest(token: "test-token-123")
        let envelope = MessageEnvelope.client(msg)
        let data = try encoder.encode(envelope)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "auth_request")
        let payload = json["payload"] as! [String: Any]
        XCTAssertEqual(payload["token"] as? String, "test-token-123")
    }

    func testSessionCreateEncoding() throws {
        let msg = ClientMessage.sessionCreate
        let envelope = MessageEnvelope.client(msg)
        let data = try encoder.encode(envelope)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "session_create")
    }

    func testSessionAttachEncoding() throws {
        let id = UUID()
        let msg = ClientMessage.sessionAttach(sessionId: id)
        let envelope = MessageEnvelope.client(msg)
        let data = try encoder.encode(envelope)
        let decoded = try decoder.decode(MessageEnvelope.self, from: data)
        if case .client(.sessionAttach(let sid)) = decoded {
            XCTAssertEqual(sid, id)
        } else { XCTFail("Wrong decode") }
    }

    func testResizeEncoding() throws {
        let msg = ClientMessage.resize(cols: 120, rows: 40)
        let envelope = MessageEnvelope.client(msg)
        let data = try encoder.encode(envelope)
        let decoded = try decoder.decode(MessageEnvelope.self, from: data)
        if case .client(.resize(let c, let r)) = decoded {
            XCTAssertEqual(c, 120)
            XCTAssertEqual(r, 40)
        } else { XCTFail("Wrong decode") }
    }

    // MARK: - Server Messages

    func testAuthSuccessEncoding() throws {
        let msg = ServerMessage.authSuccess
        let envelope = MessageEnvelope.server(msg)
        let data = try encoder.encode(envelope)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "auth_success")
    }

    func testSessionCreatedEncoding() throws {
        let id = UUID()
        let msg = ServerMessage.sessionCreated(sessionId: id, cols: 80, rows: 24)
        let envelope = MessageEnvelope.server(msg)
        let data = try encoder.encode(envelope)
        let decoded = try decoder.decode(MessageEnvelope.self, from: data)
        if case .server(.sessionCreated(let sid, let c, let r)) = decoded {
            XCTAssertEqual(sid, id)
            XCTAssertEqual(c, 80)
            XCTAssertEqual(r, 24)
        } else { XCTFail("Wrong decode") }
    }

    func testErrorEncoding() throws {
        let msg = ServerMessage.error(code: 401, message: "Unauthorized")
        let envelope = MessageEnvelope.server(msg)
        let data = try encoder.encode(envelope)
        let decoded = try decoder.decode(MessageEnvelope.self, from: data)
        if case .server(.error(let code, let message)) = decoded {
            XCTAssertEqual(code, 401)
            XCTAssertEqual(message, "Unauthorized")
        } else { XCTFail("Wrong decode") }
    }

    // MARK: - Round Trip

    func testAllClientMessagesRoundTrip() throws {
        let id = UUID()
        let messages: [ClientMessage] = [
            .authRequest(token: "tok"),
            .sessionCreate,
            .sessionAttach(sessionId: id),
            .sessionResume(sessionId: id),
            .sessionDetach,
            .resize(cols: 80, rows: 24),
            .ping,
        ]
        for msg in messages {
            let envelope = MessageEnvelope.client(msg)
            let data = try encoder.encode(envelope)
            let decoded = try decoder.decode(MessageEnvelope.self, from: data)
            XCTAssertEqual(envelope, decoded, "Round-trip failed for \(msg)")
        }
    }

    func testAllServerMessagesRoundTrip() throws {
        let id = UUID()
        let messages: [ServerMessage] = [
            .authSuccess,
            .authFailure(reason: "bad token"),
            .sessionCreated(sessionId: id, cols: 80, rows: 24),
            .sessionAttached(sessionId: id, state: "active-attached"),
            .sessionResumed(sessionId: id),
            .sessionDetached,
            .sessionTerminated(sessionId: id, reason: "cli"),
            .sessionExpired(sessionId: id),
            .sessionState(sessionId: id, state: "active-detached"),
            .resizeAck(cols: 120, rows: 40),
            .pong,
            .error(code: 500, message: "internal"),
        ]
        for msg in messages {
            let envelope = MessageEnvelope.server(msg)
            let data = try encoder.encode(envelope)
            let decoded = try decoder.decode(MessageEnvelope.self, from: data)
            XCTAssertEqual(envelope, decoded, "Round-trip failed for \(msg)")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ProtocolMessageTests`
Expected: FAIL — types not defined

- [ ] **Step 3: Implement ClientMessage enum**

```swift
// Sources/ClaudeRelayKit/Protocol/ClientMessage.swift
import Foundation

public enum ClientMessage: Codable, Equatable, Sendable {
    case authRequest(token: String)
    case sessionCreate
    case sessionAttach(sessionId: UUID)
    case sessionResume(sessionId: UUID)
    case sessionDetach
    case resize(cols: UInt16, rows: UInt16)
    case ping

    public var type: String {
        switch self {
        case .authRequest: "auth_request"
        case .sessionCreate: "session_create"
        case .sessionAttach: "session_attach"
        case .sessionResume: "session_resume"
        case .sessionDetach: "session_detach"
        case .resize: "resize"
        case .ping: "ping"
        }
    }
}
```

Use custom `Codable` conformance to flatten to `{ "type": "...", "payload": { ... } }` format. Implement `init(from:)` and `encode(to:)` that switch on the `type` string.

- [ ] **Step 4: Implement ServerMessage enum**

```swift
// Sources/ClaudeRelayKit/Protocol/ServerMessage.swift
import Foundation

public enum ServerMessage: Codable, Equatable, Sendable {
    case authSuccess
    case authFailure(reason: String)
    case sessionCreated(sessionId: UUID, cols: UInt16, rows: UInt16)
    case sessionAttached(sessionId: UUID, state: String)
    case sessionResumed(sessionId: UUID)
    case sessionDetached
    case sessionTerminated(sessionId: UUID, reason: String)
    case sessionExpired(sessionId: UUID)
    case sessionState(sessionId: UUID, state: String)
    case resizeAck(cols: UInt16, rows: UInt16)
    case pong
    case error(code: Int, message: String)

    public var type: String { /* same pattern as ClientMessage */ }
}
```

- [ ] **Step 5: Implement MessageEnvelope**

```swift
// Sources/ClaudeRelayKit/Protocol/MessageEnvelope.swift
import Foundation

public enum MessageEnvelope: Codable, Equatable, Sendable {
    case client(ClientMessage)
    case server(ServerMessage)
}
```

The envelope's `Codable` reads `"type"` first, then delegates to `ClientMessage` or `ServerMessage` based on known type strings.

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter ProtocolMessageTests`
Expected: All tests PASS

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat: implement protocol message types with full Codable support"
```

---

## Task 3: Session State Model (ClaudeRelayKit)

**Files:**
- Create: `Sources/ClaudeRelayKit/Models/SessionState.swift`
- Create: `Sources/ClaudeRelayKit/Models/SessionInfo.swift`
- Test: `Tests/ClaudeRelayKitTests/SessionStateTests.swift`

**Dependencies:** Task 1

- [ ] **Step 1: Write tests for session state transitions**

```swift
import XCTest
@testable import ClaudeRelayKit

final class SessionStateTests: XCTestCase {
    func testValidTransitions() {
        XCTAssertTrue(SessionState.created.canTransition(to: .starting))
        XCTAssertTrue(SessionState.starting.canTransition(to: .activeAttached))
        XCTAssertTrue(SessionState.activeAttached.canTransition(to: .activeDetached))
        XCTAssertTrue(SessionState.activeDetached.canTransition(to: .resuming))
        XCTAssertTrue(SessionState.resuming.canTransition(to: .activeAttached))
        XCTAssertTrue(SessionState.activeDetached.canTransition(to: .expired))
        XCTAssertTrue(SessionState.activeAttached.canTransition(to: .exited))
    }

    func testInvalidTransitions() {
        XCTAssertFalse(SessionState.created.canTransition(to: .activeAttached))
        XCTAssertFalse(SessionState.exited.canTransition(to: .activeAttached))
        XCTAssertFalse(SessionState.expired.canTransition(to: .resuming))
        XCTAssertFalse(SessionState.terminated.canTransition(to: .starting))
    }

    func testTerminalStates() {
        XCTAssertTrue(SessionState.exited.isTerminal)
        XCTAssertTrue(SessionState.failed.isTerminal)
        XCTAssertTrue(SessionState.expired.isTerminal)
        XCTAssertTrue(SessionState.terminated.isTerminal)
        XCTAssertFalse(SessionState.activeAttached.isTerminal)
    }

    func testFailedReachableFromAnyActiveState() {
        XCTAssertTrue(SessionState.starting.canTransition(to: .failed))
        XCTAssertTrue(SessionState.activeAttached.canTransition(to: .failed))
        XCTAssertTrue(SessionState.activeDetached.canTransition(to: .failed))
        XCTAssertTrue(SessionState.resuming.canTransition(to: .failed))
    }

    func testTerminatedReachableFromNonTerminal() {
        XCTAssertTrue(SessionState.activeAttached.canTransition(to: .terminated))
        XCTAssertTrue(SessionState.activeDetached.canTransition(to: .terminated))
        XCTAssertFalse(SessionState.exited.canTransition(to: .terminated))
    }

    func testSessionInfoCodable() throws {
        let info = SessionInfo(
            id: UUID(),
            state: .activeAttached,
            tokenId: "tok-1",
            createdAt: Date(),
            cols: 80, rows: 24
        )
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(SessionInfo.self, from: data)
        XCTAssertEqual(info.id, decoded.id)
        XCTAssertEqual(info.state, decoded.state)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SessionStateTests`
Expected: FAIL

- [ ] **Step 3: Implement SessionState and SessionInfo**

```swift
// Sources/ClaudeRelayKit/Models/SessionState.swift
public enum SessionState: String, Codable, Sendable {
    case created
    case starting
    case activeAttached = "active-attached"
    case activeDetached = "active-detached"
    case resuming
    case exited
    case failed
    case terminated
    case expired

    public var isTerminal: Bool {
        switch self {
        case .exited, .failed, .terminated, .expired: true
        default: false
        }
    }

    public func canTransition(to next: SessionState) -> Bool {
        // Encode the full state machine
        switch (self, next) {
        case (.created, .starting): true
        case (.starting, .activeAttached): true
        case (.starting, .failed): true
        case (.activeAttached, .activeDetached): true
        case (.activeAttached, .exited): true
        case (.activeAttached, .failed): true
        case (.activeAttached, .terminated): true
        case (.activeDetached, .resuming): true
        case (.activeDetached, .expired): true
        case (.activeDetached, .exited): true
        case (.activeDetached, .failed): true
        case (.activeDetached, .terminated): true
        case (.resuming, .activeAttached): true
        case (.resuming, .failed): true
        case (.resuming, .terminated): true
        default: false
        }
    }
}
```

```swift
// Sources/ClaudeRelayKit/Models/SessionInfo.swift
import Foundation

public struct SessionInfo: Codable, Sendable {
    public let id: UUID
    public var state: SessionState
    public let tokenId: String
    public let createdAt: Date
    public var cols: UInt16
    public var rows: UInt16

    public init(id: UUID, state: SessionState, tokenId: String,
                createdAt: Date, cols: UInt16, rows: UInt16) {
        self.id = id
        self.state = state
        self.tokenId = tokenId
        self.createdAt = createdAt
        self.cols = cols
        self.rows = rows
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter SessionStateTests`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: implement session state machine and SessionInfo model"
```

---

## Task 4: Token Model + Generator (ClaudeRelayKit)

**Files:**
- Create: `Sources/ClaudeRelayKit/Models/TokenInfo.swift`
- Create: `Sources/ClaudeRelayKit/Security/TokenGenerator.swift`
- Test: `Tests/ClaudeRelayKitTests/TokenGeneratorTests.swift`

**Dependencies:** Task 1

- [ ] **Step 1: Write tests**

```swift
import XCTest
@testable import ClaudeRelayKit

final class TokenGeneratorTests: XCTestCase {
    func testGeneratedTokenLength() {
        let (plaintext, _) = TokenGenerator.generate()
        // 32 bytes base64url = 43 chars
        XCTAssertEqual(plaintext.count, 43)
    }

    func testGeneratedTokenIsBase64URL() {
        let (plaintext, _) = TokenGenerator.generate()
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-_"))
        XCTAssertTrue(plaintext.unicodeScalars.allSatisfy { allowed.contains($0) })
    }

    func testHashIsDeterministic() {
        let hash1 = TokenGenerator.hash("test-token")
        let hash2 = TokenGenerator.hash("test-token")
        XCTAssertEqual(hash1, hash2)
    }

    func testHashDiffersForDifferentTokens() {
        let hash1 = TokenGenerator.hash("token-a")
        let hash2 = TokenGenerator.hash("token-b")
        XCTAssertNotEqual(hash1, hash2)
    }

    func testGenerateProducesMatchingHash() {
        let (plaintext, info) = TokenGenerator.generate()
        let recomputed = TokenGenerator.hash(plaintext)
        XCTAssertEqual(info.tokenHash, recomputed)
    }

    func testValidateToken() {
        let (plaintext, info) = TokenGenerator.generate()
        XCTAssertTrue(TokenGenerator.validate(plaintext, against: info.tokenHash))
        XCTAssertFalse(TokenGenerator.validate("wrong-token", against: info.tokenHash))
    }

    func testTokenInfoCodable() throws {
        let (_, info) = TokenGenerator.generate(label: "test-device")
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(TokenInfo.self, from: data)
        XCTAssertEqual(info.id, decoded.id)
        XCTAssertEqual(info.label, "test-device")
        XCTAssertEqual(info.tokenHash, decoded.tokenHash)
    }

    func testUniqueTokensPerGeneration() {
        let tokens = (0..<100).map { _ in TokenGenerator.generate().0 }
        XCTAssertEqual(Set(tokens).count, 100, "Generated tokens must be unique")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TokenGeneratorTests`
Expected: FAIL

- [ ] **Step 3: Implement TokenInfo and TokenGenerator**

```swift
// Sources/ClaudeRelayKit/Models/TokenInfo.swift
import Foundation

public struct TokenInfo: Codable, Sendable, Identifiable {
    public let id: String        // short UUID for referencing
    public let tokenHash: String // SHA-256 hex of plaintext token
    public let label: String?
    public let createdAt: Date
    public var lastUsedAt: Date?

    public init(id: String, tokenHash: String, label: String?,
                createdAt: Date, lastUsedAt: Date? = nil) {
        self.id = id
        self.tokenHash = tokenHash
        self.label = label
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}
```

```swift
// Sources/ClaudeRelayKit/Security/TokenGenerator.swift
import Foundation
import Crypto

public enum TokenGenerator {
    public static func generate(label: String? = nil) -> (plaintext: String, info: TokenInfo) {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let plaintext = Data(bytes).base64URLEncodedString()
        let tokenHash = hash(plaintext)
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let info = TokenInfo(
            id: id, tokenHash: tokenHash, label: label,
            createdAt: Date()
        )
        return (plaintext, info)
    }

    public static func hash(_ token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func validate(_ token: String, against storedHash: String) -> Bool {
        hash(token) == storedHash
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter TokenGeneratorTests`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: implement token generation with SHA-256 hashing"
```

---

## Task 5: Configuration Model (ClaudeRelayKit)

**Files:**
- Create: `Sources/ClaudeRelayKit/Models/RelayConfig.swift`

**Dependencies:** Task 1

- [ ] **Step 1: Implement RelayConfig**

```swift
// Sources/ClaudeRelayKit/Models/RelayConfig.swift
import Foundation

public struct RelayConfig: Codable, Sendable {
    public var wsPort: UInt16
    public var adminPort: UInt16
    public var detachTimeout: Int     // seconds
    public var scrollbackSize: Int    // bytes
    public var tlsCert: String?
    public var tlsKey: String?
    public var logLevel: String

    public static let `default` = RelayConfig(
        wsPort: 9200, adminPort: 9100,
        detachTimeout: 1800, scrollbackSize: 65536,
        tlsCert: nil, tlsKey: nil, logLevel: "info"
    )

    public static var configDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-relay")
    }

    public static var configFile: URL {
        configDirectory.appendingPathComponent("config.json")
    }

    public static var tokensFile: URL {
        configDirectory.appendingPathComponent("tokens.json")
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat: add RelayConfig model with defaults and file paths"
```

---

## Task 6: PTY C Shim

**Files:**
- Create: `Sources/CPTYShim/include/pty_shim.h`
- Create: `Sources/CPTYShim/pty_shim.c`

**Dependencies:** Task 1

- [ ] **Step 1: Implement the C shim header**

```c
// Sources/CPTYShim/include/pty_shim.h
#ifndef PTY_SHIM_H
#define PTY_SHIM_H

#include <sys/ioctl.h>
#include <termios.h>

/// Fork a new process with a pseudo-terminal.
/// Returns child PID to parent (>0), 0 to child, -1 on error.
/// master_fd receives the master side file descriptor.
int relay_forkpty(int *master_fd, struct winsize *ws);

/// Set terminal window size on the given master fd.
int relay_set_winsize(int fd, unsigned short rows, unsigned short cols);

#endif
```

- [ ] **Step 2: Implement the C shim**

```c
// Sources/CPTYShim/pty_shim.c
#include "pty_shim.h"
#include <util.h>

int relay_forkpty(int *master_fd, struct winsize *ws) {
    return forkpty(master_fd, NULL, NULL, ws);
}

int relay_set_winsize(int fd, unsigned short rows, unsigned short cols) {
    struct winsize ws;
    ws.ws_row = rows;
    ws.ws_col = cols;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;
    return ioctl(fd, TIOCSWINSZ, &ws);
}
```

- [ ] **Step 3: Verify build**

Run: `swift build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: add C shim for forkpty and terminal resize"
```

---

## Task 7: Ring Buffer

**Files:**
- Create: `Sources/ClaudeRelayServer/Services/RingBuffer.swift`
- Test: `Tests/ClaudeRelayServerTests/RingBufferTests.swift`

**Dependencies:** Task 1

- [ ] **Step 1: Write tests**

```swift
import XCTest
@testable import ClaudeRelayServer

final class RingBufferTests: XCTestCase {
    func testWriteAndFlush() {
        var buffer = RingBuffer(capacity: 1024)
        let data = Data("Hello, World!".utf8)
        buffer.write(data)
        let flushed = buffer.flush()
        XCTAssertEqual(flushed, data)
    }

    func testFlushClearsBuffer() {
        var buffer = RingBuffer(capacity: 1024)
        buffer.write(Data("test".utf8))
        _ = buffer.flush()
        let second = buffer.flush()
        XCTAssertTrue(second.isEmpty)
    }

    func testOverflowDropsOldestData() {
        var buffer = RingBuffer(capacity: 10)
        buffer.write(Data("12345".utf8))     // [12345]
        buffer.write(Data("67890AB".utf8))   // overflow: [890AB] + wraps
        let flushed = buffer.flush()
        // Should contain the last 10 bytes
        XCTAssertEqual(flushed.count, 10)
        // Last bytes written should be at the end
        XCTAssertTrue(flushed.hasSuffix(Data("67890AB".utf8)))
    }

    func testEmptyFlush() {
        var buffer = RingBuffer(capacity: 1024)
        let flushed = buffer.flush()
        XCTAssertTrue(flushed.isEmpty)
    }

    func testExactCapacityFill() {
        var buffer = RingBuffer(capacity: 5)
        buffer.write(Data("12345".utf8))
        let flushed = buffer.flush()
        XCTAssertEqual(flushed, Data("12345".utf8))
    }

    func testMultipleSmallWrites() {
        var buffer = RingBuffer(capacity: 1024)
        buffer.write(Data("Hello".utf8))
        buffer.write(Data(", ".utf8))
        buffer.write(Data("World".utf8))
        let flushed = buffer.flush()
        XCTAssertEqual(flushed, Data("Hello, World".utf8))
    }

    func testCount() {
        var buffer = RingBuffer(capacity: 100)
        XCTAssertEqual(buffer.count, 0)
        buffer.write(Data("12345".utf8))
        XCTAssertEqual(buffer.count, 5)
        buffer.write(Data("678".utf8))
        XCTAssertEqual(buffer.count, 8)
        _ = buffer.flush()
        XCTAssertEqual(buffer.count, 0)
    }
}

extension Data {
    func hasSuffix(_ suffix: Data) -> Bool {
        guard count >= suffix.count else { return false }
        return self.suffix(suffix.count) == suffix
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter RingBufferTests`
Expected: FAIL

- [ ] **Step 3: Implement RingBuffer**

```swift
// Sources/ClaudeRelayServer/Services/RingBuffer.swift

/// A fixed-capacity circular buffer for storing PTY output while detached.
/// When capacity is exceeded, oldest data is silently dropped.
public struct RingBuffer: Sendable {
    private var storage: [UInt8]
    private let capacity: Int
    private var head: Int = 0   // next write position
    private var filled: Int = 0 // how many bytes contain valid data

    public init(capacity: Int) {
        self.capacity = capacity
        self.storage = [UInt8](repeating: 0, count: capacity)
    }

    public var count: Int { filled }

    public mutating func write(_ data: Data) {
        for byte in data {
            storage[head] = byte
            head = (head + 1) % capacity
            if filled < capacity {
                filled += 1
            }
        }
    }

    /// Returns all buffered data in order and clears the buffer.
    public mutating func flush() -> Data {
        guard filled > 0 else { return Data() }
        var result = Data(capacity: filled)
        let start = (head - filled + capacity) % capacity
        if start + filled <= capacity {
            result.append(contentsOf: storage[start..<(start + filled)])
        } else {
            result.append(contentsOf: storage[start..<capacity])
            result.append(contentsOf: storage[0..<(start + filled - capacity)])
        }
        filled = 0
        head = 0
        return result
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter RingBufferTests`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: implement ring buffer for detached session output"
```

---

## Task 8: Token Store Actor

**Files:**
- Create: `Sources/ClaudeRelayServer/Actors/TokenStore.swift`
- Test: `Tests/ClaudeRelayServerTests/TokenStoreTests.swift`

**Dependencies:** Tasks 1, 4

- [ ] **Step 1: Write tests**

```swift
import XCTest
@testable import ClaudeRelayServer
@testable import ClaudeRelayKit

final class TokenStoreTests: XCTestCase {
    var tempDir: URL!
    var store: TokenStore!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = TokenStore(directory: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testCreateAndValidate() async throws {
        let (plaintext, info) = try await store.create(label: "test")
        XCTAssertFalse(plaintext.isEmpty)
        XCTAssertEqual(info.label, "test")

        let valid = await store.validate(token: plaintext)
        XCTAssertNotNil(valid)
        XCTAssertEqual(valid?.id, info.id)
    }

    func testValidateRejectsWrongToken() async {
        let result = await store.validate(token: "bogus-token")
        XCTAssertNil(result)
    }

    func testList() async throws {
        _ = try await store.create(label: "a")
        _ = try await store.create(label: "b")
        let list = await store.list()
        XCTAssertEqual(list.count, 2)
    }

    func testDelete() async throws {
        let (_, info) = try await store.create(label: "delete-me")
        try await store.delete(id: info.id)
        let list = await store.list()
        XCTAssertTrue(list.isEmpty)
    }

    func testRotate() async throws {
        let (oldPlaintext, info) = try await store.create(label: "rotate-me")
        let (newPlaintext, newInfo) = try await store.rotate(id: info.id)
        XCTAssertNotEqual(oldPlaintext, newPlaintext)
        XCTAssertEqual(newInfo.id, info.id)  // same ID
        XCTAssertEqual(newInfo.label, "rotate-me")

        let oldValid = await store.validate(token: oldPlaintext)
        XCTAssertNil(oldValid, "Old token should be invalid after rotate")

        let newValid = await store.validate(token: newPlaintext)
        XCTAssertNotNil(newValid)
    }

    func testPersistence() async throws {
        let (plaintext, _) = try await store.create(label: "persist")

        // Create new store instance pointing at same directory
        let store2 = TokenStore(directory: tempDir)
        let valid = await store2.validate(token: plaintext)
        XCTAssertNotNil(valid, "Token should survive reload from disk")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TokenStoreTests`
Expected: FAIL

- [ ] **Step 3: Implement TokenStore**

`TokenStore` is a Swift actor. It holds `[TokenInfo]` in memory, reads/writes `tokens.json` in the given directory. File locking via `flock()` for concurrent access from CLI.

Key methods:
- `create(label:) -> (String, TokenInfo)` — generate token, append to array, save
- `validate(token:) -> TokenInfo?` — hash and compare, update `lastUsedAt` on match
- `list() -> [TokenInfo]`
- `delete(id:)` — remove by id, save
- `rotate(id:) -> (String, TokenInfo)` — generate new token, keep same id+label, save

- [ ] **Step 4: Run tests**

Run: `swift test --filter TokenStoreTests`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: implement TokenStore actor with JSON persistence"
```

---

## Task 9: PTY Session Actor

**Files:**
- Create: `Sources/ClaudeRelayServer/Actors/PTYSession.swift`

**Dependencies:** Tasks 1, 5, 6, 7

- [ ] **Step 1: Implement PTYSession**

This actor manages a single PTY + child process. It cannot be easily unit-tested (requires real process spawning), so we test it through integration.

```swift
// Sources/ClaudeRelayServer/Actors/PTYSession.swift
import Foundation
import CPTYShim
import NIOCore

/// Manages a single PTY session: forkpty, read/write, resize, cleanup.
public actor PTYSession {
    private let masterFD: Int32
    private let childPID: pid_t
    private var ringBuffer: RingBuffer
    private var outputHandler: ((Data) -> Void)?
    private var exitHandler: (() -> Void)?
    private var readSource: DispatchSourceRead?

    public let sessionId: UUID
    public let cols: UInt16
    public let rows: UInt16

    public init(sessionId: UUID, cols: UInt16, rows: UInt16,
                scrollbackSize: Int, command: String = "/usr/local/bin/claude") throws {
        self.sessionId = sessionId
        self.cols = cols
        self.rows = rows
        self.ringBuffer = RingBuffer(capacity: scrollbackSize)

        var masterFD: Int32 = 0
        var ws = winsize()
        ws.ws_col = cols
        ws.ws_row = rows

        let pid = relay_forkpty(&masterFD, &ws)
        guard pid >= 0 else { throw PTYError.forkFailed(errno) }

        if pid == 0 {
            // Child process
            setenv("TERM", "xterm-256color", 1)
            setenv("LANG", "en_US.UTF-8", 1)
            let home = NSHomeDirectory()
            chdir(home)
            execl("/bin/zsh", "zsh", "-l", "-c", command, nil)
            _exit(1) // exec failed
        }

        // Parent
        self.masterFD = masterFD
        self.childPID = pid
        startReading()
    }

    public func setOutputHandler(_ handler: @escaping @Sendable (Data) -> Void) {
        self.outputHandler = handler
    }

    public func setExitHandler(_ handler: @escaping @Sendable () -> Void) {
        self.exitHandler = handler
    }

    public func clearOutputHandler() {
        self.outputHandler = nil
    }

    public func write(_ data: Data) {
        data.withUnsafeBytes { ptr in
            _ = Foundation.write(masterFD, ptr.baseAddress!, ptr.count)
        }
    }

    public func resize(cols: UInt16, rows: UInt16) {
        relay_set_winsize(masterFD, rows, cols)
    }

    public func flushBuffer() -> Data {
        ringBuffer.flush()
    }

    public func terminate() {
        readSource?.cancel()
        kill(childPID, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [childPID] in
            kill(childPID, SIGKILL)
        }
        close(masterFD)
    }

    private func startReading() {
        let source = DispatchSource.makeReadSource(
            fileDescriptor: masterFD,
            queue: DispatchQueue.global(qos: .userInteractive)
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 8192)
            let n = read(self.masterFD, &buf, buf.count)
            if n > 0 {
                let data = Data(buf[..<n])
                Task { await self.handleOutput(data) }
            } else if n <= 0 {
                Task { await self.handleExit() }
            }
        }
        source.setCancelHandler { [masterFD = self.masterFD] in
            close(masterFD)
        }
        source.resume()
        self.readSource = source
    }

    private func handleOutput(_ data: Data) {
        if let handler = outputHandler {
            handler(data)
        } else {
            ringBuffer.write(data)
        }
    }

    private func handleExit() {
        readSource?.cancel()
        exitHandler?()
    }
}

public enum PTYError: Error {
    case forkFailed(Int32)
}
```

- [ ] **Step 2: Verify build**

Run: `swift build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat: implement PTYSession actor with forkpty, I/O, and ring buffer"
```

---

## Task 10: Session Manager Actor

**Files:**
- Create: `Sources/ClaudeRelayServer/Actors/SessionManager.swift`
- Test: `Tests/ClaudeRelayServerTests/SessionManagerTests.swift`

**Dependencies:** Tasks 3, 8, 9

- [ ] **Step 1: Write tests for session lifecycle**

Test the state machine logic using a mock/stub approach — test `SessionManager` with a simplified PTY or by verifying state transitions without spawning real processes.

```swift
import XCTest
@testable import ClaudeRelayServer
@testable import ClaudeRelayKit

final class SessionManagerTests: XCTestCase {
    func testCreateSession() async throws {
        let manager = SessionManager(config: .default, tokenStore: makeTestTokenStore())
        let (_, tokenInfo) = try await manager.tokenStore.create(label: "test")
        let info = try await manager.createSession(tokenId: tokenInfo.id)
        XCTAssertEqual(info.state, .starting)
        XCTAssertEqual(info.tokenId, tokenInfo.id)
    }

    func testListSessions() async throws {
        let manager = SessionManager(config: .default, tokenStore: makeTestTokenStore())
        let (_, tokenInfo) = try await manager.tokenStore.create(label: "test")
        _ = try await manager.createSession(tokenId: tokenInfo.id)
        _ = try await manager.createSession(tokenId: tokenInfo.id)
        let list = await manager.listSessions()
        XCTAssertEqual(list.count, 2)
    }

    func testTerminateSession() async throws {
        let manager = SessionManager(config: .default, tokenStore: makeTestTokenStore())
        let (_, tokenInfo) = try await manager.tokenStore.create(label: "test")
        let info = try await manager.createSession(tokenId: tokenInfo.id)
        try await manager.terminateSession(id: info.id, tokenId: tokenInfo.id)
        let updated = try await manager.inspectSession(id: info.id)
        XCTAssertEqual(updated.state, .terminated)
    }

    func testSessionOwnership() async throws {
        let manager = SessionManager(config: .default, tokenStore: makeTestTokenStore())
        let (_, tok1) = try await manager.tokenStore.create(label: "user1")
        let (_, tok2) = try await manager.tokenStore.create(label: "user2")
        let info = try await manager.createSession(tokenId: tok1.id)

        // tok2 cannot terminate tok1's session
        do {
            try await manager.terminateSession(id: info.id, tokenId: tok2.id)
            XCTFail("Should have thrown ownership error")
        } catch {
            // expected
        }
    }

    private func makeTestTokenStore() -> TokenStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return TokenStore(directory: dir)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SessionManagerTests`
Expected: FAIL

- [ ] **Step 3: Implement SessionManager**

```swift
// Sources/ClaudeRelayServer/Actors/SessionManager.swift
public actor SessionManager {
    let config: RelayConfig
    let tokenStore: TokenStore
    private var sessions: [UUID: ManagedSession] = [:]
    private var detachTimers: [UUID: Task<Void, Never>] = [:]

    struct ManagedSession {
        var info: SessionInfo
        var ptySession: PTYSession?
    }

    public init(config: RelayConfig, tokenStore: TokenStore) {
        self.config = config
        self.tokenStore = tokenStore
    }

    public func createSession(tokenId: String, cols: UInt16 = 80,
                               rows: UInt16 = 24) throws -> SessionInfo {
        let id = UUID()
        let info = SessionInfo(id: id, state: .starting, tokenId: tokenId,
                               createdAt: Date(), cols: cols, rows: rows)
        let pty = try PTYSession(sessionId: id, cols: cols, rows: rows,
                                  scrollbackSize: config.scrollbackSize)
        sessions[id] = ManagedSession(info: info, ptySession: pty)
        return info
    }

    public func listSessions() -> [SessionInfo] {
        sessions.values.map(\.info)
    }

    public func inspectSession(id: UUID) throws -> SessionInfo {
        guard let session = sessions[id] else {
            throw SessionError.notFound(id)
        }
        return session.info
    }

    public func terminateSession(id: UUID, tokenId: String) throws {
        guard var session = sessions[id] else {
            throw SessionError.notFound(id)
        }
        guard session.info.tokenId == tokenId else {
            throw SessionError.ownershipViolation
        }
        guard session.info.state.canTransition(to: .terminated) else {
            throw SessionError.invalidTransition(session.info.state, .terminated)
        }
        session.info.state = .terminated
        sessions[id] = session
        Task { await session.ptySession?.terminate() }
        detachTimers[id]?.cancel()
    }

    // ... attach, detach, resume methods follow same pattern
}

public enum SessionError: Error {
    case notFound(UUID)
    case ownershipViolation
    case invalidTransition(SessionState, SessionState)
    case alreadyAttached
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter SessionManagerTests`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: implement SessionManager actor with lifecycle state machine"
```

---

## Task 11: WebSocket Server

**Files:**
- Create: `Sources/ClaudeRelayServer/Network/WebSocketServer.swift`
- Create: `Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift`

**Dependencies:** Tasks 2, 10

- [ ] **Step 1: Implement WebSocketServer**

NIO-based WebSocket server that accepts connections, upgrades HTTP to WebSocket, and installs `RelayMessageHandler` per connection.

Key implementation details:
- `ServerBootstrap` with `NIOPosix.MultiThreadedEventLoopGroup`
- HTTP1 → WebSocket upgrade via `NIOWebSocketServerUpgrader`
- Each WebSocket connection gets a `RelayMessageHandler` instance
- 10-second auth timer per connection
- Rate limiting: track failed auths per IP

```swift
// Sources/ClaudeRelayServer/Network/WebSocketServer.swift
import NIO
import NIOHTTP1
import NIOWebSocket

public final class WebSocketServer {
    private let group: EventLoopGroup
    private let sessionManager: SessionManager
    private let tokenStore: TokenStore
    private let port: UInt16
    private var channel: Channel?

    public init(group: EventLoopGroup, port: UInt16,
                sessionManager: SessionManager, tokenStore: TokenStore) {
        self.group = group
        self.port = port
        self.sessionManager = sessionManager
        self.tokenStore = tokenStore
    }

    public func start() async throws {
        let upgrader = NIOWebSocketServerUpgrader(
            shouldUpgrade: { channel, head in
                channel.eventLoop.makeSucceededFuture(HTTPHeaders())
            },
            upgradePipelineHandler: { [sessionManager, tokenStore] channel, _ in
                let handler = RelayMessageHandler(
                    sessionManager: sessionManager,
                    tokenStore: tokenStore
                )
                return channel.pipeline.addHandler(handler)
            }
        )
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 256)
            .childChannelInitializer { channel in
                let config: NIOHTTPServerUpgradeConfiguration = (
                    upgraders: [upgrader],
                    completionHandler: { _ in }
                )
                return channel.pipeline.configureHTTPServerPipeline(
                    withServerUpgrade: config
                )
            }
        channel = try await bootstrap.bind(host: "0.0.0.0", port: Int(port)).get()
    }

    public func stop() async throws {
        try await channel?.close()
    }
}
```

- [ ] **Step 2: Implement RelayMessageHandler**

```swift
// Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift
import NIO
import NIOWebSocket
import ClaudeRelayKit

/// Per-connection WebSocket handler. Bridges NIO frames to actor world.
final class RelayMessageHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame

    private let sessionManager: SessionManager
    private let tokenStore: TokenStore
    private var isAuthenticated = false
    private var attachedSessionId: UUID?
    private var authTimeout: Scheduled<Void>?
    private var context: ChannelHandlerContext?

    // Text frames → decode JSON → dispatch to actors
    // Binary frames → write to PTY
    // Close frames → detach session
    // ...implementation follows spec protocol flow
}
```

- [ ] **Step 3: Verify build**

Run: `swift build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: implement NIO WebSocket server with relay message handler"
```

---

## Task 12: Admin HTTP Server

**Files:**
- Create: `Sources/ClaudeRelayServer/Network/AdminHTTPServer.swift`
- Create: `Sources/ClaudeRelayServer/Network/AdminRoutes.swift`
- Create: `Sources/ClaudeRelayServer/Services/ConfigManager.swift`
- Test: `Tests/ClaudeRelayServerTests/AdminRoutesTests.swift`

**Dependencies:** Tasks 8, 10

- [ ] **Step 1: Write tests for admin route responses**

Test the route handler logic (request parsing + response formatting) without needing a live server. Use helper functions that take parsed request parts and return response data.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AdminRoutesTests`
Expected: FAIL

- [ ] **Step 3: Implement AdminHTTPServer + AdminRoutes + ConfigManager**

`AdminHTTPServer`: NIO HTTP1 server bound to `127.0.0.1:9100`. Simple request router that dispatches to handler functions in `AdminRoutes`.

`AdminRoutes`: Static functions for each endpoint. Each takes the relevant actor and returns JSON response data.

`ConfigManager`: Reads/writes `~/.claude-relay/config.json`. Creates directory + default config if missing.

Endpoints per spec:
- `GET /health` → `{"status":"ok"}`
- `GET /status` → `{"running":true, "pid":..., "uptime":..., "wsPort":..., "sessions":..., "version":"0.1.0"}`
- `GET /sessions` → `[SessionInfo]`
- `GET /sessions/:id` → `SessionInfo`
- `DELETE /sessions/:id` → `{"ok":true}`
- `POST /tokens` → `{"plaintext":"...", "info": TokenInfo}` (label from body)
- `GET /tokens` → `[TokenInfo]` (no hashes in response)
- `DELETE /tokens/:id` → `{"ok":true}`
- `POST /tokens/:id/rotate` → `{"plaintext":"...", "info": TokenInfo}`
- `GET /config` → `RelayConfig`
- `PUT /config/:key` → `{"ok":true}` (value from body)
- `GET /logs` → `{"lines": [...]}`

- [ ] **Step 4: Run tests**

Run: `swift test --filter AdminRoutesTests`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: implement admin HTTP API with all endpoints"
```

---

## Task 13: Server Main Entry Point

**Files:**
- Modify: `Sources/ClaudeRelayServer/main.swift`

**Dependencies:** Tasks 11, 12

- [ ] **Step 1: Implement server entry point**

```swift
// Sources/ClaudeRelayServer/main.swift
import NIO
import ClaudeRelayKit

@main
struct ClaudeRelayServer {
    static func main() async throws {
        let config = try ConfigManager.load()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        defer { try? group.syncShutdownGracefully() }

        let tokenStore = TokenStore(directory: RelayConfig.configDirectory)
        let sessionManager = SessionManager(config: config, tokenStore: tokenStore)

        let wsServer = WebSocketServer(
            group: group, port: config.wsPort,
            sessionManager: sessionManager, tokenStore: tokenStore
        )
        let adminServer = AdminHTTPServer(
            group: group, port: config.adminPort,
            sessionManager: sessionManager, tokenStore: tokenStore,
            configManager: ConfigManager()
        )

        try await wsServer.start()
        try await adminServer.start()

        print("ClaudeRelay server running")
        print("  WebSocket: 0.0.0.0:\(config.wsPort)")
        print("  Admin API: 127.0.0.1:\(config.adminPort)")

        // Block until signal
        let signal = DispatchSemaphore(value: 0)
        let sigSrc = DispatchSource.makeSignalSource(signal: SIGINT)
        sigSrc.setEventHandler { signal.signal() }
        sigSrc.resume()
        Foundation.signal(SIGINT, SIG_IGN)
        signal.wait()

        try await wsServer.stop()
        try await adminServer.stop()
    }
}
```

- [ ] **Step 2: Verify build and manual smoke test**

Run: `swift build && .build/debug/code-relay-server &`
Then: `curl http://127.0.0.1:9100/health`
Expected: `{"status":"ok"}`
Clean up: kill the server process

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat: implement server entry point with dual listeners"
```

---

## Task 14: CLI — Root + Output Formatter + Admin Client

**Files:**
- Modify: `Sources/ClaudeRelayCLI/main.swift`
- Create: `Sources/ClaudeRelayCLI/CLIRoot.swift`
- Create: `Sources/ClaudeRelayCLI/Formatters/OutputFormatter.swift`
- Create: `Sources/ClaudeRelayCLI/AdminClient.swift`
- Test: `Tests/ClaudeRelayCLITests/OutputFormatterTests.swift`

**Dependencies:** Tasks 1, 5

- [ ] **Step 1: Write tests for OutputFormatter**

```swift
import XCTest
@testable import ClaudeRelayCLI

final class OutputFormatterTests: XCTestCase {
    func testJSONOutput() throws {
        let data: [String: Any] = ["status": "ok", "port": 9200]
        let output = OutputFormatter.format(data, json: true)
        let parsed = try JSONSerialization.jsonObject(with: Data(output.utf8)) as! [String: Any]
        XCTAssertEqual(parsed["status"] as? String, "ok")
    }

    func testHumanOutput() {
        let output = OutputFormatter.formatStatus(
            running: true, pid: 1234, uptime: 3661, wsPort: 9200, sessions: 2
        )
        XCTAssertTrue(output.contains("Running"))
        XCTAssertTrue(output.contains("1234"))
        XCTAssertTrue(output.contains("9200"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement CLIRoot, OutputFormatter, AdminClient**

`CLIRoot`: root `ParsableCommand` with `--json` and `--quiet` global options.
`OutputFormatter`: switches between JSON (raw `Codable` encode) and human-readable (formatted strings).
`AdminClient`: thin HTTP client using `URLSession` that calls `http://127.0.0.1:{adminPort}/...`. Handles connection refused → "Service is not running".

- [ ] **Step 4: Run tests**

Run: `swift test --filter OutputFormatterTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: implement CLI root, output formatter, and admin client"
```

---

## Task 15: CLI — Service Commands

**Files:**
- Create: `Sources/ClaudeRelayCLI/Commands/ServiceCommands.swift`

**Dependencies:** Task 14

- [ ] **Step 1: Implement service lifecycle commands**

Commands: `load`, `unload`, `start`, `stop`, `restart`, `status`, `health`

- `load`: Generates `~/Library/LaunchAgents/com.coderemote.relay.plist` with path to the built server binary, then runs `launchctl load <plist>`.
- `unload`: Runs `launchctl unload <plist>`, then deletes the plist file.
- `start` / `stop`: `launchctl start/stop com.coderemote.relay`
- `restart`: stop + start
- `status`: `GET /status` from admin API, formatted per `--json` flag
- `health`: `GET /health` from admin API

- [ ] **Step 2: Verify build**

Run: `swift build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat: implement CLI service lifecycle commands (load/unload/start/stop/restart/status/health)"
```

---

## Task 16: CLI — Token Commands

**Files:**
- Create: `Sources/ClaudeRelayCLI/Commands/TokenCommands.swift`

**Dependencies:** Task 14

- [ ] **Step 1: Implement token management commands**

Commands: `token create`, `token list`, `token delete`, `token rotate`, `token inspect`

- `create [--label]`: `POST /tokens` → print plaintext token ONCE to stdout
- `list`: `GET /tokens` → table or JSON
- `delete <id>`: `DELETE /tokens/:id`
- `rotate <id>`: `POST /tokens/:id/rotate` → print new plaintext ONCE
- `inspect <id>`: `GET /tokens/:id` (never shows hash or plaintext)

- [ ] **Step 2: Verify build**

Run: `swift build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat: implement CLI token management commands"
```

---

## Task 17: CLI — Session + Config + Log Commands

**Files:**
- Create: `Sources/ClaudeRelayCLI/Commands/SessionCommands.swift`
- Create: `Sources/ClaudeRelayCLI/Commands/ConfigCommands.swift`
- Create: `Sources/ClaudeRelayCLI/Commands/LogCommands.swift`

**Dependencies:** Task 14

- [ ] **Step 1: Implement session commands**

- `session list`: `GET /sessions` → table or JSON
- `session inspect <id>`: `GET /sessions/:id`
- `session terminate <id>`: `DELETE /sessions/:id`

- [ ] **Step 2: Implement config commands**

- `config show`: `GET /config`
- `config set <key> <value>`: `PUT /config/:key`
- `config validate`: `GET /config` + local validation logic

- [ ] **Step 3: Implement log commands**

- `logs show [--lines N]`: `GET /logs?lines=N`
- `logs tail`: `GET /logs?follow=true` (streaming response or poll)

- [ ] **Step 4: Verify build**

Run: `swift build`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: implement CLI session, config, and log commands"
```

---

## Task 18: iOS Client Library — ConnectionConfig + AuthManager

**Files:**
- Create: `Sources/ClaudeRelayClient/ConnectionConfig.swift`
- Create: `Sources/ClaudeRelayClient/AuthManager.swift`

**Dependencies:** Task 2

- [ ] **Step 1: Implement ConnectionConfig**

```swift
import Foundation
import ClaudeRelayKit

public struct ConnectionConfig: Codable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: UInt16
    public var useTLS: Bool

    public var wsURL: URL {
        let scheme = useTLS ? "wss" : "ws"
        return URL(string: "\(scheme)://\(host):\(port)")!
    }
}
```

- [ ] **Step 2: Implement AuthManager**

Keychain wrapper using `Security` framework. Stores tokens keyed by connection ID.

```swift
import Foundation
import Security

public final class AuthManager: Sendable {
    public static let shared = AuthManager()

    public func saveToken(_ token: String, for connectionId: UUID) throws { ... }
    public func loadToken(for connectionId: UUID) throws -> String? { ... }
    public func deleteToken(for connectionId: UUID) throws { ... }
}
```

Uses `kSecClassGenericPassword` with service = `"com.coderemote.relay"` and account = connection UUID string.

- [ ] **Step 3: Verify build**

Run: `swift build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: implement iOS connection config and Keychain auth manager"
```

---

## Task 19: iOS Client Library — RelayConnection + SessionController

**Files:**
- Create: `Sources/ClaudeRelayClient/RelayConnection.swift`
- Create: `Sources/ClaudeRelayClient/SessionController.swift`

**Dependencies:** Tasks 2, 18

- [ ] **Step 1: Implement RelayConnection**

WebSocket lifecycle via `URLSessionWebSocketTask`. Handles:
- Connect / disconnect
- Send text frame (JSON control messages)
- Send binary frame (terminal input)
- Receive loop (text → decode `ServerMessage`, binary → terminal output callback)
- Connection state published as `@Published` for SwiftUI binding
- Reconnect with exponential backoff (1s, 2s, 4s, 8s, max 30s)

```swift
import Foundation
import ClaudeRelayKit

@MainActor
public final class RelayConnection: ObservableObject {
    public enum State { case disconnected, connecting, connected, reconnecting }

    @Published public private(set) var state: State = .disconnected
    private var webSocketTask: URLSessionWebSocketTask?
    private var onServerMessage: ((ServerMessage) -> Void)?
    private var onTerminalOutput: ((Data) -> Void)?
    // ...
}
```

- [ ] **Step 2: Implement SessionController**

Orchestrates auth + session lifecycle:
- `connect(config:token:)` → open WS → send `auth_request` → wait for `auth_success`
- `createSession()` → send `session_create` → wait for `session_created`
- `resumeSession(id:)` → send `session_resume` → wait for `session_resumed`
- `detach()` → send `session_detach`
- Stores active session ID for reconnect

- [ ] **Step 3: Verify build**

Run: `swift build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: implement RelayConnection and SessionController for iOS"
```

---

## Task 20: iOS Client Library — TerminalBridge

**Files:**
- Create: `Sources/ClaudeRelayClient/TerminalBridge.swift`

**Dependencies:** Task 19

- [ ] **Step 1: Implement TerminalBridge**

Bridges `RelayConnection` ↔ `SwiftTerm.TerminalView`:
- Implements SwiftTerm's `TerminalViewDelegate`
- Routes keyboard input → `RelayConnection.sendBinary(data)`
- Routes `RelayConnection.onTerminalOutput` → `TerminalView.feed(byteArray:)`
- Routes resize → `RelayConnection.sendResize(cols:rows:)`
- On resume: feeds buffered output before live streaming

```swift
import Foundation
import SwiftTerm
import ClaudeRelayKit

public final class TerminalBridge: TerminalViewDelegate {
    private let connection: RelayConnection
    private let sessionController: SessionController

    public init(connection: RelayConnection, sessionController: SessionController) {
        self.connection = connection
        self.sessionController = sessionController
        connection.onTerminalOutput = { [weak self] data in
            self?.feedOutput(data)
        }
    }

    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        connection.sendBinary(Data(data))
    }

    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        connection.sendResize(cols: UInt16(newCols), rows: UInt16(newRows))
    }

    // ...remaining delegate methods
}
```

- [ ] **Step 2: Verify build**

Run: `swift build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat: implement TerminalBridge connecting SwiftTerm to RelayConnection"
```

---

## Task 21: iOS App — Xcode Project + Views

**Files:**
- Create: `ClaudeRelayApp/` Xcode project structure
- Create: `ClaudeRelayApp/ClaudeRelayApp/ClaudeRelayApp.swift`
- Create: `ClaudeRelayApp/ClaudeRelayApp/Views/ConnectionView.swift`
- Create: `ClaudeRelayApp/ClaudeRelayApp/Views/SessionListView.swift`
- Create: `ClaudeRelayApp/ClaudeRelayApp/Views/TerminalContainerView.swift`
- Create: `ClaudeRelayApp/ClaudeRelayApp/Views/Components/StatusIndicator.swift`
- Create: `ClaudeRelayApp/ClaudeRelayApp/Views/Components/KeyboardAccessory.swift`
- Create: `ClaudeRelayApp/ClaudeRelayApp/ViewModels/ConnectionViewModel.swift`
- Create: `ClaudeRelayApp/ClaudeRelayApp/ViewModels/SessionListViewModel.swift`
- Create: `ClaudeRelayApp/ClaudeRelayApp/ViewModels/TerminalViewModel.swift`

**Dependencies:** Tasks 18, 19, 20

Note: The Xcode project cannot be created via `swift package` alone — it requires `xcodebuild` or manual `.xcodeproj` generation. The SwiftTerm dependency must be added here.

- [ ] **Step 1: Create Xcode project scaffold**

Create the directory structure. Use `swift package init --type executable` in `ClaudeRelayApp/` or scaffold manually. Add `SwiftTerm` dependency.

- [ ] **Step 2: Implement ConnectionView + ConnectionViewModel**

- Form fields: Name, Host, Port, Token, Use TLS toggle
- Save to UserDefaults (connection list) + Keychain (token)
- List of saved connections with swipe-to-delete
- Tap connection → navigate to SessionListView
- "Connect" button

- [ ] **Step 3: Implement SessionListView + SessionListViewModel**

- After auth success, shows list of sessions from server
- Each row: session ID (truncated), state, created time
- "New Session" button
- Tap existing session → resume → navigate to TerminalContainerView

- [ ] **Step 4: Implement TerminalContainerView + TerminalViewModel**

- Full-screen SwiftTerm `TerminalView` wrapped in `UIViewRepresentable`
- Custom keyboard accessory bar with: Ctrl, Tab, Esc, ↑, ↓, ←, →, |, /, ~
- Status indicator overlay (green/yellow/red)
- TerminalViewModel owns `RelayConnection`, `SessionController`, `TerminalBridge`

- [ ] **Step 5: Implement StatusIndicator + KeyboardAccessory**

- `StatusIndicator`: small colored circle (SF Symbol) + text label
- `KeyboardAccessory`: horizontal scroll bar of special key buttons, sends control sequences via TerminalBridge

- [ ] **Step 6: Verify build in Xcode**

Open in Xcode, build for iOS Simulator.
Expected: BUILD SUCCEEDED

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat: implement iOS app with connection, session list, and terminal views"
```

---

## Task 22: Integration — End-to-End Smoke Test

**Dependencies:** Tasks 13, 17, 21

- [ ] **Step 1: Manual integration test**

1. Build server: `swift build`
2. Start server: `.build/debug/code-relay-server`
3. Create token: `.build/debug/claude-relay token create --label test`
4. Verify health: `curl http://127.0.0.1:9100/health`
5. Verify sessions empty: `curl http://127.0.0.1:9100/sessions`
6. Connect from iOS simulator (or use `websocat` for quick test):
   ```bash
   websocat ws://127.0.0.1:9200
   # Send: {"type":"auth_request","payload":{"token":"<token>"}}
   # Expect: {"type":"auth_success","payload":{}}
   # Send: {"type":"session_create","payload":{}}
   # Expect: {"type":"session_created","payload":{"sessionId":"...","cols":80,"rows":24}}
   ```
7. Verify session appears: `curl http://127.0.0.1:9100/sessions`

- [ ] **Step 2: Fix any integration issues found**

- [ ] **Step 3: Commit fixes**

```bash
git add -A && git commit -m "fix: integration test fixes"
```

---

## Task 23: Hardening — TLS Support

**Dependencies:** Task 13

- [ ] **Step 1: Add TLS to WebSocket server**

When `config.tlsCert` and `config.tlsKey` are set, add `NIOSSLServerHandler` to the channel pipeline before the HTTP handler. Use `NIOSSLContext` with the configured cert/key files.

- [ ] **Step 2: Test with self-signed cert**

```bash
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 365 -nodes -subj '/CN=localhost'
.build/debug/claude-relay config set tlsCert cert.pem
.build/debug/claude-relay config set tlsKey key.pem
.build/debug/claude-relay restart
curl -k https://localhost:9200  # should get HTTP upgrade error (expected — it's WS)
```

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat: add TLS support for WebSocket server"
```

---

## Task 24: Hardening — Brute-Force Protection + Auth Timeout

**Dependencies:** Task 11

- [ ] **Step 1: Implement rate limiter**

In `RelayMessageHandler`: track failed auth attempts per IP using an in-memory dictionary with timestamps. After 5 failures in 60 seconds, close connection immediately.

- [ ] **Step 2: Implement auth timeout**

In `RelayMessageHandler.channelActive`: schedule a 10-second timer. If no successful auth by then, close the connection.

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat: add brute-force protection and auth timeout"
```

---

## Task 25: Hardening — Detach Timeout + Structured Logging

**Dependencies:** Task 10

- [ ] **Step 1: Implement detach timeout in SessionManager**

When a session transitions to `active-detached`, start a `Task.sleep` timer for `config.detachTimeout` seconds. On expiry, transition to `expired` and clean up. Cancel timer on reattach.

- [ ] **Step 2: Add structured logging**

Use `os.Logger` throughout server:
- Connection events (connect, auth, disconnect)
- Session lifecycle transitions
- Admin API requests
- Never log tokens or terminal I/O

- [ ] **Step 3: Wire logs to admin API**

Store recent log entries in a ring buffer. Serve via `GET /logs`.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: add detach timeout enforcement and structured logging"
```

---

## Parallelization Map

```
Task 1 (scaffold)
  ├─→ Task 2 (protocol) ──────────────────────┐
  ├─→ Task 3 (session state) ──────┐           │
  ├─→ Task 4 (token model) ────────┤           │
  ├─→ Task 5 (config model) ───────┤           │
  ├─→ Task 6 (PTY shim) ──────────┤           │
  └─→ Task 7 (ring buffer) ───────┤           │
                                    │           │
  Tasks 3,4,8 ─→ Task 8 (token store)│         │
  Tasks 5,6,7,9 → Task 9 (PTY session)│        │
                                    │           │
  Tasks 8,9,10 ──→ Task 10 (session mgr)       │
  Tasks 2,10 ────→ Task 11 (WS server) ──┐     │
  Tasks 8,10 ────→ Task 12 (admin HTTP) ──┤     │
                                           │     │
  Tasks 11,12 ───→ Task 13 (server main) ──┤     │
                                           │     │
  Tasks 1,5 ─────→ Task 14 (CLI root) ────┤     │
  Task 14 ───────→ Task 15 (svc cmds)  ───┤     │
  Task 14 ───────→ Task 16 (token cmds) ──┤     │
  Task 14 ───────→ Task 17 (sess/cfg cmds)┤     │
                                           │     │
  Task 2 ────────→ Task 18 (iOS config) ───┤     │
  Tasks 2,18 ────→ Task 19 (iOS connection)┤     │
  Task 19 ───────→ Task 20 (terminal bridge)    │
  Tasks 18-20 ───→ Task 21 (iOS app views) ┤     │
                                           │     │
  All above ─────→ Task 22 (integration)   │     │
  Task 13 ───────→ Task 23 (TLS)           │     │
  Task 11 ───────→ Task 24 (brute-force)   │     │
  Task 10 ───────→ Task 25 (hardening)     │     │
```

**Wave 1 (parallel):** Tasks 2, 3, 4, 5, 6, 7
**Wave 2 (parallel):** Tasks 8, 9
**Wave 3 (parallel):** Tasks 10, 14, 18
**Wave 4 (parallel):** Tasks 11, 12, 15, 16, 17, 19
**Wave 5 (parallel):** Tasks 13, 20
**Wave 6 (parallel):** Tasks 21, 23, 24, 25
**Wave 7:** Task 22 (integration)
