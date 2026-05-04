import XCTest
@testable import ClaudeRelayClient
@testable import ClaudeRelayKit

@MainActor
final class RelayConnectionTests: XCTestCase {

    func testInitialStateIsDisconnected() {
        let connection = RelayConnection()
        XCTAssertEqual(connection.state, .disconnected)
    }

    func testDisconnectFromDisconnectedIsNoOp() {
        let connection = RelayConnection()
        connection.disconnect()
        XCTAssertEqual(connection.state, .disconnected)
    }

    func testIsAliveReturnsFalseWhenDisconnected() async {
        let connection = RelayConnection()
        let alive = await connection.isAlive()
        XCTAssertFalse(alive)
    }

    func testCallbacksAreNilByDefault() {
        let connection = RelayConnection()
        XCTAssertNil(connection.onTerminalOutput)
        XCTAssertNil(connection.onSessionActivity)
        XCTAssertNil(connection.onSessionStolen)
        XCTAssertNil(connection.onSessionRenamed)
        XCTAssertNil(connection.onSendFailed)
    }

    // MARK: - Force Reconnect

    func testForceReconnectWithoutConfigThrowsNotConnected() async {
        let connection = RelayConnection()

        do {
            try await connection.forceReconnect()
            XCTFail("Expected notConnected error")
        } catch let error as RelayConnection.ConnectionError {
            if case .notConnected = error {
                // expected
            } else {
                XCTFail("Expected notConnected, got \(error)")
            }
        } catch {
            XCTFail("Expected ConnectionError, got \(error)")
        }
    }

    // MARK: - Generation Tracking

    func testGenerationStartsAtZero() {
        let connection = RelayConnection()
        XCTAssertEqual(connection.generation, 0)
    }

    // MARK: - Disconnect Resets State

    func testDisconnectResetsQualityToDisconnected() {
        let connection = RelayConnection()
        connection.disconnect()
        XCTAssertEqual(connection.connectionQuality, .disconnected)
    }

    // MARK: - Send Without Connection

    func testSendThrowsWhenDisconnected() async {
        let connection = RelayConnection()

        do {
            try await connection.send(.ping)
            XCTFail("Expected notConnected error")
        } catch let error as RelayConnection.ConnectionError {
            if case .notConnected = error {
                // expected
            } else {
                XCTFail("Expected notConnected, got \(error)")
            }
        } catch {
            XCTFail("Expected ConnectionError, got \(error)")
        }
    }

    func testSendBinaryThrowsWhenDisconnected() async {
        let connection = RelayConnection()

        do {
            try await connection.sendBinary(Data([0x00, 0x01]))
            XCTFail("Expected notConnected error")
        } catch let error as RelayConnection.ConnectionError {
            if case .notConnected = error {
                // expected
            } else {
                XCTFail("Expected notConnected, got \(error)")
            }
        } catch {
            XCTFail("Expected ConnectionError, got \(error)")
        }
    }

    func testSendResizeThrowsWhenDisconnected() async {
        let connection = RelayConnection()

        do {
            try await connection.sendResize(cols: 80, rows: 24)
            XCTFail("Expected notConnected error")
        } catch let error as RelayConnection.ConnectionError {
            if case .notConnected = error {
                // expected
            } else {
                XCTFail("Expected notConnected, got \(error)")
            }
        } catch {
            XCTFail("Expected ConnectionError, got \(error)")
        }
    }

    // MARK: - Error Descriptions

    func testConnectionErrorDescriptions() {
        let notConnected = RelayConnection.ConnectionError.notConnected
        XCTAssertNotNil(notConnected.errorDescription)
        XCTAssertTrue(notConnected.errorDescription!.contains("Not connected"))

        let encodingFailed = RelayConnection.ConnectionError.encodingFailed
        XCTAssertNotNil(encodingFailed.errorDescription)
        XCTAssertTrue(encodingFailed.errorDescription!.contains("encode"))

        let invalid = RelayConnection.ConnectionError.invalidMessage("bad frame")
        XCTAssertNotNil(invalid.errorDescription)
        XCTAssertTrue(invalid.errorDescription!.contains("bad frame"))
    }

    // MARK: - Multiple Disconnects

    func testMultipleDisconnectsAreIdempotent() {
        let connection = RelayConnection()
        connection.disconnect()
        connection.disconnect()
        connection.disconnect()
        XCTAssertEqual(connection.state, .disconnected)
        XCTAssertEqual(connection.connectionQuality, .disconnected)
    }

    // MARK: - RTT Window Boundedness

    @MainActor
    func testRTTWindowStaysBoundedUnderRepeatedMeasurePingRTT() async {
        let connection = RelayConnection()
        // Call recordRTT 100 times via the test hook. Without the cap
        // being inside recordRTT, this would grow unbounded.
        for i in 0..<100 {
            connection._testOnly_recordRTT(rtt: i % 2 == 0 ? 0.05 : nil)
        }
        XCTAssertLessThanOrEqual(connection._testOnly_rttWindowCount, 6,
            "rttWindow must be bounded to windowSize (6)")
    }
}

// MARK: - SessionController Tests

@MainActor
final class SessionControllerTests: XCTestCase {

