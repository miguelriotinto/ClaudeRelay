import XCTest
@testable import ClaudeRelayKit

final class ConnectionQualityTests: XCTestCase {

    // MARK: - Classification

    func testExcellentRequiresPerfectSuccessAndLowRTT() {
        let q = ConnectionQuality(medianRTT: 0.05, successRate: 1.0)
        XCTAssertEqual(q, .excellent)
    }

    func testGoodQuality() {
        let q = ConnectionQuality(medianRTT: 0.15, successRate: 0.9)
        XCTAssertEqual(q, .good)
    }

    func testPoorQuality() {
        let q = ConnectionQuality(medianRTT: 0.5, successRate: 0.6)
        XCTAssertEqual(q, .poor)
    }

    func testVeryPoorOnHighRTT() {
        let q = ConnectionQuality(medianRTT: 1.0, successRate: 0.9)
        XCTAssertEqual(q, .veryPoor)
    }

    func testVeryPoorOnLowSuccessRate() {
        let q = ConnectionQuality(medianRTT: 0.05, successRate: 0.4)
        XCTAssertEqual(q, .veryPoor)
    }

    // MARK: - Boundary: RTT thresholds

    func testBoundaryRTTAt100ms() {
        // RTT exactly at 0.1 is NOT < 0.1, so not excellent even with perfect success
        let q = ConnectionQuality(medianRTT: 0.1, successRate: 1.0)
        XCTAssertEqual(q, .good, "RTT == 0.1 should be good, not excellent (requires < 0.1)")
    }

    func testBoundaryRTTJustBelow100ms() {
        let q = ConnectionQuality(medianRTT: 0.099, successRate: 1.0)
        XCTAssertEqual(q, .excellent)
    }

    func testBoundaryRTTAt300ms() {
        // RTT exactly 0.3 is NOT < 0.3, so not good
        let q = ConnectionQuality(medianRTT: 0.3, successRate: 0.9)
        XCTAssertEqual(q, .poor, "RTT == 0.3 should be poor, not good (requires < 0.3)")
    }

    func testBoundaryRTTAt800ms() {
        // RTT exactly 0.8 is NOT < 0.8, so not poor → veryPoor
        let q = ConnectionQuality(medianRTT: 0.8, successRate: 0.6)
        XCTAssertEqual(q, .veryPoor, "RTT == 0.8 should be veryPoor (requires < 0.8)")
    }

    // MARK: - Boundary: success rate thresholds

    func testExcellentRequiresPerfectSuccess() {
        // RTT well below 100ms but success < 1.0 → good (not excellent)
        let q = ConnectionQuality(medianRTT: 0.02, successRate: 0.99)
        XCTAssertEqual(q, .good, "Excellent requires successRate >= 1.0")
    }

    func testGoodSuccessRateBoundary() {
        // Success exactly 0.83 with good RTT → good
        let q = ConnectionQuality(medianRTT: 0.15, successRate: 0.83)
        XCTAssertEqual(q, .good)
    }

    func testGoodSuccessRateJustBelow() {
        // Success just below 0.83 → poor (not good)
        let q = ConnectionQuality(medianRTT: 0.15, successRate: 0.829)
        XCTAssertEqual(q, .poor)
    }

    func testMinSuccessRateBoundary() {
        // Success exactly 0.5 → poor (still >= 0.5)
        let q = ConnectionQuality(medianRTT: 0.5, successRate: 0.5)
        XCTAssertEqual(q, .poor)
    }

    func testBelowMinSuccessRate() {
        // Success below 0.5 → veryPoor regardless of RTT
        let q = ConnectionQuality(medianRTT: 0.01, successRate: 0.49)
        XCTAssertEqual(q, .veryPoor)
    }

    // MARK: - Edge cases

    func testZeroRTTPerfectSuccess() {
        let q = ConnectionQuality(medianRTT: 0.0, successRate: 1.0)
        XCTAssertEqual(q, .excellent)
    }

    func testZeroSuccessRate() {
        let q = ConnectionQuality(medianRTT: 0.01, successRate: 0.0)
        XCTAssertEqual(q, .veryPoor)
    }

    func testDisconnectedNotReturnedByInit() {
        // .disconnected is never assigned by the init — it's set externally
        let worstCase = ConnectionQuality(medianRTT: 100.0, successRate: 0.0)
        XCTAssertEqual(worstCase, .veryPoor)
        XCTAssertNotEqual(worstCase, .disconnected)
    }

    // MARK: - Raw values

    func testRawValues() {
        XCTAssertEqual(ConnectionQuality.excellent.rawValue, "excellent")
        XCTAssertEqual(ConnectionQuality.good.rawValue, "good")
        XCTAssertEqual(ConnectionQuality.poor.rawValue, "poor")
        XCTAssertEqual(ConnectionQuality.veryPoor.rawValue, "veryPoor")
        XCTAssertEqual(ConnectionQuality.disconnected.rawValue, "disconnected")
    }
}
