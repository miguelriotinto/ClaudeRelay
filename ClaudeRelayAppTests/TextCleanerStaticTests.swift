import XCTest
@testable import ClaudeRelayApp

final class TextCleanerStaticTests: XCTestCase {

    func testBuildCleanupPromptContainsInput() {
        let prompt = TextCleaner.buildCleanupPrompt(for: "hello world")
        XCTAssertTrue(prompt.contains("hello world"))
    }

    func testSanitizeResponseStripsThinkBlocks() {
        let input = "<think>reasoning here</think>Clean output"
        let result = TextCleaner.sanitizeResponse(input)
        XCTAssertEqual(result, "Clean output")
    }

    func testSanitizeResponsePreservesNormalText() {
        let input = "Normal transcription output."
        let result = TextCleaner.sanitizeResponse(input)
        XCTAssertEqual(result, "Normal transcription output.")
    }

    func testSanitizeResponseTrimsWhitespace() {
        let input = "  \n  some text  \n  "
        let result = TextCleaner.sanitizeResponse(input)
        XCTAssertEqual(result, "some text")
    }

    func testSanitizeResponseStripsMultipleThinkBlocks() {
        let input = "<think>a</think>hello <think>b</think>world"
        let result = TextCleaner.sanitizeResponse(input)
        XCTAssertEqual(result, "hello world")
    }
}
