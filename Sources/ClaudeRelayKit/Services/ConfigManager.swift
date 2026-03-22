import Foundation

/// Manages loading and saving of RelayConfig from disk.
public final class ConfigManager: Sendable {

    /// Load config from ~/.claude-relay/config.json, or return defaults if not found.
    public static func load() throws -> RelayConfig {
        let configFile = RelayConfig.configFile
        let fm = FileManager.default

        guard fm.fileExists(atPath: configFile.path) else {
            return RelayConfig.default
        }

        let data = try Data(contentsOf: configFile)
        let decoder = JSONDecoder()
        return try decoder.decode(RelayConfig.self, from: data)
    }

    /// Save config to ~/.claude-relay/config.json.
    public static func save(_ config: RelayConfig) throws {
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
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
