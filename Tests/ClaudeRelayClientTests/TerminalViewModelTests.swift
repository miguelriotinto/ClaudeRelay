import XCTest
@testable import ClaudeRelayClient

@MainActor
final class TerminalViewModelTests: XCTestCase {

    private func makeVM(
        normal: Duration = .milliseconds(80),
        agentActive: Duration = .milliseconds(160)
    ) -> TerminalViewModel {
        let connection = RelayConnection()
        return TerminalViewModel(
            sessionId: UUID(),
            connection: connection,
            promptThresholds: InputPromptThresholds(
                normal: normal,
                agentActive: agentActive
            )
        )
    }

    /// Polls `condition()` every 10 ms up to `timeout`, returning once it's true
    /// or the timeout expires. Lets timing-sensitive tests finish on the fast
    /// path and tolerate scheduler jitter without inflating the test runtime.
    private func waitFor(
        timeout: Duration = .milliseconds(500),
        _ condition: () -> Bool
    ) async throws {
        let start = Date()
        let timeoutSeconds = Double(timeout.components.seconds)
            + Double(timeout.components.attoseconds) / 1e18
        while !condition() {
            if Date().timeIntervalSince(start) >= timeoutSeconds {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testBuffersOutputBeforeTerminalReady() {
        let vm = makeVM()
        var received = [Data]()
        vm.onTerminalOutput = { received.append($0) }

        vm.receiveOutput(Data([0x41]))
        vm.receiveOutput(Data([0x42]))

        XCTAssertTrue(received.isEmpty, "Output should be buffered until terminalReady()")
    }

    func testTerminalReadyFlushesBuffer() {
        let vm = makeVM()
        var received = [Data]()
        vm.onTerminalOutput = { received.append($0) }

        vm.receiveOutput(Data([0x41]))
        vm.receiveOutput(Data([0x42]))
        vm.terminalReady()

        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received[0], Data([0x41]))
        XCTAssertEqual(received[1], Data([0x42]))
    }

    func testOutputForwardedAfterReady() {
        let vm = makeVM()
        var received = [Data]()
        vm.onTerminalOutput = { received.append($0) }
        vm.terminalReady()

        vm.receiveOutput(Data([0x43]))
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0], Data([0x43]))
    }

    func testTerminalReadyIsIdempotent() {
        let vm = makeVM()
        var count = 0
        vm.onTerminalOutput = { _ in count += 1 }

        vm.receiveOutput(Data([0x41]))
        vm.terminalReady()
        vm.terminalReady()

        XCTAssertEqual(count, 1, "Second terminalReady should be a no-op")
    }

    func testPrepareForSwitchClearsState() {
        let vm = makeVM()
        vm.onTerminalOutput = { _ in }
        vm.onTitleChanged = { _ in }
        vm.terminalReady()
        vm.receiveOutput(Data([0x41]))

        vm.prepareForSwitch()

        XCTAssertNil(vm.onTerminalOutput)
        XCTAssertNil(vm.onTitleChanged)
        XCTAssertNil(vm.onAwaitingInputChanged)
    }

