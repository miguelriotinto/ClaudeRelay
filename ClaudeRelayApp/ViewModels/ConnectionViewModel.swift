import Foundation
import SwiftUI
import Combine
import ClaudeRelayClient

/// Drives the ConnectionView form and manages saved connections.
@MainActor
final class ConnectionViewModel: ObservableObject {

    // MARK: - Form Fields

    @Published var name: String = ""
    @Published var host: String = ""
    @Published var port: String = "9200"
    @Published var token: String = ""
    @Published var useTLS: Bool = false

    // MARK: - State

    @Published var savedConnections: [ConnectionConfig] = []
    @Published var isConnecting: Bool = false
    @Published var errorMessage: String?
    @Published var showError: Bool = false

    /// Set after a successful connection; used for navigation.
    @Published var activeConnection: RelayConnection?
    @Published var activeToken: String?
    @Published var isNavigatingToSessions: Bool = false

    /// Server liveness and session counts, forwarded from the status checker.
    @Published var serverStatuses: [UUID: ServerStatus] = [:]

    private let statusChecker = ServerStatusChecker()

    // MARK: - Init

    init() {
        savedConnections = SavedConnectionStore.loadAll()
        // Forward nested ObservableObject changes so SwiftUI observes them.
        statusChecker.$statuses.assign(to: &$serverStatuses)
        statusChecker.startPolling(connections: savedConnections)
    }

    /// Trigger an immediate status refresh (e.g. when the view appears).
    func refreshStatuses() {
        statusChecker.refresh(connections: savedConnections)
    }

    // MARK: - Actions

    func connect() async {
        guard !host.isEmpty else {
            presentError("Host is required.")
            return
        }
        guard let portNumber = UInt16(port), portNumber > 0 else {
            presentError("Port must be a number between 1 and 65535.")
            return
        }

        isConnecting = true
        defer { isConnecting = false }

        // Reuse existing connection's ID to avoid orphaning Keychain tokens.
        let existingId = savedConnections.first { $0.host == host && $0.port == portNumber }?.id
        let config = ConnectionConfig(
            id: existingId ?? UUID(),
            name: name.isEmpty ? host : name,
            host: host,
            port: portNumber,
            useTLS: useTLS
        )

        let connection = RelayConnection()

        do {
            try await connection.connect(config: config, token: token)

            // Save connection for future use.
            saveConnection(config)

            // Store token in Keychain.
            if !token.isEmpty {
                try? AuthManager.shared.saveToken(token, for: config.id)
            }

            activeConnection = connection
            activeToken = token
            isNavigatingToSessions = true
        } catch {
            presentError(error.localizedDescription)
        }
    }

    /// Clear stale navigation state so the view becomes interactive again.
    func resetNavigationState() {
        isNavigatingToSessions = false
        activeConnection = nil
        activeToken = nil
    }

    func fillFromSaved(_ config: ConnectionConfig) {
        name = config.name
        host = config.host
        port = String(config.port)
        useTLS = config.useTLS
        // Attempt to load token from Keychain.
        token = (try? AuthManager.shared.loadToken(for: config.id)) ?? ""
    }

    func saveConnection(_ config: ConnectionConfig) {
        savedConnections = SavedConnectionStore.add(config)
        statusChecker.refresh(connections: savedConnections)
    }

    func deleteConnection(at offsets: IndexSet) {
        for index in offsets {
            let config = savedConnections[index]
            try? AuthManager.shared.deleteToken(for: config.id)
            savedConnections = SavedConnectionStore.delete(id: config.id)
        }
        statusChecker.refresh(connections: savedConnections)
    }

    // MARK: - Helpers

    private func presentError(_ message: String) {
        errorMessage = message
        showError = true
    }
}
