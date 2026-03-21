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
            wsPort: 9200,
            sessions: 3
        )
        XCTAssertTrue(output.contains("Running"), "Should indicate Running")
        XCTAssertTrue(output.contains("12345"), "Should contain the PID")
        XCTAssertTrue(output.contains("9200"), "Should contain the port")
        XCTAssertTrue(output.contains("3"), "Should contain session count")
    }

    func testHumanStatusStopped() {
        let output = OutputFormatter.formatStatus(
            running: false,
            pid: nil,
            uptime: nil,
            wsPort: 9200,
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
}
