import XCTest
import Foundation
@testable import ClaudeRelayServer
@testable import ClaudeRelayKit

/// Ownership enforcement, session naming + rename broadcast, cross-device attach,
/// and concurrent-attach race semantics.
final class SessionOwnershipTests: SessionManagerTestCase {

    // MARK: - Ownership Enforcement

    func testSessionOwnership() async throws {
        let (_, tokenA) = try await createTestToken()
        let (_, tokenB) = try await tokenStore.create(label: "other")
        let manager = makeManager()

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

    func testResumeEnforcesOwnership() async throws {
        let (_, tokenA) = try await createTestToken()
        let (_, tokenB) = try await tokenStore.create(label: "other")
        let manager = makeManager()

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

    // MARK: - Session Names

    func testCreateSessionWithName() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = makeManager()

        let session = try await manager.createSession(tokenId: tokenInfo.id, name: "Rhaegar")

        XCTAssertEqual(session.name, "Rhaegar")
        let inspected = try await manager.inspectSession(id: session.id)
        XCTAssertEqual(inspected.name, "Rhaegar")
    }

    func testCreateSessionWithoutName() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = makeManager()

        let session = try await manager.createSession(tokenId: tokenInfo.id)

        XCTAssertNil(session.name)
    }

    func testRenameSession() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = makeManager()

        let session = try await manager.createSession(tokenId: tokenInfo.id, name: "Tyrion")
        try await manager.renameSession(id: session.id, tokenId: tokenInfo.id, name: "Jaime")

        let inspected = try await manager.inspectSession(id: session.id)
        XCTAssertEqual(inspected.name, "Jaime")
    }

    func testRenameSessionOwnershipViolation() async throws {
        let (_, tokenA) = try await createTestToken()
        let (_, tokenB) = try await tokenStore.create(label: "other")
        let manager = makeManager()

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
        let manager = makeManager()

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
        let manager = makeManager()

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
        let manager = makeManager()

        let session = try await manager.createSession(tokenId: tokenA.id, name: "Rhaegar")
        let (attachedInfo, _) = try await manager.attachSession(id: session.id, tokenId: tokenB.id)

        XCTAssertEqual(attachedInfo.name, "Rhaegar")
    }

    // MARK: - Cross-Device Attach

    func testAttachFromDetachedCrossDevice() async throws {
        // Simulates: device A owned the session and disconnected (session is
        // activeDetached), then device B attaches from its session list.
        let (_, tokenA) = try await createTestToken()
        let (_, tokenB) = try await tokenStore.create(label: "device-b")
        let manager = makeManager()

        let session = try await manager.createSession(tokenId: tokenA.id)
        try await manager.detachSession(id: session.id)
        let detached = try await manager.inspectSession(id: session.id)
        XCTAssertEqual(detached.state, .activeDetached)

        let (attachedInfo, _) = try await manager.attachSession(id: session.id, tokenId: tokenB.id)

        XCTAssertEqual(attachedInfo.state, .activeAttached)
        XCTAssertEqual(attachedInfo.tokenId, tokenB.id)
    }

    func testAttachFromAttachedTransfersOwnership() async throws {
        let (_, tokenA) = try await createTestToken()
        let (_, tokenB) = try await tokenStore.create(label: "device-b")
        let manager = makeManager()

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
        let manager = makeManager()

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

    func testCrossDeviceAttachThenResume() async throws {
        let (_, tokenA) = try await createTestToken()
        let (_, tokenB) = try await tokenStore.create(label: "device-b")
        let manager = makeManager()

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

    // MARK: - Concurrent Attach Race

    /// When two tokens race to attach the same session, the actor must serialize
    /// the calls — one attaches first (transferring ownership), the other
    /// steals from the first. Final ownership must be exactly one of the two
    /// tokens, never a third value or a split/torn state.
    func testConcurrentAttachSameSessionProducesSingleOwner() async throws {
        let (_, tokenA) = try await createTestToken()
        let (_, tokenB) = try await tokenStore.create(label: "device-b")
        let manager = makeManager()

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
