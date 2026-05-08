import XCTest
@testable import ClaudeRelaySpeech

private final class StubTranscriber: SpeechTranscribing {
    var result: String = ""
    var shouldThrow: Bool = false

    func transcribe(_ audioBuffer: [Float]) async throws -> String {
        if shouldThrow { throw TranscriberError.emptyTranscription }
        return result
    }
}

@MainActor
final class WakeWordDetectorTests: XCTestCase {

    func testExactMatchSucceeds() async {
        let stub = StubTranscriber()
        stub.result = "claude list my files"
        let detector = WakeWordDetector(transcriber: stub, keyword: "claude")

        detector.feedAudio(Array(repeating: Float(0.2), count: 16000))
        let result = await detector.checkForWakeWord()

        switch result {
        case .detected(let residueText):
            XCTAssertEqual(residueText.trimmingCharacters(in: .whitespaces), "list my files")
        default:
            XCTFail("Expected detected result, got \(result)")
        }
    }

    func testEditDistanceOneMatches() async {
        let stub = StubTranscriber()
        stub.result = "claud tell me a joke"  // missing 'e'
        let detector = WakeWordDetector(transcriber: stub, keyword: "claude")

        detector.feedAudio(Array(repeating: Float(0.2), count: 16000))
        let result = await detector.checkForWakeWord()

        if case .detected = result { /* ok */ } else {
            XCTFail("Expected fuzzy match for 'claud' to succeed")
        }
    }

    func testEditDistanceTwoDoesNotMatch() async {
        let stub = StubTranscriber()
        stub.result = "clubs tell me a joke"  // 2+ edits from 'claude'
        let detector = WakeWordDetector(transcriber: stub, keyword: "claude")

        detector.feedAudio(Array(repeating: Float(0.2), count: 16000))
        let result = await detector.checkForWakeWord()

        if case .notDetected = result { /* ok */ } else {
            XCTFail("Expected non-match for 'clubs'")
        }
    }

    func testWakeWordMustAppearAtStart() async {
        let stub = StubTranscriber()
        stub.result = "hey there claude open a file"  // wake word in middle
        let detector = WakeWordDetector(transcriber: stub, keyword: "claude")

        detector.feedAudio(Array(repeating: Float(0.2), count: 16000))
        let result = await detector.checkForWakeWord()

        if case .notDetected = result { /* ok */ } else {
            XCTFail("Wake word in the middle should not trigger")
        }
    }

    func testCaseInsensitiveMatch() async {
        let stub = StubTranscriber()
        stub.result = "CLAUDE show status"
        let detector = WakeWordDetector(transcriber: stub, keyword: "claude")

        detector.feedAudio(Array(repeating: Float(0.2), count: 16000))
        let result = await detector.checkForWakeWord()

        if case .detected = result { /* ok */ } else {
            XCTFail("Expected case-insensitive match")
        }
    }

    func testEmptyTranscriptionReturnsNotDetected() async {
        let stub = StubTranscriber()
        stub.shouldThrow = true
        let detector = WakeWordDetector(transcriber: stub, keyword: "claude")

        detector.feedAudio(Array(repeating: Float(0.2), count: 16000))
        let result = await detector.checkForWakeWord()

        if case .transcriptionFailed = result { /* ok */ } else {
            XCTFail("Expected transcriptionFailed on thrown error")
        }
    }

    func testEditDistanceOnBaseWord() {
        // Pure helper test — no async. Classic Levenshtein distances.
        XCTAssertEqual(WakeWordDetector.levenshtein("claude", "claude"), 0)
        XCTAssertEqual(WakeWordDetector.levenshtein("claude", "claud"), 1)
        // cloud: sub a→o, delete e = 2 ops
        XCTAssertEqual(WakeWordDetector.levenshtein("claude", "cloud"), 2)
        // clawed: sub u→w, sub d→e, sub e→d = 3 ops
        XCTAssertEqual(WakeWordDetector.levenshtein("claude", "clawed"), 3)
        XCTAssertEqual(WakeWordDetector.levenshtein("claude", "clubs"), 3)
    }

    func testResetClearsAudio() async {
        let stub = StubTranscriber()
        stub.result = "claude do a thing"
        let detector = WakeWordDetector(transcriber: stub, keyword: "claude")

        detector.feedAudio(Array(repeating: Float(0.2), count: 16000))
        detector.reset()

        let result = await detector.checkForWakeWord()
        if case .notDetected = result { /* ok — no audio to transcribe */ } else {
            XCTFail("Expected notDetected after reset")
        }
    }
}
