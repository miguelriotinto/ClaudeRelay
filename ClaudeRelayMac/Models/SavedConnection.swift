import Foundation
import ClaudeRelayClient

/// Manages persistence of saved connections in UserDefaults (Mac-specific storage).
struct SavedConnectionStore {

    private static let userDefaultsKey = "com.clauderelay.mac.savedConnections"

    /// Loads all saved connections from UserDefaults.
    static func loadAll() -> [ConnectionConfig] {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else {
            return []
        }
        return (try? JSONDecoder().decode([ConnectionConfig].self, from: data)) ?? []
    }

    /// Saves the given connections array to UserDefaults.
    static func saveAll(_ connections: [ConnectionConfig]) {
        guard let data = try? JSONEncoder().encode(connections) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }

    /// Adds or updates a connection (replaces entry with matching id) and persists.
    @discardableResult
    static func add(_ connection: ConnectionConfig) -> [ConnectionConfig] {
        var all = loadAll()
        if let index = all.firstIndex(where: { $0.id == connection.id }) {
            all[index] = connection
        } else {
            all.append(connection)
        }
        saveAll(all)
        return all
    }

    /// Removes a connection by id and persists the updated list.
    @discardableResult
    static func delete(id: UUID) -> [ConnectionConfig] {
        var all = loadAll()
        all.removeAll { $0.id == id }
        saveAll(all)
        return all
    }
}
