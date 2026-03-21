import XCTest
@testable import CodeRelayServer
@testable import CodeRelayKit

final class ConfigManagerTests: XCTestCase {

    func testLoadReturnsDefaultWhenNoFile() throws {
        let config = try ConfigManager.load()
        // If no custom config exists, should return defaults
        XCTAssertEqual(config.wsPort, 9200)
        XCTAssertEqual(config.adminPort, 9100)
        XCTAssertEqual(config.detachTimeout, 1800)
        XCTAssertEqual(config.scrollbackSize, 65536)
        XCTAssertEqual(config.logLevel, "info")
        XCTAssertNil(config.tlsCert)
        XCTAssertNil(config.tlsKey)
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
        XCTAssertEqual(config.detachTimeout, 1800)
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
