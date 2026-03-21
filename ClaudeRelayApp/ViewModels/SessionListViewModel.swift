import Foundation
import SwiftUI
import ClaudeRelayClient

/// Drives the SessionListView, fetching sessions and managing creation/resume.
@MainActor
final class SessionListViewModel: ObservableObject {

    // MARK: - State

    @Published var sessions: [SessionInfo] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var showError: Bool = false

    /// Set after creating or resuming a session; used for navigation.
    @Published var activeSessionId: UUID?
    @Published var isNavigatingToTerminal: Bool = false

    // MARK: - Dependencies

    let connection: RelayConnection
    let token: String
    private var sessionController: SessionController?

    // MARK: - Init

    init(connection: RelayConnection, token: String) {
        self.connection = connection
        self.token = token
    }

    // MARK: - Actions

    func fetchSessions() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let controller = sessionController ?? SessionController(connection: connection)
            if sessionController == nil {
                try await controller.authenticate(token: token)
                sessionController = controller
            }

            sessions = try await controller.listSessions()
        } catch {
            presentError(error.localizedDescription)
        }
    }

    func createNewSession() async {
        do {
            let controller = sessionController ?? SessionController(connection: connection)
            if sessionController == nil {
                try await controller.authenticate(token: token)
                sessionController = controller
            }

            let sessionId = try await controller.createSession()
            activeSessionId = sessionId
            isNavigatingToTerminal = true
        } catch {
            presentError(error.localizedDescription)
        }
    }

    func resumeSession(id: UUID) async {
        do {
            let controller = sessionController ?? SessionController(connection: connection)
            if sessionController == nil {
                try await controller.authenticate(token: token)
                sessionController = controller
            }

            try await controller.resumeSession(id: id)
            activeSessionId = id
            isNavigatingToTerminal = true
        } catch {
            presentError(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private func presentError(_ message: String) {
        errorMessage = message
        showError = true
    }
}
