import XCTest
@testable import ClaudeRelayServer
@testable import ClaudeRelayKit

final class ConfigManagerTests: XCTestCase {

    func testLoadSucceeds() throws {
        let config = try ConfigManager.load()
        // Verify config loads without error and has valid port values
        XCTAssertGreaterThan(config.wsPort, 0)
        XCTAssertGreaterThan(config.adminPort, 0)
        XCTAssertGreaterThanOrEqual(config.detachTimeout, 0)
        XCTAssertGreaterThan(config.scrollbackSize, 0)
        XCTAssertFalse(config.logLevel.isEmpty)
    }

    func testRelayConfigCodableRoundTrip() throws {
        let original = RelayConfig(
            wsPort: 8080,
            adminPort: 8081,
            detachTimeout: 600,
            scrollbackSize: 131072,
            tlsCert: "/path/to/cert.pem",
            tlsKey: "/path/to/key.pem",
            logLevel: "debug"
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(RelayConfig.self, from: data)

        XCTAssertEqual(decoded.wsPort, original.wsPort)
        XCTAssertEqual(decoded.adminPort, original.adminPort)
        XCTAssertEqual(decoded.detachTimeout, original.detachTimeout)
        XCTAssertEqual(decoded.scrollbackSize, original.scrollbackSize)
        XCTAssertEqual(decoded.tlsCert, original.tlsCert)
        XCTAssertEqual(decoded.tlsKey, original.tlsKey)
        XCTAssertEqual(decoded.logLevel, original.logLevel)
    }

    func testRelayConfigDefaultValues() {
        let config = RelayConfig.default
        XCTAssertEqual(config.wsPort, 9200)
        XCTAssertEqual(config.adminPort, 9100)
        XCTAssertEqual(config.detachTimeout, 0)
        XCTAssertFalse(config.bindAll, "New default: localhost-only bind")
    }

    func testBindAllCodableRoundTrip() throws {
        let original = RelayConfig(bindAll: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RelayConfig.self, from: data)
        XCTAssertTrue(decoded.bindAll)
    }

    /// Older configs on disk predate the bindAll key. Decoding must succeed
    /// and fall back to the safe default (localhost-only).
    func testLegacyConfigWithoutBindAllDecodesAsLocalhost() throws {
        let legacyJSON = """
        {"wsPort":9200,"adminPort":9100,"detachTimeout":0,"scrollbackSize":524288,"logLevel":"info","maxSessionsPerToken":50}
        """
        let decoded = try JSONDecoder().decode(RelayConfig.self, from: Data(legacyJSON.utf8))
        XCTAssertFalse(decoded.bindAll, "Missing key should default to localhost-only")
    }

    func testConfigDirectoryPath() {
        let dir = RelayConfig.configDirectory
        XCTAssertTrue(dir.path.hasSuffix(".claude-relay"))
    }

    func testConfigFilePath() {
        let file = RelayConfig.configFile
        XCTAssertTrue(file.path.hasSuffix("config.json"))
    }

    func testTokensFilePath() {
        let file = RelayConfig.tokensFile
        XCTAssertTrue(file.path.hasSuffix("tokens.json"))
    }
}
