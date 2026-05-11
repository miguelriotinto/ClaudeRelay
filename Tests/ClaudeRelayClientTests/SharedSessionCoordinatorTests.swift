import XCTest
@testable import ClaudeRelayClient
@testable import ClaudeRelayKit

@MainActor
final class SharedSessionCoordinatorTests: XCTestCase {

    // MARK: - Initial State

    func testInitialStateIsClean() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        XCTAssertFalse(coordinator.isRecovering)
        XCTAssertFalse(coordinator.recoveryFailed)
        XCTAssertFalse(coordinator.connectionTimedOut)
        XCTAssertFalse(coordinator.showSessionStolen)
        XCTAssertFalse(coordinator.sessionAttachFailed)
        XCTAssertNil(coordinator.activeSessionId)
        XCTAssertNil(coordinator.sessionController)
        XCTAssertTrue(coordinator.sessions.isEmpty)
        XCTAssertTrue(coordinator.terminalViewModels.isEmpty)
        XCTAssertFalse(coordinator.isTornDown)
        XCTAssertFalse(coordinator.isLoading)
    }

    // MARK: - Tear Down

    func testTearDownSetsFlag() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        coordinator.tearDown()

        XCTAssertTrue(coordinator.isTornDown)
        XCTAssertEqual(connection.state, .disconnected)
    }

    func testTearDownClearsTerminalCaches() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        let sessionId = UUID()
        coordinator.registerLiveTerminal(for: sessionId, view: NSObject())

        coordinator.tearDown()

        XCTAssertTrue(coordinator.terminalCache.cachedIds.isEmpty)
    }

    func testTearDownCancelsRecoveryTask() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(100)) }
        coordinator.recoveryTask = task

        coordinator.tearDown()

        XCTAssertTrue(task.isCancelled)
    }

    // MARK: - C-19: auto-recovery breaker reset

    func testHealthyPingResetsAutoRecoveryBreaker() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        // Force the breaker into the suspended state.
        coordinator._testOnly_setAutoRecoverySuspended(true, failures: 3)
        XCTAssertTrue(coordinator._testOnly_autoRecoverySuspended)
        XCTAssertEqual(coordinator._testOnly_consecutiveAutoRecoveryFailures, 3)

        // A single healthy ping must clear both flags.
        connection._testOnly_recordRTT(rtt: 0.05)

        // The breaker reset is dispatched via Task { @MainActor }; wait briefly.
        let exp = expectation(description: "breaker reset")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

        XCTAssertFalse(coordinator._testOnly_autoRecoverySuspended)
        XCTAssertEqual(coordinator._testOnly_consecutiveAutoRecoveryFailures, 0)
    }

    func testHealthyPingWithIdleBreakerIsNoop() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        // Breaker starts idle — healthy ping should do nothing observable.
        XCTAssertFalse(coordinator._testOnly_autoRecoverySuspended)
        connection._testOnly_recordRTT(rtt: 0.05)

        let exp = expectation(description: "noop")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

        XCTAssertFalse(coordinator._testOnly_autoRecoverySuspended)
        XCTAssertEqual(coordinator._testOnly_consecutiveAutoRecoveryFailures, 0)
    }

    // MARK: - Cancel Recovery

    func testCancelRecoverySetsCorrectState() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        coordinator.cancelRecovery()

        XCTAssertFalse(coordinator.isRecovering)
        XCTAssertTrue(coordinator.recoveryFailed)
    }

    func testCancelRecoveryCancelsInFlightTask() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(100)) }
        coordinator.recoveryTask = task

        coordinator.cancelRecovery()

        XCTAssertTrue(task.isCancelled)
    }

    // MARK: - Recovery Phase Labels

    func testRecoveryPhaseLabels() {
        XCTAssertFalse(SharedSessionCoordinator.RecoveryPhase.reconnecting.label.isEmpty)
        XCTAssertFalse(SharedSessionCoordinator.RecoveryPhase.authenticating.label.isEmpty)
        XCTAssertFalse(SharedSessionCoordinator.RecoveryPhase.resuming.label.isEmpty)
    }

    // MARK: - Session Ownership

    func testClaimAndUnclaimSession() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        let sessionId = UUID()
        coordinator.claimSession(sessionId)
        XCTAssertTrue(coordinator.ownedSessionIds.contains(sessionId))

        coordinator.unclaimSession(sessionId)
        XCTAssertFalse(coordinator.ownedSessionIds.contains(sessionId))
    }

    func testClaimSessionIdempotent() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        let sessionId = UUID()
        coordinator.claimSession(sessionId)
        coordinator.claimSession(sessionId)
        XCTAssertEqual(coordinator.ownedSessionIds.filter { $0 == sessionId }.count, 1)
    }

    // MARK: - Session Names

    func testNameFallsBackToShortId() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        let sessionId = UUID()
        let name = coordinator.name(for: sessionId)
        XCTAssertEqual(name, String(sessionId.uuidString.prefix(8)))
    }

    func testSetNameStoresLocally() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        let sessionId = UUID()
        coordinator.setName("Rhaegar", for: sessionId)
        XCTAssertEqual(coordinator.name(for: sessionId), "Rhaegar")
    }

    // MARK: - Active Sessions Filter

    func testActiveSessionsFiltersTerminalAndUnowned() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        let ownedActive = UUID()
        let ownedTerminated = UUID()
        let unowned = UUID()

        coordinator.claimSession(ownedActive)
        coordinator.claimSession(ownedTerminated)

        coordinator.sessions = [
            SessionInfo(id: ownedActive, state: .activeAttached, tokenId: "t1", createdAt: Date(), cols: 80, rows: 24),
            SessionInfo(id: ownedTerminated, state: .terminated, tokenId: "t1", createdAt: Date(), cols: 80, rows: 24),
            SessionInfo(id: unowned, state: .activeAttached, tokenId: "t2", createdAt: Date(), cols: 80, rows: 24)
        ]

        let active = coordinator.activeSessions
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.id, ownedActive)
    }

    // MARK: - Activity Tracking

    func testAgentSessionTracking() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        let sessionId = UUID()
        XCTAssertFalse(coordinator.isRunningAgent(sessionId: sessionId))
        XCTAssertNil(coordinator.activeAgent(for: sessionId))

        coordinator.agentSessions[sessionId] = "claude"
        XCTAssertTrue(coordinator.isRunningAgent(sessionId: sessionId))
        XCTAssertEqual(coordinator.activeAgent(for: sessionId), "claude")

        coordinator.agentSessions[sessionId] = "codex"
        XCTAssertEqual(coordinator.activeAgent(for: sessionId), "codex")
    }

    // MARK: - Terminal View Cache

    func testRegisterLiveTerminal() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        let sessionId = UUID()
        let view = NSObject()
        coordinator.registerLiveTerminal(for: sessionId, view: view)

        XCTAssertNotNil(coordinator.cachedTerminalView(for: sessionId))
    }

    func testEvictTerminalClearsAllState() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        let sessionId = UUID()
        coordinator.registerLiveTerminal(for: sessionId, view: NSObject())
        coordinator.terminalViewModels[sessionId] = TerminalViewModel(sessionId: sessionId, connection: connection)

        coordinator.evictTerminal(for: sessionId)

        XCTAssertNil(coordinator.cachedTerminalView(for: sessionId))
        XCTAssertNil(coordinator.viewModel(for: sessionId))
    }

    // MARK: - Present Error

    func testPresentErrorSetsFlags() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        coordinator.presentError("Something went wrong")

        XCTAssertEqual(coordinator.errorMessage, "Something went wrong")
        XCTAssertTrue(coordinator.showError)
    }

    // MARK: - Recovery Prevents Operations

    func testCreateNewSessionBlockedDuringRecovery() async {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        coordinator.isRecovering = true
        await coordinator.createNewSession()

        XCTAssertNil(coordinator.activeSessionId)
    }

    func testSwitchToSessionBlockedDuringRecovery() async {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        coordinator.isRecovering = true
        await coordinator.switchToSession(id: UUID())

        XCTAssertNil(coordinator.activeSessionId)
    }

    func testTerminateSessionBlockedDuringRecovery() async {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        coordinator.isRecovering = true
        let sessionId = UUID()
        coordinator.activeSessionId = sessionId

        await coordinator.terminateSession(id: sessionId)

        // activeSessionId should not have been cleared by the terminate (it was blocked)
        XCTAssertEqual(coordinator.activeSessionId, sessionId)
    }

    func testAttachRemoteSessionBlockedDuringRecovery() async {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        coordinator.isRecovering = true
        await coordinator.attachRemoteSession(id: UUID(), serverName: nil)

        XCTAssertNil(coordinator.activeSessionId)
    }

    // MARK: - Foreground Transition on Torn Down Coordinator

    func testHandleForegroundAfterTearDownIsNoOp() async {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        coordinator.tearDown()
        await coordinator.handleForegroundTransition()

        XCTAssertFalse(coordinator.isRecovering)
    }

    // MARK: - User Recovery After Tear Down

    func testTriggerUserRecoveryAfterTearDownIsNoOp() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        coordinator.tearDown()
        coordinator.triggerUserRecovery()

        XCTAssertNil(coordinator.recoveryTask)
    }

    // MARK: - Session Stolen Handling

    func testSessionStolenNotificationClearsActiveSession() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        let sessionId = UUID()
        coordinator.activeSessionId = sessionId
        coordinator.sessionNames[sessionId] = "TestSession"
        coordinator.agentSessions[sessionId] = "claude"
        coordinator.sessionsAwaitingInput.insert(sessionId)

        connection.onSessionStolen?(sessionId)

        // Give the Task a chance to run (it dispatches back to MainActor)
        let exp = expectation(description: "stolen callback dispatched")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

        XCTAssertNil(coordinator.activeSessionId)
        XCTAssertTrue(coordinator.showSessionStolen)
        XCTAssertEqual(coordinator.stolenSessionName, "TestSession")
        XCTAssertNil(coordinator.agentSessions[sessionId])
        XCTAssertFalse(coordinator.sessionsAwaitingInput.contains(sessionId))
    }

    /// Regression: before this fix, `handleSessionStolen` cleared `activeSessionId`
    /// and evicted the TerminalViewModel, but the stolen session remained in
    /// `ownedSessionIds`, so the sidebar still listed it. Attaching "Gendry" on
    /// the iPad left Gendry in the iPhone's local session list.
    ///
    /// TODO: Learner — implement this test.
    ///
    /// Shape:
    /// 1. Construct a SharedSessionCoordinator with a mock RelayConnection.
    /// 2. Call `coordinator.claimSession(sessionId)` to set up local state,
    ///    then push a `SessionInfo` for that id through the sessions list
    ///    (or expose a test helper) so `activeSessions` initially includes it.
    /// 3. Fire `connection.onSessionStolen?(sessionId)` and wait for the
    ///    MainActor dispatch (see the timing pattern in
    ///    `testSessionStolenNotificationClearsActiveSession`).
    /// 4. Assert: `coordinator.ownedSessionIds.contains(sessionId) == false`,
    ///    and `coordinator.activeSessions` no longer contains the session.
    ///
    /// Optional: also assert that a preexisting TerminalViewModel for the
    /// session has `isSendingSuppressed == true` after the steal. That covers
    /// the secondary defense against stale view references.
    func testSessionStolenRemovesFromOwnedSessions() {
        // TODO
    }

    // MARK: - Session Renamed Handling

    func testSessionRenamedUpdatesLocalName() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        let sessionId = UUID()
        coordinator.sessionNames[sessionId] = "OldName"

        connection.onSessionRenamed?(sessionId, "NewName")

        let exp = expectation(description: "rename callback dispatched")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(coordinator.sessionNames[sessionId], "NewName")
    }

    // MARK: - ViewModel Access

    func testViewModelReturnsNilForUnknownSession() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        XCTAssertNil(coordinator.viewModel(for: UUID()))
    }

    func testCreatedAtReturnsNilForUnknownSession() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        XCTAssertNil(coordinator.createdAt(for: UUID()))
    }

    func testCreatedAtReturnsDateForKnownSession() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        let sessionId = UUID()
        let now = Date()
        coordinator.sessions = [
            SessionInfo(id: sessionId, state: .activeAttached, tokenId: "t", createdAt: now, cols: 80, rows: 24)
        ]

        XCTAssertEqual(coordinator.createdAt(for: sessionId), now)
    }
}
