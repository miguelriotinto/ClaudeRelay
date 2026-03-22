import Foundation

/// Thread-safe in-memory log store for the admin API `/logs` endpoint.
/// Uses NSLock for synchronous access from NIO event loops without requiring `await`.
public final class LogStore: @unchecked Sendable {
    private var entries: [String] = []
    private let maxEntries: Int
    private let lock = NSLock()

    private static let timestampFormatter: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()

    public init(maxEntries: Int = 2000) {
        self.maxEntries = maxEntries
    }

    /// Append a log entry with automatic timestamp prefix.
    public func append(level: String = "info", category: String, message: String) {
        let timestamp = Self.timestampFormatter.string(from: Date())
        let entry = "[\(timestamp)] [\(level.uppercased())] [\(category)] \(message)"
        lock.lock()
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        lock.unlock()
    }

    /// Return the most recent `count` entries.
    public func recent(count: Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(entries.suffix(count))
    }
}
