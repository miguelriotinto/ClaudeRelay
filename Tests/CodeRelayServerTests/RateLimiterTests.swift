import XCTest
@testable import CodeRelayServer

final class RateLimiterTests: XCTestCase {

    func testAllowsUnderThreshold() async {
        let limiter = RateLimiter(maxAttempts: 3, windowSeconds: 60)
        let blocked1 = await limiter.recordFailure(ip: "1.2.3.4")
        XCTAssertFalse(blocked1, "Should not block after 1 failure")
        let blocked2 = await limiter.recordFailure(ip: "1.2.3.4")
        XCTAssertFalse(blocked2, "Should not block after 2 failures")
    }

    func testBlocksAtThreshold() async {
        let limiter = RateLimiter(maxAttempts: 3, windowSeconds: 60)
        await limiter.recordFailure(ip: "1.2.3.4")
        await limiter.recordFailure(ip: "1.2.3.4")
        let blocked = await limiter.recordFailure(ip: "1.2.3.4")
        XCTAssertTrue(blocked, "Should block at threshold")
    }

    func testIsBlockedReturnsTrueWhenBlocked() async {
        let limiter = RateLimiter(maxAttempts: 2, windowSeconds: 60)
        await limiter.recordFailure(ip: "10.0.0.1")
        await limiter.recordFailure(ip: "10.0.0.1")
        let blocked = await limiter.isBlocked(ip: "10.0.0.1")
        XCTAssertTrue(blocked)
    }

    func testIsBlockedReturnsFalseForUnknownIP() async {
        let limiter = RateLimiter(maxAttempts: 5, windowSeconds: 60)
        let blocked = await limiter.isBlocked(ip: "unknown")
        XCTAssertFalse(blocked)
    }

    func testResetClearsBlocking() async {
        let limiter = RateLimiter(maxAttempts: 2, windowSeconds: 60)
        await limiter.recordFailure(ip: "5.5.5.5")
        await limiter.recordFailure(ip: "5.5.5.5")
        let blockedBefore = await limiter.isBlocked(ip: "5.5.5.5")
        XCTAssertTrue(blockedBefore)

        await limiter.reset(ip: "5.5.5.5")
        let blockedAfter = await limiter.isBlocked(ip: "5.5.5.5")
        XCTAssertFalse(blockedAfter)
    }

    func testDifferentIPsAreIndependent() async {
        let limiter = RateLimiter(maxAttempts: 2, windowSeconds: 60)
        await limiter.recordFailure(ip: "A")
        await limiter.recordFailure(ip: "A")
        let blockedA = await limiter.isBlocked(ip: "A")
        let blockedB = await limiter.isBlocked(ip: "B")
        XCTAssertTrue(blockedA)
        XCTAssertFalse(blockedB)
    }

    func testWindowExpiry() async {
        // Use a 0-second window so entries expire immediately
        let limiter = RateLimiter(maxAttempts: 2, windowSeconds: 0)
        await limiter.recordFailure(ip: "X")
        await limiter.recordFailure(ip: "X")
        // After cleanup (triggered by isBlocked), entries should be expired
        let blocked = await limiter.isBlocked(ip: "X")
        XCTAssertFalse(blocked, "Should not be blocked after window expires")
    }
}
