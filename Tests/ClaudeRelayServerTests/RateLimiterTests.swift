import XCTest
@testable import ClaudeRelayServer

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

    func testRateLimiterEvictsLRUEntries() async {
        // maxTrackedIPs=10 triggers eviction only above 11 (10 + 10/10 headroom).
        // Add 25 unique IPs and confirm the total is bounded well below 25.
        let limiter = RateLimiter(maxAttempts: 5, windowSeconds: 600, maxTrackedIPs: 10)

        for i in 0..<25 {
            await limiter.recordFailure(ip: "10.0.0.\(i)")
        }
        let count = await limiter._testOnly_trackedIPCount
        // We allow some slack because eviction only runs after crossing 11;
        // the count will hover in the 12-20 range depending on how the
        // amortization unfolds, but must never approach 25.
        XCTAssertLessThanOrEqual(count, 20, "LRU cap should keep the map well below the unlimited case")
        XCTAssertGreaterThanOrEqual(count, 10, "Should retain at least the configured capacity")

        // Most recent entry should still be tracked but not blocked (1 failure < 5 threshold).
        let blockedRecent = await limiter.isBlocked(ip: "10.0.0.24")
        XCTAssertFalse(blockedRecent, "Recent IP with single failure should not be blocked")
    }

    /// Regression test for the real-world "window expires" path, not just the
    /// 0-second degenerate case. Uses a 1-second window and waits past it to
    /// verify an IP becomes unblocked once its failure entries age out.
    func testIPUnblocksAfterWindowElapses() async {
        let limiter = RateLimiter(maxAttempts: 2, windowSeconds: 1, maxTrackedIPs: 100)
        await limiter.recordFailure(ip: "9.9.9.9")
        await limiter.recordFailure(ip: "9.9.9.9")
        let blockedInitially = await limiter.isBlocked(ip: "9.9.9.9")
        XCTAssertTrue(blockedInitially)

        try? await Task.sleep(for: .milliseconds(1100))
        let blockedAfterWait = await limiter.isBlocked(ip: "9.9.9.9")
        XCTAssertFalse(blockedAfterWait,
                       "IP should be released once the failure window has elapsed")
    }
}
