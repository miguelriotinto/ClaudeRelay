import Foundation
import SwiftUI
import ClaudeRelayClient
import ClaudeRelayKit

/// Central coordinator for session management in the workspace.
@MainActor
final class SessionCoordinator: ObservableObject {

    // MARK: - Published State

    @Published var sessions: [SessionInfo] = []
    @Published var activeSessionId: UUID?
    @Published var sessionNames: [UUID: String] = [:]
    /// Last known terminal title per session (survives VM destruction on session switch).
    @Published var terminalTitles: [UUID: String] = [:]
    /// Sessions where Claude Code is currently running.
    @Published var claudeSessions: Set<UUID> = []
    /// Sessions currently waiting for user input (e.g. Claude Code prompt).
    @Published var sessionsAwaitingInput: Set<UUID> = []
    @Published var isLoading = false
    @Published private(set) var isRecovering = false
    @Published var errorMessage: String?
    @Published var showError = false
    @Published var connectionTimedOut = false
    /// Set when another device steals the active session — triggers an alert.
    @Published var stolenSessionName: String?
    @Published var stolenSessionShortId: String?
    @Published var showSessionStolen = false

    /// Sessions owned by this device (non-terminal, claimed via create or attach).
    /// Sessions created on other devices won't appear here until explicitly attached.
    var activeSessions: [SessionInfo] {
        sessions.filter { !$0.state.isTerminal && ownedSessionIds.contains($0.id) }
    }

    // MARK: - Dependencies

    let connection: RelayConnection
    private let token: String
    private var sessionController: SessionController?
    private var terminalViewModels: [UUID: TerminalViewModel] = [:]
    var recoveryTask: Task<Void, Never>?
    private var isTornDown = false

    // MARK: - Init

