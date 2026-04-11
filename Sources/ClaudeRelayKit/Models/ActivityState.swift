import Foundation

/// Activity state of a terminal session, tracked by the server.
/// The server monitors PTY output continuously (even for detached sessions)
/// and pushes state changes to connected clients.
public enum ActivityState: String, Codable, Equatable, Sendable {
    /// Terminal output flowing, no Claude detected.
    case active = "active"
    /// No terminal output for the silence threshold, no Claude detected.
    case idle = "idle"
    /// Claude Code is running, terminal output flowing.
    case claudeActive = "claude_active"
    /// Claude Code is running, no output for the silence threshold (awaiting input).
    case claudeIdle = "claude_idle"

    /// Whether Claude Code is currently running in this session.
    public var isClaudeRunning: Bool {
        switch self {
        case .claudeActive, .claudeIdle: return true
        case .active, .idle: return false
        }
    }

    /// Whether the session appears to be waiting for user input.
    public var isAwaitingInput: Bool {
        switch self {
        case .idle, .claudeIdle: return true
        case .active, .claudeActive: return false
        }
    }
}
