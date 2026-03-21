import Foundation

// MARK: - RateLimiter

/// Tracks failed authentication attempts per IP address and blocks IPs that
/// exceed the threshold within a rolling time window.
/// In-memory only; all state resets on process restart.
public actor RateLimiter {
    private var attempts: [String: [Date]] = [:]
    private let maxAttempts: Int
    private let windowSeconds: TimeInterval

    // MARK: - Init

    public init(maxAttempts: Int = 5, windowSeconds: TimeInterval = 60) {
        self.maxAttempts = maxAttempts
        self.windowSeconds = windowSeconds
    }

    // MARK: - Public API

    /// Record a failed authentication attempt for the given IP.
    /// Returns `true` if the IP should now be blocked (threshold reached).
    @discardableResult
    public func recordFailure(ip: String) -> Bool {
        cleanup(ip: ip)
        attempts[ip, default: []].append(Date())
        return attempts[ip, default: []].count >= maxAttempts
    }

    /// Check whether the given IP is currently blocked.
    public func isBlocked(ip: String) -> Bool {
        cleanup(ip: ip)
        return (attempts[ip]?.count ?? 0) >= maxAttempts
    }

    /// Reset tracking for an IP (e.g. after a successful auth).
    public func reset(ip: String) {
        attempts.removeValue(forKey: ip)
    }

    // MARK: - Private

    /// Remove timestamps outside the current rolling window.
    private func cleanup(ip: String) {
        guard var timestamps = attempts[ip] else { return }
        let cutoff = Date().addingTimeInterval(-windowSeconds)
        timestamps.removeAll { $0 < cutoff }
        if timestamps.isEmpty {
            attempts.removeValue(forKey: ip)
        } else {
            attempts[ip] = timestamps
        }
    }
}
