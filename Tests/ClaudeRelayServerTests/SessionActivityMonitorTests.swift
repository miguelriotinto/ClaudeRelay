import XCTest
import Foundation
@testable import ClaudeRelayServer
@testable import ClaudeRelayKit

final class SessionActivityMonitorTests: XCTestCase {

    private func makeMonitor(
        silenceThreshold: TimeInterval = 0.1,
        agentSilenceThreshold: TimeInterval = 0.2,
        onChange: @escaping @Sendable (ActivityState, CodingAgent?) -> Void = { _, _ in }
    ) -> SessionActivityMonitor {
        SessionActivityMonitor(
            silenceThreshold: silenceThreshold,
            agentSilenceThreshold: agentSilenceThreshold,
            onChange: onChange
        )
    }

    /// Test-only helper so existing tests that only care about state can stay concise.
    private func makeMonitorStateOnly(
        silenceThreshold: TimeInterval = 0.1,
        agentSilenceThreshold: TimeInterval = 0.2,
        onChange: @escaping @Sendable (ActivityState) -> Void
    ) -> SessionActivityMonitor {
        makeMonitor(silenceThreshold: silenceThreshold, agentSilenceThreshold: agentSilenceThreshold) { state, _ in
            onChange(state)
        }
    }

    private func output(_ string: String) -> Data {
        Data(string.utf8)
    }

    /// OSC title-set: ESC ] 0 ; <title> BEL
    private func titleSequence(_ title: String) -> Data {
        var bytes: [UInt8] = [0x1B, 0x5D, 0x30, 0x3B]
        bytes.append(contentsOf: title.utf8)
        bytes.append(0x07)
        return Data(bytes)
    }

    private var leaveAltScreen: Data {
        Data([0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x34, 0x39, 0x6C])
    }

    // MARK: - Initial State

    func testInitialStateIsActive() {
        let monitor = makeMonitor()
        XCTAssertEqual(monitor.state, .active)
        XCTAssertNil(monitor.activeAgent)
    }

    // MARK: - Agent Entry Detection

    func testDetectsClaudeEntryFromTitle() {
        var states: [ActivityState] = []
        var agents: [CodingAgent?] = []
        let monitor = makeMonitor { state, agent in
            states.append(state); agents.append(agent)
        }
        monitor.processOutput(titleSequence("claude"))
        XCTAssertEqual(monitor.state, .agentActive)
        XCTAssertEqual(monitor.activeAgent, .claude)
        XCTAssertEqual(states, [.agentActive])
        XCTAssertEqual(agents, [.claude])
    }

    func testDetectsCodexEntryFromTitle() {
        var agents: [CodingAgent?] = []
        let monitor = makeMonitor { _, agent in agents.append(agent) }
        monitor.processOutput(titleSequence("Codex — working"))
        XCTAssertEqual(monitor.state, .agentActive)
        XCTAssertEqual(monitor.activeAgent, .codex)
        XCTAssertEqual(agents, [.codex])
    }

    func testDetectsClaudeEntryFromTitleCaseInsensitive() {
        let monitor = makeMonitor()
        monitor.processOutput(titleSequence("Claude Code - ~/projects"))
        XCTAssertEqual(monitor.state, .agentActive)
        XCTAssertEqual(monitor.activeAgent, .claude)
    }

    func testDoesNotDetectAgentFromUnrelatedTitle() {
        let monitor = makeMonitor()
        monitor.processOutput(titleSequence("vim myfile.txt"))
        XCTAssertEqual(monitor.state, .active)
        XCTAssertNil(monitor.activeAgent)
    }

    // MARK: - Agent Exit Detection (Debounced)

    func testAltScreenExitDoesNotImmediatelyExitAgent() {
        var states: [ActivityState] = []
        let monitor = makeMonitorStateOnly { states.append($0) }
        monitor.processOutput(titleSequence("claude"))
        XCTAssertEqual(monitor.state, .agentActive)
        monitor.processOutput(leaveAltScreen)
        XCTAssertEqual(monitor.state, .agentActive, "Alt-screen exit must not immediately exit agent")
        XCTAssertEqual(states, [.agentActive])
    }

    func testDetectsAgentExitFromNonAgentTitleDebounced() {
        var states: [ActivityState] = []
        let monitor = makeMonitorStateOnly { states.append($0) }
        monitor.processOutput(titleSequence("claude"))
        XCTAssertEqual(monitor.state, .agentActive)
        monitor.processOutput(titleSequence("zsh"))
        XCTAssertEqual(monitor.state, .agentActive, "Single non-agent signal should not exit")
        monitor.updateForegroundProcess(agent: nil)
        XCTAssertEqual(monitor.state, .active)
        XCTAssertEqual(states, [.agentActive, .active])
    }

