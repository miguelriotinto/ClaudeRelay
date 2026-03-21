import XCTest
@testable import ClaudeRelayKit

final class TokenGeneratorTests: XCTestCase {

    // MARK: - Token Generation

    func testGeneratedTokenIs43Characters() {
        let (plaintext, _) = TokenGenerator.generate()
        XCTAssertEqual(plaintext.count, 43, "Token should be 43 characters (32 bytes base64url no padding)")
    }

    func testGeneratedTokenIsBase64URL() {
        let (plaintext, _) = TokenGenerator.generate()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        for scalar in plaintext.unicodeScalars {
            XCTAssertTrue(allowed.contains(scalar), "Character '\(scalar)' is not valid base64URL")
        }
    }

    // MARK: - Hashing

    func testHashIsDeterministic() {
        let input = "test-token-value"
        let hash1 = TokenGenerator.hash(input)
        let hash2 = TokenGenerator.hash(input)
        XCTAssertEqual(hash1, hash2, "Hash should be deterministic")
    }

    func testDifferentTokensProduceDifferentHashes() {
        let hash1 = TokenGenerator.hash("token-one")
        let hash2 = TokenGenerator.hash("token-two")
        XCTAssertNotEqual(hash1, hash2, "Different tokens should produce different hashes")
    }

    func testGenerateProducesMatchingHash() {
        let (plaintext, info) = TokenGenerator.generate()
        let expectedHash = TokenGenerator.hash(plaintext)
        XCTAssertEqual(info.tokenHash, expectedHash, "TokenInfo hash should match hash of plaintext")
    }

    // MARK: - Validation

    func testValidatePositive() {
        let (plaintext, info) = TokenGenerator.generate()
        XCTAssertTrue(TokenGenerator.validate(plaintext, against: info.tokenHash), "Should validate correct token")
    }

    func testValidateNegative() {
        let (_, info) = TokenGenerator.generate()
        XCTAssertFalse(TokenGenerator.validate("wrong-token", against: info.tokenHash), "Should reject wrong token")
    }

    // MARK: - TokenInfo Codable

    func testTokenInfoCodableRoundTrip() throws {
        let (_, info) = TokenGenerator.generate(label: "my-label")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(info)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TokenInfo.self, from: data)

        XCTAssertEqual(decoded.id, info.id)
        XCTAssertEqual(decoded.tokenHash, info.tokenHash)
        XCTAssertEqual(decoded.label, info.label)
        XCTAssertEqual(decoded.label, "my-label")
        XCTAssertEqual(
            decoded.createdAt.timeIntervalSinceReferenceDate,
            info.createdAt.timeIntervalSinceReferenceDate,
            accuracy: 1.0
        )
        XCTAssertNil(decoded.lastUsedAt)
    }

    // MARK: - Uniqueness

    func testHundredGeneratedTokensAreUnique() {
        var tokens = Set<String>()
        for _ in 0..<100 {
            let (plaintext, _) = TokenGenerator.generate()
            tokens.insert(plaintext)
        }
        XCTAssertEqual(tokens.count, 100, "All 100 generated tokens should be unique")
    }
}
