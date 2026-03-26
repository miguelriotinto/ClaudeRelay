import Foundation
import SwiftUI
import ClaudeRelayClient

/// Drives the Quick Connect sheet for ephemeral or save-and-connect flows.
@MainActor
final class QuickConnectViewModel: ObservableObject {

    @Published var host: String = ""
    @Published var port: String = "9200"
    @Published var token: String = ""
    @Published var useTLS: Bool = false
    @Published var isConnecting: Bool = false
    @Published var activeConnection: RelayConnection?
    @Published var activeToken: String?
    @Published var isNavigatingToWorkspace: Bool = false
    @Published var errorMessage: String?
    @Published var showError: Bool = false

    /// Tracks whether a server was saved (for the onServerSaved callback).
    private(set) var didSaveServer: Bool = false

    var isValid: Bool { !host.isEmpty }

    // MARK: - Actions

    func connectTemporary() async {
        await performConnect(save: false)
    }

    func saveAndConnect() async {
        await performConnect(save: true)
    }

    func resetNavigationState() {
        isNavigatingToWorkspace = false
        activeConnection = nil
        activeToken = nil
    }

    // MARK: - Private

    private func performConnect(save: Bool) async {
        guard isValid else { return }
        guard let portNumber = UInt16(port), portNumber > 0 else {
            presentError("Port must be a number between 1 and 65535.")
            return
        }

        isConnecting = true
        defer { isConnecting = false }

        let config = ConnectionConfig(
            id: UUID(),
            name: host,
            host: host,
            port: portNumber,
            useTLS: useTLS
        )

        if save {
            SavedConnectionStore.add(config)
            if !token.isEmpty {
                try? AuthManager.shared.saveToken(token, for: config.id)
            }
            didSaveServer = true
        }

        let connection = RelayConnection()

        do {
            try await connection.connect(config: config, token: token)
            activeConnection = connection
            activeToken = token
            isNavigatingToWorkspace = true
        } catch {
            presentError(error.localizedDescription)
        }
    }

    private func presentError(_ message: String) {
        errorMessage = message
        showError = true
    }
}
