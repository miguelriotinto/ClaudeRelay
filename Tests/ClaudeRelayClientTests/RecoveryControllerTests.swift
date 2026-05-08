import XCTest
@testable import ClaudeRelayClient
@testable import ClaudeRelayKit

@MainActor
final class RecoveryControllerTests: XCTestCase {

    private func makeCoordinatorAndController() -> (SharedSessionCoordinator, RecoveryController) {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")
        let controller = coordinator.recoveryController!
        return (coordinator, controller)
    }

    // MARK: - Circuit Breaker

    func testBreakerResetClearsState() {
        let (_, controller) = makeCoordinatorAndController()
        controller._testOnly_setAutoRecoverySuspended(true, failures: 3)

        controller.resetAutoRecoveryBreaker()

        XCTAssertFalse(controller._testOnly_autoRecoverySuspended)
        XCTAssertEqual(controller._testOnly_consecutiveAutoRecoveryFailures, 0)
    }

    func testBreakerResetIsNoOpWhenAlreadyIdle() {
        let (_, controller) = makeCoordinatorAndController()
        XCTAssertFalse(controller._testOnly_autoRecoverySuspended)
        XCTAssertEqual(controller._testOnly_consecutiveAutoRecoveryFailures, 0)

        // Should not crash or change state
        controller.resetAutoRecoveryBreaker()

        XCTAssertFalse(controller._testOnly_autoRecoverySuspended)
    }

    // MARK: - scheduleAutoRecovery gates

    func testScheduleAutoRecoveryBlockedWhenTornDown() {
        let (coordinator, controller) = makeCoordinatorAndController()
        coordinator.tearDown()

        controller.scheduleAutoRecovery()

        XCTAssertNil(coordinator.recoveryTask)
    }

    func testScheduleAutoRecoveryBlockedWhenSuspended() {
        let (coordinator, controller) = makeCoordinatorAndController()
        controller._testOnly_setAutoRecoverySuspended(true, failures: 3)

        controller.scheduleAutoRecovery()

        XCTAssertNil(coordinator.recoveryTask)
    }

    // MARK: - triggerUserRecovery

    func testTriggerUserRecoveryBlockedWhenTornDown() {
        let (coordinator, controller) = makeCoordinatorAndController()
        coordinator.tearDown()

        controller.triggerUserRecovery()

        XCTAssertNil(coordinator.recoveryTask)
    }

    // MARK: - cancel

    func testCancelBumpsGenerationAndSuspends() {
        let (coordinator, controller) = makeCoordinatorAndController()
        coordinator.isRecovering = true

        controller.cancel()

        XCTAssertFalse(coordinator.isRecovering)
        XCTAssertTrue(coordinator.recoveryFailed)
        XCTAssertTrue(controller._testOnly_autoRecoverySuspended)
    }

    func testCancelDebouncesPreviousTrigger() {
        let (coordinator, controller) = makeCoordinatorAndController()
        controller.cancel()

        // Immediately try user recovery — should be debounced within 1s
        controller.triggerUserRecovery()
        XCTAssertNil(coordinator.recoveryTask, "Recovery should be debounced within 1s of cancel")
    }
}
