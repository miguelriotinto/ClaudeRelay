import NIO
import NIOCore
import NIOWebSocket
import Foundation
import ClaudeRelayKit

// swiftlint:disable:next type_body_length
final class RelayMessageHandler: ChannelInboundHandler, @unchecked Sendable {
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
    private var authAttempts = 0
    private static let maxAuthAttempts = 3
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()
    private static let maxTextFrameSize = 1_000_000   // 1MB
    private static let maxBinaryFrameSize = 1_000_000 // 1MB

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
            let frameData = frame.data
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
        let data = frame.unmaskedData
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
        let data = frame.unmaskedData
        if data.readableBytes > Self.maxBinaryFrameSize {
            sendServerMessage(.error(code: 413, message: "Binary frame too large"), context: context)
            return
        }
        let inputData = data.withUnsafeReadableBytes { Data($0) }
        Task {
            await pty.write(inputData)
        }
    }

    // MARK: - Auth

    private func handleAuth(token: String, context: ChannelHandlerContext) {
        let tokenStore = self.tokenStore
        let ctx = UnsafeTransfer(context)
        Task { [weak self] in
            let tokenInfo = await tokenStore.validate(token: token)
            ctx.value.eventLoop.execute {
                guard let self = self else { return }
                if let info = tokenInfo {
                    self.isAuthenticated = true
                    self.authenticatedTokenId = info.id
                    self.authTimeout?.cancel()
                    self.authTimeout = nil
                    RelayLogger.log(category: "auth", "Auth success for token \(info.id)")
                    self.sendServerMessage(.authSuccess, context: ctx.value)
                } else {
                    self.authAttempts += 1
                    let remote = ctx.value.remoteAddress?.description ?? "unknown"
                    RelayLogger.log(.error, category: "auth", "Auth failed — invalid token (attempt \(self.authAttempts)/\(Self.maxAuthAttempts)) from \(remote)")
                    self.sendServerMessage(.authFailure(reason: "Invalid token"), context: ctx.value)
                    if self.authAttempts >= Self.maxAuthAttempts {
                        RelayLogger.log(.error, category: "auth", "Max auth attempts reached, closing connection from \(remote)")
                        ctx.value.close(promise: nil)
                    }
                }
            }
        }
    }

    // MARK: - Session Create

    private func handleSessionCreate(context: ChannelHandlerContext) {
        guard let tokenId = authenticatedTokenId else { return }
        let sessionManager = self.sessionManager
        let ctx = UnsafeTransfer(context)
        Task { [weak self] in
            do {
                await self?.autoDetachIfNeeded()
                let info = try await sessionManager.createSession(tokenId: tokenId)
                let sessionId = info.id
                // Attach immediately
                let (_, pty) = try await sessionManager.attachSession(id: sessionId, tokenId: tokenId)
                RelayLogger.log(category: "session", "Session created: \(sessionId)")
                ctx.value.eventLoop.execute {
                    guard let self = self else { return }
                    self.attachedSessionId = sessionId
                    self.attachedPTY = pty
                    self.sendServerMessage(.sessionCreated(sessionId: sessionId, cols: info.cols, rows: info.rows), context: ctx.value)
                    self.wirePTYOutput(pty: pty, context: ctx.value)
                }
            } catch {
                RelayLogger.log(.error, category: "session", "Session create failed: \(error)")
                ctx.value.eventLoop.execute {
                    self?.sendServerMessage(.error(code: 500, message: "Failed to create session: \(error)"), context: ctx.value)
                }
            }
        }
    }

    // MARK: - Session Attach

    private func handleSessionAttach(sessionId: UUID, context: ChannelHandlerContext) {
        guard let tokenId = authenticatedTokenId else { return }
        let sessionManager = self.sessionManager
        let ctx = UnsafeTransfer(context)
        Task { [weak self] in
            do {
                await self?.autoDetachIfNeeded()
                let (info, pty) = try await sessionManager.attachSession(id: sessionId, tokenId: tokenId)
                RelayLogger.log(category: "session", "Session attached: \(sessionId)")
                ctx.value.eventLoop.execute {
                    guard let self = self else { return }
                    self.attachedSessionId = sessionId
                    self.attachedPTY = pty
                    self.sendServerMessage(.sessionAttached(sessionId: sessionId, state: info.state.rawValue), context: ctx.value)
                    self.wirePTYOutput(pty: pty, context: ctx.value)
                }
            } catch {
                RelayLogger.log(.error, category: "session", "Attach failed for \(sessionId): \(error)")
                ctx.value.eventLoop.execute {
                    self?.sendServerMessage(.error(code: 404, message: "Attach failed: \(error)"), context: ctx.value)
                }
            }
        }
    }

    // MARK: - Session Resume

    private func handleSessionResume(sessionId: UUID, context: ChannelHandlerContext) {
        guard let tokenId = authenticatedTokenId else { return }
        let sessionManager = self.sessionManager
        let ctx = UnsafeTransfer(context)
        Task { [weak self] in
            do {
                await self?.autoDetachIfNeeded()
                let (_, _, pty) = try await sessionManager.resumeSession(id: sessionId, tokenId: tokenId)
                RelayLogger.log(category: "session", "Session resumed: \(sessionId)")
                // Read scrollback history to send to client
                let buffered = await pty.readBuffer()
                // Filter out stale escape sequence responses that may have accumulated
                let filtered = Self.filterEscapeResponses(buffered)
                ctx.value.eventLoop.execute {
                    guard let self = self else { return }
                    self.attachedSessionId = sessionId
                    self.attachedPTY = pty
                    self.sendServerMessage(.sessionResumed(sessionId: sessionId), context: ctx.value)
                    // Send buffered data as binary
                    if !filtered.isEmpty {
                        self.sendBinaryData(filtered, context: ctx.value)
                    }
                    self.wirePTYOutput(pty: pty, context: ctx.value)
                }
            } catch {
                ctx.value.eventLoop.execute {
                    self?.sendServerMessage(.error(code: 404, message: "Resume failed: \(error)"), context: ctx.value)
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
        let ctx = UnsafeTransfer(context)
        Task { [weak self] in
            do {
                try await sessionManager.detachSession(id: sessionId)
                RelayLogger.log(category: "session", "Session detached: \(sessionId)")
                ctx.value.eventLoop.execute {
                    guard let self = self else { return }
                    self.attachedSessionId = nil
                    self.attachedPTY = nil
                    self.sendServerMessage(.sessionDetached, context: ctx.value)
                }
            } catch {
                ctx.value.eventLoop.execute {
                    self?.sendServerMessage(.error(code: 500, message: "Detach failed: \(error)"), context: ctx.value)
                }
            }
        }
    }

    // MARK: - Session Terminate

    private func handleSessionTerminate(sessionId: UUID, context: ChannelHandlerContext) {
        guard let tokenId = authenticatedTokenId else { return }
        let sessionManager = self.sessionManager
        let ctx = UnsafeTransfer(context)
        Task { [weak self] in
            do {
                try await sessionManager.terminateSession(id: sessionId, tokenId: tokenId)
                RelayLogger.log(category: "session", "Session terminated: \(sessionId)")
                ctx.value.eventLoop.execute {
                    self?.sendServerMessage(.sessionTerminated(sessionId: sessionId, reason: "client_request"), context: ctx.value)
                    if self?.attachedSessionId == sessionId {
                        self?.attachedSessionId = nil
                        self?.attachedPTY = nil
                    }
                }
            } catch {
                ctx.value.eventLoop.execute {
                    self?.sendServerMessage(.error(code: 404, message: "Terminate failed: \(error)"), context: ctx.value)
                }
            }
        }
    }

    // MARK: - Session List

    private func handleSessionList(context: ChannelHandlerContext) {
        guard let tokenId = authenticatedTokenId else { return }
        let sessionManager = self.sessionManager
        let ctx = UnsafeTransfer(context)
        Task { [weak self] in
            let sessions = await sessionManager.listSessionsForToken(tokenId: tokenId)
            ctx.value.eventLoop.execute {
                self?.sendServerMessage(.sessionList(sessions: sessions), context: ctx.value)
            }
        }
    }

    // MARK: - Resize

    private func handleResize(cols: UInt16, rows: UInt16, context: ChannelHandlerContext) {
        guard let pty = attachedPTY else {
            sendServerMessage(.error(code: 400, message: "No session attached"), context: context)
            return
        }
        let ctx = UnsafeTransfer(context)
        Task { [weak self] in
            await pty.resize(cols: cols, rows: rows)
            ctx.value.eventLoop.execute {
                self?.sendServerMessage(.resizeAck(cols: cols, rows: rows), context: ctx.value)
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
        let ctx = UnsafeTransfer(context)
        Task { [weak self] in
            await pty.setOutputHandler { [weak self] data in
                ctx.value.eventLoop.execute {
                    self?.sendBinaryData(data, context: ctx.value)
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
                RelayLogger.log(.error, category: "connection", "Write failed: \(error)")
            }
            context.writeAndFlush(wrapOutboundOut(frame), promise: promise)
        } catch {
            RelayLogger.log(.error, category: "connection", "JSON encode failed for \(message): \(error)")
        }
    }

    private func sendBinaryData(_ data: Data, context: ChannelHandlerContext) {
        guard context.channel.isActive else { return }
        var buffer = context.channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        let frame = WebSocketFrame(fin: true, opcode: .binary, data: buffer)
        let promise = context.eventLoop.makePromise(of: Void.self)
        promise.futureResult.whenFailure { error in
            RelayLogger.log(.error, category: "connection", "Binary write failed (\(data.count) bytes): \(error)")
        }
        context.writeAndFlush(wrapOutboundOut(frame), promise: promise)
    }

    // MARK: - Escape Sequence Filtering

    /// Filters out stale escape sequence responses (DA, DSR, etc.) that may have accumulated
    /// in the scrollback buffer while the session was detached. These responses would otherwise
    /// appear as garbage characters when the terminal reattaches.
    private static func filterEscapeResponses(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }

        let bytes = [UInt8](data)
        var filtered = [UInt8]()
        filtered.reserveCapacity(bytes.count)

        var i = 0
        while i < bytes.count {
            // Look for CSI (ESC [ or 0x9B)
            if i < bytes.count - 1 && bytes[i] == 0x1B && bytes[i + 1] == 0x5B {
                // ESC [ sequence
                var j = i + 2
                // Scan parameter bytes (0x30-0x3F) and intermediate bytes (0x20-0x2F)
                while j < bytes.count && (
                    (bytes[j] >= 0x30 && bytes[j] <= 0x3F) ||
                    (bytes[j] >= 0x20 && bytes[j] <= 0x2F)
                ) {
                    j += 1
                }
                // Final byte is 0x40-0x7E
                if j < bytes.count && bytes[j] >= 0x40 && bytes[j] <= 0x7E {
                    let finalByte = bytes[j]
                    // Filter out common response sequences:
                    // - 'c' = DA (Device Attributes)
                    // - 'R' = CPR (Cursor Position Report)
                    // - 'n' = DSR (Device Status Report)
                    // - 'y' = DECREQTPARM response
                    if finalByte == 0x63 || finalByte == 0x52 || finalByte == 0x6E || finalByte == 0x79 {
                        // Skip this entire sequence
                        i = j + 1
                        continue
                    }
                }
            }
            // Not a filtered sequence, keep the byte
            filtered.append(bytes[i])
            i += 1
        }

        return Data(filtered)
    }
}
