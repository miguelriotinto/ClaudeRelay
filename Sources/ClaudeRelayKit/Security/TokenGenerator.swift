import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Security

// MARK: - Data Extension

extension Data {
    /// Base64URL encoding without padding (RFC 4648 Section 5).
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - TokenGenerator

/// Generates cryptographically secure API tokens and provides hashing/validation utilities.
public enum TokenGenerator {

    /// Generates a new random token and its associated `TokenInfo`.
    ///
    /// - Parameter label: Optional human-readable label for the token.
    /// - Returns: A tuple of the plaintext token (43 chars, base64URL) and its `TokenInfo`.
    public static func generate(label: String? = nil) -> (plaintext: String, info: TokenInfo) {
        // 32 cryptographically secure random bytes
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "Failed to generate random bytes")

        // Base64URL encode (no padding) -> 43 characters
        let plaintext = Data(bytes).base64URLEncodedString()

        // SHA-256 hash of the plaintext
        let tokenHash = hash(plaintext)

        // Short ID from UUID
        let id = String(UUID().uuidString.prefix(8)).lowercased()

        let info = TokenInfo(
            id: id,
            tokenHash: tokenHash,
            label: label,
            createdAt: Date()
        )

        return (plaintext, info)
    }

    /// Computes the SHA-256 hex digest of a token string.
    ///
    /// - Parameter token: The plaintext token.
    /// - Returns: Lowercase hex-encoded SHA-256 hash.
    public static func hash(_ token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Validates a plaintext token against a stored hash.
    ///
    /// - Parameters:
    ///   - token: The plaintext token to validate.
    ///   - storedHash: The previously stored SHA-256 hex hash.
    /// - Returns: `true` if the token matches the stored hash.
    public static func validate(_ token: String, against storedHash: String) -> Bool {
        hash(token) == storedHash
    }
}
