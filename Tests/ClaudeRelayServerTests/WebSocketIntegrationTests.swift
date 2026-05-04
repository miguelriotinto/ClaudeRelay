import XCTest
import Foundation
import NIO
import NIOPosix
import ClaudeRelayKit
@testable import ClaudeRelayServer
@testable import ClaudeRelayClient

/// Integration tests that spin up a real `WebSocketServer` and exercise the
/// full client → server → client round trip via `RelayConnection` and
/// `SessionController`.
///
/// These tests share a test target with `SessionManagerTests`, which defines
/// `MockPTYSession` for PTY-free session management (see that file).
final class WebSocketIntegrationTests: XCTestCase {

    /// End-to-end smoke test: start a real `WebSocketServer`, connect a
    /// `RelayConnection` + `SessionController`, authenticate with a freshly
    /// minted token, and verify the controller transitions to authenticated.
    @MainActor
    func testClientAuthenticatesAgainstRealServer() async throws {
        // Scratch directory for TokenStore persistence.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WSIntegration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        var config = RelayConfig.default
        // Random high ports to avoid collisions with a locally-running dev server.
        config.wsPort = UInt16.random(in: 19_000..<20_000)
        config.adminPort = UInt16.random(in: 20_000..<21_000)

        let tokenStore = TokenStore(directory: tempDir)
        let (plaintext, _) = try await tokenStore.create(label: "integration")

        let sessionManager = SessionManager(
            config: config,
            tokenStore: tokenStore,
            ptyFactory: { id, cols, rows, scrollback in
                MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
            }
        )

        let server = WebSocketServer(
            group: group,
            config: config,
            sessionManager: sessionManager,
            tokenStore: tokenStore
        )
        try await server.start()

        // Small delay so the listening socket is ready to accept.
        try? await Task.sleep(for: .milliseconds(100))

        let connection = RelayConnection()
        let controller = SessionController(connection: connection)
        let clientConfig = ConnectionConfig(
            name: "IntegrationTest",
            host: "127.0.0.1",
            port: config.wsPort
        )

        try await connection.connect(config: clientConfig, token: plaintext)
        try await controller.authenticate(token: plaintext)

        XCTAssertTrue(controller.isAuthenticated,
                      "Controller should report authenticated after successful auth_request")
        XCTAssertTrue(controller.isAuthValid,
                      "Auth should be valid on the current connection generation")

        connection.disconnect()

        // Shut down the server while the event loop is still live — this avoids
        // NIO's "Cannot schedule tasks on an EventLoop that has already shut down"
        // warning that occurs when close work is scheduled from a defer after
        // `group.syncShutdownGracefully()` has already run.
        try? await server.stop()
    }

    /// After `forceReconnect`, the client should obtain a fresh connection
    /// generation and be able to re-authenticate successfully against the
    /// still-running server. This is a lighter-weight proxy for the full
    /// server-restart recovery flow (which is owned by SharedSessionCoordinator
    /// and requires significantly more test scaffolding to exercise end-to-end).
    @MainActor
    func testForceReconnectPreservesAuthFlowAgainstRealServer() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WSIntegrationReconnect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        var config = RelayConfig.default
        config.wsPort = UInt16.random(in: 19_000..<20_000)
        config.adminPort = UInt16.random(in: 20_000..<21_000)

        let tokenStore = TokenStore(directory: tempDir)
        let (plaintext, _) = try await tokenStore.create(label: "reconnect")

        let sessionManager = SessionManager(
            config: config,
            tokenStore: tokenStore,
            ptyFactory: { id, cols, rows, scrollback in
                MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
            }
        )

        let server = WebSocketServer(
            group: group,
            config: config,
            sessionManager: sessionManager,
            tokenStore: tokenStore
        )
        try await server.start()

        try? await Task.sleep(for: .milliseconds(100))

        let connection = RelayConnection()
        let controller = SessionController(connection: connection)
        let clientConfig = ConnectionConfig(
            name: "ReconnectTest",
            host: "127.0.0.1",
            port: config.wsPort
        )

        try await connection.connect(config: clientConfig, token: plaintext)
        try await controller.authenticate(token: plaintext)
        let genBefore = connection.generation
        XCTAssertTrue(controller.isAuthenticated)

        // Force a fresh transport. The stored config/token should let the
        // client reconnect without the caller re-supplying them.
        try await connection.forceReconnect()

        // After reconnect, auth must be re-asserted (a new unauthenticated
        // handler on the server side). The controller's own auth bit is sticky
        // across forceReconnect but `isAuthValid` reads through generation and
        // should correctly report stale.
        XCTAssertGreaterThan(connection.generation, genBefore,
                             "forceReconnect must bump the generation")
        controller.resetAuth()
        try await controller.authenticate(token: plaintext)
        XCTAssertTrue(controller.isAuthenticated)
        XCTAssertTrue(controller.isAuthValid)

        connection.disconnect()
        try? await server.stop()
    }
}