    func testPrepareForReplaySeedsRISIntoPendingBuffer() {
        let vm = makeVM()
        vm.onTerminalOutput = { _ in }
        vm.terminalReady()
        vm.receiveOutput(Data([0x41]))

        vm.prepareForReplay()

        XCTAssertNil(vm.onTerminalOutput)
        XCTAssertNil(vm.onTitleChanged)

        // After prepareForReplay, the pending buffer should contain RIS.
        // Re-wire and call terminalReady to flush it.
        var received = [Data]()
        vm.onTerminalOutput = { received.append($0) }
        vm.terminalReady()

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0], Data([0x1B, 0x63]))
    }

    func testResetForReplaySendsRIS() {
        let vm = makeVM()
        var received = [Data]()
        vm.onTerminalOutput = { received.append($0) }
        vm.terminalReady()

        vm.resetForReplay()

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0], Data([0x1B, 0x63]))
    }

    func testSendInputClearsAwaitingInput() async throws {
        let vm = makeVM()
        var received = [Data]()
        vm.onTerminalOutput = { received.append($0) }
        vm.terminalReady()

        vm.receiveOutput(Data([0x24, 0x20]))
        try await waitFor { vm.awaitingInput }
        XCTAssertTrue(vm.awaitingInput)

        vm.sendInput(Data([0x0A]))
        XCTAssertFalse(vm.awaitingInput)
    }

    func testAwaitingInputCallbackFires() async throws {
        let vm = makeVM()
        var received = [Data]()
        vm.onTerminalOutput = { received.append($0) }
        vm.terminalReady()

        var transitions = [Bool]()
        vm.onAwaitingInputChanged = { transitions.append($0) }

        vm.receiveOutput(Data([0x24, 0x20]))
        try await waitFor { !transitions.isEmpty }

        XCTAssertEqual(transitions, [true])
    }

    func testAgentActiveUsesLongerThreshold() async throws {
        let vm = makeVM()
        var received = [Data]()
        vm.onTerminalOutput = { received.append($0) }
        vm.terminalReady()
        vm.isAgentActive = true

        vm.receiveOutput(Data([0x24, 0x20]))
        // At 100 ms the agentActive threshold (160 ms) hasn't elapsed yet; assert
        // the timer hasn't fired. This is a deterministic sleep — the invariant
        // is "did NOT fire" which can't be polled (we need a hard deadline).
        // 60 ms slack against the threshold gives enough margin for typical CI
        // jitter without stretching the test unnecessarily.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(vm.awaitingInput, "Should not trigger before agentActive threshold")

        // Now poll for the positive transition — any jitter lets us wait longer
        // without slowing the happy path.
        try await waitFor { vm.awaitingInput }
        XCTAssertTrue(vm.awaitingInput, "Should trigger after agentActive threshold elapses")
    }

    func testPendingOutputByteCapEvictsOldest() {
        let vm = makeVM()
        // 80 × 64 KB = 5 MB, exceeding the 4 MB cap.
        let chunk = Data(repeating: 0x41, count: 64 * 1024)
        for _ in 0..<80 {
            vm.receiveOutput(chunk)
        }

        var received = [Data]()
        vm.onTerminalOutput = { received.append($0) }
        vm.terminalReady()

        let totalBytes = received.reduce(0) { $0 + $1.count }
        XCTAssertLessThanOrEqual(totalBytes, 4 * 1024 * 1024 + 64 * 1024,
            "pending buffer should have been capped at ~4MB + one overshoot chunk")
        XCTAssertGreaterThan(totalBytes, 3 * 1024 * 1024,
            "cap should keep at least ~3 MB of recent output")
    }

    /// Boundary case: buffering data up to *exactly* the 4 MB cap must not
    /// evict anything. The eviction path only runs when size *exceeds* the cap.
    func testPendingOutputExactlyAtCapDoesNotEvict() {
        let vm = makeVM()
        // 4 × 1 MB = 4 MB, exactly at the cap.
        let chunk = Data(repeating: 0x42, count: 1024 * 1024)
        for _ in 0..<4 {
            vm.receiveOutput(chunk)
        }

        var received = [Data]()
        vm.onTerminalOutput = { received.append($0) }
        vm.terminalReady()

        let total = received.reduce(0) { $0 + $1.count }
        XCTAssertEqual(total, 4 * 1024 * 1024,
            "All 4 MB should be preserved when buffer is at cap (but not over)")
    }

    /// Boundary case: buffering slightly over the cap must evict the oldest
    /// chunks so the total stays within cap + one head-chunk slack.
    func testPendingOutputOverCapDropsOldestChunks() {
        let vm = makeVM()
        let chunk = Data(repeating: 0x43, count: 64 * 1024)     // 64 KB
        for _ in 0..<80 {                                        // 5 MB > 4 MB cap
            vm.receiveOutput(chunk)
        }

        var received = [Data]()
        vm.onTerminalOutput = { received.append($0) }
        vm.terminalReady()

        let total = received.reduce(0) { $0 + $1.count }
        XCTAssertLessThanOrEqual(total, 4 * 1024 * 1024 + chunk.count,
            "Total delivered should stay within cap + one head chunk slack")
    }
}
