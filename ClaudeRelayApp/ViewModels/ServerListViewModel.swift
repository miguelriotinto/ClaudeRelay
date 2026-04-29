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

    enum ReconnectPhase: CaseIterable {
        case credentials, server, connecting, restoring

        var label: String {
            switch self {
            case .credentials: return "Retrieving credentials…"
            case .server:      return "Resolving server…"
            case .connecting:  return "Connecting to server…"
            case .restoring:   return "Restoring workspace…"
            }
        }
    }

    @Published var isAutoReconnecting: Bool = false
    @Published var autoReconnectServerName: String?
    @Published var reconnectPhase: ReconnectPhase = .credentials

    private let statusChecker = ServerStatusChecker()
    private var connectTask: Task<Void, Never>?
    private var autoReconnectTask: Task<Void, Never>?

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

    // MARK: - Auto Connect

    func autoConnectServerIfNeeded() -> ConnectionConfig? {
        let settings = AppSettings.shared
        guard settings.autoConnectEnabled,
              let uuid = UUID(uuidString: settings.lastConnectedServerId),
              let server = servers.first(where: { $0.id == uuid }) else {
            return nil
        }
        return server
    }

    private static let phaseMinDuration: Duration = .milliseconds(500)

    func startAutoReconnect(to server: ConnectionConfig) {
        autoReconnectTask = Task {
            await autoReconnect(to: server)
        }
    }

    func cancelAutoReconnect() {
        autoReconnectTask?.cancel()
        autoReconnectTask = nil
        isAutoReconnecting = false
        autoReconnectServerName = nil
    }

    private func advancePhase(_ phase: ReconnectPhase) async throws {
        reconnectPhase = phase
        try await Task.sleep(for: Self.phaseMinDuration)
    }

    private func autoReconnect(to server: ConnectionConfig) async {
        isAutoReconnecting = true
        autoReconnectServerName = server.name
        reconnectPhase = .credentials

        do {
            // Phase 1: Retrieve credentials from Keychain
            try await advancePhase(.credentials)
            guard let token = try? AuthManager.shared.loadToken(for: server.id),
                  !token.isEmpty else {
                isAutoReconnecting = false
                autoReconnectServerName = nil
                presentError("No auth token saved for \(server.name). Edit the server to add one.")
                return
            }

            // Phase 2: Resolve server endpoint
            try await advancePhase(.server)
            let connection = RelayConnection()

            // Phase 3: WebSocket handshake
            try await advancePhase(.connecting)
            try await connection.connect(config: server, token: token)
            try Task.checkCancellation()

            // Phase 4: Hand off to workspace
            try await advancePhase(.restoring)

            activeConnection = connection
            activeToken = token
            connectedServerId = server.id
            AppSettings.shared.lastConnectedServerId = server.id.uuidString
            statusChecker.stopPolling()
            isAutoReconnecting = false
            autoReconnectServerName = nil
            isNavigatingToWorkspace = true
        } catch {
            isAutoReconnecting = false
            autoReconnectServerName = nil
            if !(error is CancellationError) {
                presentError(error.localizedDescription)
            }
        }
    }

    // MARK: - Private

    private func presentError(_ message: String) {
        errorMessage = message
        showError = true
    }
}
