import Foundation

/// Manages loading and saving of RelayConfig from disk.
public final class ConfigManager: Sendable {

    private static let sharedDecoder = JSONDecoder()
    private static let sharedEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    /// Load config from ~/.claude-relay/config.json, or return defaults if not found.
    public static func load() throws -> RelayConfig {
        let configFile = RelayConfig.configFile
        let fm = FileManager.default

        guard fm.fileExists(atPath: configFile.path) else {
            return RelayConfig.default
        }

        let data = try Data(contentsOf: configFile)
        return try sharedDecoder.decode(RelayConfig.self, from: data)
    }

    /// Save config to ~/.claude-relay/config.json.
    public static func save(_ config: RelayConfig) throws {
        try ensureDirectory()
        let data = try sharedEncoder.encode(config)
        try data.write(to: RelayConfig.configFile, options: .atomic)
    }

    /// Create ~/.claude-relay/ directory if it doesn't exist.
    public static func ensureDirectory() throws {
        let dir = RelayConfig.configDirectory
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
