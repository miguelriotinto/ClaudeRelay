import Foundation
import CodeRelayClient

/// Manages persistence of saved connections in UserDefaults.
struct SavedConnectionStore {

    private static let userDefaultsKey = "com.coderemote.savedConnections"

    /// Loads all saved connections from UserDefaults.
    static func loadAll() -> [ConnectionConfig] {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else {
            return []
        }
        do {
            return try JSONDecoder().decode([ConnectionConfig].self, from: data)
        } catch {
            return []
        }
    }

    /// Saves the given connections array to UserDefaults.
    static func saveAll(_ connections: [ConnectionConfig]) {
        do {
            let data = try JSONEncoder().encode(connections)
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        } catch {
            // Silently fail; production code should log this.
        }
    }

    /// Adds a connection and persists the updated list.
    @discardableResult
    static func add(_ connection: ConnectionConfig) -> [ConnectionConfig] {
        var all = loadAll()
        // Replace if same id exists, otherwise append.
        if let index = all.firstIndex(where: { $0.id == connection.id }) {
            all[index] = connection
        } else {
            all.append(connection)
        }
        saveAll(all)
        return all
    }

    /// Deletes a connection by id and persists the updated list.
    @discardableResult
    static func delete(id: UUID) -> [ConnectionConfig] {
        var all = loadAll()
        all.removeAll { $0.id == id }
        saveAll(all)
        return all
    }
}