    func testTwoNonAgentTitlesExitAgent() {
        var states: [ActivityState] = []
        let monitor = makeMonitorStateOnly { states.append($0) }
        monitor.processOutput(titleSequence("claude"))
        XCTAssertEqual(monitor.state, .agentActive)
        monitor.processOutput(titleSequence("zsh"))
        monitor.processOutput(titleSequence("bash"))
        XCTAssertEqual(monitor.state, .active)
        XCTAssertEqual(states, [.agentActive, .active])
    }

    func testShellPromptDoesNotExitAgent() {
        let monitor = makeMonitor()
        monitor.processOutput(titleSequence("claude"))
        XCTAssertEqual(monitor.state, .agentActive)
        monitor.processOutput(output("user@host ~/projects $"))
        XCTAssertEqual(monitor.state, .agentActive, "Shell prompt should not exit agent")
    }

    func testShellPromptDoesNotExitWhenNotInAgent() {
        var states: [ActivityState] = []
        let monitor = makeMonitorStateOnly { states.append($0) }
        monitor.processOutput(output("user@host ~ $"))
        XCTAssertEqual(monitor.state, .active)
        XCTAssertTrue(states.isEmpty, "No state change expected")
    }

    // MARK: - Agent-to-Agent Switching

    /// When a different agent takes over (e.g. user exits Claude and launches Codex),
    /// the switch must be immediate — no debounce — because the signal is unambiguous.
    func testImmediateSwitchFromClaudeToCodex() {
        var transitions: [(ActivityState, CodingAgent?)] = []
        let monitor = makeMonitor { state, agent in transitions.append((state, agent)) }
        monitor.updateForegroundProcess(agent: .claude)
        XCTAssertEqual(monitor.activeAgent, .claude)
        monitor.updateForegroundProcess(agent: .codex)
        XCTAssertEqual(monitor.activeAgent, .codex)
        // Both transitions should have fired — the second re-fires agentActive with new agent.
        XCTAssertEqual(transitions.count, 1, "same state .agentActive shouldn't re-emit, but agent switch must update activeAgent")
        XCTAssertEqual(monitor.activeAgent, .codex)
    }

    /// Title-based switch between agents — same semantics as poll-based.
    func testSwitchFromClaudeToCodexViaTitle() {
        let monitor = makeMonitor()
        monitor.processOutput(titleSequence("claude"))
        XCTAssertEqual(monitor.activeAgent, .claude)
        monitor.processOutput(titleSequence("codex"))
        XCTAssertEqual(monitor.activeAgent, .codex)
    }

    // MARK: - Silence Detection

