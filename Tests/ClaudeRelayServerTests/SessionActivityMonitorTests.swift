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

    // MARK: - Claude Exit Detection

    func testDetectsClaudeExitFromShellPrompt() {
        var states: [ActivityState] = []
        let monitor = makeMonitor { states.append($0) }
        monitor.processOutput(titleSequence("claude"))
        XCTAssertEqual(monitor.state, .claudeActive)
        monitor.processOutput(output("user@host ~/projects $"))
        XCTAssertEqual(monitor.state, .active)
        XCTAssertEqual(states, [.claudeActive, .active])
    }

    func testDetectsClaudeExitFromAltScreenExit() {
        var states: [ActivityState] = []
        let monitor = makeMonitor { states.append($0) }
        monitor.processOutput(titleSequence("claude"))
        XCTAssertEqual(monitor.state, .claudeActive)
        monitor.processOutput(leaveAltScreen)
        XCTAssertEqual(monitor.state, .active)
        XCTAssertEqual(states, [.claudeActive, .active])
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

    // MARK: - Cleanup

    func testCancelStopsSilenceTimer() async {
        var states: [ActivityState] = []
        let monitor = makeMonitor(silenceThreshold: 0.05) { states.append($0) }
        monitor.processOutput(output("something"))
        monitor.cancel()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(states.isEmpty || !states.contains(.idle))
    }
}
