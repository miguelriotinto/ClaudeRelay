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

    /// Active (non-terminal) sessions, cached to avoid recomputing on every SwiftUI redraw.
    var activeSessions: [SessionInfo] {
        sessions.filter { !$0.state.isTerminal }
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
        claudeSessions = []

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
    }

    // MARK: - Names

    func name(for id: UUID) -> String {
        sessionNames[id] ?? id.uuidString.prefix(8).description
    }

    func setName(_ name: String, for id: UUID) {
        sessionNames[id] = name
        Self.saveNames(sessionNames)
    }

    private func assignDefaultName(for id: UUID) {
        let usedNames = Set(sessionNames.values)
        let themeNames = AppSettings.shared.sessionNamingTheme.names
        let available = themeNames.filter { !usedNames.contains($0) }
        let name = available.randomElement() ?? "Session \(sessionNames.count + 1)"
        sessionNames[id] = name
        Self.saveNames(sessionNames)
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

            // Apply activity state from session list (initial sync on connect/reconnect).
            for session in sessions {
                if let activity = session.activity {
                    handleActivityUpdate(sessionId: session.id, activity: activity)
                }
            }

            // Prune Claude state for sessions that no longer exist on the server.
            let serverIds = Set(sessions.map { $0.id })
            let stale = claudeSessions.subtracting(serverIds)
            if !stale.isEmpty {
                claudeSessions.subtract(stale)
                sessionsAwaitingInput.subtract(stale)
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

            let sessionId = try await controller.createSession()
            assignDefaultName(for: sessionId)

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
    private func handleActivityUpdate(sessionId: UUID, activity: ActivityState) {
        // Update Claude running state
        if activity.isClaudeRunning {
            if !claudeSessions.contains(sessionId) {
                claudeSessions.insert(sessionId)
                terminalViewModels[sessionId]?.isClaudeActive = true
            }
        } else {
            if claudeSessions.contains(sessionId) {
                claudeSessions.remove(sessionId)
                terminalViewModels[sessionId]?.isClaudeActive = false
            }
        }

        // Update awaiting-input state (only flash for Claude sessions)
        if activity.isAwaitingInput && activity.isClaudeRunning {
            sessionsAwaitingInput.insert(sessionId)
        } else {
            sessionsAwaitingInput.remove(sessionId)
        }
    }

    // MARK: - Connection Recovery

    /// Called when the app returns to the foreground. Checks if the WebSocket
    /// is still alive and, if not, reconnects + re-authenticates + resumes
    /// the previously active session transparently.
    func handleForegroundTransition() async {
        guard !isRecovering, !isTornDown else { return }

        let alive = await connection.isAlive()
        if alive { return }

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
