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

    // MARK: - VAD-driven transitions

    func testSpeechStartTransitionsToDetectingWakeWord() async {
        let vad = MockVAD()
        let transcriber = StubSpeechTranscriber()
        transcriber.result = ""   // no wake word
        let engine = makeEngine(vad: vad, transcriber: transcriber)
        await engine.enable()

        vad.eventsToReturn = [.speechStart]
        await engine.ingest(chunk: Array(repeating: Float(0.3), count: 480))

        XCTAssertEqual(engine.state, .detectingWakeWord)
    }

    func testNoWakeWordReturnsToListening() async {
        let vad = MockVAD()
        let transcriber = StubSpeechTranscriber()
        transcriber.result = "hello there"
        let engine = makeEngine(vad: vad, transcriber: transcriber)
        await engine.enable()

        vad.eventsToReturn = [.speechStart, .speechContinue, .silenceStart]
        for _ in 0..<3 {
            await engine.ingest(chunk: Array(repeating: Float(0.3), count: 480))
        }
        await engine.waitForPendingWork()

        XCTAssertEqual(engine.state, .listening)
    }

    func testWakeWordTransitionsOutOfDetectingWakeWord() async {
        let vad = MockVAD()
        let transcriber = StubSpeechTranscriber()
        transcriber.result = "claude open a file"
        let engine = makeEngine(vad: vad, transcriber: transcriber)
        await engine.enable()

        vad.eventsToReturn = [.speechStart, .speechContinue, .silenceStart]
        for _ in 0..<3 {
            await engine.ingest(chunk: Array(repeating: Float(0.3), count: 480))
        }
        await engine.waitForPendingWork()
        await engine.waitForPendingWork()
        await engine.waitForPendingWork()

        // After wake-word detection → turn-end → transcription → cleaning → output,
        // the engine should converge back to .listening.
        XCTAssertEqual(engine.state, .listening)
    }
}
