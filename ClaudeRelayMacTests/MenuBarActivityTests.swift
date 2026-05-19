import XCTest
import ClaudeRelayKit
@testable import ClaudeDock

@MainActor
final class MenuBarActivityTests: XCTestCase {

    private func makeSession(id: UUID = UUID(), state: SessionState = .activeAttached) -> SessionInfo {
        SessionInfo(id: id, state: state, tokenId: "tok", createdAt: Date(), cols: 80, rows: 24)
    }

    // MARK: - No agents

    func testActiveWhenNotAwaitingInput() {
        let s = makeSession()
        let (states, ids) = MenuBarViewModel.computeActivityStates(
            sessions: [s],
            awaitingInput: [],
            activeAgentLookup: { _ in nil }
        )
        XCTAssertEqual(states[s.id], .active)
        XCTAssertNil(ids[s.id])
    }

    func testIdleWhenAwaitingInput() {
        let s = makeSession()
        let (states, ids) = MenuBarViewModel.computeActivityStates(
            sessions: [s],
            awaitingInput: [s.id],
            activeAgentLookup: { _ in nil }
        )
        XCTAssertEqual(states[s.id], .idle)
        XCTAssertNil(ids[s.id])
    }

    // MARK: - With agents

    func testAgentActiveWhenRunning() {
        let s = makeSession()
        let (states, ids) = MenuBarViewModel.computeActivityStates(
            sessions: [s],
            awaitingInput: [],
            activeAgentLookup: { _ in "claude-code" }
        )
        XCTAssertEqual(states[s.id], .agentActive)
        XCTAssertEqual(ids[s.id], "claude-code")
    }

    func testAgentIdleWhenAwaitingInput() {
        let s = makeSession()
        let (states, ids) = MenuBarViewModel.computeActivityStates(
            sessions: [s],
            awaitingInput: [s.id],
            activeAgentLookup: { _ in "codex" }
        )
        XCTAssertEqual(states[s.id], .agentIdle)
        XCTAssertEqual(ids[s.id], "codex")
    }

    // MARK: - Mixed sessions

    func testMixedSessionStates() {
        let s1 = makeSession()
        let s2 = makeSession()
        let s3 = makeSession()

        let agents: [UUID: String] = [s1.id: "claude-code"]

        let (states, ids) = MenuBarViewModel.computeActivityStates(
            sessions: [s1, s2, s3],
            awaitingInput: [s2.id, s1.id],
            activeAgentLookup: { agents[$0] }
        )

        XCTAssertEqual(states[s1.id], .agentIdle)
        XCTAssertEqual(ids[s1.id], "claude-code")
        XCTAssertEqual(states[s2.id], .idle)
        XCTAssertNil(ids[s2.id])
        XCTAssertEqual(states[s3.id], .active)
        XCTAssertNil(ids[s3.id])
    }

    func testEmptySessionsReturnsEmptyMaps() {
        let (states, ids) = MenuBarViewModel.computeActivityStates(
            sessions: [],
            awaitingInput: [UUID()],
            activeAgentLookup: { _ in "ghost" }
        )
        XCTAssertTrue(states.isEmpty)
        XCTAssertTrue(ids.isEmpty)
    }

    // MARK: - Ownership filter
    //
    // The menu bar dropdown must only list sessions this device owns. The
    // server-side list (and `SharedSessionCoordinator.sessions`) returns every
    // session under the auth token regardless of which device owns it; the
    // sidebar filters to owned-and-non-terminal via `coordinator.activeSessions`.
    // The menu bar previously skipped that filter and leaked cross-device
    // sessions into the dropdown. These tests pin the corrected behaviour.

    func testFilterOwnedKeepsOwnedNonTerminalSessions() {
        let owned = makeSession(id: UUID(), state: .activeAttached)
        let foreign = makeSession(id: UUID(), state: .activeDetached)
        let result = MenuBarViewModel.filterOwned(
            sessions: [owned, foreign],
            owned: [owned.id]
        )
        XCTAssertEqual(result.map { $0.id }, [owned.id])
    }

    func testFilterOwnedDropsTerminalEvenIfOwned() {
        let live = makeSession(id: UUID(), state: .activeAttached)
        let exited = makeSession(id: UUID(), state: .exited)
        let result = MenuBarViewModel.filterOwned(
            sessions: [live, exited],
            owned: [live.id, exited.id]
        )
        XCTAssertEqual(result.map { $0.id }, [live.id])
    }

    func testFilterOwnedReturnsEmptyWhenNoneOwned() {
        let a = makeSession()
        let b = makeSession()
        let result = MenuBarViewModel.filterOwned(
            sessions: [a, b],
            owned: []
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testFilterOwnedPreservesInputOrder() {
        let first  = makeSession()
        let second = makeSession()
        let third  = makeSession()
        let result = MenuBarViewModel.filterOwned(
            sessions: [first, second, third],
            owned: [first.id, second.id, third.id]
        )
        XCTAssertEqual(result.map { $0.id }, [first.id, second.id, third.id])
    }
}
