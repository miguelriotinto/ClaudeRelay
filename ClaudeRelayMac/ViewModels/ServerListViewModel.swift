import Foundation
import SwiftUI
import ClaudeRelayClient

@MainActor
final class ServerListViewModel: ObservableObject {

    @Published private(set) var connections: [ConnectionConfig] = []
    @Published private(set) var statuses: [UUID: Bool] = [:]
    @Published var selectedConnectionId: UUID?

    private var statusCheckers: [UUID: ServerStatusChecker] = [:]

    init() {
        loadConnections()
    }

    // MARK: - CRUD

    func loadConnections() {
        connections = SavedConnectionStore.loadAll()
        // Select the last-used server if it exists, otherwise the first.
        let lastId = AppSettings.shared.lastServerId
        if let uuid = UUID(uuidString: lastId), connections.contains(where: { $0.id == uuid }) {
            selectedConnectionId = uuid
        } else {
            selectedConnectionId = connections.first?.id
        }
        startAllStatusPolling()
    }

    func addOrUpdate(_ connection: ConnectionConfig) {
        _ = SavedConnectionStore.add(connection)
        loadConnections()
    }

    func delete(id: UUID) {
        statusCheckers[id]?.stopPolling()
        statusCheckers.removeValue(forKey: id)
        statuses.removeValue(forKey: id)
        _ = SavedConnectionStore.delete(id: id)
        loadConnections()
    }

    // MARK: - Selection

    func selectedConnection() -> ConnectionConfig? {
        guard let id = selectedConnectionId else { return nil }
        return connections.first { $0.id == id }
    }

    func markAsLastUsed(_ id: UUID) {
        AppSettings.shared.lastServerId = id.uuidString
    }

    // MARK: - Lifecycle

    /// Stops all reachability polling. Call from views when the ViewModel
    /// goes out of scope (e.g., window closes). Cannot be called from deinit
    /// because stopPolling is @MainActor-isolated.
    func stopAllPolling() {
        for checker in statusCheckers.values {
            checker.stopPolling()
        }
        statusCheckers.removeAll()
    }

    // MARK: - Status Polling

    private func startAllStatusPolling() {
        // Stop pollers for deleted servers.
        let currentIds = Set(connections.map { $0.id })
        for (id, checker) in statusCheckers where !currentIds.contains(id) {
            checker.stopPolling()
            statusCheckers.removeValue(forKey: id)
        }

        // Start polling for new servers.
        for config in connections where statusCheckers[config.id] == nil {
            let checker = ServerStatusChecker()
            checker.startPolling(config)
            statusCheckers[config.id] = checker

            // Bridge the checker's published state into our statuses map.
            let serverId = config.id
            Task { [weak self, weak checker] in
                guard let checker else { return }
                for await reachable in checker.$isReachable.values {
                    await MainActor.run {
                        self?.statuses[serverId] = reachable
                    }
                }
            }
        }
    }
}
