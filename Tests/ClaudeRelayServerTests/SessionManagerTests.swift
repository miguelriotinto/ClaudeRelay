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
    private var activityHandler: (@Sendable (ActivityState) -> Void)?

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
    func getActivityState() -> ActivityState { .active }
    func setActivityHandler(_ handler: @escaping @Sendable (ActivityState) -> Void) {
        activityHandler = handler
    }
    func recordInput() {}
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

    func testActivityObserverReceivesChanges() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })

        let session = try await manager.createSession(tokenId: tokenInfo.id)

        var received: [ActivityState] = []
        let expectation = XCTestExpectation(description: "activity callback")
        expectation.expectedFulfillmentCount = 2
        let observerId = await manager.addActivityObserver(tokenId: tokenInfo.id) { sessionId, activity in
            XCTAssertEqual(sessionId, session.id)
            received.append(activity)
            expectation.fulfill()
        }

        await manager.reportActivityChange(sessionId: session.id, activity: .claudeActive)
        await fulfillment(of: [expectation], timeout: 1.0)
        // First callback is initial state push (.active), second is explicit change
        XCTAssertEqual(received, [.active, .claudeActive])
        await manager.removeActivityObserver(id: observerId)
    }

    func testActivityObserverOnlyReceivesOwnToken() async throws {
        let (_, tokenA) = try await createTestToken()
        let (_, tokenB) = try await tokenStore.create(label: "other")
        let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })

        let sessionA = try await manager.createSession(tokenId: tokenA.id)
        let sessionB = try await manager.createSession(tokenId: tokenB.id)

        var receivedSessionIds: [UUID] = []
        let expectation = XCTestExpectation(description: "only token A")
        expectation.expectedFulfillmentCount = 2
        let observerId = await manager.addActivityObserver(tokenId: tokenA.id) { sessionId, _ in
            receivedSessionIds.append(sessionId)
            expectation.fulfill()
        }

        await manager.reportActivityChange(sessionId: sessionB.id, activity: .claudeActive)
        await manager.reportActivityChange(sessionId: sessionA.id, activity: .idle)

        await fulfillment(of: [expectation], timeout: 1.0)
        // Initial push for sessionA + explicit change for sessionA (not sessionB)
        XCTAssertEqual(receivedSessionIds, [sessionA.id, sessionA.id])
        await manager.removeActivityObserver(id: observerId)
    }

    func testRemoveActivityObserverStopsCallbacks() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })

        let session = try await manager.createSession(tokenId: tokenInfo.id)

        var callCount = 0
        let observerId = await manager.addActivityObserver(tokenId: tokenInfo.id) { _, _ in
            callCount += 1
        }

        // callCount is 1 from initial state push on registration
        await manager.reportActivityChange(sessionId: session.id, activity: .claudeActive)
        // callCount is now 2
        await manager.removeActivityObserver(id: observerId)
        await manager.reportActivityChange(sessionId: session.id, activity: .idle)

        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(callCount, 2, "Should not receive callbacks after removal")
    }

    // MARK: - Steal Observer

    func testStealObserverFiresOnReattach() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })

        let session = try await manager.createSession(tokenId: tokenInfo.id)

        let expectation = XCTestExpectation(description: "steal callback")
        let observerId = await manager.addStealObserver(tokenId: tokenInfo.id) { sessionId in
            XCTAssertEqual(sessionId, session.id)
            expectation.fulfill()
        }

        // Session is already activeAttached from createSession.
        // Re-attaching should fire the steal observer.
        _ = try await manager.attachSession(id: session.id, tokenId: tokenInfo.id)

        await fulfillment(of: [expectation], timeout: 1.0)
        await manager.removeStealObserver(id: observerId)
    }

    func testStealObserverExcludesSelf() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })

        let session = try await manager.createSession(tokenId: tokenInfo.id)

        var callCount = 0
        let observerId = await manager.addStealObserver(tokenId: tokenInfo.id) { _ in
            callCount += 1
        }

        // Exclude our own observer — should NOT fire.
        _ = try await manager.attachSession(id: session.id, tokenId: tokenInfo.id, excludeObserver: observerId)

        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(callCount, 0, "Excluded observer should not fire")
        await manager.removeStealObserver(id: observerId)
    }

    func testStealObserverDoesNotFireOnResume() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })

        let session = try await manager.createSession(tokenId: tokenInfo.id)

        // Detach first, then resume (not a re-attach from activeAttached)
        try await manager.detachSession(id: session.id)

        var callCount = 0
        let observerId = await manager.addStealObserver(tokenId: tokenInfo.id) { _ in
            callCount += 1
        }

        // Resume from detached state — this is not a steal.
        _ = try await manager.resumeSession(id: session.id, tokenId: tokenInfo.id)

        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(callCount, 0, "Steal should not fire for resume from detached state")
        await manager.removeStealObserver(id: observerId)
    }

    // MARK: - Session Names

    func testCreateSessionWithName() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })

        let session = try await manager.createSession(tokenId: tokenInfo.id, name: "Rhaegar")

        XCTAssertEqual(session.name, "Rhaegar")
        let inspected = try await manager.inspectSession(id: session.id)
        XCTAssertEqual(inspected.name, "Rhaegar")
    }

    func testCreateSessionWithoutName() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })

        let session = try await manager.createSession(tokenId: tokenInfo.id)

        XCTAssertNil(session.name)
    }

    func testRenameSession() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })

        let session = try await manager.createSession(tokenId: tokenInfo.id, name: "Tyrion")
        try await manager.renameSession(id: session.id, tokenId: tokenInfo.id, name: "Jaime")

        let inspected = try await manager.inspectSession(id: session.id)
        XCTAssertEqual(inspected.name, "Jaime")
    }

    func testRenameSessionOwnershipViolation() async throws {
        let (_, tokenA) = try await createTestToken()
        let (_, tokenB) = try await tokenStore.create(label: "other")
        let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })

        let session = try await manager.createSession(tokenId: tokenA.id, name: "Tyrion")

        do {
            try await manager.renameSession(id: session.id, tokenId: tokenB.id, name: "Stolen")
            XCTFail("Expected ownership violation")
        } catch let error as SessionError {
            if case .ownershipViolation = error {
                // expected
            } else {
                XCTFail("Expected ownershipViolation, got \(error)")
            }
        }
    }

    func testRenameSessionBroadcastsToObservers() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })

        let session = try await manager.createSession(tokenId: tokenInfo.id, name: "Old")

        let expectation = XCTestExpectation(description: "rename callback")
        var receivedName: String?
        var receivedSessionId: UUID?
        let observerId = await manager.addRenameObserver(tokenId: tokenInfo.id) { sessionId, name in
            receivedSessionId = sessionId
            receivedName = name
            expectation.fulfill()
        }

        try await manager.renameSession(id: session.id, tokenId: tokenInfo.id, name: "New")

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(receivedSessionId, session.id)
        XCTAssertEqual(receivedName, "New")
        await manager.removeRenameObserver(id: observerId)
    }

    func testListSessionsIncludesName() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })

        _ = try await manager.createSession(tokenId: tokenInfo.id, name: "Named")
        _ = try await manager.createSession(tokenId: tokenInfo.id)

        let list = await manager.listSessionsForToken(tokenId: tokenInfo.id)
        let names = list.map { $0.name }
        XCTAssertTrue(names.contains("Named"))
        XCTAssertTrue(names.contains(nil))
    }

    func testAttachSessionPreservesName() async throws {
        let (_, tokenA) = try await createTestToken()
        let (_, tokenB) = try await tokenStore.create(label: "other")
        let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })

        let session = try await manager.createSession(tokenId: tokenA.id, name: "Rhaegar")
        let (attachedInfo, _) = try await manager.attachSession(id: session.id, tokenId: tokenB.id)

        XCTAssertEqual(attachedInfo.name, "Rhaegar")
    }
}
