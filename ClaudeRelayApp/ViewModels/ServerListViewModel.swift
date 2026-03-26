import Foundation
import SwiftUI
import Combine
import ClaudeRelayClient

/// Manages the server list and status polling.
@MainActor
final class ServerListViewModel: ObservableObject {

    @Published var servers: [ConnectionConfig] = []
    @Published var serverStatuses: [UUID: ServerStatus] = [:]

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

    func deleteServer(at offsets: IndexSet) {
        for index in offsets {
            let config = servers[index]
            try? AuthManager.shared.deleteToken(for: config.id)
            servers = SavedConnectionStore.delete(id: config.id)
        }
        statusChecker.refresh(connections: servers)
    }
}