    func testTransitionsToIdleAfterSilence() async {
        // Poll with exponential backoff instead of a fixed wait. The silence
        // timer fires on a private dispatch queue, so the transition to .idle
        // can arrive at any point after `silenceThreshold`. Previous iterations
        // of this test used a fixed 50 ms sleep, which occasionally lost the
        // race on heavily-loaded CI runners.
        let monitor = makeMonitor(silenceThreshold: 0.05)
        monitor.processOutput(output("some output"))

        var delay: UInt64 = 10_000_000      // 10 ms
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: delay)
            if monitor.state == .idle { break }
            delay = min(delay * 2, 100_000_000) // cap at 100 ms
        }

        XCTAssertEqual(monitor.state, .idle)
    }

    func testTransitionsToAgentIdleAfterSilence() async {
        let expectation = XCTestExpectation(description: "agentIdle state")
        let monitor = makeMonitorStateOnly(silenceThreshold: 0.05, agentSilenceThreshold: 0.1) { state in
            if state == .agentIdle { expectation.fulfill() }
        }
        monitor.processOutput(titleSequence("claude"))
        monitor.processOutput(output("thinking..."))
        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(monitor.state, .agentIdle)
    }

    func testNewOutputCancelsSilenceTimer() async {
        let monitor = makeMonitor(silenceThreshold: 0.2)
        monitor.processOutput(output("line 1"))
        try? await Task.sleep(for: .milliseconds(100))
        monitor.processOutput(output("line 2"))
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(monitor.state, .active)
    }

    func testInputResetsSilenceToActive() async {
        let idleExpectation = XCTestExpectation(description: "idle")
        let monitor = makeMonitorStateOnly(silenceThreshold: 0.05) { state in
            if state == .idle { idleExpectation.fulfill() }
        }
        monitor.processOutput(output("prompt $"))
        await fulfillment(of: [idleExpectation], timeout: 1.0)
        XCTAssertEqual(monitor.state, .idle)
        monitor.recordInput()
        XCTAssertEqual(monitor.state, .active)
    }

    // MARK: - Shell Prompt Heuristic

    func testShellPromptHeuristic() {
        XCTAssertTrue(SessionActivityMonitor.looksLikeShellPrompt("user@host ~ $"))
        XCTAssertTrue(SessionActivityMonitor.looksLikeShellPrompt("root@server /var/log #"))
        XCTAssertTrue(SessionActivityMonitor.looksLikeShellPrompt("miguelriotinto@Mac ~/Desktop/Projects %"))
        XCTAssertFalse(SessionActivityMonitor.looksLikeShellPrompt("$"))
        XCTAssertFalse(SessionActivityMonitor.looksLikeShellPrompt("  some_var=$"))
        XCTAssertFalse(SessionActivityMonitor.looksLikeShellPrompt(String(repeating: "a", count: 121) + "$"))
        XCTAssertFalse(SessionActivityMonitor.looksLikeShellPrompt("hello world"))
    }

    // MARK: - Escape-Only Output (TUI Noise)

    /// Regression: escape-only output (cursor moves, screen redraws) must not
    /// break the agentIdle state.
    func testEscapeOnlyOutputDoesNotBreakAgentIdle() async {
        let idleExpectation = XCTestExpectation(description: "agentIdle")
        var states: [ActivityState] = []
        let monitor = makeMonitorStateOnly(agentSilenceThreshold: 0.05) { state in
            states.append(state)
            if state == .agentIdle { idleExpectation.fulfill() }
        }

        monitor.processOutput(titleSequence("claude"))
        monitor.processOutput(output("thinking..."))

        await fulfillment(of: [idleExpectation], timeout: 1.0)
        XCTAssertEqual(monitor.state, .agentIdle)

        let escapeOnly = Data([0x1B, 0x5B, 0x48])
        states.removeAll()
        monitor.processOutput(escapeOnly)
        XCTAssertEqual(monitor.state, .agentIdle, "Escape-only output must not break agentIdle")
        XCTAssertTrue(states.isEmpty, "No state transition expected for escape-only noise")
    }

    // MARK: - Foreground Process Detection

    func testForegroundProcessDetectsClaudeEntry() {
        var states: [ActivityState] = []
        let monitor = makeMonitorStateOnly { states.append($0) }
        monitor.updateForegroundProcess(agent: .claude)
        XCTAssertEqual(monitor.state, .agentActive)
        XCTAssertEqual(states, [.agentActive])
    }

    func testForegroundProcessDetectsCodexEntry() {
        var agents: [CodingAgent?] = []
        let monitor = makeMonitor { _, agent in agents.append(agent) }
        monitor.updateForegroundProcess(agent: .codex)
        XCTAssertEqual(monitor.state, .agentActive)
        XCTAssertEqual(monitor.activeAgent, .codex)
        XCTAssertEqual(agents, [.codex])
    }

    func testForegroundProcessExitRequiresDebounce() {
        var states: [ActivityState] = []
        let monitor = makeMonitorStateOnly { states.append($0) }
        monitor.updateForegroundProcess(agent: .claude)
        monitor.updateForegroundProcess(agent: nil)
        XCTAssertEqual(monitor.state, .agentActive, "Single non-agent poll should not exit")
        monitor.updateForegroundProcess(agent: nil)
        XCTAssertEqual(monitor.state, .active)
        XCTAssertEqual(states, [.agentActive, .active])
    }

    func testForegroundProcessAgentPollResetsDebounce() {
        var states: [ActivityState] = []
        let monitor = makeMonitorStateOnly { states.append($0) }
        monitor.updateForegroundProcess(agent: .claude)
        monitor.updateForegroundProcess(agent: nil)
        XCTAssertEqual(monitor.state, .agentActive)
        monitor.updateForegroundProcess(agent: .claude)
        monitor.updateForegroundProcess(agent: nil)
        XCTAssertEqual(monitor.state, .agentActive, "Debounce counter should reset on agent poll")
        XCTAssertEqual(states, [.agentActive])
    }

    func testForegroundProcessNoOpWhenAlreadyInState() {
        var states: [ActivityState] = []
        let monitor = makeMonitorStateOnly { states.append($0) }
        monitor.updateForegroundProcess(agent: .claude)
        monitor.updateForegroundProcess(agent: .claude)
        XCTAssertEqual(states.count, 1, "Duplicate poll should not re-trigger transition")
    }

    func testForegroundProcessIdleAfterSilence() async {
        let expectation = XCTestExpectation(description: "agentIdle via foreground")
        let monitor = makeMonitorStateOnly(agentSilenceThreshold: 0.05) { state in
            if state == .agentIdle { expectation.fulfill() }
        }
        monitor.updateForegroundProcess(agent: .claude)
        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(monitor.state, .agentIdle)
    }

    // MARK: - Force Exit (PTY death)

    func testForceExitClearsAgentState() {
        var states: [ActivityState] = []
        let monitor = makeMonitorStateOnly { states.append($0) }
        monitor.updateForegroundProcess(agent: .claude)
        XCTAssertEqual(monitor.state, .agentActive)
        states.removeAll()

        monitor.forceExit()
        XCTAssertEqual(monitor.state, .idle)
        XCTAssertNil(monitor.activeAgent)
        XCTAssertEqual(states, [.idle])
    }

    func testForceExitFromAgentIdle() async {
        let idleExpectation = XCTestExpectation(description: "agentIdle")
        var states: [ActivityState] = []
        let monitor = makeMonitorStateOnly(agentSilenceThreshold: 0.05) { state in
            states.append(state)
            if state == .agentIdle { idleExpectation.fulfill() }
        }
        monitor.updateForegroundProcess(agent: .claude)
        await fulfillment(of: [idleExpectation], timeout: 1.0)
        XCTAssertEqual(monitor.state, .agentIdle)
        states.removeAll()

        monitor.forceExit()
        XCTAssertEqual(monitor.state, .idle)
        XCTAssertEqual(states, [.idle])
    }

    func testForceExitWhenNotRunningAgent() {
        var states: [ActivityState] = []
        let monitor = makeMonitorStateOnly { states.append($0) }
        monitor.processOutput(output("hello"))
        XCTAssertEqual(monitor.state, .active)
        states.removeAll()

        monitor.forceExit()
        XCTAssertEqual(monitor.state, .idle)
        XCTAssertEqual(states, [.idle])
    }

    func testForceExitPreventsSubsequentSilenceTimer() async {
        var states: [ActivityState] = []
        let monitor = makeMonitorStateOnly(agentSilenceThreshold: 0.05) { states.append($0) }
        monitor.updateForegroundProcess(agent: .claude)
        monitor.processOutput(output("working..."))
        monitor.forceExit()
        states.removeAll()

        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(monitor.state, .idle)
        XCTAssertTrue(states.isEmpty, "No further transitions after forceExit")
    }

    func testNoStateChangeAfterCancel() {
        var states: [ActivityState] = []
        let monitor = makeMonitorStateOnly { states.append($0) }
        monitor.updateForegroundProcess(agent: .claude)
        states.removeAll()

        monitor.cancel()
        monitor.processOutput(output("late output"))
        monitor.updateForegroundProcess(agent: nil)
        monitor.updateForegroundProcess(agent: nil)
        monitor.forceExit()
        XCTAssertTrue(states.isEmpty, "No transitions after cancel")
    }

    // MARK: - Rapid Launch/Exit Cycles

    func testRapidAgentLaunchExitCycle() {
        var states: [ActivityState] = []
        let monitor = makeMonitorStateOnly { states.append($0) }

        monitor.updateForegroundProcess(agent: .claude)
        XCTAssertEqual(monitor.state, .agentActive)

        monitor.updateForegroundProcess(agent: nil)
        monitor.updateForegroundProcess(agent: nil)
        XCTAssertEqual(monitor.state, .active)

        monitor.updateForegroundProcess(agent: .claude)
        XCTAssertEqual(monitor.state, .agentActive)

        monitor.updateForegroundProcess(agent: nil)
        monitor.updateForegroundProcess(agent: nil)
        XCTAssertEqual(monitor.state, .active)

        XCTAssertEqual(states, [.agentActive, .active, .agentActive, .active])
    }

    func testForceExitResetsDebounceCounter() {
        var states: [ActivityState] = []
        let monitor = makeMonitorStateOnly { states.append($0) }
        monitor.updateForegroundProcess(agent: .claude)
        monitor.updateForegroundProcess(agent: nil)
        XCTAssertEqual(monitor.state, .agentActive)

        monitor.forceExit()
        XCTAssertEqual(monitor.state, .idle)

        monitor.updateForegroundProcess(agent: .claude)
        XCTAssertEqual(monitor.state, .agentActive)
    }

    // MARK: - Silence Timeout via Actor (applySilenceTimeout)

    func testApplySilenceTimeoutWhenAgentRunning() {
        let monitor = makeMonitor()
        monitor.updateForegroundProcess(agent: .claude)
        monitor.processOutput(output("some output"))
        XCTAssertEqual(monitor.state, .agentActive)

        monitor.applySilenceTimeout()
        XCTAssertEqual(monitor.state, .agentIdle)
    }

    func testApplySilenceTimeoutWhenNotAgent() {
        let monitor = makeMonitor()
        monitor.processOutput(output("prompt"))
        XCTAssertEqual(monitor.state, .active)

        monitor.applySilenceTimeout()
        XCTAssertEqual(monitor.state, .idle)
    }

    func testApplySilenceTimeoutNoOpAfterCancel() {
        var states: [ActivityState] = []
        let monitor = makeMonitorStateOnly { states.append($0) }
        monitor.processOutput(output("data"))
        monitor.cancel()
        states.removeAll()

        monitor.applySilenceTimeout()
        XCTAssertTrue(states.isEmpty)
    }

    // MARK: - Mixed Signal Edge Cases

    func testTitleEntryThenPollExitCrossSignal() {
        var states: [ActivityState] = []
        let monitor = makeMonitorStateOnly { states.append($0) }
        monitor.processOutput(titleSequence("Claude Code - project"))
        XCTAssertEqual(monitor.state, .agentActive)
        monitor.processOutput(titleSequence("zsh"))
        XCTAssertEqual(monitor.state, .agentActive)
        monitor.updateForegroundProcess(agent: nil)
        XCTAssertEqual(monitor.state, .active)
    }

    func testPollEntryThenTitleExitCrossSignal() {
        var states: [ActivityState] = []
        let monitor = makeMonitorStateOnly { states.append($0) }
        monitor.updateForegroundProcess(agent: .claude)
        XCTAssertEqual(monitor.state, .agentActive)
        monitor.processOutput(titleSequence("bash"))
        monitor.processOutput(titleSequence("user@host ~ %"))
        XCTAssertEqual(monitor.state, .active)
    }

    // MARK: - Cleanup

    func testCancelStopsSilenceTimer() async {
        var states: [ActivityState] = []
        let monitor = makeMonitorStateOnly(silenceThreshold: 0.05) { states.append($0) }
        monitor.processOutput(output("something"))
        monitor.cancel()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(states.isEmpty || !states.contains(.idle))
    }

    // MARK: - Fast path: regex/UTF-8 decode skipped when no agent running

    func testEscapeOnlyOutputTransitionsToActiveWhenNotAgent() {
        var states: [ActivityState] = []
        let monitor = makeMonitorStateOnly(silenceThreshold: 10, agentSilenceThreshold: 10) { states.append($0) }
        monitor.applySilenceTimeout()
        XCTAssertEqual(states.last, .idle)

        monitor.processOutput(Data([0x1B, 0x5B, 0x32, 0x41]))
        XCTAssertEqual(states.last, .active, "escape-only output must drive non-agent monitor back to .active")
        monitor.cancel()
    }

    func testEscapeOnlyOutputDoesNotCountAsActivityWhenAgentRunning() {
        var states: [ActivityState] = []
        let monitor = makeMonitorStateOnly(silenceThreshold: 10, agentSilenceThreshold: 10) { states.append($0) }
        monitor.updateForegroundProcess(agent: .claude)
        states.removeAll()
        monitor.processOutput(Data([0x1B, 0x5B, 0x32, 0x41]))
        XCTAssertTrue(states.isEmpty, "escape-only output must not transition while agent is running")
        monitor.cancel()
    }

    func testNonUTF8OutputCountsAsActivityWhenAgentRunning() {
        var states: [ActivityState] = []
        let monitor = makeMonitorStateOnly(silenceThreshold: 10, agentSilenceThreshold: 10) { states.append($0) }
        monitor.updateForegroundProcess(agent: .claude)
        monitor.applySilenceTimeout()
        XCTAssertEqual(states.last, .agentIdle)

        monitor.processOutput(Data([0xFF, 0xFE, 0xFD]))
        XCTAssertEqual(states.last, .agentActive, "non-UTF-8 chunk must fall back to .agentActive")
        monitor.cancel()
    }
}
