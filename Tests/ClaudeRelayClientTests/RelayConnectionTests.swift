import XCTest
@testable import ClaudeRelayClient

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
}

final class ConnectionConfigTests: XCTestCase {

    func testWSURLPlaintext() {
        let config = ConnectionConfig(name: "Test", host: "192.168.1.1", port: 9200)
        XCTAssertEqual(config.wsURL.absoluteString, "ws://192.168.1.1:9200")
    }

    func testWSURLWithTLS() {
        let config = ConnectionConfig(name: "Test", host: "relay.example.com", port: 443, useTLS: true)
        XCTAssertEqual(config.wsURL.absoluteString, "wss://relay.example.com:443")
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
