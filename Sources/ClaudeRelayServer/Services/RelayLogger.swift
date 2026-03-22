import os

// MARK: - RelayLogger

/// Structured logging facade for the ClaudeRelay server.
///
/// Categories:
///  - `connection` : WebSocket connect / disconnect events
///  - `session`    : Session state transitions and lifecycle
///  - `auth`       : Authentication attempts (NEVER log tokens)
///  - `admin`      : Admin API requests
///  - `server`     : Server lifecycle (start, stop)
///
/// Security: This logger must NEVER emit tokens, secrets, or raw terminal I/O.
public enum RelayLogger {
    private static let subsystem = "com.coderemote.relay"

    /// WebSocket connection events (open, close, error).
    public static let connection = Logger(subsystem: subsystem, category: "connection")

    /// Session lifecycle: creation, state transitions, expiry.
    public static let session = Logger(subsystem: subsystem, category: "session")

    /// Authentication: login attempts, failures, rate-limiting.
    /// NEVER log token values through this logger.
    public static let auth = Logger(subsystem: subsystem, category: "auth")

    /// Admin API: incoming requests, responses, errors.
    public static let admin = Logger(subsystem: subsystem, category: "admin")

    /// In-memory log store queryable via the admin `/logs` endpoint.
    public private(set) static var store = LogStore()

    /// Log to both os.Logger and the in-memory LogStore.
    public static func log(
        _ level: OSLogType = .info,
        category: String,
        _ message: String
    ) {
        let logger = Logger(subsystem: subsystem, category: category)
        logger.log(level: level, "\(message, privacy: .public)")

        let levelString: String
        switch level {
        case .debug: levelString = "debug"
        case .error: levelString = "error"
        case .fault: levelString = "fault"
        default: levelString = "info"
        }
        store.append(level: levelString, category: category, message: message)
    }
}
