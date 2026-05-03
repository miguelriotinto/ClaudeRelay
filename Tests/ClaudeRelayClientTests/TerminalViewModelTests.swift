import XCTest
@testable import ClaudeRelayClient

@MainActor
final class TerminalViewModelTests: XCTestCase {

    private func makeVM() -> TerminalViewModel {
        let connection = RelayConnection()
        return TerminalViewModel(sessionId: UUID(), connection: connection)
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
        try await Task.sleep(for: .milliseconds(1200))
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
        try await Task.sleep(for: .milliseconds(1200))

        XCTAssertEqual(transitions, [true])
    }

    func testClaudeActiveUsesLongerThreshold() async throws {
        let vm = makeVM()
        var received = [Data]()
        vm.onTerminalOutput = { received.append($0) }
        vm.terminalReady()
        vm.isClaudeActive = true

        vm.receiveOutput(Data([0x24, 0x20]))
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertFalse(vm.awaitingInput, "Should not trigger at 1.2s when Claude threshold is 2s")

        try await Task.sleep(for: .milliseconds(1000))
        XCTAssertTrue(vm.awaitingInput, "Should trigger after 2s+ total")
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
}
