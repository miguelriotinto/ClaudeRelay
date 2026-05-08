import XCTest
import ClaudeRelaySpeech

final class WhisperHallucinationTests: XCTestCase {

    // MARK: - Known hallucinations

    func testThankYouIsHallucination() {
        XCTAssertTrue(WhisperTranscriber.isSilenceHallucination("Thank you"))
    }

    func testThanksForWatchingIsHallucination() {
        XCTAssertTrue(WhisperTranscriber.isSilenceHallucination("Thanks for watching!"))
    }

    func testByeIsHallucination() {
        XCTAssertTrue(WhisperTranscriber.isSilenceHallucination("Bye."))
    }

    func testSubscribeIsHallucination() {
        XCTAssertTrue(WhisperTranscriber.isSilenceHallucination("Subscribe"))
    }

    func testOkayIsHallucination() {
        XCTAssertTrue(WhisperTranscriber.isSilenceHallucination("Okay"))
    }

    func testHmmIsHallucination() {
        XCTAssertTrue(WhisperTranscriber.isSilenceHallucination("Hmm"))
    }

    // MARK: - Case insensitivity & punctuation

    func testCaseInsensitive() {
        XCTAssertTrue(WhisperTranscriber.isSilenceHallucination("THANK YOU"))
        XCTAssertTrue(WhisperTranscriber.isSilenceHallucination("Thank You"))
    }

    func testPunctuationStripped() {
        XCTAssertTrue(WhisperTranscriber.isSilenceHallucination("Thank you!"))
        XCTAssertTrue(WhisperTranscriber.isSilenceHallucination("Bye..."))
        XCTAssertTrue(WhisperTranscriber.isSilenceHallucination("Subscribe!"))
    }

    // MARK: - Normal text is NOT hallucination

    func testNormalTextNotHallucination() {
        XCTAssertFalse(WhisperTranscriber.isSilenceHallucination("Fix the login bug"))
    }

    func testLongerTextNotHallucination() {
        XCTAssertFalse(WhisperTranscriber.isSilenceHallucination("I want to build a feature that lets users subscribe to notifications"))
    }

    func testEmptyStringNotHallucination() {
        XCTAssertFalse(WhisperTranscriber.isSilenceHallucination(""))
    }

    func testWhitespaceOnlyNotHallucination() {
        XCTAssertFalse(WhisperTranscriber.isSilenceHallucination("   "))
    }
}
