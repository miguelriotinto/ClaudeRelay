import Foundation
import SwiftUI
import Combine
import ClaudeRelayClient

/// Manages the server list, status polling, and connection lifecycle.
@MainActor
final class ServerListViewModel: ObservableObject {

    @Published var servers: [ConnectionConfig] = []
    @Published var serverStatuses: [UUID: ServerStatus] = [:]

    // MARK: - Connection State

    @Published var isConnecting: Bool = false
    @Published var connectingServerId: UUID?
    @Published var activeConnection: RelayConnection?
    @Published var activeToken: String?
    @Published var connectedServerId: UUID?
    @Published var isNavigatingToWorkspace: Bool = false
    @Published var errorMessage: String?
    @Published var showError: Bool = false

    private let statusChecker = ServerStatusChecker()

    // MARK: - Init

    init() {
        servers = SavedConnectionStore.loadAll()
        statusChecker.$statuses.assign(to: &$serverStatuses)
    }

    // MARK: - Polling

    func startPolling() {
        statusChecker.startPolling(connections: servers)
    }

    func stopPolling() {
        statusChecker.stopPolling()
    }

    // MARK: - Actions

    func refreshServers() {
        servers = SavedConnectionStore.loadAll()
        statusChecker.refresh(connections: servers)
    }

    func refreshStatuses() {
        statusChecker.refresh(connections: servers)
    }

    func connect(to server: ConnectionConfig) async {
        guard let token = try? AuthManager.shared.loadToken(for: server.id),
              !token.isEmpty else {
            presentError("No auth token saved for \(server.name). Edit the server to add one.")
            return
        }

        isConnecting = true
        connectingServerId = server.id
        defer {
            isConnecting = false
            connectingServerId = nil
        }

        let connection = RelayConnection()

        do {
            try await connection.connect(config: server, token: token)
            activeConnection = connection
            activeToken = token
            connectedServerId = server.id
            statusChecker.stopPolling()
            isNavigatingToWorkspace = true
        } catch {
            presentError(error.localizedDescription)
        }
    }

    func resetNavigationState() {
        isNavigatingToWorkspace = false
        activeConnection = nil
        activeToken = nil
        connectedServerId = nil
        refreshServers()
        startPolling()
    }

    func deleteServer(at offsets: IndexSet) {
        for index in offsets {
            let config = servers[index]
            try? AuthManager.shared.deleteToken(for: config.id)
            servers = SavedConnectionStore.delete(id: config.id)
        }
        statusChecker.refresh(connections: servers)
    }

    func deleteServer(id: UUID) {
        try? AuthManager.shared.deleteToken(for: id)
        servers = SavedConnectionStore.delete(id: id)
        statusChecker.refresh(connections: servers)
    }

    // MARK: - Private

    private func presentError(_ message: String) {
        errorMessage = message
        showError = true
    }
}
