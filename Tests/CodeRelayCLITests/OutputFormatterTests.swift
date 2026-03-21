import XCTest
@testable import CodeRelayCLI

final class OutputFormatterTests: XCTestCase {

    // MARK: - JSON Format

    func testJSONFormat() throws {
        struct Sample: Codable {
            let name: String
            let count: Int
        }
        let sample = Sample(name: "test", count: 42)
        let result = OutputFormatter.formatJSON(sample)

        // Verify it's valid JSON by decoding it back
        let data = result.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Sample.self, from: data)
        XCTAssertEqual(decoded.name, "test")
        XCTAssertEqual(decoded.count, 42)
    }

    // MARK: - Human Status

    func testHumanStatusRunning() {
        let output = OutputFormatter.formatStatus(
            running: true,
            pid: 12345,
            uptime: 3661,
            sessions: 3
        )
        XCTAssertTrue(output.contains("Running"), "Should indicate Running")
        XCTAssertTrue(output.contains("12345"), "Should contain the PID")
        XCTAssertTrue(output.contains("3"), "Should contain session count")
    }

    func testHumanStatusStopped() {
        let output = OutputFormatter.formatStatus(
            running: false,
            pid: nil,
            uptime: nil,
            sessions: 0
        )
        XCTAssertTrue(output.contains("Stopped"), "Should indicate Stopped")
    }

    // MARK: - Table Format

    func testTableFormat() {
        let headers = ["ID", "Name", "Status"]
        let rows = [
            ["1", "alpha", "active"],
            ["2", "beta", "inactive"],
        ]
        let output = OutputFormatter.formatTable(headers: headers, rows: rows)

        // Verify headers present
        XCTAssertTrue(output.contains("ID"))
        XCTAssertTrue(output.contains("Name"))
        XCTAssertTrue(output.contains("Status"))

        // Verify rows present
        XCTAssertTrue(output.contains("alpha"))
        XCTAssertTrue(output.contains("beta"))
        XCTAssertTrue(output.contains("active"))
        XCTAssertTrue(output.contains("inactive"))

        // Verify alignment: each line should have the same structure
        let lines = output.split(separator: "\n")
        // Header + separator + 2 data rows = at least 4 lines
        XCTAssertGreaterThanOrEqual(lines.count, 4)
    }

    func testTableFormatEmpty() {
        let headers = ["Col1", "Col2"]
        let rows: [[String]] = []
        let output = OutputFormatter.formatTable(headers: headers, rows: rows)
        XCTAssertTrue(output.contains("Col1"))
        XCTAssertTrue(output.contains("Col2"))
    }

    // MARK: - Uptime Formatting

    func testUptimeSeconds() {
        let output = OutputFormatter.formatStatus(
            running: true, pid: 1, uptime: 45, sessions: 0
        )
        XCTAssertTrue(output.contains("45s"))
    }

    func testUptimeMinutes() {
        let output = OutputFormatter.formatStatus(
            running: true, pid: 1, uptime: 125, sessions: 0
        )
        XCTAssertTrue(output.contains("2m 5s"))
    }

    func testUptimeHours() {
        let output = OutputFormatter.formatStatus(
            running: true, pid: 1, uptime: 7265, sessions: 0
        )
        XCTAssertTrue(output.contains("2h 1m 5s"))
    }

    func testStatusWithNilUptime() {
        let output = OutputFormatter.formatStatus(
            running: true, pid: 999, uptime: nil, sessions: 2
        )
        XCTAssertFalse(output.contains("Uptime"), "Should not show uptime when nil")
        XCTAssertTrue(output.contains("999"))
        XCTAssertTrue(output.contains("2"))
    }

    // MARK: - Table Edge Cases

    func testTableFormatEmptyHeaders() {
        let output = OutputFormatter.formatTable(headers: [], rows: [])
        XCTAssertEqual(output, "")
    }

    func testTableFormatSingleColumn() {
        let output = OutputFormatter.formatTable(headers: ["Name"], rows: [["Alice"], ["Bob"]])
        XCTAssertTrue(output.contains("Alice"))
        XCTAssertTrue(output.contains("Bob"))
    }
}
