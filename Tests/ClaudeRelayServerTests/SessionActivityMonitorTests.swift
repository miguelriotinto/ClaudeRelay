import XCTest
import Foundation
@testable import ClaudeRelayServer
@testable import ClaudeRelayKit

final class SessionActivityMonitorTests: XCTestCase {

    private func makeMonitor(
        silenceThreshold: TimeInterval = 0.1,
        claudeSilenceThreshold: TimeInterval = 0.2,
        onChange: @escaping @Sendable (ActivityState) -> Void = { _ in }
    ) -> SessionActivityMonitor {
        SessionActivityMonitor(
            silenceThreshold: silenceThreshold,
            claudeSilenceThreshold: claudeSilenceThreshold,
            onChange: onChange
        )
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
    }

    // MARK: - Claude Entry Detection

    func testDetectsClaudeEntryFromTitle() {
        var states: [ActivityState] = []
        let monitor = makeMonitor { states.append($0) }
        monitor.processOutput(titleSequence("claude"))
        XCTAssertEqual(monitor.state, .claudeActive)
        XCTAssertEqual(states, [.claudeActive])
    }

    func testDetectsClaudeEntryFromTitleCaseInsensitive() {
        let monitor = makeMonitor()
        monitor.processOutput(titleSequence("Claude Code - ~/projects"))
        XCTAssertEqual(monitor.state, .claudeActive)
    }

    func testDoesNotDetectClaudeFromUnrelatedTitle() {
        let monitor = makeMonitor()
        monitor.processOutput(titleSequence("vim myfile.txt"))
        XCTAssertEqual(monitor.state, .active)
    }

    // MARK: - Claude Exit Detection (Debounced)

    func testAltScreenExitDoesNotImmediatelyExitClaude() {
        var states: [ActivityState] = []
        let monitor = makeMonitor { states.append($0) }
        monitor.processOutput(titleSequence("claude"))
        XCTAssertEqual(monitor.state, .claudeActive)
        // Alt-screen exit alone no longer exits Claude (tools like vim/less use alt screen)
        monitor.processOutput(leaveAltScreen)
        XCTAssertEqual(monitor.state, .claudeActive, "Alt-screen exit must not immediately exit Claude")
        XCTAssertEqual(states, [.claudeActive])
    }

    func testDetectsClaudeExitFromNonClaudeTitleDebounced() {
        var states: [ActivityState] = []
        let monitor = makeMonitor { states.append($0) }
        monitor.processOutput(titleSequence("claude"))
        XCTAssertEqual(monitor.state, .claudeActive)
        // First non-Claude title: increments debounce counter but doesn't exit yet
        monitor.processOutput(titleSequence("zsh"))
        XCTAssertEqual(monitor.state, .claudeActive, "Single non-Claude signal should not exit")
        // Second non-Claude signal (via process poll): confirms exit
        monitor.updateForegroundProcess(isClaude: false)
        XCTAssertEqual(monitor.state, .active)
        XCTAssertEqual(states, [.claudeActive, .active])
    }

    func testTwoNonClaudeTitlesExitClaude() {
        var states: [ActivityState] = []
        let monitor = makeMonitor { states.append($0) }
        monitor.processOutput(titleSequence("claude"))
        XCTAssertEqual(monitor.state, .claudeActive)
        // Two consecutive non-Claude titles meet the debounce threshold
        monitor.processOutput(titleSequence("zsh"))
        monitor.processOutput(titleSequence("bash"))
        XCTAssertEqual(monitor.state, .active)
        XCTAssertEqual(states, [.claudeActive, .active])
    }

    func testShellPromptDoesNotExitClaude() {
        let monitor = makeMonitor()
        monitor.processOutput(titleSequence("claude"))
        XCTAssertEqual(monitor.state, .claudeActive)
        monitor.processOutput(output("user@host ~/projects $"))
        XCTAssertEqual(monitor.state, .claudeActive, "Shell prompt should not exit Claude")
    }

    func testShellPromptDoesNotExitWhenNotInClaude() {
        var states: [ActivityState] = []
        let monitor = makeMonitor { states.append($0) }
        monitor.processOutput(output("user@host ~ $"))
        XCTAssertEqual(monitor.state, .active)
        XCTAssertTrue(states.isEmpty, "No state change expected")
    }

    // MARK: - Silence Detection

    func testTransitionsToIdleAfterSilence() async {
        let expectation = XCTestExpectation(description: "idle state")
        let monitor = makeMonitor(silenceThreshold: 0.05) { state in
            if state == .idle { expectation.fulfill() }
        }
        monitor.processOutput(output("some output"))
        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(monitor.state, .idle)
    }

