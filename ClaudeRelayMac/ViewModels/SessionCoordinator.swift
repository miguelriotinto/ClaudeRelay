import Foundation
import SwiftUI
import ClaudeRelayClient
import ClaudeRelayKit

/// Minimal Phase 1 coordinator: connect, auth, one session.
/// Phase 2 expands this with full session lifecycle, sidebar, observers.
@MainActor
final class SessionCoordinator: ObservableObject {

    // MARK: - Published state

    @Published private(set) var isConnected = false
    @Published private(set) var isAuthenticated = false
    @Published private(set) var activeSessionId: UUID?
    @Published private(set) var errorMessage: String?

    // MARK: - Dependencies

    let connection: RelayConnection
    private var sessionController: SessionController?
    private(set) var terminalViewModel: TerminalViewModel?

    private let config: ConnectionConfig
    private let token: String

    init(config: ConnectionConfig, token: String) {
        self.config = config
        self.token = token
        self.connection = RelayConnection()
    }

    // MARK: - Lifecycle

    func start() async {
        do {
            try await connection.connect(config: config, token: token)
            isConnected = true
            let controller = SessionController(connection: connection)
            try await controller.authenticate(token: token)
            sessionController = controller
            isAuthenticated = true

            let sessionId = try await controller.createSession(name: nil)
            let vm = TerminalViewModel(sessionId: sessionId, connection: connection)
            terminalViewModel = vm
            activeSessionId = sessionId
            wireOutput(to: sessionId, vm: vm)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func tearDown() {
        Task { try? await sessionController?.detach() }
        connection.disconnect()
    }

    // MARK: - Private

    private func wireOutput(to sessionId: UUID, vm: TerminalViewModel) {
        connection.onTerminalOutput = { [weak vm] data in
            vm?.receiveOutput(data)
        }
    }
}
