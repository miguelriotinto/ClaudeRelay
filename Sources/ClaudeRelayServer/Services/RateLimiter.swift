import Foundation

// MARK: - RateLimiter

/// Tracks failed authentication attempts per IP address and blocks IPs that
/// exceed the threshold within a rolling time window. Capped at
/// `maxTrackedIPs` with LRU eviction to prevent unbounded memory growth
/// under sustained scanning traffic.
/// In-memory only; all state resets on process restart.
public actor RateLimiter {
    private struct Entry {
        var timestamps: [Date]
        var lastAccess: Date
    }

    private var attempts: [String: Entry] = [:]
    private let maxAttempts: Int
    private let windowSeconds: TimeInterval
    private let maxTrackedIPs: Int

    // MARK: - Init

    public init(maxAttempts: Int = 5,
                windowSeconds: TimeInterval = 60,
                maxTrackedIPs: Int = 10_000) {
        self.maxAttempts = maxAttempts
        self.windowSeconds = windowSeconds
        self.maxTrackedIPs = maxTrackedIPs
    }

    // MARK: - Public API

    /// Record a failed authentication attempt for the given IP.
    /// Returns `true` if the IP should now be blocked (threshold reached).
    @discardableResult
    public func recordFailure(ip: String) -> Bool {
        cleanup(ip: ip)
        var entry = attempts[ip] ?? Entry(timestamps: [], lastAccess: Date())
        entry.timestamps.append(Date())
        entry.lastAccess = Date()
        attempts[ip] = entry
        evictIfNeeded()
        return entry.timestamps.count >= maxAttempts
    }

    /// Check whether the given IP is currently blocked. Touches `lastAccess`
    /// as a side effect so actively-checked IPs don't get LRU-evicted out
    /// from under an ongoing auth attempt.
    public func isBlocked(ip: String) -> Bool {
        cleanup(ip: ip)
        if var entry = attempts[ip] {
            entry.lastAccess = Date()
            attempts[ip] = entry
            return entry.timestamps.count >= maxAttempts
        }
        return false
    }

    /// Reset tracking for an IP (e.g. after a successful auth).
    public func reset(ip: String) {
        attempts.removeValue(forKey: ip)
    }

    // MARK: - Private

    /// Remove timestamps outside the current rolling window.
    private func cleanup(ip: String) {
        guard var entry = attempts[ip] else { return }
        let cutoff = Date().addingTimeInterval(-windowSeconds)
        // Timestamps are appended chronologically, so drop from the front.
        while let first = entry.timestamps.first, first < cutoff {
            entry.timestamps.removeFirst()
        }
        if entry.timestamps.isEmpty {
            attempts.removeValue(forKey: ip)
        } else {
            attempts[ip] = entry
        }
    }

    /// If we're at or above the eviction threshold, drop the oldest 10% by
    /// `lastAccess`. The threshold is `maxTrackedIPs * 1.1` (10% headroom) so
    /// each sort+evict amortizes over ~maxTrackedIPs/10 insertions instead of
    /// firing on every single failure past the soft cap.
    private func evictIfNeeded() {
        let evictCount = max(1, maxTrackedIPs / 10)
        guard attempts.count > maxTrackedIPs + evictCount else { return }
        let sorted = attempts.sorted { $0.value.lastAccess < $1.value.lastAccess }
        for (ip, _) in sorted.prefix(evictCount) {
            attempts.removeValue(forKey: ip)
        }
    }

    // MARK: - Test Hooks

    /// Exposed only for tests. Do not call from production code.
    public var _testOnly_trackedIPCount: Int { attempts.count }
}
