import Foundation

/// A wire-format envelope that wraps either a `ClientMessage` or `ServerMessage`.
///
/// Encodes to: `{"type":"<message_type>","payload":{...}}`
public enum MessageEnvelope: Equatable, Sendable {
    case client(ClientMessage)
    case server(ServerMessage)
}

// MARK: - Codable

extension MessageEnvelope: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, payload
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .client(let message):
            try container.encode(message.typeString, forKey: .type)
            try container.encode(message, forKey: .payload)
        case .server(let message):
            try container.encode(message.typeString, forKey: .type)
            try container.encode(message, forKey: .payload)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let typeString = try container.decode(String.self, forKey: .type)

        if ClientMessage.allTypeStrings.contains(typeString) {
            let payloadDecoder = try container.superDecoder(forKey: .payload)
            let message = try ClientMessage.decode(typeString: typeString, from: payloadDecoder)
            self = .client(message)
        } else if ServerMessage.allTypeStrings.contains(typeString) {
            let payloadDecoder = try container.superDecoder(forKey: .payload)
            let message = try ServerMessage.decode(typeString: typeString, from: payloadDecoder)
            self = .server(message)
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown message type: \(typeString)"
            )
        }
    }
}