    init(connection: RelayConnection, token: String) {
        self.connection = connection
        self.token = token
        sessionNames = Self.loadNames()
        ownedSessionIds = Self.loadOwned()
        claudeSessions = Self.loadClaudeSessions()

        connection.onReconnected = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.handleAutoReconnect()
            }
        }

        connection.onSessionActivity = { [weak self] sessionId, activity in
            Task { @MainActor [weak self] in
                self?.handleActivityUpdate(sessionId: sessionId, activity: activity)
            }
        }

        connection.onSessionStolen = { [weak self] sessionId in
            Task { @MainActor [weak self] in
                self?.handleSessionStolen(sessionId: sessionId)
            }
        }

        connection.onSessionRenamed = { [weak self] sessionId, name in
            Task { @MainActor [weak self] in
                self?.handleSessionRenamed(sessionId: sessionId, name: name)
            }
        }
    }

    // MARK: - Names

    func name(for id: UUID) -> String {
        sessionNames[id] ?? id.uuidString.prefix(8).description
    }

    func setName(_ name: String, for id: UUID) {
        sessionNames[id] = name
        Self.saveNames(sessionNames)
        Task {
            try? await sessionController?.renameSession(id: id, name: name)
        }
    }

    private func pickDefaultName() -> String {
        let usedNames = Set(sessionNames.values)
        let themeNames = AppSettings.shared.sessionNamingTheme.names
        let available = themeNames.filter { !usedNames.contains($0) }
        return available.randomElement() ?? "Session \(sessionNames.count + 1)"
    }

    // MARK: - Persistence

    private static let namesKey = "com.clauderelay.sessionNames"
    private static func loadNames() -> [UUID: String] {
        guard let data = UserDefaults.standard.data(forKey: namesKey),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict.reduce(into: [:]) { result, pair in
            if let uuid = UUID(uuidString: pair.key) {
                result[uuid] = pair.value
            }
        }
    }

    private static func saveNames(_ names: [UUID: String]) {
        let dict = names.reduce(into: [String: String]()) { $0[$1.key.uuidString] = $1.value }
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: namesKey)
        }
    }

    // MARK: - Claude Session Persistence

    private static let claudeSessionsKey = "com.clauderelay.claudeSessions"

    private static func loadClaudeSessions() -> Set<UUID> {
        guard let arr = UserDefaults.standard.stringArray(forKey: claudeSessionsKey) else { return [] }
        return Set(arr.compactMap { UUID(uuidString: $0) })
    }

    private func saveClaudeSessions() {
        let arr = claudeSessions.map { $0.uuidString }
        UserDefaults.standard.set(arr, forKey: Self.claudeSessionsKey)
    }

    // MARK: - Device-Local Ownership

    /// Session IDs this device has created or attached.
    /// Keyed per device so iCloud UserDefaults sync doesn't merge ownership across devices.
    private(set) var ownedSessionIds: Set<UUID> = []

    private static var ownedKey: String {
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        return "com.clauderelay.ownedSessions.\(deviceId)"
    }

    private static func loadOwned() -> Set<UUID> {
        guard let arr = UserDefaults.standard.stringArray(forKey: ownedKey) else { return [] }
        return Set(arr.compactMap { UUID(uuidString: $0) })
    }

    private func saveOwned() {
        let arr = ownedSessionIds.map { $0.uuidString }
        UserDefaults.standard.set(arr, forKey: Self.ownedKey)
    }

    private func claimSession(_ id: UUID) {
        guard !ownedSessionIds.contains(id) else { return }
        ownedSessionIds.insert(id)
        saveOwned()
    }

    private func unclaimSession(_ id: UUID) {
        ownedSessionIds.remove(id)
        saveOwned()
    }

    // MARK: - Authentication

    private func ensureAuthenticated() async throws -> SessionController {
        if let controller = sessionController, controller.isAuthenticated {
            return controller
        }
        let controller = sessionController ?? SessionController(connection: connection)
        try await controller.authenticate(token: token)
        sessionController = controller
        return controller
    }

    // MARK: - Session List

    private var lastFetchTime: Date = .distantPast

    func fetchSessions() async {
        // Debounce: skip if fetched within the last 500ms
        let now = Date()
        guard now.timeIntervalSince(lastFetchTime) >= 0.5 else { return }
        lastFetchTime = now

        isLoading = true
        defer { isLoading = false }

        do {
            let controller = try await ensureAuthenticated()
            sessions = try await controller.listSessions()

            // Merge server-side names into local cache (server wins).
            for session in sessions {
                if let serverName = session.name {
                    sessionNames[session.id] = serverName
                }
            }
            Self.saveNames(sessionNames)

            // Apply activity state from session list (initial sync on connect/reconnect).
            // Sessions without an activity field (terminated, no PTY) are treated as
            // non-Claude to clear any stale persisted state from a previous launch.
            for session in sessions {
                let activity = session.activity ?? .idle
                handleActivityUpdate(sessionId: session.id, activity: activity)
            }

            // Prune state for sessions that no longer exist on the server.
            let serverIds = Set(sessions.map { $0.id })
            let staleActivity = claudeSessions.subtracting(serverIds)
            if !staleActivity.isEmpty {
                claudeSessions.subtract(staleActivity)
                sessionsAwaitingInput.subtract(staleActivity)
                saveClaudeSessions()
            }
            let staleOwned = ownedSessionIds.subtracting(serverIds)
            if !staleOwned.isEmpty {
                ownedSessionIds.subtract(staleOwned)
                saveOwned()
            }
        } catch {
            // Session list refresh is non-critical — don't alert the user.
        }
    }

    // MARK: - Create

    func createNewSession() async {
        guard !isRecovering else { return }
        do {
            let controller = try await ensureAuthenticated()

            if let currentId = activeSessionId {
                try? await controller.detach()
                terminalViewModels[currentId]?.prepareForSwitch()
                terminalViewModels[currentId] = nil
            }

            let name = pickDefaultName()
            let sessionId = try await controller.createSession(name: name)
            claimSession(sessionId)
            sessionNames[sessionId] = name
            Self.saveNames(sessionNames)

            let vm = TerminalViewModel(sessionId: sessionId, connection: connection)
            terminalViewModels[sessionId] = vm

            wireTerminalOutput(to: sessionId)
            activeSessionId = sessionId

            await fetchSessions()
        } catch {
            presentError(error.localizedDescription)
        }
    }

    // MARK: - Switch

    func switchToSession(id: UUID) async {
        guard !isRecovering, id != activeSessionId else { return }

        do {
            let controller = try await ensureAuthenticated()

            if let currentId = activeSessionId {
                try? await controller.detach()
                terminalViewModels[currentId]?.prepareForSwitch()
                terminalViewModels[currentId] = nil
            }

            try await controller.resumeSession(id: id)

            if terminalViewModels[id] == nil {
                terminalViewModels[id] = TerminalViewModel(sessionId: id, connection: connection)
            } else {
                terminalViewModels[id]?.prepareForSwitch()
            }

            wireTerminalOutput(to: id)
            activeSessionId = id

            await fetchSessions()
        } catch {
            presentError(error.localizedDescription)
        }
    }

    // MARK: - Attach from Another Device

    /// Fetches sessions running on the server that this device has not claimed.
    /// Uses cross-token listing so sessions from other devices (different tokens) are visible.
    func fetchAttachableSessions() async -> [SessionInfo] {
        do {
            let controller = try await ensureAuthenticated()
            let all = try await controller.listAllSessions()
            let filtered = all.filter { session in
                !session.state.isTerminal && !ownedSessionIds.contains(session.id)
            }
            if filtered.isEmpty && !all.isEmpty {
                print("[attach] \(all.count) sessions on server, all filtered out. owned=\(ownedSessionIds.map { $0.uuidString.prefix(8) })")
            }
            return filtered
        } catch {
            print("[attach] listAllSessions failed: \(error)")
            return []
        }
    }

    /// Attaches to a session that may be active on another device.
    /// On failure, the previous active session is preserved so the terminal
    /// does not end up blank with a dangling activeSessionId.
    func attachRemoteSession(id: UUID) async {
        guard !isRecovering else { return }
        let previousId = activeSessionId
        do {
            let controller = try await ensureAuthenticated()

            // Detach current server-side attachment (if any) so the server
            // can accept a new attach on this connection. Keep the local VM
            // in place until the new attach succeeds.
            if previousId != nil {
                try? await controller.detach()
            }

            try await controller.attachSession(id: id)

            // Attach succeeded — now swap the local VM.
            if let currentId = previousId, currentId != id {
                terminalViewModels[currentId]?.prepareForSwitch()
                terminalViewModels[currentId] = nil
            }

            claimSession(id)

            let vm = TerminalViewModel(sessionId: id, connection: connection)
            terminalViewModels[id] = vm
            wireTerminalOutput(to: id)
            activeSessionId = id

            // Prefer the server-side name; fall back to local theme name.
            // Done after wiring so scrollback binary frames aren't dropped.
            if sessionNames[id] == nil {
                let name = pickDefaultName()
                sessionNames[id] = name
                Self.saveNames(sessionNames)
                try? await controller.renameSession(id: id, name: name)
            }

            await fetchSessions()
        } catch {
            // Attach failed. Try to restore the previous session on the server
            // so the local terminal keeps working.
            if let previousId {
                try? await sessionController?.resumeSession(id: previousId)
                wireTerminalOutput(to: previousId)
            }
            presentError(error.localizedDescription)
        }
    }

    // MARK: - Terminate

    func terminateSession(id: UUID) async {
        guard !isRecovering else { return }
        do {
            try await connection.send(.sessionTerminate(sessionId: id))
            // If it was the active session, clear state.
            if activeSessionId == id {
                activeSessionId = nil
                terminalViewModels[id] = nil
            }
            claudeSessions.remove(id)
            unclaimSession(id)
            sessionNames.removeValue(forKey: id)
            terminalTitles.removeValue(forKey: id)
            sessionsAwaitingInput.remove(id)
            Self.saveNames(sessionNames)
            await fetchSessions()
        } catch {
            presentError(error.localizedDescription)
        }
    }

    // MARK: - Access

    func viewModel(for sessionId: UUID) -> TerminalViewModel? {
        terminalViewModels[sessionId]
    }

    func createdAt(for sessionId: UUID) -> Date? {
        sessions.first { $0.id == sessionId }?.createdAt
    }

    /// Whether the session is currently running Claude Code.
    func isRunningClaude(sessionId: UUID) -> Bool {
        claudeSessions.contains(sessionId)
    }

    /// Called by the SwiftTerm delegate when the terminal title changes.
    /// Persists the title so it survives TerminalViewModel destruction on tab switch.
    /// Claude entry/exit detection is handled exclusively by server-side
    /// SessionActivityMonitor via sessionActivity messages — client-side title
    /// detection was removed because scrollback replay re-fires stale OSC titles,
    /// causing false Claude-active state on tab switch.
    func updateTerminalTitle(_ title: String, for sessionId: UUID) {
        terminalTitles[sessionId] = title
    }

    /// Handle server-pushed activity state changes for any session (including background ones).
    ///
    /// This is the single source of truth for Claude detection state on the client.
    /// Called in these scenarios:
    /// - Server pushes real-time state change (ongoing monitoring)
    /// - Server pushes initial state on observer registration (connect/reconnect)
    /// - Session list fetch provides activity snapshot (fallback sync)
    /// - Session attach/resume response includes current activity
    private func handleActivityUpdate(sessionId: UUID, activity: ActivityState) {
        // Update Claude running state
        var claudeChanged = false
        if activity.isClaudeRunning {
            if !claudeSessions.contains(sessionId) {
                claudeSessions.insert(sessionId)
                terminalViewModels[sessionId]?.isClaudeActive = true
                claudeChanged = true
            }
        } else {
            if claudeSessions.contains(sessionId) {
                claudeSessions.remove(sessionId)
                terminalViewModels[sessionId]?.isClaudeActive = false
                claudeChanged = true
            }
        }
        if claudeChanged { saveClaudeSessions() }

        // Update awaiting-input state: only flash when Claude is idle (waiting for input).
        // .claudeIdle is the only state that should trigger the attention flash.
        if activity == .claudeIdle {
            sessionsAwaitingInput.insert(sessionId)
        } else {
            sessionsAwaitingInput.remove(sessionId)
        }
    }

    /// Handle server notification that another device attached to our active session.
    private func handleSessionStolen(sessionId: UUID) {
        let sessionName = name(for: sessionId)
        let shortId = String(sessionId.uuidString.prefix(8))

        // Clean up the stolen session from this device.
        if activeSessionId == sessionId {
            terminalViewModels[sessionId] = nil
            activeSessionId = nil
        }
        claudeSessions.remove(sessionId)
        sessionsAwaitingInput.remove(sessionId)

        stolenSessionName = sessionName
        stolenSessionShortId = shortId
        showSessionStolen = true

        Task { await fetchSessions() }
    }

    /// Handle server broadcast: another connection renamed a session.
    private func handleSessionRenamed(sessionId: UUID, name: String) {
        sessionNames[sessionId] = name
        Self.saveNames(sessionNames)
    }

    // MARK: - Connection Recovery

    /// Called when the app returns to the foreground. Checks if the WebSocket
    /// is still alive and, if not, reconnects + re-authenticates + resumes
    /// the previously active session transparently.
    func handleForegroundTransition() async {
        guard !isRecovering, !isTornDown else { return }

        let alive = await connection.isAlive()
        if alive {
            // Connection survived suspension — refresh activity state from the
            // server since push messages may have been lost while iOS had the
            // app suspended.
            await fetchSessions()
            return
        }

        isRecovering = true
        defer { isRecovering = false }

        // 1. Force-reconnect the transport
        do {
            try await connection.forceReconnect()
        } catch {
            guard !isTornDown else { return }
            if !(error is CancellationError) {
                connectionTimedOut = true
            }
            return
        }

        // 2. Re-auth + resume
        guard !isTornDown else { return }
        await restoreSession()
    }

    /// Called when RelayConnection's exponential-backoff auto-reconnect succeeds.
    /// The transport is up but the server doesn't know us — re-auth + resume.
    private func handleAutoReconnect() async {
        isRecovering = true
        defer { isRecovering = false }

        await restoreSession()
    }

    /// Shared recovery path: re-authenticate and resume the active session.
    private func restoreSession() async {
        sessionController?.resetAuth()

        do {
            let controller = try await ensureAuthenticated()

            guard !isTornDown else { return }
            if let activeId = activeSessionId {
                try await controller.resumeSession(id: activeId)
                wireTerminalOutput(to: activeId)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !isTornDown else { return }
            if activeSessionId != nil {
                activeSessionId = nil
            }
            connectionTimedOut = true
            return
        }

        if !isTornDown {
            await fetchSessions()
        }
    }

    // MARK: - Cleanup

    /// Cancel any in-flight recovery, detach, and disconnect.
    func tearDown() {
        isTornDown = true
        recoveryTask?.cancel()
        recoveryTask = nil
        if activeSessionId != nil {
            Task { try? await sessionController?.detach() }
        }
        connection.disconnect()
    }

    // MARK: - Private

    private func wireTerminalOutput(to sessionId: UUID) {
        // Restore Claude state from persistence onto the (possibly new) VM.
        if claudeSessions.contains(sessionId) {
            terminalViewModels[sessionId]?.isClaudeActive = true
        }

        // The callback fires from the receive loop which is already on MainActor,
        // so no extra Task hop is needed.
        connection.onTerminalOutput = { [weak self] data in
            self?.terminalViewModels[sessionId]?.receiveOutput(data)
        }
        // Persist terminal title changes so they survive VM destruction on session switch.
        terminalViewModels[sessionId]?.onTitleChanged = { [weak self] title in
            self?.updateTerminalTitle(title, for: sessionId)
        }
        // Claude entry/exit and awaiting-input state are driven exclusively by
        // server-side SessionActivityMonitor via sessionActivity messages
        // (handleActivityUpdate). No client-side detection is wired here.
    }

    private func presentError(_ message: String) {
        errorMessage = message
        showError = true
    }

}
