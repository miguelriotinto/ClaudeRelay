import XCTest
@testable import ClaudeRelayServer
@testable import ClaudeRelayKit

final class ConfigManagerTests: XCTestCase {

    func testLoadSucceeds() throws {
        let config = try ConfigManager.load()
        // Verify config loads without error and has valid port values
        XCTAssertGreaterThan(config.wsPort, 0)
        XCTAssertGreaterThan(config.adminPort, 0)
        XCTAssertGreaterThan(config.detachTimeout, 0)
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
