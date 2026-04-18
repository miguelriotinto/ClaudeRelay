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
    public typealias PTYFactory = @Sendable (UUID, UInt16, UInt16, Int) throws -> any PTYSessionProtocol

    public let config: RelayConfig
    public let tokenStore: TokenStore
    private let ptyFactory: PTYFactory
    private var sessions: [UUID: ManagedSession] = [:]
    private var detachTimers: [UUID: Task<Void, Never>] = [:]
    public typealias ActivityObserver = @Sendable (UUID, ActivityState) -> Void
    private var activityObservers: [UUID: (tokenId: String, callback: ActivityObserver)] = [:]
    public typealias StealObserver = @Sendable (UUID) -> Void
    private var stealObservers: [UUID: (tokenId: String, callback: StealObserver)] = [:]
    public typealias RenameObserver = @Sendable (UUID, String) -> Void
    private var renameObservers: [UUID: (tokenId: String, callback: RenameObserver)] = [:]

    struct ManagedSession {
        var info: SessionInfo
        var ptySession: (any PTYSessionProtocol)?
        var terminalSince: Date?
    }

    // MARK: - Init

    public init(config: RelayConfig, tokenStore: TokenStore, ptyFactory: PTYFactory? = nil) {
        self.config = config
        self.tokenStore = tokenStore
        self.ptyFactory = ptyFactory ?? { id, cols, rows, scrollback in
            try PTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        }
    }

    // MARK: - Public API

    /// Create a new session bound to the given token.
    public func createSession(
        tokenId: String,
        cols: UInt16 = 80,
        rows: UInt16 = 24,
        name: String? = nil
    ) async throws -> SessionInfo {
        let id = UUID()
        let now = Date()

        // Create initial info in .starting state (created -> starting)
        let startingInfo = SessionInfo(
            id: id,
            name: name,
            state: .starting,
            tokenId: tokenId,
            createdAt: now,
            cols: cols,
            rows: rows
        )

        // Create PTY session and activate its read source
        let pty = try ptyFactory(id, cols, rows, config.scrollbackSize)
        await pty.startReading()

        // Transition starting -> activeAttached
        let activeInfo = SessionInfo(
            id: id,
            name: name,
            state: .activeAttached,
            tokenId: tokenId,
            createdAt: now,
            cols: cols,
            rows: rows
        )

        var managed = ManagedSession(info: activeInfo, ptySession: pty)

        // Set up exit handler BEFORE storing — guarantees handler is in place
        // before any EOF from the read source can fire handleExit().
        let manager = self
        await pty.setExitHandler {
            Task {
                await manager.handlePTYExit(sessionId: id)
            }
        }

        let sessionId = id
        await pty.setActivityHandler { [weak self] newState in
            Task {
                await self?.reportActivityChange(sessionId: sessionId, activity: newState)
            }
        }

        // Store session
        sessions[id] = managed

        return activeInfo
    }

    /// Attach to a session (wire up I/O).
    /// - Parameter excludeObserver: Observer ID to exclude from steal notifications
    ///   (the connection doing the attach should not receive its own stolen push).
    /// Supports cross-token attach: if the session belongs to a different token,
    /// ownership is transferred and the old token's observers are notified.
    public func attachSession(
        id: UUID,
        tokenId: String,
        excludeObserver: UUID? = nil
    ) throws -> (SessionInfo, any PTYSessionProtocol) {
        guard var managed = sessions[id] else {
            throw SessionError.notFound(id)
        }
        guard let pty = managed.ptySession else {
            throw SessionError.notFound(id)
        }

        // Transition to activeAttached
        let newState: SessionState = .activeAttached
        let currentState = managed.info.state

        // If already attached, allow re-attach (replace stale connection)
        let isReattach = currentState == .activeAttached
        guard isReattach || currentState.canTransition(to: newState) else {
            throw SessionError.invalidTransition(currentState, newState)
        }

        let oldTokenId = managed.info.tokenId

        // Notify the old token's observers that this session is being stolen.
        if isReattach {
            reportSessionStolen(sessionId: id, tokenId: oldTokenId, excludeObserver: excludeObserver)
        }

        // Transfer ownership to the attaching token (enables cross-device attach).
        let newInfo = SessionInfo(
            id: managed.info.id,
            name: managed.info.name,
            state: newState,
            tokenId: tokenId,
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
            name: managed.info.name,
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
    ) throws -> (SessionInfo, Data, any PTYSessionProtocol) {
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
                id: managed.info.id, name: managed.info.name, state: .activeDetached,
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
            name: managed.info.name,
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
            name: managed.info.name,
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
            name: managed.info.name,
            state: newState,
            tokenId: managed.info.tokenId,
            createdAt: managed.info.createdAt,
            cols: managed.info.cols,
            rows: managed.info.rows
        )
        managed.info = newInfo
        managed.terminalSince = Date()
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

        purgeTerminalSessions()
    }

    /// Rename a session. Validates ownership and broadcasts to observers.
    public func renameSession(id: UUID, tokenId: String, name: String) throws {
        guard var managed = sessions[id] else {
            throw SessionError.notFound(id)
        }
        guard managed.info.tokenId == tokenId else {
            throw SessionError.ownershipViolation
        }

        let info = managed.info
        managed.info = SessionInfo(
            id: info.id,
            name: name,
            state: info.state,
            tokenId: info.tokenId,
            createdAt: info.createdAt,
            cols: info.cols,
            rows: info.rows,
            activity: info.activity
        )
        sessions[id] = managed

        // Broadcast rename to all observers for this token
        for (_, observer) in renameObservers where observer.tokenId == tokenId {
            observer.callback(id, name)
        }
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

    /// List sessions for a specific token, enriched with current activity state.
    public func listSessionsForToken(tokenId: String) async -> [SessionInfo] {
        var results: [SessionInfo] = []
        for managed in sessions.values where managed.info.tokenId == tokenId {
            var info = managed.info
            if let pty = managed.ptySession {
                let activity = await pty.getActivityState()
                info = SessionInfo(
                    id: info.id,
                    name: info.name,
                    state: info.state,
                    tokenId: info.tokenId,
                    createdAt: info.createdAt,
                    cols: info.cols,
                    rows: info.rows,
                    activity: activity
                )
            }
            results.append(info)
        }
        return results
    }

    /// List all sessions across all tokens, enriched with current activity state.
    /// Used for cross-device attach — lets a device see sessions from other tokens.
    public func listAllSessions() async -> [SessionInfo] {
        var results: [SessionInfo] = []
        for managed in sessions.values {
            var info = managed.info
            if let pty = managed.ptySession {
                let activity = await pty.getActivityState()
                info = SessionInfo(
                    id: info.id,
                    name: info.name,
                    state: info.state,
                    tokenId: info.tokenId,
                    createdAt: info.createdAt,
                    cols: info.cols,
                    rows: info.rows,
                    activity: activity
                )
            }
            results.append(info)
        }
        return results
    }

    // MARK: - Activity Observers

    @discardableResult
    public func addActivityObserver(
        tokenId: String,
        callback: @escaping ActivityObserver
    ) async -> UUID {
        let observerId = UUID()
        activityObservers[observerId] = (tokenId: tokenId, callback: callback)

        // Push current activity state for all sessions owned by this token so the
        // client immediately reflects the correct state without waiting for a change.
        for managed in sessions.values where managed.info.tokenId == tokenId {
            guard !managed.info.state.isTerminal, let pty = managed.ptySession else { continue }
            let activity = await pty.getActivityState()
            callback(managed.info.id, activity)
        }

        return observerId
    }

    public func removeActivityObserver(id: UUID) {
        activityObservers.removeValue(forKey: id)
    }

    public func reportActivityChange(sessionId: UUID, activity: ActivityState) {
        guard let managed = sessions[sessionId] else { return }
        guard !managed.info.state.isTerminal else { return }
        let tokenId = managed.info.tokenId
        for (_, observer) in activityObservers where observer.tokenId == tokenId {
            observer.callback(sessionId, activity)
        }
    }

    // MARK: - Steal Observers

    @discardableResult
    public func addStealObserver(
        tokenId: String,
        callback: @escaping StealObserver
    ) -> UUID {
        let observerId = UUID()
        stealObservers[observerId] = (tokenId: tokenId, callback: callback)
        return observerId
    }

    public func removeStealObserver(id: UUID) {
        stealObservers.removeValue(forKey: id)
    }

    private func reportSessionStolen(sessionId: UUID, tokenId: String, excludeObserver: UUID?) {
        for (observerId, observer) in stealObservers where observer.tokenId == tokenId {
            if observerId != excludeObserver {
                observer.callback(sessionId)
            }
        }
    }

    // MARK: - Rename Observers

    @discardableResult
    public func addRenameObserver(
        tokenId: String,
        callback: @escaping RenameObserver
    ) -> UUID {
        let observerId = UUID()
        renameObservers[observerId] = (tokenId: tokenId, callback: callback)
        return observerId
    }

    public func removeRenameObserver(id: UUID) {
        renameObservers.removeValue(forKey: id)
    }

    // MARK: - Shutdown

    /// Terminates all active sessions. Called during graceful server shutdown.
    public func shutdown() async {
        // Collect PTYs to terminate
        var ptysToTerminate: [any PTYSessionProtocol] = []
        for (id, managed) in sessions where !managed.info.state.isTerminal {
            if let pty = managed.ptySession {
                ptysToTerminate.append(pty)
            }
            var updated = managed
            updated.info = SessionInfo(
                id: managed.info.id,
                name: managed.info.name,
                state: .terminated,
                tokenId: managed.info.tokenId,
                createdAt: managed.info.createdAt,
                cols: managed.info.cols,
                rows: managed.info.rows
            )
            sessions[id] = updated
        }
        // Await all PTY terminations in parallel
        await withTaskGroup(of: Void.self) { group in
            for pty in ptysToTerminate {
                group.addTask { await pty.terminate() }
            }
        }
        // Cancel all detach timers
        for (_, timer) in detachTimers {
            timer.cancel()
        }
        detachTimers.removeAll()
    }

    // MARK: - Cleanup

    /// Removes sessions in terminal states (exited, failed, terminated, expired)
    /// that have been in that state for longer than the grace period.
    private func purgeTerminalSessions(gracePeriod: TimeInterval = 300) {
        let cutoff = Date().addingTimeInterval(-gracePeriod)
        let staleIds = sessions.filter { _, managed in
            managed.info.state.isTerminal && (managed.terminalSince ?? managed.info.createdAt) < cutoff
        }.map { $0.key }

        for id in staleIds {
            sessions.removeValue(forKey: id)
            detachTimers[id]?.cancel()
            detachTimers.removeValue(forKey: id)
        }

        if !staleIds.isEmpty {
            RelayLogger.log(category: "session", "Purged \(staleIds.count) terminal session(s)")
        }
    }

    // MARK: - Internal Handlers

    private func handlePTYExit(sessionId: UUID) {
        guard var managed = sessions[sessionId] else { return }
        let currentState = managed.info.state
        guard currentState.canTransition(to: .exited) else { return }

        let newInfo = SessionInfo(
            id: managed.info.id,
            name: managed.info.name,
            state: .exited,
            tokenId: managed.info.tokenId,
            createdAt: managed.info.createdAt,
            cols: managed.info.cols,
            rows: managed.info.rows
        )
        managed.info = newInfo

        // Terminate PTY to close master FD and free the kernel PTY pair
        if let pty = managed.ptySession {
            Task {
                await pty.terminate()
            }
        }
        managed.ptySession = nil
        managed.terminalSince = Date()
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
            name: managed.info.name,
            state: .expired,
            tokenId: managed.info.tokenId,
            createdAt: managed.info.createdAt,
            cols: managed.info.cols,
            rows: managed.info.rows
        )
        managed.info = newInfo
        managed.terminalSince = Date()
        sessions[sessionId] = managed

        // Clean up timer entry
        detachTimers.removeValue(forKey: sessionId)

        // Terminate PTY
        if let pty = managed.ptySession {
            Task {
                await pty.terminate()
            }
        }
        managed.ptySession = nil
        sessions[sessionId] = managed

        purgeTerminalSessions()
    }
}
