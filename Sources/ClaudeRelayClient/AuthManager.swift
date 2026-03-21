import Foundation
import Security

/// Keychain wrapper for storing authentication tokens associated with ClaudeRelay connections.
public final class AuthManager: Sendable {
    public static let shared = AuthManager()

    private let service = "com.coderemote.relay"

    public init() {}

    // MARK: - Public API

    /// Saves an authentication token to the Keychain for the given connection.
    public func saveToken(_ token: String, for connectionId: UUID) throws {
        guard let data = token.data(using: .utf8) else {
            throw AuthManagerError.encodingFailed
        }

        let account = connectionId.uuidString

        // Delete any existing entry first to avoid duplicates.
        try? deleteToken(for: connectionId)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AuthManagerError.keychainError(status: status)
        }
    }

    /// Loads an authentication token from the Keychain for the given connection.
    /// Returns `nil` if no token is stored.
    public func loadToken(for connectionId: UUID) throws -> String? {
        let account = connectionId.uuidString

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw AuthManagerError.keychainError(status: status)
        }

        guard let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw AuthManagerError.decodingFailed
        }

        return token
    }

    /// Deletes an authentication token from the Keychain for the given connection.
    public func deleteToken(for connectionId: UUID) throws {
        let account = connectionId.uuidString

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthManagerError.keychainError(status: status)
        }
    }
}

// MARK: - Errors

public enum AuthManagerError: Error, LocalizedError {
    case encodingFailed
    case decodingFailed
    case keychainError(status: OSStatus)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode token as UTF-8 data."
        case .decodingFailed:
            return "Failed to decode token from Keychain data."
        case .keychainError(let status):
            return "Keychain operation failed with status \(status)."
        }
    }
}
