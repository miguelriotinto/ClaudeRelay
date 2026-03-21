import NIO
import NIOCore
import NIOWebSocket
import Foundation
import CodeRelayKit

final class RelayMessageHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let sessionManager: SessionManager
    private let tokenStore: TokenStore
    private var isAuthenticated = false
    private var authenticatedTokenId: String?
    private var attachedSessionId: UUID?
    private var attachedPTY: PTYSession?
    private var context: ChannelHandlerContext?
    private var authTimeout: Scheduled<Void>?

    init(sessionManager: SessionManager, tokenStore: TokenStore) {
        self.sessionManager = sessionManager
        self.tokenStore = tokenStore
    }

    func channelActive(context: ChannelHandlerContext) {
        self.context = context
        // Start 10-second auth timer
        authTimeout = context.eventLoop.scheduleTask(in: .seconds(10)) { [weak self] in
            guard let self = self, !self.isAuthenticated else { return }
            self.sendServerMessage(.error(code: 401, message: "Authentication timeout"), context: context)
            context.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        authTimeout?.cancel()
        cleanupSession()
        self.context = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)

        switch frame.opcode {
        case .text:
            handleTextFrame(frame, context: context)
        case .binary:
            handleBinaryFrame(frame, context: context)
        case .connectionClose:
            cleanupSession()
            context.close(promise: nil)
        case .ping:
            var frameData = frame.data
            let pong = WebSocketFrame(fin: true, opcode: .pong, data: frameData)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
        default:
            break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        cleanupSession()
        context.close(promise: nil)
    }

    // MARK: - Text Frame Handling

    private func handleTextFrame(_ frame: WebSocketFrame, context: ChannelHandlerContext) {
        var data = frame.unmaskedData
        guard let bytes = data.readBytes(length: data.readableBytes) else { return }
        let jsonData = Data(bytes)

        let envelope: MessageEnvelope
        do {
            envelope = try JSONDecoder().decode(MessageEnvelope.self, from: jsonData)
        } catch {
            sendServerMessage(.error(code: 400, message: "Invalid message format"), context: context)
            return
        }

        guard case .client(let clientMessage) = envelope else {
            sendServerMessage(.error(code: 400, message: "Expected client message"), context: context)
            return
        }

        // If not authenticated, only allow auth_request and ping
        if !isAuthenticated {
            switch clientMessage {
            case .authRequest(let token):
                handleAuth(token: token, context: context)
            case .ping:
                sendServerMessage(.pong, context: context)
            default:
                sendServerMessage(.error(code: 401, message: "Not authenticated"), context: context)
            }
            return
        }

        // Authenticated message dispatch
        switch clientMessage {
        case .authRequest:
            sendServerMessage(.error(code: 400, message: "Already authenticated"), context: context)
        case .sessionCreate:
            handleSessionCreate(context: context)
        case .sessionAttach(let sessionId):
            handleSessionAttach(sessionId: sessionId, context: context)
        case .sessionResume(let sessionId):
            handleSessionResume(sessionId: sessionId, context: context)
        case .sessionDetach:
            handleSessionDetach(context: context)
        case .sessionList:
            handleSessionList(context: context)
        case .resize(let cols, let rows):
            handleResize(cols: cols, rows: rows, context: context)
        case .ping:
            sendServerMessage(.pong, context: context)
        }
    }

    // MARK: - Binary Frame Handling

    private func handleBinaryFrame(_ frame: WebSocketFrame, context: ChannelHandlerContext) {
        guard isAuthenticated, let pty = attachedPTY else { return }
        var data = frame.unmaskedData
        guard let bytes = data.readBytes(length: data.readableBytes) else { return }
        let inputData = Data(bytes)
        Task {
            await pty.write(inputData)
        }
    }

    // MARK: - Auth

    private func handleAuth(token: String, context: ChannelHandlerContext) {
        let tokenStore = self.tokenStore
        Task { [weak self] in
            let tokenInfo = await tokenStore.validate(token: token)
            context.eventLoop.execute {
                guard let self = self else { return }
                if let info = tokenInfo {
                    self.isAuthenticated = true
                    self.authenticatedTokenId = info.id
                    self.authTimeout?.cancel()
                    self.authTimeout = nil
                    self.sendServerMessage(.authSuccess, context: context)
                } else {
                    self.sendServerMessage(.authFailure(reason: "Invalid token"), context: context)
                }
            }
        }
    }

    // MARK: - Session Create

    private func handleSessionCreate(context: ChannelHandlerContext) {
        guard let tokenId = authenticatedTokenId else { return }
        let sessionManager = self.sessionManager
        Task { [weak self] in
            do {
                let info = try await sessionManager.createSession(tokenId: tokenId)
                let sessionId = info.id
                // Attach immediately
                let (attachedInfo, pty) = try await sessionManager.attachSession(id: sessionId, tokenId: tokenId)
                context.eventLoop.execute {
                    guard let self = self else { return }
                    self.attachedSessionId = sessionId
                    self.attachedPTY = pty
                    self.sendServerMessage(.sessionCreated(sessionId: sessionId, cols: info.cols, rows: info.rows), context: context)
                    self.wirePTYOutput(pty: pty, context: context)
                }
            } catch {
                context.eventLoop.execute {
                    self?.sendServerMessage(.error(code: 500, message: "Failed to create session: \(error)"), context: context)
                }
            }
        }
    }

    // MARK: - Session Attach

    private func handleSessionAttach(sessionId: UUID, context: ChannelHandlerContext) {
        guard let tokenId = authenticatedTokenId else { return }
        let sessionManager = self.sessionManager
        Task { [weak self] in
            do {
                let (info, pty) = try await sessionManager.attachSession(id: sessionId, tokenId: tokenId)
                context.eventLoop.execute {
                    guard let self = self else { return }
                    self.attachedSessionId = sessionId
                    self.attachedPTY = pty
                    self.sendServerMessage(.sessionAttached(sessionId: sessionId, state: info.state.rawValue), context: context)
                    self.wirePTYOutput(pty: pty, context: context)
                }
            } catch {
                context.eventLoop.execute {
                    self?.sendServerMessage(.error(code: 404, message: "Attach failed: \(error)"), context: context)
                }
            }
        }
    }

    // MARK: - Session Resume

    private func handleSessionResume(sessionId: UUID, context: ChannelHandlerContext) {
        guard let tokenId = authenticatedTokenId else { return }
        let sessionManager = self.sessionManager
        Task { [weak self] in
            do {
                let (info, _, pty) = try await sessionManager.resumeSession(id: sessionId, tokenId: tokenId)
                // Flush buffered data
                let buffered = await pty.flushBuffer()
                context.eventLoop.execute {
                    guard let self = self else { return }
                    self.attachedSessionId = sessionId
                    self.attachedPTY = pty
                    self.sendServerMessage(.sessionResumed(sessionId: sessionId), context: context)
                    // Send buffered data as binary
                    if !buffered.isEmpty {
                        self.sendBinaryData(buffered, context: context)
                    }
                    self.wirePTYOutput(pty: pty, context: context)
                }
            } catch {
                context.eventLoop.execute {
                    self?.sendServerMessage(.error(code: 404, message: "Resume failed: \(error)"), context: context)
                }
            }
        }
    }

    // MARK: - Session Detach

    private func handleSessionDetach(context: ChannelHandlerContext) {
        guard let sessionId = attachedSessionId else {
            sendServerMessage(.error(code: 400, message: "No session attached"), context: context)
            return
        }
        let sessionManager = self.sessionManager
        Task { [weak self] in
            do {
                try await sessionManager.detachSession(id: sessionId)
                context.eventLoop.execute {
                    guard let self = self else { return }
                    self.attachedSessionId = nil
                    self.attachedPTY = nil
                    self.sendServerMessage(.sessionDetached, context: context)
                }
            } catch {
                context.eventLoop.execute {
                    self?.sendServerMessage(.error(code: 500, message: "Detach failed: \(error)"), context: context)
                }
            }
        }
    }

    // MARK: - Session List

    private func handleSessionList(context: ChannelHandlerContext) {
        guard let tokenId = authenticatedTokenId else { return }
        let sessionManager = self.sessionManager
        Task { [weak self] in
            let sessions = await sessionManager.listSessionsForToken(tokenId: tokenId)
            context.eventLoop.execute {
                self?.sendServerMessage(.sessionList(sessions: sessions), context: context)
            }
        }
    }

    // MARK: - Resize

    private func handleResize(cols: UInt16, rows: UInt16, context: ChannelHandlerContext) {
        guard let pty = attachedPTY else {
            sendServerMessage(.error(code: 400, message: "No session attached"), context: context)
            return
        }
        Task { [weak self] in
            await pty.resize(cols: cols, rows: rows)
            context.eventLoop.execute {
                self?.sendServerMessage(.resizeAck(cols: cols, rows: rows), context: context)
            }
        }
    }

    // MARK: - PTY Output Wiring

    private func wirePTYOutput(pty: PTYSession, context: ChannelHandlerContext) {
        Task {
            await pty.setOutputHandler { [weak self] data in
                context.eventLoop.execute {
                    self?.sendBinaryData(data, context: context)
                }
            }
        }
    }

    // MARK: - Cleanup

    private func cleanupSession() {
        guard let sessionId = attachedSessionId else { return }
        let sessionManager = self.sessionManager
        let pty = self.attachedPTY
        attachedSessionId = nil
        attachedPTY = nil
        Task {
            if let pty = pty {
                await pty.clearOutputHandler()
            }
            try? await sessionManager.detachSession(id: sessionId)
        }
    }

    // MARK: - Send Helpers

    private func sendServerMessage(_ message: ServerMessage, context: ChannelHandlerContext) {
        let envelope = MessageEnvelope.server(message)
        do {
            let data = try JSONEncoder().encode(envelope)
            var buffer = context.channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
            context.writeAndFlush(wrapOutboundOut(frame), promise: nil)
        } catch {
            // Encoding failure — not much we can do
        }
    }

    private func sendBinaryData(_ data: Data, context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        let frame = WebSocketFrame(fin: true, opcode: .binary, data: buffer)
        context.writeAndFlush(wrapOutboundOut(frame), promise: nil)
    }
}
