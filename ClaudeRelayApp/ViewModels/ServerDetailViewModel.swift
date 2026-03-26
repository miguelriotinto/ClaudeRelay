import Foundation
import SwiftUI
import ClaudeRelayClient

/// Manages the server detail screen: connection, duplication, deletion.
@MainActor
final class ServerDetailViewModel: ObservableObject {

    @Published var server: ConnectionConfig
    @Published var status: ServerStatus?
    @Published var isConnecting: Bool = false
    @Published var activeConnection: RelayConnection?
    @Published var activeToken: String?
    @Published var isNavigatingToWorkspace: Bool = false
    @Published var errorMessage: String?
    @Published var showError: Bool = false
    @Published var showDeleteConfirmation: Bool = false

    var hasToken: Bool {
        (try? AuthManager.shared.loadToken(for: server.id)) != nil
    }

    init(server: ConnectionConfig) {
        self.server = server
    }

    // MARK: - Actions

    func refreshStatus() async {
        status = await ServerStatusChecker.probe(config: server)
    }

    func connect() async {
        isConnecting = true
        defer { isConnecting = false }

        guard let token = try? AuthManager.shared.loadToken(for: server.id),
              !token.isEmpty else {
            presentError("No auth token saved for this server. Edit the server to add one.")
            return
        }

        let connection = RelayConnection()

        do {
            try await connection.connect(config: server, token: token)
            activeConnection = connection
            activeToken = token
            isNavigatingToWorkspace = true
        } catch {
            presentError(error.localizedDescription)
        }
    }

    func duplicate() -> ConnectionConfig {
        let copy = ConnectionConfig(
            id: UUID(),
            name: "Copy of \(server.name)",
            host: server.host,
            port: server.port,
            useTLS: server.useTLS
        )
        SavedConnectionStore.add(copy)

        // Copy token if one exists for the original server.
        if let token = try? AuthManager.shared.loadToken(for: server.id) {
            try? AuthManager.shared.saveToken(token, for: copy.id)
        }

        return copy
    }

    func delete() {
        try? AuthManager.shared.deleteToken(for: server.id)
        SavedConnectionStore.delete(id: server.id)
    }

    func resetNavigationState() {
        isNavigatingToWorkspace = false
        activeConnection = nil
        activeToken = nil
    }

    // MARK: - Private

    private func presentError(_ message: String) {
        errorMessage = message
        showError = true
    }
}
