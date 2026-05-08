import XCTest
@testable import ClaudeRelaySpeech

@MainActor
final class ContinuousListeningEngineTests: XCTestCase {

    private func makeEngine(
        vad: MockVAD = MockVAD(),
        turnEnd: MockTurnEndDetector = MockTurnEndDetector(),
        transcriber: StubSpeechTranscriber = StubSpeechTranscriber(),
        cleaner: StubTextCleaner = StubTextCleaner(),
        audioSource: NoopAudioSource = NoopAudioSource()
    ) -> ContinuousListeningEngine {
        ContinuousListeningEngine(
            vad: vad,
            wakeWordDetector: WakeWordDetector(transcriber: transcriber, keyword: "claude"),
            turnEndDetector: turnEnd,
            transcriber: transcriber,
            cleaner: cleaner,
            audioSource: audioSource
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

    // MARK: - End-to-end

    func testFullPipelineDeliversCleanedText() async {
        let vad = MockVAD()
        let transcriber = StubSpeechTranscriber()
        transcriber.result = "claude list my files"
        let cleaner = StubTextCleaner()
        cleaner.result = "List my files"
        let turnEnd = MockTurnEndDetector()
        turnEnd.resultToReturn = .speakerDone(confidence: 0.95)

        let engine = makeEngine(
            vad: vad,
            turnEnd: turnEnd,
            transcriber: transcriber,
            cleaner: cleaner
        )
        await engine.enable()

        var delivered: String?
        engine.onUtteranceReady = { text in delivered = text }

        // Simulate: speechStart → speechContinue → silenceStart
        vad.eventsToReturn = [.speechStart, .speechContinue, .silenceStart]
        for _ in 0..<3 {
            await engine.ingest(chunk: Array(repeating: Float(0.3), count: 480))
        }
        // After wake-word check → turn-end → transcription → cleanup, await each stage.
        await engine.waitForPendingWork()
        await engine.waitForPendingWork()
        await engine.waitForPendingWork()

        XCTAssertEqual(delivered, "List my files")
        XCTAssertEqual(engine.state, .listening)
    }

    func testSpeakerContinuingKeepsRecording() async {
        let vad = MockVAD()
        let transcriber = StubSpeechTranscriber()
        transcriber.result = "claude open the door"
        let turnEnd = MockTurnEndDetector()
        turnEnd.resultToReturn = .speakerContinuing(confidence: 0.8)

        let engine = makeEngine(vad: vad, turnEnd: turnEnd, transcriber: transcriber)
        await engine.enable()

        vad.eventsToReturn = [.speechStart, .silenceStart]
        await engine.ingest(chunk: Array(repeating: Float(0.3), count: 480))
        await engine.ingest(chunk: Array(repeating: Float(0.1), count: 480))
        await engine.waitForPendingWork()
        // runTurnEndCheck fires a new pendingTask; await it.
        await engine.waitForPendingWork()

        XCTAssertEqual(engine.state, .recording)
    }

    func testDisableCancelsInflightWork() async {
        let vad = MockVAD()
        let transcriber = StubSpeechTranscriber()
        transcriber.result = "claude"
        let engine = makeEngine(vad: vad, transcriber: transcriber)
        await engine.enable()

        vad.eventsToReturn = [.speechStart, .silenceStart]
        await engine.ingest(chunk: Array(repeating: Float(0.3), count: 480))
        await engine.ingest(chunk: Array(repeating: Float(0.1), count: 480))
        // Disable immediately, before pending task completes
        await engine.disable()

        XCTAssertEqual(engine.state, .idle)
    }

    func testEnableStartsAudioSource() async {
        let source = NoopAudioSource()
        let engine = makeEngine(audioSource: source)
        await engine.enable()
        XCTAssertEqual(source.startCallCount, 1)
        XCTAssertEqual(source.stopCallCount, 0)
    }

    func testDisableStopsAudioSource() async {
        let source = NoopAudioSource()
        let engine = makeEngine(audioSource: source)
        await engine.enable()
        await engine.disable()
        XCTAssertEqual(source.startCallCount, 1)
        XCTAssertEqual(source.stopCallCount, 1)
    }
}
