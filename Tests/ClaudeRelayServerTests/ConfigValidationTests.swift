import XCTest
@testable import ClaudeRelayKit
@testable import ClaudeRelayServer

final class ConfigValidationTests: XCTestCase {

    // MARK: - Port Validation

    func testValidPorts() throws {
        var config = RelayConfig.default
        try AdminRoutes.applyConfigValue(1024, forKey: "wsPort", to: &config)
        XCTAssertEqual(config.wsPort, 1024)
        try AdminRoutes.applyConfigValue(9200, forKey: "wsPort", to: &config)
        XCTAssertEqual(config.wsPort, 9200)
        try AdminRoutes.applyConfigValue(65535, forKey: "adminPort", to: &config)
        XCTAssertEqual(config.adminPort, 65535)
    }

    func testPortTooLow() {
        var config = RelayConfig.default
        XCTAssertThrowsError(try AdminRoutes.applyConfigValue(1023, forKey: "wsPort", to: &config))
        XCTAssertThrowsError(try AdminRoutes.applyConfigValue(80, forKey: "wsPort", to: &config))
        XCTAssertThrowsError(try AdminRoutes.applyConfigValue(0, forKey: "adminPort", to: &config))
    }

    func testPortTooHigh() {
        var config = RelayConfig.default
        XCTAssertThrowsError(try AdminRoutes.applyConfigValue(65536, forKey: "wsPort", to: &config))
        XCTAssertThrowsError(try AdminRoutes.applyConfigValue(99999, forKey: "adminPort", to: &config))
    }

    // MARK: - Scrollback Size Validation

    func testValidScrollbackSize() throws {
        var config = RelayConfig.default
        try AdminRoutes.applyConfigValue(1024, forKey: "scrollbackSize", to: &config)
        XCTAssertEqual(config.scrollbackSize, 1024)
        try AdminRoutes.applyConfigValue(1_000_000, forKey: "scrollbackSize", to: &config)
        XCTAssertEqual(config.scrollbackSize, 1_000_000)
    }

    func testScrollbackSizeTooSmall() {
        var config = RelayConfig.default
        XCTAssertThrowsError(try AdminRoutes.applyConfigValue(0, forKey: "scrollbackSize", to: &config))
        XCTAssertThrowsError(try AdminRoutes.applyConfigValue(1023, forKey: "scrollbackSize", to: &config))
        XCTAssertThrowsError(try AdminRoutes.applyConfigValue(-1, forKey: "scrollbackSize", to: &config))
    }

    // MARK: - Detach Timeout Validation

    func testValidDetachTimeout() throws {
        var config = RelayConfig.default
        try AdminRoutes.applyConfigValue(0, forKey: "detachTimeout", to: &config)
        XCTAssertEqual(config.detachTimeout, 0)
        try AdminRoutes.applyConfigValue(3600, forKey: "detachTimeout", to: &config)
        XCTAssertEqual(config.detachTimeout, 3600)
    }

    func testNegativeDetachTimeout() {
        var config = RelayConfig.default
        XCTAssertThrowsError(try AdminRoutes.applyConfigValue(-1, forKey: "detachTimeout", to: &config))
        XCTAssertThrowsError(try AdminRoutes.applyConfigValue(-100, forKey: "detachTimeout", to: &config))
    }

    // MARK: - Log Level Validation

    func testValidLogLevels() throws {
        var config = RelayConfig.default
        for level in ["trace", "debug", "info", "warning", "error"] {
            try AdminRoutes.applyConfigValue(level, forKey: "logLevel", to: &config)
            XCTAssertEqual(config.logLevel, level)
        }
    }

    func testInvalidLogLevel() {
        var config = RelayConfig.default
        XCTAssertThrowsError(try AdminRoutes.applyConfigValue("invalid", forKey: "logLevel", to: &config))
        XCTAssertThrowsError(try AdminRoutes.applyConfigValue("TRACE", forKey: "logLevel", to: &config))
        XCTAssertThrowsError(try AdminRoutes.applyConfigValue("", forKey: "logLevel", to: &config))
    }

    // MARK: - Unknown Key

    func testUnknownConfigKey() {
        var config = RelayConfig.default
        XCTAssertThrowsError(try AdminRoutes.applyConfigValue("value", forKey: "nonexistent", to: &config))
    }

    // MARK: - Type Mismatch

    func testTypeMismatch() {
        var config = RelayConfig.default
        XCTAssertThrowsError(try AdminRoutes.applyConfigValue("notAnInt", forKey: "wsPort", to: &config))
        XCTAssertThrowsError(try AdminRoutes.applyConfigValue(42, forKey: "logLevel", to: &config))
    }
}
