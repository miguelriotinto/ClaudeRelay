import Foundation
import NIOCore
import NIOHTTP1
import CodeRelayKit

enum AdminRoutes {
    private static let startTime = Date()

    static func handle(
        method: HTTPMethod,
        uri: String,
        body: ByteBuffer?,
        sessionManager: SessionManager,
        tokenStore: TokenStore
    ) async -> AdminResponse {
        // Strip query string and split path
        let path = uri.split(separator: "?").first.map(String.init) ?? uri
        let components = path.split(separator: "/").map(String.init)
        let count = components.count

        // GET /health
        if method == .GET && components == ["health"] {
            return .json(["status": "ok"])
        }

        // GET /status
        if method == .GET && components == ["status"] {
            let sessions = await sessionManager.listSessions()
            let uptime = Date().timeIntervalSince(startTime)
            let info: [String: Any] = [
                "status": "running",
                "pid": ProcessInfo.processInfo.processIdentifier,
                "uptime_seconds": Int(uptime),
                "session_count": sessions.count
            ]
            return .json(info)
        }

        // GET /sessions
        if method == .GET && components == ["sessions"] {
            let sessions = await sessionManager.listSessions()
            return .encodable(sessions)
        }

        // GET /sessions/:id
        if method == .GET && count == 2 && components[0] == "sessions" {
            guard let uuid = UUID(uuidString: components[1]) else {
                return .error("Invalid session ID", status: 400)
            }
            do {
                let info = try await sessionManager.inspectSession(id: uuid)
                return .encodable(info)
            } catch {
                return .error("Session not found", status: 404)
            }
        }

        // DELETE /sessions/:id
        if method == .DELETE && count == 2 && components[0] == "sessions" {
            guard let uuid = UUID(uuidString: components[1]) else {
                return .error("Invalid session ID", status: 400)
            }
            do {
                try await sessionManager.terminateSession(id: uuid)
                return .json(["status": "terminated"])
            } catch {
                return .error("Session not found", status: 404)
            }
        }

        // POST /tokens
        if method == .POST && components == ["tokens"] {
            var label: String? = nil
            if let body = body, let bytes = body.getBytes(at: body.readerIndex, length: body.readableBytes) {
                let data = Data(bytes)
                if let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    label = parsed["label"] as? String
                }
            }
            do {
                let (plaintext, info) = try await tokenStore.create(label: label)
                let result: [String: Any] = [
                    "token": plaintext,
                    "id": info.id,
                    "label": info.label ?? ""
                ]
                return .json(result, status: 201)
            } catch {
                return .error("Failed to create token: \(error)", status: 500)
            }
        }

        // GET /tokens
        if method == .GET && components == ["tokens"] {
            let tokens = await tokenStore.list()
            return .encodable(tokens)
        }

        // DELETE /tokens/:id
        if method == .DELETE && count == 2 && components[0] == "tokens" {
            let id = components[1]
            do {
                try await tokenStore.delete(id: id)
                return .json(["status": "deleted"])
            } catch {
                return .error("Token not found", status: 404)
            }
        }

        // POST /tokens/:id/rotate
        if method == .POST && count == 3 && components[0] == "tokens" && components[2] == "rotate" {
            let id = components[1]
            do {
                let (plaintext, info) = try await tokenStore.rotate(id: id)
                let result: [String: Any] = [
                    "token": plaintext,
                    "id": info.id,
                    "label": info.label ?? ""
                ]
                return .json(result)
            } catch {
                return .error("Token not found", status: 404)
            }
        }

        // GET /config
        if method == .GET && components == ["config"] {
            do {
                let config = try ConfigManager.load()
                return .encodable(config)
            } catch {
                return .error("Failed to load config: \(error)", status: 500)
            }
        }

        // PUT /config/:key
        if method == .PUT && count == 2 && components[0] == "config" {
            let key = components[1]
            guard let body = body,
                  let bytes = body.getBytes(at: body.readerIndex, length: body.readableBytes),
                  let parsed = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
                  let value = parsed["value"] else {
                return .error("Missing value in body", status: 400)
            }
            do {
                var config = try ConfigManager.load()
                switch key {
                case "wsPort":
                    if let v = value as? Int { config.wsPort = UInt16(v) }
                case "adminPort":
                    if let v = value as? Int { config.adminPort = UInt16(v) }
                case "detachTimeout":
                    if let v = value as? Int { config.detachTimeout = v }
                case "scrollbackSize":
                    if let v = value as? Int { config.scrollbackSize = v }
                case "logLevel":
                    if let v = value as? String { config.logLevel = v }
                case "tlsCert":
                    config.tlsCert = value as? String
                case "tlsKey":
                    config.tlsKey = value as? String
                default:
                    return .error("Unknown config key: \(key)", status: 400)
                }
                try ConfigManager.save(config)
                return .encodable(config)
            } catch {
                return .error("Failed to update config: \(error)", status: 500)
            }
        }

        // GET /logs
        if method == .GET && components == ["logs"] {
            return .json(["logs": [String](), "message": "Log collection not yet implemented"])
        }

        return .error("Not found", status: 404)
    }
}