    func testTransitionsToClaudeIdleAfterSilence() async {
        let expectation = XCTestExpectation(description: "claudeIdle state")
        let monitor = makeMonitor(silenceThreshold: 0.05, claudeSilenceThreshold: 0.1) { state in
            if state == .claudeIdle { expectation.fulfill() }
        }
        monitor.processOutput(titleSequence("claude"))
        monitor.processOutput(output("thinking..."))
        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(monitor.state, .claudeIdle)
    }

    func testNewOutputCancelsSilenceTimer() async {
        var states: [ActivityState] = []
        let monitor = makeMonitor(silenceThreshold: 0.2) { states.append($0) }
        monitor.processOutput(output("line 1"))
        try? await Task.sleep(for: .milliseconds(100))
        monitor.processOutput(output("line 2"))
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(monitor.state, .active)
    }

    func testInputResetsSilenceToActive() async {
        let idleExpectation = XCTestExpectation(description: "idle")
        let monitor = makeMonitor(silenceThreshold: 0.05) { state in
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
    /// break the claudeIdle state. Before the fix, such noise would transition
    /// to claudeActive without resetting the silence timer, permanently killing
    /// the idle signal.
    func testEscapeOnlyOutputDoesNotBreakClaudeIdle() async {
        let idleExpectation = XCTestExpectation(description: "claudeIdle")
        var states: [ActivityState] = []
        let monitor = makeMonitor(claudeSilenceThreshold: 0.05) { state in
            states.append(state)
            if state == .claudeIdle { idleExpectation.fulfill() }
        }

        // Enter Claude and produce visible output
        monitor.processOutput(titleSequence("claude"))
        monitor.processOutput(output("thinking..."))

        // Wait for idle
        await fulfillment(of: [idleExpectation], timeout: 1.0)
        XCTAssertEqual(monitor.state, .claudeIdle)

        // Send escape-only output (cursor move) — should NOT break idle
        let escapeOnly = Data([0x1B, 0x5B, 0x48]) // ESC [ H (cursor home)
        states.removeAll()
        monitor.processOutput(escapeOnly)
        XCTAssertEqual(monitor.state, .claudeIdle, "Escape-only output must not break claudeIdle")
        XCTAssertTrue(states.isEmpty, "No state transition expected for escape-only noise")
    }

    // MARK: - Foreground Process Detection

    func testForegroundProcessDetectsClaudeEntry() {
        var states: [ActivityState] = []
        let monitor = makeMonitor { states.append($0) }
        monitor.updateForegroundProcess(isClaude: true)
        XCTAssertEqual(monitor.state, .claudeActive)
        XCTAssertEqual(states, [.claudeActive])
    }

    func testForegroundProcessExitRequiresDebounce() {
        var states: [ActivityState] = []
        let monitor = makeMonitor { states.append($0) }
        monitor.updateForegroundProcess(isClaude: true)
        // Single non-Claude poll should not exit (debounce)
        monitor.updateForegroundProcess(isClaude: false)
        XCTAssertEqual(monitor.state, .claudeActive, "Single non-Claude poll should not exit")
        // Second consecutive non-Claude poll confirms exit
        monitor.updateForegroundProcess(isClaude: false)
        XCTAssertEqual(monitor.state, .active)
        XCTAssertEqual(states, [.claudeActive, .active])
    }

    func testForegroundProcessClaudePollResetsDebounce() {
        var states: [ActivityState] = []
        let monitor = makeMonitor { states.append($0) }
        monitor.updateForegroundProcess(isClaude: true)
        // One non-Claude poll
        monitor.updateForegroundProcess(isClaude: false)
        XCTAssertEqual(monitor.state, .claudeActive)
        // Claude returns — resets debounce counter
        monitor.updateForegroundProcess(isClaude: true)
        // Another single non-Claude poll — should NOT exit (counter was reset)
        monitor.updateForegroundProcess(isClaude: false)
        XCTAssertEqual(monitor.state, .claudeActive, "Debounce counter should reset on Claude poll")
        XCTAssertEqual(states, [.claudeActive])
    }

    func testForegroundProcessNoOpWhenAlreadyInState() {
        var states: [ActivityState] = []
        let monitor = makeMonitor { states.append($0) }
        monitor.updateForegroundProcess(isClaude: true)
        monitor.updateForegroundProcess(isClaude: true)
        XCTAssertEqual(states.count, 1, "Duplicate poll should not re-trigger transition")
    }

    func testForegroundProcessIdleAfterSilence() async {
        let expectation = XCTestExpectation(description: "claudeIdle via foreground")
        let monitor = makeMonitor(claudeSilenceThreshold: 0.05) { state in
            if state == .claudeIdle { expectation.fulfill() }
        }
        monitor.updateForegroundProcess(isClaude: true)
        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(monitor.state, .claudeIdle)
    }

    // MARK: - Force Exit (PTY death)

    func testForceExitClearsClaudeState() {
        var states: [ActivityState] = []
        let monitor = makeMonitor { states.append($0) }
        monitor.updateForegroundProcess(isClaude: true)
        XCTAssertEqual(monitor.state, .claudeActive)
        states.removeAll()

        monitor.forceExit()
        XCTAssertEqual(monitor.state, .idle)
        XCTAssertEqual(states, [.idle])
    }

    func testForceExitFromClaudeIdle() async {
        let idleExpectation = XCTestExpectation(description: "claudeIdle")
        var states: [ActivityState] = []
        let monitor = makeMonitor(claudeSilenceThreshold: 0.05) { state in
            states.append(state)
            if state == .claudeIdle { idleExpectation.fulfill() }
        }
        monitor.updateForegroundProcess(isClaude: true)
        await fulfillment(of: [idleExpectation], timeout: 1.0)
        XCTAssertEqual(monitor.state, .claudeIdle)
        states.removeAll()

        monitor.forceExit()
        XCTAssertEqual(monitor.state, .idle)
        XCTAssertEqual(states, [.idle])
    }

    func testForceExitWhenNotRunningClaude() {
        var states: [ActivityState] = []
        let monitor = makeMonitor { states.append($0) }
        monitor.processOutput(output("hello"))
        XCTAssertEqual(monitor.state, .active)
        states.removeAll()

        monitor.forceExit()
        XCTAssertEqual(monitor.state, .idle)
        XCTAssertEqual(states, [.idle])
    }

    func testForceExitPreventsSubsequentSilenceTimer() async {
        var states: [ActivityState] = []
        let monitor = makeMonitor(claudeSilenceThreshold: 0.05) { states.append($0) }
        monitor.updateForegroundProcess(isClaude: true)
        monitor.processOutput(output("working..."))
        monitor.forceExit()
        states.removeAll()

        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(monitor.state, .idle)
        XCTAssertTrue(states.isEmpty, "No further transitions after forceExit")
    }

    func testNoStateChangeAfterCancel() {
        var states: [ActivityState] = []
        let monitor = makeMonitor { states.append($0) }
        monitor.updateForegroundProcess(isClaude: true)
        states.removeAll()

        monitor.cancel()
        monitor.processOutput(output("late output"))
        monitor.updateForegroundProcess(isClaude: false)
        monitor.updateForegroundProcess(isClaude: false)
        monitor.forceExit()
        XCTAssertTrue(states.isEmpty, "No transitions after cancel")
    }

    // MARK: - Rapid Launch/Exit Cycles

    func testRapidClaudeLaunchExitCycle() {
        var states: [ActivityState] = []
        let monitor = makeMonitor { states.append($0) }

        // Launch
        monitor.updateForegroundProcess(isClaude: true)
        XCTAssertEqual(monitor.state, .claudeActive)

        // Rapid exit (two consecutive non-Claude)
        monitor.updateForegroundProcess(isClaude: false)
        monitor.updateForegroundProcess(isClaude: false)
        XCTAssertEqual(monitor.state, .active)

        // Immediate relaunch
        monitor.updateForegroundProcess(isClaude: true)
        XCTAssertEqual(monitor.state, .claudeActive)

        // Another exit
        monitor.updateForegroundProcess(isClaude: false)
        monitor.updateForegroundProcess(isClaude: false)
        XCTAssertEqual(monitor.state, .active)

        XCTAssertEqual(states, [.claudeActive, .active, .claudeActive, .active])
    }

    func testForceExitResetsDebounceCounter() {
        var states: [ActivityState] = []
        let monitor = makeMonitor { states.append($0) }
        monitor.updateForegroundProcess(isClaude: true)
        // One non-Claude poll (debounce counter = 1)
        monitor.updateForegroundProcess(isClaude: false)
        XCTAssertEqual(monitor.state, .claudeActive)

        // Force exit resets everything
        monitor.forceExit()
        XCTAssertEqual(monitor.state, .idle)

        // New Claude launch should work cleanly
        monitor.updateForegroundProcess(isClaude: true)
        XCTAssertEqual(monitor.state, .claudeActive)
    }

    // MARK: - Silence Timeout via Actor (applySilenceTimeout)

    func testApplySilenceTimeoutWhenClaudeRunning() {
        let monitor = makeMonitor()
        monitor.updateForegroundProcess(isClaude: true)
        monitor.processOutput(output("some output"))
        XCTAssertEqual(monitor.state, .claudeActive)

        monitor.applySilenceTimeout()
        XCTAssertEqual(monitor.state, .claudeIdle)
    }

    func testApplySilenceTimeoutWhenNotClaude() {
        let monitor = makeMonitor()
        monitor.processOutput(output("prompt"))
        XCTAssertEqual(monitor.state, .active)

        monitor.applySilenceTimeout()
        XCTAssertEqual(monitor.state, .idle)
    }

    func testApplySilenceTimeoutNoOpAfterCancel() {
        var states: [ActivityState] = []
        let monitor = makeMonitor { states.append($0) }
        monitor.processOutput(output("data"))
        monitor.cancel()
        states.removeAll()

        monitor.applySilenceTimeout()
        XCTAssertTrue(states.isEmpty)
    }

    // MARK: - Mixed Signal Edge Cases

    func testTitleEntryThenPollExitCrossSignal() {
        var states: [ActivityState] = []
        let monitor = makeMonitor { states.append($0) }
        // Enter via title
        monitor.processOutput(titleSequence("Claude Code - project"))
        XCTAssertEqual(monitor.state, .claudeActive)
        // Exit via one title + one poll (cross-source debounce)
        monitor.processOutput(titleSequence("zsh"))
        XCTAssertEqual(monitor.state, .claudeActive)
        monitor.updateForegroundProcess(isClaude: false)
        XCTAssertEqual(monitor.state, .active)
    }

    func testPollEntryThenTitleExitCrossSignal() {
        var states: [ActivityState] = []
        let monitor = makeMonitor { states.append($0) }
        // Enter via poll
        monitor.updateForegroundProcess(isClaude: true)
        XCTAssertEqual(monitor.state, .claudeActive)
        // Exit via two titles
        monitor.processOutput(titleSequence("bash"))
        monitor.processOutput(titleSequence("user@host ~ %"))
        XCTAssertEqual(monitor.state, .active)
    }

    // MARK: - Cleanup

    func testCancelStopsSilenceTimer() async {
        var states: [ActivityState] = []
        let monitor = makeMonitor(silenceThreshold: 0.05) { states.append($0) }
        monitor.processOutput(output("something"))
        monitor.cancel()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(states.isEmpty || !states.contains(.idle))
    }

    // MARK: - Fast path (Task 2): regex/UTF-8 decode skipped when !isClaudeRunning

    /// When Claude is not running, any output (including a pure escape-sequence
    /// chunk) must be counted as activity. We prove this by first seeding the
    /// monitor to `.idle` via applySilenceTimeout, then feeding an escape-only
    /// chunk, and asserting the transition to `.active` fires onChange.
    /// This guards the refactor that skips UTF-8 decode + ANSI regex on the
    /// non-Claude path: observable behavior must match the old code.
    func testEscapeOnlyOutputTransitionsToActiveWhenNotClaude() {
        var states: [ActivityState] = []
        let monitor = SessionActivityMonitor(
            silenceThreshold: 10,
            claudeSilenceThreshold: 10,
            onChange: { states.append($0) }
        )
        // Seed to .idle so the escape-only chunk produces an observable transition.
        monitor.applySilenceTimeout()
        XCTAssertEqual(states.last, .idle)

        // Pure escape sequence: cursor-up 2 times. No visible text.
        monitor.processOutput(Data([0x1B, 0x5B, 0x32, 0x41]))
        XCTAssertEqual(states.last, .active, "escape-only output must drive !claude monitor back to .active")
        monitor.cancel()
    }

    /// When Claude IS running, escape-only output must NOT count as activity.
    /// (Complements testEscapeOnlyOutputDoesNotBreakClaudeIdle by confirming no
    /// state change at all from a pure escape chunk, not just "stays idle".)
    func testEscapeOnlyOutputDoesNotCountAsActivityWhenClaudeRunning() {
        var states: [ActivityState] = []
        let monitor = SessionActivityMonitor(
            silenceThreshold: 10,
            claudeSilenceThreshold: 10,
            onChange: { states.append($0) }
        )
        monitor.updateForegroundProcess(isClaude: true)
        states.removeAll() // drop the .active → .claudeActive entry transition
        monitor.processOutput(Data([0x1B, 0x5B, 0x32, 0x41]))
        XCTAssertTrue(states.isEmpty, "escape-only output must not transition while Claude is running")
        monitor.cancel()
    }
}
