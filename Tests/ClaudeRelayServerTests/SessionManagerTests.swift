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
    private var activityHandler: (@Sendable (ActivityState, CodingAgent?) -> Void)?

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
    func getActiveAgent() -> CodingAgent? { nil }
    func setActivityHandler(_ handler: @escaping @Sendable (ActivityState, CodingAgent?) -> Void) {
        activityHandler = handler
    }
    func recordInput() {}
    func setPollCadence(_ seconds: TimeInterval) {}
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
        var receivedAgents: [String?] = []
        let expectation = XCTestExpectation(description: "activity callback")
        expectation.expectedFulfillmentCount = 2
        let observerId = await manager.addActivityObserver(tokenId: tokenInfo.id) { sessionId, activity, agent in
            XCTAssertEqual(sessionId, session.id)
            received.append(activity)
            receivedAgents.append(agent)
            expectation.fulfill()
        }

        await manager.reportActivityChange(sessionId: session.id, activity: .agentActive, agent: "claude")
        await fulfillment(of: [expectation], timeout: 1.0)
        // First callback is initial state push (.active, nil agent), second is explicit change.
        XCTAssertEqual(received, [.active, .agentActive])
        XCTAssertEqual(receivedAgents, [nil, "claude"])
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
        let observerId = await manager.addActivityObserver(tokenId: tokenA.id) { sessionId, _, _ in
            receivedSessionIds.append(sessionId)
            expectation.fulfill()
        }

        await manager.reportActivityChange(sessionId: sessionB.id, activity: .agentActive, agent: "claude")
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
        let observerId = await manager.addActivityObserver(tokenId: tokenInfo.id) { _, _, _ in
            callCount += 1
        }

        // callCount is 1 from initial state push on registration
        await manager.reportActivityChange(sessionId: session.id, activity: .agentActive, agent: "claude")
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

    func testAttachFromDetachedCrossDevice() async throws {
        // Simulates: device A owned the session and disconnected (session is
        // activeDetached), then device B attaches from its session list.
        let (_, tokenA) = try await createTestToken()
        let (_, tokenB) = try await tokenStore.create(label: "device-b")
        let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })

        let session = try await manager.createSession(tokenId: tokenA.id)
        try await manager.detachSession(id: session.id)
        let detached = try await manager.inspectSession(id: session.id)
        XCTAssertEqual(detached.state, .activeDetached)

        let (attachedInfo, _) = try await manager.attachSession(id: session.id, tokenId: tokenB.id)

        XCTAssertEqual(attachedInfo.state, .activeAttached)
        XCTAssertEqual(attachedInfo.tokenId, tokenB.id)
    }

    // MARK: - Attach / Reattach Edge Cases

    func testAttachToTerminatedSessionFails() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })

        let session = try await manager.createSession(tokenId: tokenInfo.id)
        try await manager.terminateSession(id: session.id, tokenId: tokenInfo.id)

        do {
            _ = try await manager.attachSession(id: session.id, tokenId: tokenInfo.id)
            XCTFail("Expected invalidTransition error")
        } catch let error as SessionError {
            if case .invalidTransition(let from, let to) = error {
                XCTAssertEqual(from, .terminated)
                XCTAssertEqual(to, .activeAttached)
            } else {
                XCTFail("Expected invalidTransition, got \(error)")
            }
        }
    }

    func testAttachToNonexistentSessionFails() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })

        do {
            _ = try await manager.attachSession(id: UUID(), tokenId: tokenInfo.id)
            XCTFail("Expected notFound error")
        } catch let error as SessionError {
            if case .notFound = error {
                // expected
            } else {
                XCTFail("Expected notFound, got \(error)")
            }
        }
    }

    func testAttachFromAttachedTransfersOwnership() async throws {
        let (_, tokenA) = try await createTestToken()
        let (_, tokenB) = try await tokenStore.create(label: "device-b")
        let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })

        let session = try await manager.createSession(tokenId: tokenA.id)
        XCTAssertEqual(session.tokenId, tokenA.id)

        let (attachedInfo, _) = try await manager.attachSession(id: session.id, tokenId: tokenB.id)
        XCTAssertEqual(attachedInfo.tokenId, tokenB.id)

        let inspected = try await manager.inspectSession(id: session.id)
        XCTAssertEqual(inspected.tokenId, tokenB.id)
    }

    func testChainStealAcrossThreeDevices() async throws {
        let (_, tokenA) = try await createTestToken()
        let (_, tokenB) = try await tokenStore.create(label: "device-b")
        let (_, tokenC) = try await tokenStore.create(label: "device-c")
        let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })

        let session = try await manager.createSession(tokenId: tokenA.id)

        // Observer for token A (original owner)
        let stealExpA = XCTestExpectation(description: "steal from A")
        let observerA = await manager.addStealObserver(tokenId: tokenA.id) { sessionId in
            XCTAssertEqual(sessionId, session.id)
            stealExpA.fulfill()
        }

        // Device B steals from A — observer A should fire
        _ = try await manager.attachSession(id: session.id, tokenId: tokenB.id)
        await fulfillment(of: [stealExpA], timeout: 1.0)
        await manager.removeStealObserver(id: observerA)

        // Observer for token B (new owner)
        let stealExpB = XCTestExpectation(description: "steal from B")
        let observerB = await manager.addStealObserver(tokenId: tokenB.id) { sessionId in
            XCTAssertEqual(sessionId, session.id)
            stealExpB.fulfill()
        }

        // Device C steals from B — observer B should fire
        _ = try await manager.attachSession(id: session.id, tokenId: tokenC.id)
        await fulfillment(of: [stealExpB], timeout: 1.0)
        await manager.removeStealObserver(id: observerB)

        let inspected = try await manager.inspectSession(id: session.id)
        XCTAssertEqual(inspected.tokenId, tokenC.id)
    }

    func testStealObserverMultipleObserversOnlyNonExcludedFire() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })

        let session = try await manager.createSession(tokenId: tokenInfo.id)

        var observer1Calls = 0
        var observer2Calls = 0
        let exp2 = XCTestExpectation(description: "observer2 fires")

        let id1 = await manager.addStealObserver(tokenId: tokenInfo.id) { _ in
            observer1Calls += 1
        }
        _ = await manager.addStealObserver(tokenId: tokenInfo.id) { _ in
            observer2Calls += 1
            exp2.fulfill()
        }

        // Exclude observer 1 — only observer 2 should fire
        _ = try await manager.attachSession(id: session.id, tokenId: tokenInfo.id, excludeObserver: id1)
        await fulfillment(of: [exp2], timeout: 1.0)
        XCTAssertEqual(observer1Calls, 0, "Excluded observer should not fire")
        XCTAssertEqual(observer2Calls, 1, "Non-excluded observer should fire once")
    }

    // MARK: - Resume Edge Cases

    func testResumeFromAttachedImplicitlyDetaches() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })

        let session = try await manager.createSession(tokenId: tokenInfo.id)
        // Session starts activeAttached from createSession.
        let info = try await manager.inspectSession(id: session.id)
        XCTAssertEqual(info.state, .activeAttached)

        // Resume without explicit detach — should succeed via implicit detach.
        let (resumed, _, _) = try await manager.resumeSession(id: session.id, tokenId: tokenInfo.id)
        XCTAssertEqual(resumed.state, .activeAttached)
    }

    func testResumeEnforcesOwnership() async throws {
        let (_, tokenA) = try await createTestToken()
        let (_, tokenB) = try await tokenStore.create(label: "other")
        let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })

        let session = try await manager.createSession(tokenId: tokenA.id)
        try await manager.detachSession(id: session.id)

        do {
            _ = try await manager.resumeSession(id: session.id, tokenId: tokenB.id)
            XCTFail("Expected ownership violation")
        } catch let error as SessionError {
            if case .ownershipViolation = error {
                // expected
            } else {
                XCTFail("Expected ownershipViolation, got \(error)")
            }
        }
    }

    func testResumeTerminatedSessionFails() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })

        let session = try await manager.createSession(tokenId: tokenInfo.id)
        try await manager.terminateSession(id: session.id, tokenId: tokenInfo.id)

        do {
            _ = try await manager.resumeSession(id: session.id, tokenId: tokenInfo.id)
            XCTFail("Expected error for terminated session")
        } catch {
            // Any error is acceptable (notFound if PTY nil, or invalidTransition)
        }
    }

    func testResumeNonexistentSessionFails() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })

        do {
            _ = try await manager.resumeSession(id: UUID(), tokenId: tokenInfo.id)
            XCTFail("Expected notFound error")
        } catch let error as SessionError {
            if case .notFound = error {
                // expected
            } else {
                XCTFail("Expected notFound, got \(error)")
            }
        }
    }

    // MARK: - Detach Edge Cases

    func testDetachAlreadyDetachedFails() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })

        let session = try await manager.createSession(tokenId: tokenInfo.id)
        try await manager.detachSession(id: session.id)

        do {
            try await manager.detachSession(id: session.id)
            XCTFail("Expected invalidTransition error")
        } catch let error as SessionError {
            if case .invalidTransition(let from, let to) = error {
                XCTAssertEqual(from, .activeDetached)
                XCTAssertEqual(to, .activeDetached)
            } else {
                XCTFail("Expected invalidTransition, got \(error)")
            }
        }
    }

    func testDetachNonexistentSessionFails() async throws {
        let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })

        do {
            try await manager.detachSession(id: UUID())
            XCTFail("Expected notFound error")
        } catch let error as SessionError {
            if case .notFound = error {
                // expected
            } else {
                XCTFail("Expected notFound, got \(error)")
            }
        }
    }

    // MARK: - Cross-Token Session Listing

    func testListAllSessionsCrossToken() async throws {
        let (_, tokenA) = try await createTestToken()
        let (_, tokenB) = try await tokenStore.create(label: "other")
        let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })

        let sessionA = try await manager.createSession(tokenId: tokenA.id, name: "Alpha")
        let sessionB = try await manager.createSession(tokenId: tokenB.id, name: "Bravo")

        let allSessions = await manager.listAllSessions()
        XCTAssertEqual(allSessions.count, 2)

        let ids = Set(allSessions.map { $0.id })
        XCTAssertTrue(ids.contains(sessionA.id))
        XCTAssertTrue(ids.contains(sessionB.id))
    }

    func testListAllSessionsExcludesTerminated() async throws {
        let (_, tokenA) = try await createTestToken()
        let (_, tokenB) = try await tokenStore.create(label: "other")
        let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })

        let sessionA = try await manager.createSession(tokenId: tokenA.id)
        _ = try await manager.createSession(tokenId: tokenB.id)
        try await manager.terminateSession(id: sessionA.id, tokenId: tokenA.id)

        let allSessions = await manager.listAllSessions()
        let nonTerminal = allSessions.filter { !$0.state.isTerminal }
        XCTAssertEqual(nonTerminal.count, 1)
    }

    // MARK: - Detach-Resume Round Trip with Multiple Sessions

    func testDetachResumeMultipleSessions() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })

        let session1 = try await manager.createSession(tokenId: tokenInfo.id, name: "S1")
        let session2 = try await manager.createSession(tokenId: tokenInfo.id, name: "S2")

        // Detach session 1, then resume it while session 2 is still attached
        try await manager.detachSession(id: session1.id)
        let info1 = try await manager.inspectSession(id: session1.id)
        XCTAssertEqual(info1.state, .activeDetached)

        let (resumed, _, _) = try await manager.resumeSession(id: session1.id, tokenId: tokenInfo.id)
        XCTAssertEqual(resumed.state, .activeAttached)

        // Session 2 should still be in its original state
        let info2 = try await manager.inspectSession(id: session2.id)
        XCTAssertEqual(info2.state, .activeAttached)
    }

    // MARK: - Cross-Device Attach Steals Then Resume by New Owner

    func testCrossDeviceAttachThenResume() async throws {
        let (_, tokenA) = try await createTestToken()
        let (_, tokenB) = try await tokenStore.create(label: "device-b")
        let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })

        let session = try await manager.createSession(tokenId: tokenA.id, name: "Shared")

        // Device B attaches (steals from A)
        let (attached, _) = try await manager.attachSession(id: session.id, tokenId: tokenB.id)
        XCTAssertEqual(attached.tokenId, tokenB.id)

        // Device B detaches
        try await manager.detachSession(id: session.id)
        let detached = try await manager.inspectSession(id: session.id)
        XCTAssertEqual(detached.state, .activeDetached)
        XCTAssertEqual(detached.tokenId, tokenB.id)

        // Device B resumes — should succeed since B is now the owner
        let (resumed, _, _) = try await manager.resumeSession(id: session.id, tokenId: tokenB.id)
        XCTAssertEqual(resumed.state, .activeAttached)

        // Device A should no longer be able to resume (ownership transferred)
        try await manager.detachSession(id: session.id)
        do {
            _ = try await manager.resumeSession(id: session.id, tokenId: tokenA.id)
            XCTFail("Expected ownership violation")
        } catch let error as SessionError {
            if case .ownershipViolation = error {
                // expected — A no longer owns this session
            } else {
                XCTFail("Expected ownershipViolation, got \(error)")
            }
        }
    }

    // MARK: - Periodic Observer Cleanup

    func testPurgeStaleObserversRemovesOldEntries() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })

        _ = await manager.addActivityObserver(tokenId: tokenInfo.id) { _, _, _ in }
        _ = await manager.addStealObserver(tokenId: tokenInfo.id) { _ in }
        _ = await manager.addRenameObserver(tokenId: tokenInfo.id) { _, _ in }

        let beforeCount = await manager._testOnly_observerCount
        XCTAssertEqual(beforeCount, 3, "Should have 3 observers registered")

        // Purge with zero-second cutoff evicts everything because Date() is strictly
        // greater than any timestamp we just recorded.
        await manager.purgeStaleObservers(olderThan: 0)

        let afterCount = await manager._testOnly_observerCount
        XCTAssertEqual(afterCount, 0, "All observers should have been purged with 0s cutoff")
    }

    func testCreateSessionEnforcesPerTokenLimit() async throws {
        let (_, tokenInfo) = try await createTestToken()
        var config = RelayConfig.default
        config.maxSessionsPerToken = 3
        let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })

        for i in 0..<3 {
            _ = try await manager.createSession(tokenId: tokenInfo.id, name: "s\(i)")
        }

        do {
            _ = try await manager.createSession(tokenId: tokenInfo.id, name: "overflow")
            XCTFail("Expected sessionLimitExceeded")
        } catch SessionError.sessionLimitExceeded(let limit) {
            XCTAssertEqual(limit, 3)
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testCreateSessionUnlimitedWhenLimitIsZero() async throws {
        let (_, tokenInfo) = try await createTestToken()
        var config = RelayConfig.default
        config.maxSessionsPerToken = 0
        let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })

        for i in 0..<10 {
            _ = try await manager.createSession(tokenId: tokenInfo.id, name: "s\(i)")
        }
        let list = await manager.listSessionsForToken(tokenId: tokenInfo.id)
        XCTAssertEqual(list.count, 10)
    }

    // MARK: - Concurrent Attach Race

    /// When two tokens race to attach the same session, the actor must serialize
    /// the calls — one attaches first (transferring ownership), the other
    /// stealsfrom the first. Final ownership must be exactly one of the two
    /// tokens, never a third value or a split/torn state.
    func testConcurrentAttachSameSessionProducesSingleOwner() async throws {
        let (_, tokenA) = try await createTestToken()
        let (_, tokenB) = try await tokenStore.create(label: "device-b")

        let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })

        let session = try await manager.createSession(tokenId: tokenA.id)

        async let resultA: Void = {
            do {
                _ = try await manager.attachSession(id: session.id, tokenId: tokenA.id)
            } catch {
                // One of the racers may lose depending on scheduling; ignore.
            }
        }()
        async let resultB: Void = {
            do {
                _ = try await manager.attachSession(id: session.id, tokenId: tokenB.id)
            } catch {
                // One of the racers may lose depending on scheduling; ignore.
            }
        }()
        _ = await (resultA, resultB)

        let final = try await manager.inspectSession(id: session.id)
        XCTAssertTrue(final.tokenId == tokenA.id || final.tokenId == tokenB.id,
                      "Ownership should resolve to exactly one token, got \(final.tokenId)")
        XCTAssertEqual(final.state, .activeAttached,
                       "Session should end up attached to whichever token won the race")
    }
}
