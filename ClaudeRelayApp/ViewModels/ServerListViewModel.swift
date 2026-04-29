import Foundation
import SwiftUI
import Combine
import ClaudeRelayClient

@MainActor
final class ServerListViewModel: ObservableObject {

    @Published var servers: [ConnectionConfig] = []
    @Published var serverStatuses: [UUID: ServerStatus] = [:]

    // MARK: - Connection State

    @Published var isConnecting: Bool = false
    @Published var connectingServerId: UUID?
    @Published var connectingServerName: String?
    @Published var activeConnection: RelayConnection?
    @Published var activeToken: String?
    @Published var connectedServerId: UUID?
    @Published var isNavigatingToWorkspace: Bool = false
    @Published var errorMessage: String?
    @Published var showError: Bool = false

    private let statusChecker = ServerStatusChecker()
    private var connectTask: Task<Void, Never>?

    // MARK: - Init

    init() {
        servers = ClaudeRelayApp.savedConnections.loadAll()
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
        servers = ClaudeRelayApp.savedConnections.loadAll()
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
        connectingServerName = server.name
        defer {
            isConnecting = false
            connectingServerId = nil
            connectingServerName = nil
        }

        let connection = RelayConnection()

        do {
            try await connection.connect(config: server, token: token)
            activeConnection = connection
            activeToken = token
            connectedServerId = server.id
            AppSettings.shared.lastConnectedServerId = server.id.uuidString
            statusChecker.stopPolling()
            isNavigatingToWorkspace = true
        } catch {
            if !(error is CancellationError) {
                presentError(error.localizedDescription)
            }
        }
    }

    func cancelConnect() {
        connectTask?.cancel()
        connectTask = nil
        isConnecting = false
        connectingServerId = nil
        connectingServerName = nil
    }

    func startConnect(to server: ConnectionConfig) {
        connectTask = Task {
            await connect(to: server)
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
            servers = ClaudeRelayApp.savedConnections.delete(id: config.id)
        }
        statusChecker.refresh(connections: servers)
    }

    func deleteServer(id: UUID) {
        try? AuthManager.shared.deleteToken(for: id)
        servers = ClaudeRelayApp.savedConnections.delete(id: id)
        statusChecker.refresh(connections: servers)
    }

    // MARK: - Private

    private func presentError(_ message: String) {
        errorMessage = message
        showError = true
    }
}
