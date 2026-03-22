import NIO
import NIOCore
import NIOWebSocket
import Foundation
import ClaudeRelayKit

final class RelayMessageHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let sessionManager: SessionManager
    private let tokenStore: TokenStore
    private var isAuthenticated = false
    private var authenticatedTokenId: String?
    private var attachedSessionId: UUID?
    private var attachedPTY: (any PTYSessionProtocol)?
    private var context: ChannelHandlerContext?
    private var authTimeout: Scheduled<Void>?
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()
    private static let maxTextFrameSize = 1_000_000 // 1MB

    init(sessionManager: SessionManager, tokenStore: TokenStore) {
        self.sessionManager = sessionManager
        self.tokenStore = tokenStore
    }

    func channelActive(context: ChannelHandlerContext) {
        self.context = context
        let remote = context.remoteAddress?.description ?? "unknown"
        RelayLogger.log(category: "connection", "WebSocket connected from \(remote)")
        // Start 10-second auth timer
        authTimeout = context.eventLoop.scheduleTask(in: .seconds(10)) { [weak self] in
            guard let self = self, !self.isAuthenticated else { return }
            RelayLogger.log(.error, category: "auth", "Auth timeout for \(remote)")
            self.sendServerMessage(.error(code: 401, message: "Authentication timeout"), context: context)
            context.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        let remote = context.remoteAddress?.description ?? "unknown"
        RelayLogger.log(category: "connection", "WebSocket disconnected from \(remote)")
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
        let readable = data.readableBytes
        guard readable > 0 else { return }
        if readable > Self.maxTextFrameSize {
            sendServerMessage(.error(code: 413, message: "Message too large"), context: context)
            context.close(promise: nil)
            return
        }
        let jsonData = data.withUnsafeReadableBytes { Data($0) }

        let envelope: MessageEnvelope
        do {
            envelope = try jsonDecoder.decode(MessageEnvelope.self, from: jsonData)
        } catch {
            sendServerMessage(.error(code: 400, message: "Invalid message format"), context: context)
            return
        }

        guard case .client(let clientMessage) = envelope else {
            sendServerMessage(.error(code: 400, message: "Expected client message"), context: context)
            return
        }

        if !isAuthenticated {
            handleUnauthenticatedMessage(clientMessage, context: context)
        } else {
            handleAuthenticatedMessage(clientMessage, context: context)
        }
    }

    private func handleUnauthenticatedMessage(_ message: ClientMessage, context: ChannelHandlerContext) {
        switch message {
        case .authRequest(let token):
            handleAuth(token: token, context: context)
        case .ping:
            sendServerMessage(.pong, context: context)
        default:
            sendServerMessage(.error(code: 401, message: "Not authenticated"), context: context)
        }
    }

    private func handleAuthenticatedMessage(_ message: ClientMessage, context: ChannelHandlerContext) {
        switch message {
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
        case .sessionTerminate(let sessionId):
            handleSessionTerminate(sessionId: sessionId, context: context)
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
                    RelayLogger.log(category: "auth", "Auth success for token \(info.id)")
                    self.sendServerMessage(.authSuccess, context: context)
                } else {
                    RelayLogger.log(.error, category: "auth", "Auth failed — invalid token")
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
                await self?.autoDetachIfNeeded()
                let info = try await sessionManager.createSession(tokenId: tokenId)
                let sessionId = info.id
                // Attach immediately
                let (attachedInfo, pty) = try await sessionManager.attachSession(id: sessionId, tokenId: tokenId)
                RelayLogger.log(category: "session", "Session created: \(sessionId)")
                context.eventLoop.execute {
                    guard let self = self else { return }
                    self.attachedSessionId = sessionId
                    self.attachedPTY = pty
                    self.sendServerMessage(.sessionCreated(sessionId: sessionId, cols: info.cols, rows: info.rows), context: context)
                    self.wirePTYOutput(pty: pty, context: context)
                }
            } catch {
                RelayLogger.log(.error, category: "session", "Session create failed: \(error)")
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
                await self?.autoDetachIfNeeded()
                let (info, pty) = try await sessionManager.attachSession(id: sessionId, tokenId: tokenId)
                RelayLogger.log(category: "session", "Session attached: \(sessionId)")
                context.eventLoop.execute {
                    guard let self = self else { return }
                    self.attachedSessionId = sessionId
                    self.attachedPTY = pty
                    self.sendServerMessage(.sessionAttached(sessionId: sessionId, state: info.state.rawValue), context: context)
                    self.wirePTYOutput(pty: pty, context: context)
                }
            } catch {
                RelayLogger.log(.error, category: "session", "Attach failed for \(sessionId): \(error)")
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
                await self?.autoDetachIfNeeded()
                let (info, _, pty) = try await sessionManager.resumeSession(id: sessionId, tokenId: tokenId)
                RelayLogger.log(category: "session", "Session resumed: \(sessionId)")
                // Read scrollback history to send to client
                let buffered = await pty.readBuffer()
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
                RelayLogger.log(category: "session", "Session detached: \(sessionId)")
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

    // MARK: - Session Terminate

    private func handleSessionTerminate(sessionId: UUID, context: ChannelHandlerContext) {
        guard let tokenId = authenticatedTokenId else { return }
        let sessionManager = self.sessionManager
        Task { [weak self] in
            do {
                try await sessionManager.terminateSession(id: sessionId, tokenId: tokenId)
                RelayLogger.log(category: "session", "Session terminated: \(sessionId)")
                context.eventLoop.execute {
                    self?.sendServerMessage(.sessionTerminated(sessionId: sessionId, reason: "client_request"), context: context)
                    // If we were attached to this session, clear local state.
                    if self?.attachedSessionId == sessionId {
                        self?.attachedSessionId = nil
                        self?.attachedPTY = nil
                    }
                }
            } catch {
                context.eventLoop.execute {
                    self?.sendServerMessage(.error(code: 404, message: "Terminate failed: \(error)"), context: context)
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

    // MARK: - Auto-Detach

    /// Detaches the currently attached session (if any) before attaching a new one.
    /// Must be called from the event loop (inside context.eventLoop.execute or channelRead).
    private func autoDetachIfNeeded() async {
        guard let sessionId = attachedSessionId else { return }
        let sessionManager = self.sessionManager
        if let pty = attachedPTY {
            await pty.clearOutputHandler()
        }
        attachedSessionId = nil
        attachedPTY = nil
        try? await sessionManager.detachSession(id: sessionId)
    }

    // MARK: - PTY Output Wiring

    private func wirePTYOutput(pty: any PTYSessionProtocol, context: ChannelHandlerContext) {
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
        guard context.channel.isActive else { return }
        let envelope = MessageEnvelope.server(message)
        do {
            let data = try jsonEncoder.encode(envelope)
            var buffer = context.channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
            let promise = context.eventLoop.makePromise(of: Void.self)
            promise.futureResult.whenFailure { error in
                print("[RelayMessageHandler] Write failed: \(error)")
            }
            context.writeAndFlush(wrapOutboundOut(frame), promise: promise)
        } catch {
            print("[RelayMessageHandler] JSON encode failed for \(message): \(error)")
        }
    }

    private func sendBinaryData(_ data: Data, context: ChannelHandlerContext) {
        guard context.channel.isActive else { return }
        var buffer = context.channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        let frame = WebSocketFrame(fin: true, opcode: .binary, data: buffer)
        let promise = context.eventLoop.makePromise(of: Void.self)
        promise.futureResult.whenFailure { error in
            print("[RelayMessageHandler] Binary write failed (\(data.count) bytes): \(error)")
        }
        context.writeAndFlush(wrapOutboundOut(frame), promise: promise)
    }
}
