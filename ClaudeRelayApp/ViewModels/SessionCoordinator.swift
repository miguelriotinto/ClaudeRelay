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
    /// Captured shell prompts per session — used to detect Claude exit.
    private var shellPrompts: [UUID: String] = [:]
    var recoveryTask: Task<Void, Never>?
    private var isTornDown = false

    // MARK: - Init

    init(connection: RelayConnection, token: String) {
        self.connection = connection
        self.token = token
        sessionNames = Self.loadNames()

        connection.onReconnected = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.handleAutoReconnect()
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
        } catch {
            // Session list refresh is non-critical — log but don't alert the user.
            print("[SessionCoordinator] fetchSessions failed: \(error.localizedDescription)")
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
            sessionNames.removeValue(forKey: id)
            terminalTitles.removeValue(forKey: id)
            claudeSessions.remove(id)
            shellPrompts.removeValue(forKey: id)
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
    /// Handles Claude entry detection — exit is detected via shell prompt reappearance.
    func updateTerminalTitle(_ title: String, for sessionId: UUID) {
        terminalTitles[sessionId] = title

        if title.localizedCaseInsensitiveContains("claude") {
            if !claudeSessions.contains(sessionId) {
                claudeSessions.insert(sessionId)
            }
        }
    }

    /// Process ANSI-stripped terminal output for shell prompt capture and Claude exit detection.
    func processCleanOutput(_ text: String, for sessionId: UUID) {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if claudeSessions.contains(sessionId) {
            // Claude exit detection: if the shell prompt reappears, Claude has exited.
            if let prompt = shellPrompts[sessionId],
               lines.contains(where: { $0.contains(prompt) }) {
                claudeSessions.remove(sessionId)
            }
        } else {
            // Shell prompt capture/update: keep tracking the latest prompt
            // so it reflects the shell state right before Claude starts.
            if let prompt = lines.last(where: { Self.looksLikeShellPrompt($0) }) {
                shellPrompts[sessionId] = prompt
            }
        }
    }

    /// Heuristic: does this ANSI-stripped line look like a shell prompt?
    private static func looksLikeShellPrompt(_ line: String) -> Bool {
        guard line.count >= 2 else { return false }
        return line.hasSuffix("$") || line.hasSuffix("%") || line.hasSuffix("#")
    }

    // MARK: - Connection Recovery

    /// Called when the app returns to the foreground. Checks if the WebSocket
    /// is still alive and, if not, reconnects + re-authenticates + resumes
    /// the previously active session transparently.
    func handleForegroundTransition() async {
        guard !isRecovering, !isTornDown else { return }

        let alive = await connection.isAlive()
        if alive { return }

        print("[SessionCoordinator] Connection dead after foreground — reconnecting")

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
        print("[SessionCoordinator] Auto-reconnect succeeded — re-authenticating")

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
            print("[SessionCoordinator] Restore cancelled (lifecycle), will retry on next foreground")
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
        // The callback fires from the receive loop which is already on MainActor,
        // so no extra Task hop is needed.
        connection.onTerminalOutput = { [weak self] data in
            self?.terminalViewModels[sessionId]?.receiveOutput(data)
        }
        // Persist terminal title changes so they survive VM destruction on session switch.
        terminalViewModels[sessionId]?.onTitleChanged = { [weak self] title in
            self?.updateTerminalTitle(title, for: sessionId)
        }
        // Feed ANSI-stripped output to coordinator for prompt capture / Claude exit detection.
        terminalViewModels[sessionId]?.onCleanOutput = { [weak self] text in
            self?.processCleanOutput(text, for: sessionId)
        }
        // Track input-awaiting state for tab flashing.
        terminalViewModels[sessionId]?.onAwaitingInputChanged = { [weak self] awaiting in
            if awaiting {
                self?.sessionsAwaitingInput.insert(sessionId)
            } else {
                self?.sessionsAwaitingInput.remove(sessionId)
            }
        }
    }

    private func presentError(_ message: String) {
        errorMessage = message
        showError = true
    }

}
