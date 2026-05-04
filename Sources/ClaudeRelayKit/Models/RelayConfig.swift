import Foundation

/// Configuration model for the ClaudeRelay server.
public struct RelayConfig: Codable, Sendable {

    /// WebSocket listening port.
    public var wsPort: UInt16

    /// Admin API listening port.
    public var adminPort: UInt16

    /// Seconds before a detached session is reaped. 0 = never expire (default).
    public var detachTimeout: Int

    /// Maximum scrollback buffer size in bytes.
    public var scrollbackSize: Int

    /// Optional path to a TLS certificate file.
    public var tlsCert: String?

    /// Optional path to a TLS private-key file.
    public var tlsKey: String?

    /// Logging verbosity (e.g. "trace", "debug", "info", "warning", "error").
    public var logLevel: String

    /// Maximum active (non-terminal) sessions per token. 0 means unlimited.
    public var maxSessionsPerToken: Int

    // MARK: - Initializer

    public init(
        wsPort: UInt16 = 9200,
        adminPort: UInt16 = 9100,
        detachTimeout: Int = 0,
        scrollbackSize: Int = 524288,
        tlsCert: String? = nil,
        tlsKey: String? = nil,
        logLevel: String = "info",
        maxSessionsPerToken: Int = 50
    ) {
        self.wsPort = wsPort
        self.adminPort = adminPort
        self.detachTimeout = detachTimeout
        self.scrollbackSize = scrollbackSize
        self.tlsCert = tlsCert
        self.tlsKey = tlsKey
        self.logLevel = logLevel
        self.maxSessionsPerToken = maxSessionsPerToken
    }

    // MARK: - Static Properties

    /// An instance populated with all default values.
    public static let `default` = RelayConfig()

    /// The configuration directory: `~/.claude-relay/`.
    public static let configDirectory: URL = {
        #if os(iOS) || os(tvOS) || os(watchOS)
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent(".claude-relay", isDirectory: true)
        #else
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-relay", isDirectory: true)
        #endif
    }()

    /// The main configuration file: `~/.claude-relay/config.json`.
    public static let configFile: URL = configDirectory.appendingPathComponent("config.json")

    /// The tokens file: `~/.claude-relay/tokens.json`.
    public static let tokensFile: URL = configDirectory.appendingPathComponent("tokens.json")

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case wsPort, adminPort, detachTimeout, scrollbackSize
        case tlsCert, tlsKey, logLevel, maxSessionsPerToken
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.wsPort = try c.decodeIfPresent(UInt16.self, forKey: .wsPort) ?? 9200
        self.adminPort = try c.decodeIfPresent(UInt16.self, forKey: .adminPort) ?? 9100
        self.detachTimeout = try c.decodeIfPresent(Int.self, forKey: .detachTimeout) ?? 0
        self.scrollbackSize = try c.decodeIfPresent(Int.self, forKey: .scrollbackSize) ?? 524288
        self.tlsCert = try c.decodeIfPresent(String.self, forKey: .tlsCert)
        self.tlsKey = try c.decodeIfPresent(String.self, forKey: .tlsKey)
        self.logLevel = try c.decodeIfPresent(String.self, forKey: .logLevel) ?? "info"
        self.maxSessionsPerToken = try c.decodeIfPresent(Int.self, forKey: .maxSessionsPerToken) ?? 50
    }
}
