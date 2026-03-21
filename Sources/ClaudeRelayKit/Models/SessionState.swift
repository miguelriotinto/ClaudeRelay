import Foundation

/// Represents the lifecycle state of a ClaudeRelay session.
public enum SessionState: String, Codable, Sendable {
    case created = "created"
    case starting = "starting"
    case activeAttached = "active-attached"
    case activeDetached = "active-detached"
    case resuming = "resuming"
    case exited = "exited"
    case failed = "failed"
    case terminated = "terminated"
    case expired = "expired"

    /// Whether this state is terminal (no further transitions allowed).
    public var isTerminal: Bool {
        switch self {
        case .exited, .failed, .terminated, .expired:
            return true
        default:
            return false
        }
    }

    /// Returns whether a transition from this state to the given target state is valid.
    public func canTransition(to target: SessionState) -> Bool {
        switch self {
        case .created:
            return target == .starting
        case .starting:
            return [.activeAttached, .failed].contains(target)
        case .activeAttached:
            return [.activeDetached, .exited, .failed, .terminated].contains(target)
        case .activeDetached:
            return [.resuming, .expired, .exited, .failed, .terminated].contains(target)
        case .resuming:
            return [.activeAttached, .failed, .terminated].contains(target)
        case .exited, .failed, .terminated, .expired:
            return false
        }
    }
}
