import XCTest
@testable import ClaudeRelayKit

final class ProtocolMessageTests: XCTestCase {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    // MARK: - Helper

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(obj as? [String: Any])
    }

    // MARK: - ClientMessage Encoding Structure

    func testAuthRequestEncoding() throws {
        let msg = ClientMessage.authRequest(token: "my-token")
        let envelope = MessageEnvelope.client(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "auth_request")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?["token"] as? String, "my-token")
    }

    func testSessionCreateEncoding() throws {
        let msg = ClientMessage.sessionCreate()
        let envelope = MessageEnvelope.client(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "session_create")
        // payload should be empty object or absent
        let payload = obj["payload"] as? [String: Any]
        XCTAssertNotNil(payload)
        XCTAssertTrue(payload?.isEmpty ?? true)
    }

    func testSessionAttachEncoding() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let msg = ClientMessage.sessionAttach(sessionId: id)
        let envelope = MessageEnvelope.client(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "session_attach")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["sessionId"] as? String, id.uuidString)
    }

    func testSessionResumeEncoding() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let msg = ClientMessage.sessionResume(sessionId: id)
        let envelope = MessageEnvelope.client(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "session_resume")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["sessionId"] as? String, id.uuidString)
    }

    func testSessionDetachEncoding() throws {
        let msg = ClientMessage.sessionDetach
        let envelope = MessageEnvelope.client(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "session_detach")
    }

    func testResizeEncoding() throws {
        let msg = ClientMessage.resize(cols: 120, rows: 40)
        let envelope = MessageEnvelope.client(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "resize")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["cols"] as? Int, 120)
        XCTAssertEqual(payload?["rows"] as? Int, 40)
    }

    func testPingEncoding() throws {
        let msg = ClientMessage.ping
        let envelope = MessageEnvelope.client(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "ping")
    }

    // MARK: - ServerMessage Encoding Structure

    func testAuthSuccessEncoding() throws {
        let msg = ServerMessage.authSuccess()
        let envelope = MessageEnvelope.server(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "auth_success")
    }

    func testAuthFailureEncoding() throws {
        let msg = ServerMessage.authFailure(reason: "invalid token")
        let envelope = MessageEnvelope.server(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "auth_failure")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["reason"] as? String, "invalid token")
    }

    func testSessionCreatedEncoding() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let msg = ServerMessage.sessionCreated(sessionId: id, cols: 80, rows: 24)
        let envelope = MessageEnvelope.server(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "session_created")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["sessionId"] as? String, id.uuidString)
        XCTAssertEqual(payload?["cols"] as? Int, 80)
        XCTAssertEqual(payload?["rows"] as? Int, 24)
    }

    func testSessionAttachedEncoding() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let msg = ServerMessage.sessionAttached(sessionId: id, state: "running")
        let envelope = MessageEnvelope.server(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "session_attached")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["sessionId"] as? String, id.uuidString)
        XCTAssertEqual(payload?["state"] as? String, "running")
    }

    func testSessionResumedEncoding() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let msg = ServerMessage.sessionResumed(sessionId: id)
        let envelope = MessageEnvelope.server(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "session_resumed")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["sessionId"] as? String, id.uuidString)
    }

    func testSessionDetachedEncoding() throws {
        let msg = ServerMessage.sessionDetached
        let envelope = MessageEnvelope.server(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "session_detached")
    }

    func testSessionTerminatedEncoding() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let msg = ServerMessage.sessionTerminated(sessionId: id, reason: "user exit")
        let envelope = MessageEnvelope.server(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "session_terminated")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["sessionId"] as? String, id.uuidString)
        XCTAssertEqual(payload?["reason"] as? String, "user exit")
    }

    func testSessionExpiredEncoding() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let msg = ServerMessage.sessionExpired(sessionId: id)
        let envelope = MessageEnvelope.server(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "session_expired")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["sessionId"] as? String, id.uuidString)
    }

    func testSessionStateEncoding() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let msg = ServerMessage.sessionState(sessionId: id, state: "idle")
        let envelope = MessageEnvelope.server(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "session_state")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["sessionId"] as? String, id.uuidString)
        XCTAssertEqual(payload?["state"] as? String, "idle")
    }

    func testResizeAckEncoding() throws {
        let msg = ServerMessage.resizeAck(cols: 120, rows: 40)
        let envelope = MessageEnvelope.server(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "resize_ack")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["cols"] as? Int, 120)
        XCTAssertEqual(payload?["rows"] as? Int, 40)
    }

    func testPongEncoding() throws {
        let msg = ServerMessage.pong
        let envelope = MessageEnvelope.server(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "pong")
    }

    func testErrorEncoding() throws {
        let msg = ServerMessage.error(code: 404, message: "not found")
        let envelope = MessageEnvelope.server(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "error")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["code"] as? Int, 404)
        XCTAssertEqual(payload?["message"] as? String, "not found")
    }

    // MARK: - Round-trip ClientMessage

    func testClientMessageRoundTrips() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let messages: [ClientMessage] = [
            .authRequest(token: "abc123"),
            .sessionCreate(),
            .sessionAttach(sessionId: id),
            .sessionResume(sessionId: id),
            .sessionDetach,
            .resize(cols: 80, rows: 24),
            .ping
        ]

        for original in messages {
            let envelope = MessageEnvelope.client(original)
            let data = try encoder.encode(envelope)
            let decoded = try decoder.decode(MessageEnvelope.self, from: data)

            guard case .client(let roundTripped) = decoded else {
                XCTFail("Expected .client envelope, got \(decoded)")
                continue
            }
            XCTAssertEqual(original, roundTripped, "Round-trip failed for \(original)")
        }
    }

    // MARK: - Round-trip ServerMessage

    func testServerMessageRoundTrips() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let messages: [ServerMessage] = [
            .authSuccess(),
            .authFailure(reason: "bad creds"),
            .sessionCreated(sessionId: id, cols: 80, rows: 24),
            .sessionAttached(sessionId: id, state: "running"),
            .sessionResumed(sessionId: id),
            .sessionDetached,
            .sessionTerminated(sessionId: id, reason: "exit"),
            .sessionExpired(sessionId: id),
            .sessionState(sessionId: id, state: "idle"),
            .sessionActivity(sessionId: id, activity: .claudeIdle),
            .sessionStolen(sessionId: id),
            .sessionRenamed(sessionId: id, name: "Varys"),
            .resizeAck(cols: 120, rows: 40),
            .pong,
            .error(code: 500, message: "internal")
        ]

        for original in messages {
            let envelope = MessageEnvelope.server(original)
            let data = try encoder.encode(envelope)
            let decoded = try decoder.decode(MessageEnvelope.self, from: data)

            guard case .server(let roundTripped) = decoded else {
                XCTFail("Expected .server envelope, got \(decoded)")
                continue
            }
            XCTAssertEqual(original, roundTripped, "Round-trip failed for \(original)")
        }
    }

    // MARK: - Field Verification

    func testAuthRequestFieldVerification() throws {
        let json = #"{"type":"auth_request","payload":{"token":"secret-token-123"}}"#
        let envelope = try decoder.decode(MessageEnvelope.self, from: Data(json.utf8))
        guard case .client(.authRequest(let token, let protocolVersion)) = envelope else {
            XCTFail("Expected authRequest"); return
        }
        XCTAssertEqual(token, "secret-token-123")
        XCTAssertNil(protocolVersion)
    }

    func testSessionCreatedFieldVerification() throws {
        let id = "12345678-1234-1234-1234-123456789ABC"
        let json = #"{"type":"session_created","payload":{"sessionId":"\#(id)","cols":132,"rows":50}}"#
        let envelope = try decoder.decode(MessageEnvelope.self, from: Data(json.utf8))
        guard case .server(.sessionCreated(let sessionId, let cols, let rows)) = envelope else {
            XCTFail("Expected sessionCreated"); return
        }
        XCTAssertEqual(sessionId.uuidString, id)
        XCTAssertEqual(cols, 132)
        XCTAssertEqual(rows, 50)
    }

    func testErrorFieldVerification() throws {
        let json = #"{"type":"error","payload":{"code":429,"message":"rate limited"}}"#
        let envelope = try decoder.decode(MessageEnvelope.self, from: Data(json.utf8))
        guard case .server(.error(let code, let message)) = envelope else {
            XCTFail("Expected error"); return
        }
        XCTAssertEqual(code, 429)
        XCTAssertEqual(message, "rate limited")
    }

    func testResizeFieldVerification() throws {
        let json = #"{"type":"resize","payload":{"cols":200,"rows":60}}"#
        let envelope = try decoder.decode(MessageEnvelope.self, from: Data(json.utf8))
        guard case .client(.resize(let cols, let rows)) = envelope else {
            XCTFail("Expected resize"); return
        }
        XCTAssertEqual(cols, 200)
        XCTAssertEqual(rows, 60)
    }

    func testSessionTerminatedFieldVerification() throws {
        let id = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let json = #"{"type":"session_terminated","payload":{"sessionId":"\#(id)","reason":"timeout"}}"#
        let envelope = try decoder.decode(MessageEnvelope.self, from: Data(json.utf8))
        guard case .server(.sessionTerminated(let sessionId, let reason)) = envelope else {
            XCTFail("Expected sessionTerminated"); return
        }
        XCTAssertEqual(sessionId.uuidString, id)
        XCTAssertEqual(reason, "timeout")
    }

    // MARK: - session_list_result Regression

    /// Regression test: session_list used to collide with client's session_list
    /// type string. Server now uses "session_list_result". This test ensures
    /// the server response decodes as .server, not .client.
    func testSessionListResultDecodesAsServer() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let json = """
        {"type":"session_list_result","payload":{"sessions":[{"id":"\(id.uuidString)","state":"active-attached","tokenId":"tok_1","createdAt":1735689600.0,"cols":80,"rows":24,"activity":"claude_active"}]}}
        """
        let envelope = try decoder.decode(MessageEnvelope.self, from: Data(json.utf8))
        guard case .server(.sessionList(let sessions)) = envelope else {
            XCTFail("Expected .server(.sessionList), got \(envelope)")
            return
        }
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].id, id)
        XCTAssertEqual(sessions[0].activity, .claudeActive)
    }

    // MARK: - sessionActivity

    func testSessionActivityEncoding() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let msg = ServerMessage.sessionActivity(sessionId: id, activity: .claudeIdle)
        let envelope = MessageEnvelope.server(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "session_activity")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["sessionId"] as? String, id.uuidString)
        XCTAssertEqual(payload?["activity"] as? String, "claude_idle")
    }

    func testSessionActivityFieldVerification() throws {
        let id = "12345678-1234-1234-1234-123456789ABC"
        let json = #"{"type":"session_activity","payload":{"sessionId":"\#(id)","activity":"claude_active"}}"#
        let envelope = try decoder.decode(MessageEnvelope.self, from: Data(json.utf8))
        guard case .server(.sessionActivity(let sessionId, let activity)) = envelope else {
            XCTFail("Expected sessionActivity"); return
        }
        XCTAssertEqual(sessionId.uuidString, id)
        XCTAssertEqual(activity, .claudeActive)
    }

    func testSessionActivityRoundTrip() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let states: [ActivityState] = [.active, .idle, .claudeActive, .claudeIdle]
        for state in states {
            let original = ServerMessage.sessionActivity(sessionId: id, activity: state)
            let envelope = MessageEnvelope.server(original)
            let data = try encoder.encode(envelope)
            let decoded = try decoder.decode(MessageEnvelope.self, from: data)
            guard case .server(let roundTripped) = decoded else {
                XCTFail("Expected .server envelope"); continue
            }
            XCTAssertEqual(original, roundTripped, "Round-trip failed for activity \(state)")
        }
    }

    // MARK: - sessionStolen

    func testSessionStolenEncoding() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let msg = ServerMessage.sessionStolen(sessionId: id)
        let envelope = MessageEnvelope.server(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "session_stolen")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["sessionId"] as? String, id.uuidString)
    }

    func testSessionStolenFieldVerification() throws {
        let id = "12345678-1234-1234-1234-123456789ABC"
        let json = #"{"type":"session_stolen","payload":{"sessionId":"\#(id)"}}"#
        let envelope = try decoder.decode(MessageEnvelope.self, from: Data(json.utf8))
        guard case .server(.sessionStolen(let sessionId)) = envelope else {
            XCTFail("Expected sessionStolen"); return
        }
        XCTAssertEqual(sessionId.uuidString, id)
    }

    // MARK: - sessionCreate with name

    func testSessionCreateWithNameEncoding() throws {
        let msg = ClientMessage.sessionCreate(name: "Rhaegar")
        let envelope = MessageEnvelope.client(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "session_create")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["name"] as? String, "Rhaegar")
    }

    func testSessionCreateWithoutNameEncoding() throws {
        let msg = ClientMessage.sessionCreate(name: nil)
        let envelope = MessageEnvelope.client(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "session_create")
    }

    func testSessionCreateWithNameRoundTrip() throws {
        let original = ClientMessage.sessionCreate(name: "Tyrion")
        let envelope = MessageEnvelope.client(original)
        let data = try encoder.encode(envelope)
        let decoded = try decoder.decode(MessageEnvelope.self, from: data)
        guard case .client(let roundTripped) = decoded else {
            XCTFail("Expected .client envelope"); return
        }
        XCTAssertEqual(original, roundTripped)
    }

    func testSessionCreateWithoutNameRoundTrip() throws {
        let original = ClientMessage.sessionCreate(name: nil)
        let envelope = MessageEnvelope.client(original)
        let data = try encoder.encode(envelope)
        let decoded = try decoder.decode(MessageEnvelope.self, from: data)
        guard case .client(let roundTripped) = decoded else {
            XCTFail("Expected .client envelope"); return
        }
        XCTAssertEqual(original, roundTripped)
    }

    // MARK: - sessionRename

    func testSessionRenameEncoding() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let msg = ClientMessage.sessionRename(sessionId: id, name: "Daenerys")
        let envelope = MessageEnvelope.client(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "session_rename")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["sessionId"] as? String, id.uuidString)
        XCTAssertEqual(payload?["name"] as? String, "Daenerys")
    }

    func testSessionRenameRoundTrip() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let original = ClientMessage.sessionRename(sessionId: id, name: "Sansa")
        let envelope = MessageEnvelope.client(original)
        let data = try encoder.encode(envelope)
        let decoded = try decoder.decode(MessageEnvelope.self, from: data)
        guard case .client(let roundTripped) = decoded else {
            XCTFail("Expected .client envelope"); return
        }
        XCTAssertEqual(original, roundTripped)
    }

    func testSessionRenameFieldVerification() throws {
        let id = "12345678-1234-1234-1234-123456789ABC"
        let json = #"{"type":"session_rename","payload":{"sessionId":"\#(id)","name":"Arya"}}"#
        let envelope = try decoder.decode(MessageEnvelope.self, from: Data(json.utf8))
        guard case .client(.sessionRename(let sessionId, let name)) = envelope else {
            XCTFail("Expected sessionRename"); return
        }
        XCTAssertEqual(sessionId.uuidString, id)
        XCTAssertEqual(name, "Arya")
    }

    // MARK: - sessionRenamed

    func testSessionRenamedEncoding() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let msg = ServerMessage.sessionRenamed(sessionId: id, name: "Cersei")
        let envelope = MessageEnvelope.server(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "session_renamed")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["sessionId"] as? String, id.uuidString)
        XCTAssertEqual(payload?["name"] as? String, "Cersei")
    }

    func testSessionRenamedRoundTrip() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let original = ServerMessage.sessionRenamed(sessionId: id, name: "Jon Snow")
        let envelope = MessageEnvelope.server(original)
        let data = try encoder.encode(envelope)
        let decoded = try decoder.decode(MessageEnvelope.self, from: data)
        guard case .server(let roundTripped) = decoded else {
            XCTFail("Expected .server envelope"); return
        }
        XCTAssertEqual(original, roundTripped)
    }

    func testSessionRenamedFieldVerification() throws {
        let id = "12345678-1234-1234-1234-123456789ABC"
        let json = #"{"type":"session_renamed","payload":{"sessionId":"\#(id)","name":"Bran"}}"#
        let envelope = try decoder.decode(MessageEnvelope.self, from: Data(json.utf8))
        guard case .server(.sessionRenamed(let sessionId, let name)) = envelope else {
            XCTFail("Expected sessionRenamed"); return
        }
        XCTAssertEqual(sessionId.uuidString, id)
        XCTAssertEqual(name, "Bran")
    }

    // MARK: - Equatable

    func testClientMessageEquatable() {
        let id = UUID()
        XCTAssertEqual(ClientMessage.ping, ClientMessage.ping)
        XCTAssertEqual(ClientMessage.sessionCreate(), ClientMessage.sessionCreate())
        XCTAssertEqual(ClientMessage.authRequest(token: "a"), ClientMessage.authRequest(token: "a"))
        XCTAssertNotEqual(ClientMessage.authRequest(token: "a"), ClientMessage.authRequest(token: "b"))
        XCTAssertEqual(ClientMessage.sessionAttach(sessionId: id), ClientMessage.sessionAttach(sessionId: id))
        XCTAssertNotEqual(ClientMessage.ping, ClientMessage.sessionCreate())
    }

    func testServerMessageEquatable() {
        let id = UUID()
        XCTAssertEqual(ServerMessage.pong, ServerMessage.pong)
        XCTAssertEqual(ServerMessage.authSuccess(), ServerMessage.authSuccess())
        XCTAssertEqual(ServerMessage.error(code: 1, message: "a"), ServerMessage.error(code: 1, message: "a"))
        XCTAssertNotEqual(ServerMessage.error(code: 1, message: "a"), ServerMessage.error(code: 2, message: "a"))
        XCTAssertEqual(ServerMessage.sessionCreated(sessionId: id, cols: 80, rows: 24),
                       ServerMessage.sessionCreated(sessionId: id, cols: 80, rows: 24))
    }
}