    // MARK: - Auth State

    func testIsAuthValidInitiallyFalse() {
        let connection = RelayConnection()
        let controller = SessionController(connection: connection)
        XCTAssertFalse(controller.isAuthValid)
    }

    func testResetAuthClearsState() {
        let connection = RelayConnection()
        let controller = SessionController(connection: connection)
        controller.resetAuth()
        XCTAssertFalse(controller.isAuthenticated)
        XCTAssertNil(controller.sessionId)
    }

    func testIsAuthValidFalseAfterReset() {
        let connection = RelayConnection()
        let controller = SessionController(connection: connection)
        controller.resetAuth()
        XCTAssertFalse(controller.isAuthValid)
    }

    // MARK: - Error Classification

    func testSessionErrorIsNotAuthenticatedDetection() {
        let notAuth = SessionController.SessionError.unexpectedResponse("Not authenticated")
        XCTAssertTrue(notAuth.isNotAuthenticated)

        let notAuthCase = SessionController.SessionError.unexpectedResponse("not authenticated yet")
        XCTAssertTrue(notAuthCase.isNotAuthenticated)

        let other = SessionController.SessionError.unexpectedResponse("Session not found")
        XCTAssertFalse(other.isNotAuthenticated)

        let authFailed = SessionController.SessionError.authenticationFailed(reason: "bad token")
        XCTAssertFalse(authFailed.isNotAuthenticated)

        let timeout = SessionController.SessionError.timeout
        XCTAssertFalse(timeout.isNotAuthenticated)
    }

    // MARK: - Error Descriptions

    func testSessionErrorDescriptions() {
        let authFailed = SessionController.SessionError.authenticationFailed(reason: "invalid token")
        XCTAssertNotNil(authFailed.errorDescription)
        XCTAssertTrue(authFailed.errorDescription!.contains("invalid token"))

        let versionMismatch = SessionController.SessionError.versionIncompatible(clientVersion: 1, serverVersion: 0)
        XCTAssertNotNil(versionMismatch.errorDescription)
        XCTAssertTrue(versionMismatch.errorDescription!.contains("not compatible"))

        let unexpected = SessionController.SessionError.unexpectedResponse("weird_type")
        XCTAssertNotNil(unexpected.errorDescription)
        XCTAssertTrue(unexpected.errorDescription!.contains("weird_type"))

        let timeout = SessionController.SessionError.timeout
        XCTAssertNotNil(timeout.errorDescription)
        XCTAssertTrue(timeout.errorDescription!.contains("timed out"))
    }

    // MARK: - Generation Staleness

    func testAuthenticatedGenerationTracksConnectionGeneration() {
        let connection = RelayConnection()
        let controller = SessionController(connection: connection)
        XCTAssertEqual(controller.authenticatedGeneration, 0)
        XCTAssertEqual(connection.generation, 0)
    }
}

// MARK: - ConnectionConfig Tests

final class ConnectionConfigTests: XCTestCase {

    func testWSURLPlaintext() {
        let config = ConnectionConfig(name: "Test", host: "192.168.1.1", port: 9200)
        XCTAssertEqual(config.wsURL?.absoluteString, "ws://192.168.1.1:9200")
    }

    func testWSURLWithTLS() {
        let config = ConnectionConfig(name: "Test", host: "relay.example.com", port: 443, useTLS: true)
        XCTAssertEqual(config.wsURL?.absoluteString, "wss://relay.example.com:443")
    }

    func testDefaultPort() {
        let config = ConnectionConfig(name: "Test", host: "localhost")
        XCTAssertEqual(config.port, 9200)
    }

    func testCodableRoundTrip() throws {
        let original = ConnectionConfig(name: "Dev Server", host: "10.0.0.1", port: 8080, useTLS: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConnectionConfig.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.host, original.host)
        XCTAssertEqual(decoded.port, original.port)
        XCTAssertEqual(decoded.useTLS, original.useTLS)
    }
}

// MARK: - ConnectionQuality Tests

final class ConnectionQualityTests: XCTestCase {

    func testExcellentQuality() {
        let quality = ConnectionQuality(medianRTT: 0.05, successRate: 1.0)
        XCTAssertEqual(quality, .excellent)
    }

    func testGoodQuality() {
        let quality = ConnectionQuality(medianRTT: 0.2, successRate: 0.9)
        XCTAssertEqual(quality, .good)
    }

    func testPoorQuality() {
        let quality = ConnectionQuality(medianRTT: 0.5, successRate: 0.6)
        XCTAssertEqual(quality, .poor)
    }

    func testVeryPoorFromHighRTT() {
        let quality = ConnectionQuality(medianRTT: 1.0, successRate: 0.9)
        XCTAssertEqual(quality, .veryPoor)
    }

    func testVeryPoorFromLowSuccessRate() {
        let quality = ConnectionQuality(medianRTT: 0.05, successRate: 0.3)
        XCTAssertEqual(quality, .veryPoor)
    }

    func testBoundaryExcellentRequiresFullSuccess() {
        let notQuite = ConnectionQuality(medianRTT: 0.05, successRate: 0.99)
        XCTAssertNotEqual(notQuite, .excellent)
    }
}
