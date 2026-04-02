import XCTest
import Foundation
@testable import ClaudeRelayServer
@testable import ClaudeRelayKit

// MARK: - MockPTYSession

actor MockPTYSession: PTYSessionProtocol {
    let sessionId: UUID
    private var outputHandler: (@Sendable (Data) -> Void)?
    private var exitHandler: (@Sendable () -> Void)?
    private var terminated = false

    init(sessionId: UUID, cols: UInt16, rows: UInt16, scrollbackSize: Int) {
        self.sessionId = sessionId
    }

    func startReading() {}
    func setOutputHandler(_ handler: @escaping @Sendable (Data) -> Void) { outputHandler = handler }
    func setExitHandler(_ handler: @escaping @Sendable () -> Void) { exitHandler = handler }
    func clearOutputHandler() { outputHandler = nil }
    func write(_ data: Data) {}
    func resize(cols: UInt16, rows: UInt16) {}
    func readBuffer() -> Data { Data() }
    func terminate() { terminated = true }
}

// MARK: - SessionManagerTests

final class SessionManagerTests: XCTestCase {

    private var tempDir: URL!
    private var tokenStore: TokenStore!
    private var config: RelayConfig!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionManagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        tokenStore = TokenStore(directory: tempDir)
        config = RelayConfig(detachTimeout: 5, scrollbackSize: 4096)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    private func createTestToken() async throws -> (plaintext: String, info: TokenInfo) {
        return try await tokenStore.create(label: "test")
    }

    // MARK: - Tests

    func testCreateSession() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })

        let session = try await manager.createSession(tokenId: tokenInfo.id, cols: 80, rows: 24)

        XCTAssertEqual(session.tokenId, tokenInfo.id)
        XCTAssertEqual(session.cols, 80)
        XCTAssertEqual(session.rows, 24)
        XCTAssertEqual(session.state, .activeAttached)
    }

    func testListSessions() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })

        _ = try await manager.createSession(tokenId: tokenInfo.id)
        _ = try await manager.createSession(tokenId: tokenInfo.id)

        let list = await manager.listSessions()
        XCTAssertEqual(list.count, 2)
    }

    func testTerminateSession() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })

        let session = try await manager.createSession(tokenId: tokenInfo.id)
        try await manager.terminateSession(id: session.id, tokenId: tokenInfo.id)

        let info = try await manager.inspectSession(id: session.id)
        XCTAssertEqual(info.state, .terminated)
    }

    func testSessionOwnership() async throws {
        let (_, tokenA) = try await createTestToken()
        let (_, tokenB) = try await tokenStore.create(label: "other")
        let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })

        let session = try await manager.createSession(tokenId: tokenA.id)

        // Token B should not be able to terminate token A's session
        do {
            try await manager.terminateSession(id: session.id, tokenId: tokenB.id)
            XCTFail("Expected ownership violation error")
        } catch let error as SessionError {
            if case .ownershipViolation = error {
                // expected
            } else {
                XCTFail("Expected ownershipViolation, got \(error)")
            }
        }

        // Admin (nil tokenId) should succeed
        try await manager.terminateSession(id: session.id, tokenId: nil)
        let info = try await manager.inspectSession(id: session.id)
        XCTAssertEqual(info.state, .terminated)
    }

    func testDetachAndResume() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })

        let session = try await manager.createSession(tokenId: tokenInfo.id)

        // Attach first to get to activeAttached
        let (attachedInfo, _) = try await manager.attachSession(id: session.id, tokenId: tokenInfo.id)
        XCTAssertEqual(attachedInfo.state, .activeAttached)

        // Detach
        try await manager.detachSession(id: session.id)
        let detachedInfo = try await manager.inspectSession(id: session.id)
        XCTAssertEqual(detachedInfo.state, .activeDetached)

        // Resume
        let (resumedInfo, _, _) = try await manager.resumeSession(id: session.id, tokenId: tokenInfo.id)
        XCTAssertEqual(resumedInfo.state, .activeAttached)
    }

    func testListSessionsForToken() async throws {
        let (_, tokenA) = try await createTestToken()
        let (_, tokenB) = try await tokenStore.create(label: "other")
        let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })

        _ = try await manager.createSession(tokenId: tokenA.id)
        _ = try await manager.createSession(tokenId: tokenA.id)
        _ = try await manager.createSession(tokenId: tokenB.id)

        let listA = await manager.listSessionsForToken(tokenId: tokenA.id)
        XCTAssertEqual(listA.count, 2)

        let listB = await manager.listSessionsForToken(tokenId: tokenB.id)
        XCTAssertEqual(listB.count, 1)
    }

    func testInspectNonexistentSession() async throws {
        let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })

        do {
            _ = try await manager.inspectSession(id: UUID())
            XCTFail("Expected notFound error")
        } catch let error as SessionError {
            if case .notFound = error {
                // expected
            } else {
                XCTFail("Expected notFound, got \(error)")
            }
        }
    }
}
