import XCTest
@testable import ClaudeRelaySpeech

@MainActor
final class ContinuousListeningEngineTests: XCTestCase {

    private func makeEngine(
        vad: MockVAD = MockVAD(),
        turnEnd: MockTurnEndDetector = MockTurnEndDetector(),
        transcriber: StubSpeechTranscriber = StubSpeechTranscriber(),
        cleaner: StubTextCleaner = StubTextCleaner()
    ) -> ContinuousListeningEngine {
        ContinuousListeningEngine(
            vad: vad,
            wakeWordDetector: WakeWordDetector(transcriber: transcriber, keyword: "claude"),
            turnEndDetector: turnEnd,
            transcriber: transcriber,
            cleaner: cleaner
        )
    }

    func testInitialStateIsIdle() {
        let engine = makeEngine()
        XCTAssertEqual(engine.state, .idle)
    }

    func testEnableTransitionsToListening() async {
        let engine = makeEngine()
        await engine.enable()
        XCTAssertEqual(engine.state, .listening)
    }

    func testDisableTransitionsToIdle() async {
        let engine = makeEngine()
        await engine.enable()
        await engine.disable()
        XCTAssertEqual(engine.state, .idle)
    }

    func testEnableTwiceIsNoOp() async {
        let engine = makeEngine()
        await engine.enable()
        await engine.enable()
        XCTAssertEqual(engine.state, .listening)
    }

    func testDisableFromIdleIsNoOp() async {
        let engine = makeEngine()
        await engine.disable()
        XCTAssertEqual(engine.state, .idle)
    }
}
