import XCTest
@testable import ClaudeRelayApp

final class TextCleanerStaticTests: XCTestCase {

    func testBuildCleanupPromptContainsInput() {
        let prompt = TextCleaner.buildCleanupPrompt(for: "hello world")
        XCTAssertTrue(prompt.contains("hello world"))
        XCTAssertTrue(prompt.contains("Clean this transcription"))
    }

    func testBuildCleanupPromptWithPromptEnhancement() {
        let prompt = TextCleaner.buildCleanupPrompt(for: "hello world", promptEnhancement: true)
        XCTAssertTrue(prompt.contains("hello world"))
        XCTAssertTrue(prompt.contains("Claude Code prompt"))
    }

    func testBuildCleanupPromptDefaultIsFalse() {
        let defaultPrompt = TextCleaner.buildCleanupPrompt(for: "test")
        let explicitFalse = TextCleaner.buildCleanupPrompt(for: "test", promptEnhancement: false)
        XCTAssertEqual(defaultPrompt, explicitFalse)
    }

    func testLooksHallucinatedDetectsCodeFences() {
        XCTAssertTrue(TextCleaner.looksHallucinated(input: "hello", output: "```swift\nprint(\"hi\")\n```"))
    }

    func testLooksHallucinatedDetectsHTML() {
        XCTAssertTrue(TextCleaner.looksHallucinated(input: "hello", output: "<div class=\"container\">stuff</div>"))
    }

    func testLooksHallucinatedAllowsNormalOutput() {
        XCTAssertFalse(TextCleaner.looksHallucinated(input: "fix the login bug", output: "Fix the login bug."))
    }

    func testLooksHallucinatedDetectsExpansion() {
        let short = "hello"
        let long = String(repeating: "generated content ", count: 20)
        XCTAssertTrue(TextCleaner.looksHallucinated(input: short, output: long))
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
