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
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var showError = false

    // MARK: - Dependencies

    let connection: RelayConnection
    private let token: String
    private var sessionController: SessionController?
    private var terminalViewModels: [UUID: TerminalViewModel] = [:]

    // MARK: - Init

    init(connection: RelayConnection, token: String) {
        self.connection = connection
        self.token = token
        sessionNames = Self.loadNames()
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
        let name = Self.gotNames.randomElement() ?? "Unnamed"
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

    func fetchSessions() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let controller = try await ensureAuthenticated()
            sessions = try await controller.listSessions()
        } catch {
            presentError(error.localizedDescription)
        }
    }

    // MARK: - Create

    func createNewSession() async {
        do {
            let controller = try await ensureAuthenticated()

            if let currentId = activeSessionId {
                try? await controller.detach()
                terminalViewModels[currentId]?.prepareForSwitch()
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
        guard id != activeSessionId else { return }

        do {
            let controller = try await ensureAuthenticated()

            if let currentId = activeSessionId {
                try? await controller.detach()
                terminalViewModels[currentId]?.prepareForSwitch()
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
        do {
            try await connection.send(.sessionTerminate(sessionId: id))
            // If it was the active session, clear state.
            if activeSessionId == id {
                activeSessionId = nil
                terminalViewModels[id] = nil
            }
            sessionNames.removeValue(forKey: id)
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

    // MARK: - Foreground Recovery

    /// Called when the app returns to the foreground. Checks if the WebSocket
    /// is still alive and, if not, reconnects + re-authenticates + resumes
    /// the previously active session transparently.
    func handleForegroundTransition() async {
        let alive = await connection.isAlive()
        if alive { return }

        print("[SessionCoordinator] Connection dead after foreground — reconnecting")

        // 1. Force-reconnect the transport
        do {
            try await connection.forceReconnect()
        } catch {
            presentError("Reconnection failed: \(error.localizedDescription)")
            return
        }

        // 2. Force re-authentication (server doesn't know this new WebSocket)
        sessionController?.resetAuth()

        do {
            let controller = try await ensureAuthenticated()

            // 3. Resume the session that was active before backgrounding
            if let activeId = activeSessionId {
                try await controller.resumeSession(id: activeId)
                wireTerminalOutput(to: activeId)
            }
        } catch {
            // Session may have been terminated server-side while backgrounded
            if activeSessionId != nil {
                activeSessionId = nil
                presentError("Session could not be restored: \(error.localizedDescription)")
            }
        }

        await fetchSessions()
    }

    // MARK: - Cleanup

    func detachActive() {
        guard activeSessionId != nil else { return }
        Task {
            try? await sessionController?.detach()
        }
    }

    // MARK: - Private

    private func wireTerminalOutput(to sessionId: UUID) {
        connection.onTerminalOutput = { [weak self] data in
            guard let self = self else { return }
            Task { @MainActor in
                self.terminalViewModels[sessionId]?.receiveOutput(data)
            }
        }
    }

    private func presentError(_ message: String) {
        errorMessage = message
        showError = true
    }

    // MARK: - GoT Character Names

    static let gotNames = [
        "Arya", "Tyrion", "Daenerys", "Jon Snow", "Cersei",
        "Sansa", "Bran", "Jaime", "Brienne", "Theon",
        "Samwell", "Jorah", "Davos", "Missandei", "Varys",
        "Tormund", "Podrick", "Gendry", "Bronn", "Sandor",
        "Melisandre", "Ygritte", "Oberyn", "Margaery", "Olenna",
        "Ramsay", "Stannis", "Robb", "Catelyn", "Ned",
        "Hodor", "Gilly", "Drogo", "Viserys", "Littlefinger",
        "Tywin", "Joffrey", "Tommen", "Myrcella", "Rickon",
        "Osha", "Shae", "Yara", "Euron", "Ellaria",
        "Grey Worm", "Barristan", "Jojen", "Meera", "Benjen",
        "Lyanna", "Rhaegar", "Aemon", "Qyburn", "Septa",
        "Ros", "Talisa", "Edmure", "Blackfish", "Walder Frey",
        "Loras", "Renly", "Robert", "Lancel", "Hot Pie",
        "Nymeria", "Ghost", "Drogon", "Rhaegal", "Viserion",
    ]
}
