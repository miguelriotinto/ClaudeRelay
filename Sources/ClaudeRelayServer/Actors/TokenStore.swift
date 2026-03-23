import Foundation
import ClaudeRelayKit

/// Manages token CRUD operations with JSON file persistence and file locking.
public actor TokenStore {

    // MARK: - Properties

    private let directory: URL
    private var filePath: URL { directory.appendingPathComponent("tokens.json") }
    private var tokens: [TokenInfo]?

    // MARK: - Errors

    public enum TokenStoreError: Error, LocalizedError {
        case tokenNotFound(id: String)
        case tokenExpired(id: String)

        public var errorDescription: String? {
            switch self {
            case .tokenNotFound(let id):
                return "Token with id '\(id)' not found."
            case .tokenExpired(let id):
                return "Token with id '\(id)' has expired."
            }
        }
    }

    // MARK: - Init

    public init(directory: URL) {
        self.directory = directory
    }

    // MARK: - Public API

    /// Generate a new token, persist it, and return the plaintext + info.
    public func create(label: String?, expiryDays: Int? = nil) throws -> (plaintext: String, info: TokenInfo) {
        let loaded = try ensureLoaded()
        let (plaintext, info) = TokenGenerator.generate(label: label, expiryDays: expiryDays)
        var mutable = loaded
        mutable.append(info)
        try save(mutable)
        tokens = mutable
        return (plaintext, info)
    }

    /// Validate a plaintext token against stored hashes. Updates `lastUsedAt` on match.
    /// Returns `nil` if the token is not found or has expired.
    public func validate(token: String) -> TokenInfo? {
        let loaded = (try? ensureLoaded()) ?? []
        let hash = TokenGenerator.hash(token)
        guard let index = loaded.firstIndex(where: { $0.tokenHash == hash }) else {
            return nil
        }
        if loaded[index].isExpired {
            return nil
        }
        var mutable = loaded
        mutable[index].lastUsedAt = Date()
        try? save(mutable)
        tokens = mutable
        return mutable[index]
    }

    /// Return all stored token infos.
    public func list() -> [TokenInfo] {
        (try? ensureLoaded()) ?? []
    }

    /// Remove a token by id.
    public func delete(id: String) throws {
        var loaded = try ensureLoaded()
        guard let index = loaded.firstIndex(where: { $0.id == id }) else {
            throw TokenStoreError.tokenNotFound(id: id)
        }
        loaded.remove(at: index)
        try save(loaded)
        tokens = loaded
    }

    /// Rotate a token: generate new plaintext/hash but keep id, label, createdAt.
    public func rotate(id: String) throws -> (plaintext: String, info: TokenInfo) {
        var loaded = try ensureLoaded()
        guard let index = loaded.firstIndex(where: { $0.id == id }) else {
            throw TokenStoreError.tokenNotFound(id: id)
        }
        let existing = loaded[index]
        let (newPlaintext, generated) = TokenGenerator.generate(label: existing.label)

        let rotated = TokenInfo(
            id: existing.id,
            tokenHash: generated.tokenHash,
            label: existing.label,
            createdAt: existing.createdAt,
            lastUsedAt: nil,
            expiresAt: existing.expiresAt
        )

        loaded[index] = rotated
        try save(loaded)
        tokens = loaded
        return (newPlaintext, rotated)
    }

    /// Rename a token's label.
    public func rename(id: String, label: String) throws -> TokenInfo {
        var loaded = try ensureLoaded()
        guard let index = loaded.firstIndex(where: { $0.id == id }) else {
            throw TokenStoreError.tokenNotFound(id: id)
        }
        loaded[index].label = label
        try save(loaded)
        tokens = loaded
        return loaded[index]
    }

    /// Return a single token info by id.
    public func inspect(id: String) throws -> TokenInfo {
        let loaded = try ensureLoaded()
        guard let info = loaded.first(where: { $0.id == id }) else {
            throw TokenStoreError.tokenNotFound(id: id)
        }
        return info
    }

    // MARK: - Private Helpers

    /// Lazy-load tokens from disk on first access.
    private func ensureLoaded() throws -> [TokenInfo] {
        if let tokens = tokens {
            return tokens
        }
        let loaded = try loadFromDisk()
        tokens = loaded
        return loaded
    }

    /// Read tokens from disk. Actor isolation guarantees single-threaded access.
    private func loadFromDisk() throws -> [TokenInfo] {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        guard fm.fileExists(atPath: filePath.path) else {
            return []
        }
        let data = try Data(contentsOf: filePath)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([TokenInfo].self, from: data)
    }

    /// Write tokens to disk atomically. Actor isolation guarantees single-threaded access.
    private func save(_ infos: [TokenInfo]) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(infos)
        try data.write(to: filePath, options: .atomic)
    }
}
