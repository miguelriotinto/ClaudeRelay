import Foundation

/// Messages sent from the server to the client.
public enum ServerMessage: Equatable, Sendable {
    case authSuccess
    case authFailure(reason: String)
    case sessionCreated(sessionId: UUID, cols: UInt16, rows: UInt16)
    case sessionAttached(sessionId: UUID, state: String)
    case sessionResumed(sessionId: UUID)
    case sessionDetached
    case sessionTerminated(sessionId: UUID, reason: String)
    case sessionExpired(sessionId: UUID)
    case sessionState(sessionId: UUID, state: String)
    case resizeAck(cols: UInt16, rows: UInt16)
    case pong
    case error(code: Int, message: String)

    // MARK: - Wire type strings

    public var typeString: String {
        switch self {
        case .authSuccess:         return "auth_success"
        case .authFailure:         return "auth_failure"
        case .sessionCreated:      return "session_created"
        case .sessionAttached:     return "session_attached"
        case .sessionResumed:      return "session_resumed"
        case .sessionDetached:     return "session_detached"
        case .sessionTerminated:   return "session_terminated"
        case .sessionExpired:      return "session_expired"
        case .sessionState:        return "session_state"
        case .resizeAck:           return "resize_ack"
        case .pong:                return "pong"
        case .error:               return "error"
        }
    }

    // MARK: - Known type strings

    static let allTypeStrings: Set<String> = [
        "auth_success", "auth_failure", "session_created", "session_attached",
        "session_resumed", "session_detached", "session_terminated",
        "session_expired", "session_state", "resize_ack", "pong", "error",
    ]
}

// MARK: - Codable

extension ServerMessage: Codable {
    private enum PayloadCodingKeys: String, CodingKey {
        case reason, sessionId, cols, rows, state, code, message
    }

    public func encodePayload(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: PayloadCodingKeys.self)
        switch self {
        case .authSuccess:
            break
        case .authFailure(let reason):
            try container.encode(reason, forKey: .reason)
        case .sessionCreated(let sessionId, let cols, let rows):
            try container.encode(sessionId, forKey: .sessionId)
            try container.encode(cols, forKey: .cols)
            try container.encode(rows, forKey: .rows)
        case .sessionAttached(let sessionId, let state):
            try container.encode(sessionId, forKey: .sessionId)
            try container.encode(state, forKey: .state)
        case .sessionResumed(let sessionId):
            try container.encode(sessionId, forKey: .sessionId)
        case .sessionDetached:
            break
        case .sessionTerminated(let sessionId, let reason):
            try container.encode(sessionId, forKey: .sessionId)
            try container.encode(reason, forKey: .reason)
        case .sessionExpired(let sessionId):
            try container.encode(sessionId, forKey: .sessionId)
        case .sessionState(let sessionId, let state):
            try container.encode(sessionId, forKey: .sessionId)
            try container.encode(state, forKey: .state)
        case .resizeAck(let cols, let rows):
            try container.encode(cols, forKey: .cols)
            try container.encode(rows, forKey: .rows)
        case .pong:
            break
        case .error(let code, let message):
            try container.encode(code, forKey: .code)
            try container.encode(message, forKey: .message)
        }
    }

    public static func decode(typeString: String, from decoder: Decoder) throws -> ServerMessage {
        let container = try decoder.container(keyedBy: PayloadCodingKeys.self)
        switch typeString {
        case "auth_success":
            return .authSuccess
        case "auth_failure":
            let reason = try container.decode(String.self, forKey: .reason)
            return .authFailure(reason: reason)
        case "session_created":
            let sessionId = try container.decode(UUID.self, forKey: .sessionId)
            let cols = try container.decode(UInt16.self, forKey: .cols)
            let rows = try container.decode(UInt16.self, forKey: .rows)
            return .sessionCreated(sessionId: sessionId, cols: cols, rows: rows)
        case "session_attached":
            let sessionId = try container.decode(UUID.self, forKey: .sessionId)
            let state = try container.decode(String.self, forKey: .state)
            return .sessionAttached(sessionId: sessionId, state: state)
        case "session_resumed":
            let sessionId = try container.decode(UUID.self, forKey: .sessionId)
            return .sessionResumed(sessionId: sessionId)
        case "session_detached":
            return .sessionDetached
        case "session_terminated":
            let sessionId = try container.decode(UUID.self, forKey: .sessionId)
            let reason = try container.decode(String.self, forKey: .reason)
            return .sessionTerminated(sessionId: sessionId, reason: reason)
        case "session_expired":
            let sessionId = try container.decode(UUID.self, forKey: .sessionId)
            return .sessionExpired(sessionId: sessionId)
        case "session_state":
            let sessionId = try container.decode(UUID.self, forKey: .sessionId)
            let state = try container.decode(String.self, forKey: .state)
            return .sessionState(sessionId: sessionId, state: state)
        case "resize_ack":
            let cols = try container.decode(UInt16.self, forKey: .cols)
            let rows = try container.decode(UInt16.self, forKey: .rows)
            return .resizeAck(cols: cols, rows: rows)
        case "pong":
            return .pong
        case "error":
            let code = try container.decode(Int.self, forKey: .code)
            let message = try container.decode(String.self, forKey: .message)
            return .error(code: code, message: message)
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Unknown server message type: \(typeString)"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        try encodePayload(to: encoder)
    }

    public init(from decoder: Decoder) throws {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "ServerMessage must be decoded via MessageEnvelope"
            )
        )
    }
}
