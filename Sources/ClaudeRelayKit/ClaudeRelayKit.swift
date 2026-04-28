/// ClaudeRelayKit provides shared types and utilities for the ClaudeRelay system.
public enum ClaudeRelayKit {
    public static let version = "0.2.2"

    /// Current wire-protocol version. Bump when messages change in breaking ways.
    public static let protocolVersion = 1

    /// Oldest protocol version this build can communicate with.
    /// Keep at 0 until a breaking wire-protocol change forces older clients out.
    public static let minProtocolVersion = 0
}

/// Features that require coordinated iOS app + server updates.
///
/// Each case documents a capability and the protocol version that introduced it.
/// When adding a new wire-level feature:
/// 1. Add a case here with its `introducedIn` version.
/// 2. Bump `ClaudeRelayKit.protocolVersion`.
/// 3. If the feature is mandatory, bump `ClaudeRelayKit.minProtocolVersion`.
public enum ProtocolFeature: String, CaseIterable, Sendable {
    /// Baseline session CRUD, auth, resize, detach/resume.
    case sessionManagement
    /// Image paste via clipboard relay (paste_image / paste_image_result).
    case imagePaste
    /// Server-pushed activity state (sessionActivity messages).
    case activityMonitoring
    /// Cross-device session attach with steal notifications.
    case sessionSteal
    /// Session rename broadcast across devices.
    case sessionRename

    /// The protocol version that introduced this feature.
    public var introducedIn: Int {
        switch self {
        case .sessionManagement:  return 1
        case .imagePaste:         return 1
        case .activityMonitoring: return 1
        case .sessionSteal:       return 1
        case .sessionRename:      return 1
        }
    }

    /// Whether a peer at the given protocol version supports this feature.
    public func isSupported(byProtocolVersion peerVersion: Int) -> Bool {
        peerVersion >= introducedIn
    }
}
