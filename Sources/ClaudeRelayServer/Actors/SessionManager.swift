import Foundation
import ClaudeRelayKit

// MARK: - SessionError

public enum SessionError: Error {
    case notFound(UUID)
    case ownershipViolation
    case invalidTransition(SessionState, SessionState)
    case alreadyAttached
}

// MARK: - SessionManager Actor

public actor SessionManager {
    public let config: RelayConfig
    public let tokenStore: TokenStore
    private var sessions: [UUID: ManagedSession] = [:]
    private var detachTimers: [UUID: Task<Void, Never>] = [:]

    struct ManagedSession {
        var info: SessionInfo
        var ptySession: PTYSession?
    }

    // MARK: - Init

    public init(config: RelayConfig, tokenStore: TokenStore) {
        self.config = config
        self.tokenStore = tokenStore
    }

    // MARK: - Public API

    /// Create a new session bound to the given token.
    public func createSession(
        tokenId: String,
        cols: UInt16 = 80,
        rows: UInt16 = 24
    ) throws -> SessionInfo {
        let id = UUID()
        let now = Date()

        // Create initial info in .starting state (created -> starting)
        let startingInfo = SessionInfo(
            id: id,
            state: .starting,
            tokenId: tokenId,
            createdAt: now,
            cols: cols,
            rows: rows
        )

        // Create PTY session
        let pty = try PTYSession(
            sessionId: id,
            cols: cols,
            rows: rows,
            scrollbackSize: config.scrollbackSize,
            command: "/bin/cat"
        )

        // Transition starting -> activeAttached
        let activeInfo = SessionInfo(
            id: id,
            state: .activeAttached,
            tokenId: tokenId,
            createdAt: now,
            cols: cols,
            rows: rows
        )

        var managed = ManagedSession(info: activeInfo, ptySession: pty)

        // Set up exit handler to transition to .exited
        let manager = self
        Task { [id] in
            await pty.setExitHandler {
                Task {
                    await manager.handlePTYExit(sessionId: id)
                }
            }
        }

        // Store session
        sessions[id] = managed

        return activeInfo
    }

    /// Attach to a session (wire up I/O).
    public func attachSession(
        id: UUID,
        tokenId: String
    ) throws -> (SessionInfo, PTYSession) {
        guard var managed = sessions[id] else {
            throw SessionError.notFound(id)
        }
        guard managed.info.tokenId == tokenId else {
            throw SessionError.ownershipViolation
        }
        guard let pty = managed.ptySession else {
            throw SessionError.notFound(id)
        }

        // Transition to activeAttached
        let newState: SessionState = .activeAttached
        let currentState = managed.info.state

        // If already attached, allow re-attach (replace stale connection)
        guard currentState == .activeAttached || currentState.canTransition(to: newState) else {
            throw SessionError.invalidTransition(currentState, newState)
        }

        let newInfo = SessionInfo(
            id: managed.info.id,
            state: newState,
            tokenId: managed.info.tokenId,
            createdAt: managed.info.createdAt,
            cols: managed.info.cols,
            rows: managed.info.rows
        )
        managed.info = newInfo
        sessions[id] = managed

        return (newInfo, pty)
    }

    /// Detach a session (client disconnected, session stays alive).
    public func detachSession(id: UUID) throws {
        guard var managed = sessions[id] else {
            throw SessionError.notFound(id)
        }

        let currentState = managed.info.state
        let newState: SessionState = .activeDetached
        guard currentState.canTransition(to: newState) else {
            throw SessionError.invalidTransition(currentState, newState)
        }

        let newInfo = SessionInfo(
            id: managed.info.id,
            state: newState,
            tokenId: managed.info.tokenId,
            createdAt: managed.info.createdAt,
            cols: managed.info.cols,
            rows: managed.info.rows
        )
        managed.info = newInfo
        sessions[id] = managed

        // Clear output handler so output goes to ring buffer
        if let pty = managed.ptySession {
            Task {
                await pty.clearOutputHandler()
            }
        }

        // Start detach timeout timer (0 = never expire).
        let timeoutSeconds = config.detachTimeout
        if timeoutSeconds > 0 {
            let manager = self
            let timer = Task<Void, Never> {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
                if !Task.isCancelled {
                    try? await manager.handleDetachTimeout(sessionId: id)
                }
            }
            detachTimers[id]?.cancel()
            detachTimers[id] = timer
        }
    }

    /// Resume a detached session.
    public func resumeSession(
        id: UUID,
        tokenId: String
    ) throws -> (SessionInfo, Data, PTYSession) {
        guard var managed = sessions[id] else {
            throw SessionError.notFound(id)
        }
        guard managed.info.tokenId == tokenId else {
            throw SessionError.ownershipViolation
        }
        guard let pty = managed.ptySession else {
            throw SessionError.notFound(id)
        }

        var currentState = managed.info.state

        // If still attached (client didn't detach cleanly), detach first.
        if currentState == .activeAttached {
            managed.info = SessionInfo(
                id: managed.info.id, state: .activeDetached,
                tokenId: managed.info.tokenId, createdAt: managed.info.createdAt,
                cols: managed.info.cols, rows: managed.info.rows
            )
            currentState = .activeDetached
        }

        guard currentState.canTransition(to: .resuming) else {
            throw SessionError.invalidTransition(currentState, .resuming)
        }

        // Transition through resuming -> activeAttached
        // First: activeDetached -> resuming
        let resumingInfo = SessionInfo(
            id: managed.info.id,
            state: .resuming,
            tokenId: managed.info.tokenId,
            createdAt: managed.info.createdAt,
            cols: managed.info.cols,
            rows: managed.info.rows
        )
        managed.info = resumingInfo

        // Then: resuming -> activeAttached
        let attachedInfo = SessionInfo(
            id: managed.info.id,
            state: .activeAttached,
            tokenId: managed.info.tokenId,
            createdAt: managed.info.createdAt,
            cols: managed.info.cols,
            rows: managed.info.rows
        )
        managed.info = attachedInfo
        sessions[id] = managed

        // Cancel detach timer
        detachTimers[id]?.cancel()
        detachTimers[id] = nil

        // Buffer reading requires awaiting the PTYSession actor, so return
        // empty data here — the caller reads the buffer via pty.readBuffer().
        return (attachedInfo, Data(), pty)
    }

    /// Terminate a session.
    public func terminateSession(id: UUID, tokenId: String? = nil) throws {
        guard var managed = sessions[id] else {
            throw SessionError.notFound(id)
        }

        // Ownership check (skip if admin / nil tokenId)
        if let tokenId = tokenId {
            guard managed.info.tokenId == tokenId else {
                throw SessionError.ownershipViolation
            }
        }

        let currentState = managed.info.state
        let newState: SessionState = .terminated

        // If already terminal, no-op
        guard !currentState.isTerminal else {
            return
        }

        guard currentState.canTransition(to: newState) else {
            throw SessionError.invalidTransition(currentState, newState)
        }

        let newInfo = SessionInfo(
            id: managed.info.id,
            state: newState,
            tokenId: managed.info.tokenId,
            createdAt: managed.info.createdAt,
            cols: managed.info.cols,
            rows: managed.info.rows
        )
        managed.info = newInfo
        sessions[id] = managed

        // Terminate PTY
        if let pty = managed.ptySession {
            Task {
                await pty.terminate()
            }
        }

        // Cancel detach timer
        detachTimers[id]?.cancel()
        detachTimers[id] = nil
    }

    /// List all sessions.
    public func listSessions() -> [SessionInfo] {
        return sessions.values.map { $0.info }
    }

    /// Inspect a single session.
    public func inspectSession(id: UUID) throws -> SessionInfo {
        guard let managed = sessions[id] else {
            throw SessionError.notFound(id)
        }
        return managed.info
    }

    /// List sessions for a specific token.
    public func listSessionsForToken(tokenId: String) -> [SessionInfo] {
        return sessions.values
            .filter { $0.info.tokenId == tokenId }
            .map { $0.info }
    }

    // MARK: - Cleanup

    /// Removes sessions in terminal states (exited, failed, terminated, expired)
    /// that have been in that state for longer than the grace period.
    private func purgeTerminalSessions(gracePeriod: TimeInterval = 300) {
        let cutoff = Date().addingTimeInterval(-gracePeriod)
        let staleIds = sessions.filter { _, managed in
            managed.info.state.isTerminal && managed.info.createdAt < cutoff
        }.map { $0.key }

        for id in staleIds {
            sessions.removeValue(forKey: id)
            detachTimers[id]?.cancel()
            detachTimers.removeValue(forKey: id)
        }

        if !staleIds.isEmpty {
            print("[SessionManager] Purged \(staleIds.count) terminal session(s)")
        }
    }

    // MARK: - Internal Handlers

    private func handlePTYExit(sessionId: UUID) {
        guard var managed = sessions[sessionId] else { return }
        let currentState = managed.info.state
        guard currentState.canTransition(to: .exited) else { return }

        let newInfo = SessionInfo(
            id: managed.info.id,
            state: .exited,
            tokenId: managed.info.tokenId,
            createdAt: managed.info.createdAt,
            cols: managed.info.cols,
            rows: managed.info.rows
        )
        managed.info = newInfo
        managed.ptySession = nil
        sessions[sessionId] = managed

        // Clean up timer
        detachTimers[sessionId]?.cancel()
        detachTimers.removeValue(forKey: sessionId)

        purgeTerminalSessions()
    }

    private func handleDetachTimeout(sessionId: UUID) {
        guard var managed = sessions[sessionId] else { return }
        let currentState = managed.info.state
        guard currentState.canTransition(to: .expired) else { return }

        let newInfo = SessionInfo(
            id: managed.info.id,
            state: .expired,
            tokenId: managed.info.tokenId,
            createdAt: managed.info.createdAt,
            cols: managed.info.cols,
            rows: managed.info.rows
        )
        managed.info = newInfo
        sessions[sessionId] = managed

        // Clean up timer entry
        detachTimers.removeValue(forKey: sessionId)

        // Terminate PTY
        if let pty = managed.ptySession {
            Task {
                await pty.terminate()
            }
        }

        purgeTerminalSessions()
    }
}
