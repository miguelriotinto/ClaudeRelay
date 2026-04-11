import XCTest
@testable import ClaudeRelayKit

final class ActivityStateTests: XCTestCase {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    func testAllCasesRoundTrip() throws {
        let cases: [ActivityState] = [.active, .idle, .claudeActive, .claudeIdle]
        for state in cases {
            let data = try encoder.encode(state)
            let decoded = try decoder.decode(ActivityState.self, from: data)
            XCTAssertEqual(state, decoded, "Round-trip failed for \(state)")
        }
    }

    func testRawValues() {
        XCTAssertEqual(ActivityState.active.rawValue, "active")
        XCTAssertEqual(ActivityState.idle.rawValue, "idle")
        XCTAssertEqual(ActivityState.claudeActive.rawValue, "claude_active")
        XCTAssertEqual(ActivityState.claudeIdle.rawValue, "claude_idle")
    }

    func testDecodesFromJSON() throws {
        let json = #""claude_idle""#
        let decoded = try decoder.decode(ActivityState.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, .claudeIdle)
    }

    func testEquatable() {
        XCTAssertEqual(ActivityState.active, ActivityState.active)
        XCTAssertNotEqual(ActivityState.active, ActivityState.idle)
        XCTAssertNotEqual(ActivityState.claudeActive, ActivityState.claudeIdle)
    }

    func testIsClaudeRunning() {
        XCTAssertFalse(ActivityState.active.isClaudeRunning)
        XCTAssertFalse(ActivityState.idle.isClaudeRunning)
        XCTAssertTrue(ActivityState.claudeActive.isClaudeRunning)
        XCTAssertTrue(ActivityState.claudeIdle.isClaudeRunning)
    }

    func testIsAwaitingInput() {
        XCTAssertFalse(ActivityState.active.isAwaitingInput)
        XCTAssertTrue(ActivityState.idle.isAwaitingInput)
        XCTAssertFalse(ActivityState.claudeActive.isAwaitingInput)
        XCTAssertTrue(ActivityState.claudeIdle.isAwaitingInput)
    }
}
