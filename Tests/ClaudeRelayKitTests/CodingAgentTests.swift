import XCTest
@testable import ClaudeRelayKit

final class CodingAgentTests: XCTestCase {

    // MARK: - Process Name Matching

    func testClaudeExactMatch() {
        XCTAssertTrue(CodingAgent.claude.matchesProcessName("claude"))
    }

    func testClaudePrefixMatch() {
        XCTAssertTrue(CodingAgent.claude.matchesProcessName("claude-code"))
    }

    func testClaudeCaseInsensitive() {
        XCTAssertTrue(CodingAgent.claude.matchesProcessName("Claude"))
    }

    func testClaudeNoFalsePositive() {
        XCTAssertFalse(CodingAgent.claude.matchesProcessName("claudette"))
    }

    func testCodexExactMatch() {
        XCTAssertTrue(CodingAgent.codex.matchesProcessName("codex"))
    }

    func testCodexPrefixMatch() {
        XCTAssertTrue(CodingAgent.codex.matchesProcessName("codex-cli"))
    }

    func testCodexDoesNotMatchClaude() {
        XCTAssertFalse(CodingAgent.codex.matchesProcessName("claude"))
    }

    // MARK: - Title Matching

    func testClaudeTitleMatch() {
        XCTAssertTrue(CodingAgent.claude.matchesTitle("~/project — Claude Code"))
    }

    func testClaudeTitleCaseInsensitive() {
        XCTAssertTrue(CodingAgent.claude.matchesTitle("CLAUDE running"))
    }

    func testCodexTitleMatch() {
        XCTAssertTrue(CodingAgent.codex.matchesTitle("Codex session"))
    }

    func testUnrelatedTitle() {
        XCTAssertFalse(CodingAgent.claude.matchesTitle("vim editor"))
        XCTAssertFalse(CodingAgent.codex.matchesTitle("vim editor"))
    }

    // MARK: - Registry Lookups

    func testFindById() {
        XCTAssertEqual(CodingAgent.find(id: "claude"), .claude)
        XCTAssertEqual(CodingAgent.find(id: "codex"), .codex)
        XCTAssertNil(CodingAgent.find(id: "unknown"))
    }

    func testMatchingProcessName() {
        XCTAssertEqual(CodingAgent.matching(processName: "claude"), .claude)
        XCTAssertEqual(CodingAgent.matching(processName: "codex"), .codex)
        XCTAssertNil(CodingAgent.matching(processName: "vim"))
    }

    func testMatchingTitle() {
        XCTAssertEqual(CodingAgent.matching(title: "Claude Code — ~/project"), .claude)
        XCTAssertEqual(CodingAgent.matching(title: "codex interactive"), .codex)
        XCTAssertNil(CodingAgent.matching(title: "zsh"))
    }

    func testRegistryPriorityOrderMatters() {
        // If a title contains both keywords, first registered agent wins.
        // This is a deliberate design: .claude is first in .all.
        let agent = CodingAgent.matching(title: "claude and codex")
        XCTAssertEqual(agent, .claude)
    }
}
