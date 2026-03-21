import Foundation

/// Messages sent from the client to the server.
public enum ClientMessage: Equatable, Sendable {
    case authRequest(token: String)
    case sessionCreate
    case sessionAttach(sessionId: UUID)
    case sessionResume(sessionId: UUID)
    case sessionDetach
    case sessionList
    case resize(cols: UInt16, rows: UInt16)
    case ping

    // MARK: - Wire type strings

    public var typeString: String {
        switch self {
        case .authRequest:    return "auth_request"
        case .sessionCreate:  return "session_create"
        case .sessionAttach:  return "session_attach"
        case .sessionResume:  return "session_resume"
        case .sessionDetach:  return "session_detach"
        case .sessionList:    return "session_list"
        case .resize:         return "resize"
        case .ping:           return "ping"
        }
    }

    // MARK: - Known type strings

    static let allTypeStrings: Set<String> = [
        "auth_request", "session_create", "session_attach",
        "session_resume", "session_detach", "session_list", "resize", "ping",
    ]
}

// MARK: - Codable

extension ClientMessage: Codable {
    private enum PayloadCodingKeys: String, CodingKey {
        case token, sessionId, cols, rows
    }

    public func encodePayload(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: PayloadCodingKeys.self)
        switch self {
        case .authRequest(let token):
            try container.encode(token, forKey: .token)
        case .sessionCreate:
            break
        case .sessionAttach(let sessionId):
            try container.encode(sessionId, forKey: .sessionId)
        case .sessionResume(let sessionId):
            try container.encode(sessionId, forKey: .sessionId)
        case .sessionDetach:
            break
        case .sessionList:
            break
        case .resize(let cols, let rows):
            try container.encode(cols, forKey: .cols)
            try container.encode(rows, forKey: .rows)
        case .ping:
            break
        }
    }

    public static func decode(typeString: String, from decoder: Decoder) throws -> ClientMessage {
        let container = try decoder.container(keyedBy: PayloadCodingKeys.self)
        switch typeString {
        case "auth_request":
            let token = try container.decode(String.self, forKey: .token)
            return .authRequest(token: token)
        case "session_create":
            return .sessionCreate
        case "session_attach":
            let sessionId = try container.decode(UUID.self, forKey: .sessionId)
            return .sessionAttach(sessionId: sessionId)
        case "session_resume":
            let sessionId = try container.decode(UUID.self, forKey: .sessionId)
            return .sessionResume(sessionId: sessionId)
        case "session_detach":
            return .sessionDetach
        case "session_list":
            return .sessionList
        case "resize":
            let cols = try container.decode(UInt16.self, forKey: .cols)
            let rows = try container.decode(UInt16.self, forKey: .rows)
            return .resize(cols: cols, rows: rows)
        case "ping":
            return .ping
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Unknown client message type: \(typeString)"
                )
            )
        }
    }

    // Default Codable conformance delegates through MessageEnvelope.
    // These are here to satisfy the protocol but envelope is the primary entry point.
    public func encode(to encoder: Encoder) throws {
        try encodePayload(to: encoder)
    }

    public init(from decoder: Decoder) throws {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "ClientMessage must be decoded via MessageEnvelope"
            )
        )
    }
}
