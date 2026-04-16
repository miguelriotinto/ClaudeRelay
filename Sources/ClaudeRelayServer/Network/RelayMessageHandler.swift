import NIO
import NIOCore
import NIOWebSocket
import Foundation
import ClaudeRelayKit
import AppKit

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
    private var activityObserverId: UUID?
    private var stealObserverId: UUID?
    private var renameObserverId: UUID?
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
        case .sessionCreate(let name):
            handleSessionCreate(name: name, context: context)
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
        case .sessionListAll:
            handleSessionListAll(context: context)
        case .sessionRename(let sessionId, let name):
            handleSessionRename(sessionId: sessionId, name: name, context: context)
        case .resize(let cols, let rows):
            handleResize(cols: cols, rows: rows, context: context)
        case .pasteImage(let data):
            handlePasteImage(base64Data: data, context: context)
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
            await pty.recordInput()
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

                    // Subscribe to activity updates for all sessions owned by this token.
                    let manager = self.sessionManager
                    let observerCtx = UnsafeTransfer(ctx.value)
                    Task { [weak self] in
                        let observerId = await manager.addActivityObserver(tokenId: info.id) { [weak self] sessionId, activity in
                            observerCtx.value.eventLoop.execute {
                                self?.sendServerMessage(
                                    .sessionActivity(sessionId: sessionId, activity: activity),
                                    context: observerCtx.value
                                )
                            }
                        }
                        // Subscribe to steal notifications so this connection learns
                        // when another device attaches to one of its sessions.
                        let stealId = await manager.addStealObserver(tokenId: info.id) { [weak self] sessionId in
                            observerCtx.value.eventLoop.execute {
                                guard let self = self else { return }
                                // Only notify if this connection is the one that lost the session.
                                if self.attachedSessionId == sessionId {
                                    self.attachedSessionId = nil
                                    self.attachedPTY = nil
                                    self.sendServerMessage(.sessionStolen(sessionId: sessionId), context: observerCtx.value)
                                }
                            }
                        }
                        let renameId = await manager.addRenameObserver(tokenId: info.id) { [weak self] sessionId, name in
                            observerCtx.value.eventLoop.execute {
                                self?.sendServerMessage(.sessionRenamed(sessionId: sessionId, name: name), context: observerCtx.value)
                            }
                        }
                        observerCtx.value.eventLoop.execute {
                            self?.activityObserverId = observerId
                            self?.stealObserverId = stealId
                            self?.renameObserverId = renameId
                        }
                    }
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

    private func handleSessionCreate(name: String?, context: ChannelHandlerContext) {
        guard let tokenId = authenticatedTokenId else { return }
        let sessionManager = self.sessionManager
        let ctx = UnsafeTransfer(context)
        Task { [weak self] in
            do {
                await self?.autoDetachIfNeeded()
                let info = try await sessionManager.createSession(tokenId: tokenId, name: name)
                let sessionId = info.id
                // Attach immediately
                let (_, pty) = try await sessionManager.attachSession(id: sessionId, tokenId: tokenId)
                RelayLogger.log(category: "session", "Session created: \(sessionId) (name: \(name ?? "nil"))")
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

    private func handleSessionRename(sessionId: UUID, name: String, context: ChannelHandlerContext) {
        guard let tokenId = authenticatedTokenId else { return }
        let sessionManager = self.sessionManager
        let ctx = UnsafeTransfer(context)
        Task { [weak self] in
            do {
                try await sessionManager.renameSession(id: sessionId, tokenId: tokenId, name: name)
                RelayLogger.log(category: "session", "Session renamed: \(sessionId) -> \(name)")
            } catch {
                ctx.value.eventLoop.execute {
                    self?.sendServerMessage(.error(code: 404, message: "Rename failed: \(error)"), context: ctx.value)
                }
            }
        }
    }

    // MARK: - Session Attach

    private func handleSessionAttach(sessionId: UUID, context: ChannelHandlerContext) {
        guard let tokenId = authenticatedTokenId else { return }
        let sessionManager = self.sessionManager
        let ctx = UnsafeTransfer(context)
        let myStealId = self.stealObserverId
        Task { [weak self] in
            do {
                await self?.autoDetachIfNeeded()
                let (info, pty) = try await sessionManager.attachSession(id: sessionId, tokenId: tokenId, excludeObserver: myStealId)
                let activity = await pty.getActivityState()
                RelayLogger.log(category: "session", "Session attached: \(sessionId)")
                ctx.value.eventLoop.execute {
                    guard let self = self else { return }
                    self.attachedSessionId = sessionId
                    self.attachedPTY = pty
                    self.sendServerMessage(.sessionAttached(sessionId: sessionId, state: info.state.rawValue), context: ctx.value)
                    self.sendServerMessage(.sessionActivity(sessionId: sessionId, activity: activity), context: ctx.value)
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

    private func handleSessionListAll(context: ChannelHandlerContext) {
        guard isAuthenticated else { return }
        let sessionManager = self.sessionManager
        let ctx = UnsafeTransfer(context)
        Task { [weak self] in
            let sessions = await sessionManager.listAllSessions()
            ctx.value.eventLoop.execute {
                self?.sendServerMessage(.sessionListAll(sessions: sessions), context: ctx.value)
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
        if let observerId = activityObserverId {
            let manager = sessionManager
            activityObserverId = nil
            Task {
                await manager.removeActivityObserver(id: observerId)
            }
        }
        if let observerId = stealObserverId {
            let manager = sessionManager
            stealObserverId = nil
            Task {
                await manager.removeStealObserver(id: observerId)
            }
        }
        if let observerId = renameObserverId {
            let manager = sessionManager
            renameObserverId = nil
            Task {
                await manager.removeRenameObserver(id: observerId)
            }
        }

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

    // MARK: - Paste Image

    /// Handles an image paste from the iOS client.
    /// Decodes the base64 PNG, writes it to the macOS pasteboard,
    /// then sends Cmd+V to the PTY so Claude Code picks it up.
    private func handlePasteImage(base64Data: String, context: ChannelHandlerContext) {
        guard let pty = attachedPTY else {
            sendServerMessage(.error(code: 400, message: "No session attached"), context: context)
            return
        }

        guard let imageData = Data(base64Encoded: base64Data) else {
            sendServerMessage(.pasteImageResult(success: false), context: context)
            return
        }

        // Write image to the macOS system clipboard.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(imageData, forType: .png)

        // Send Cmd+V to the PTY. Terminal emulators encode Cmd+V as the
        // bracketed paste sequence, but the shell/Claude Code actually reads
        // the clipboard directly when it detects a paste. We just need to
        // trigger the paste action — sending the standard "paste" escape
        // that terminals use: the raw Ctrl+V (0x16) character.
        // However, Claude Code is a TUI that reads the clipboard on paste
        // events. The simplest reliable trigger is typing Cmd+V which in
        // a macOS terminal sends nothing special — the terminal emulator
        // itself handles it by reading the clipboard and sending bracketed
        // paste. Since we're writing directly to the PTY (not a terminal
        // emulator), we simulate what the terminal emulator does:
        // send the clipboard content as a bracketed paste.
        //
        // But for images, Claude Code doesn't receive text — it receives
        // a paste event and then checks NSPasteboard for image data.
        // On macOS, the Terminal.app / iTerm sends "\u{16}" (Ctrl+V)
        // for Cmd+V when bracketed paste mode is off. Claude Code's
        // input handler detects this and checks the pasteboard.
        //
        // We send a single newline inside a bracketed paste to signal
        // "something was pasted" while the actual image is on the clipboard.
        let bracketedPasteStart = Data([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]) // ESC[200~
        let bracketedPasteEnd = Data([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E])   // ESC[201~
        let pasteContent = Data("\n".utf8)

        let ctx = UnsafeTransfer(context)
        Task {
            await pty.write(bracketedPasteStart + pasteContent + bracketedPasteEnd)
            ctx.value.eventLoop.execute { [weak self] in
                self?.sendServerMessage(.pasteImageResult(success: true), context: ctx.value)
            }
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
