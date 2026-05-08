import XCTest
@testable import ClaudeRelaySpeech

final class ContinuousListeningStateTests: XCTestCase {

    func testIsActiveReturnsFalseForIdle() {
        XCTAssertFalse(ContinuousListeningState.idle.isActive)
    }

    func testIsActiveReturnsTrueForListening() {
        XCTAssertTrue(ContinuousListeningState.listening.isActive)
    }

    func testIsActiveReturnsTrueForRecording() {
        XCTAssertTrue(ContinuousListeningState.recording.isActive)
    }

    func testIsCapturingReturnsTrueForRecording() {
        XCTAssertTrue(ContinuousListeningState.recording.isCapturing)
    }

    func testIsCapturingReturnsTrueForDetectingTurnEnd() {
        XCTAssertTrue(ContinuousListeningState.detectingTurnEnd.isCapturing)
    }

    func testIsCapturingReturnsFalseForListening() {
        XCTAssertFalse(ContinuousListeningState.listening.isCapturing)
    }

    func testErrorEquality() {
        XCTAssertEqual(
            ContinuousListeningState.error("fail"),
            ContinuousListeningState.error("fail")
        )
        XCTAssertNotEqual(
            ContinuousListeningState.error("a"),
            ContinuousListeningState.error("b")
        )
    }
}
