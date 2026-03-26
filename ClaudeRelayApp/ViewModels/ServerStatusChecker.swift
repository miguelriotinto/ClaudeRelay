import Foundation
import ClaudeRelayClient
import ClaudeRelayKit

/// Status of a single saved server connection.
struct ServerStatus: Equatable {
    var isLive: Bool = false
    var sessionCount: Int = 0
}

/// Periodically probes each saved connection over WebSocket to check
/// liveness (auth success) and session count (session_list).
@MainActor
final class ServerStatusChecker: ObservableObject {

    @Published var statuses: [UUID: ServerStatus] = [:]

    private var pollTask: Task<Void, Never>?
    private let interval: TimeInterval

    init(interval: TimeInterval = 15) {
        self.interval = interval
    }

    func startPolling(connections: [ConnectionConfig]) {
        pollTask?.cancel()
        guard !connections.isEmpty else { return }

        pollTask = Task { [weak self, interval] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.checkAll(connections)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh(connections: [ConnectionConfig]) {
        startPolling(connections: connections)
    }

    // MARK: - Private

    private func checkAll(_ connections: [ConnectionConfig]) async {
        // Probe all connections concurrently.
        await withTaskGroup(of: (UUID, ServerStatus).self) { group in
            for config in connections {
                group.addTask {
                    let status = await Self.probe(config: config)
                    return (config.id, status)
                }
            }

            for await (id, status) in group {
                statuses[id] = status
            }
        }
    }

    /// Opens a short-lived WebSocket, authenticates, queries session list, then disconnects.
    @MainActor
    static func probe(config: ConnectionConfig) async -> ServerStatus {
        // Load token from Keychain — without it we can't authenticate.
        guard let token = try? AuthManager.shared.loadToken(for: config.id),
              !token.isEmpty else {
            return ServerStatus()
        }

        let connection = RelayConnection()
        let controller = SessionController(connection: connection)

        // Wrap in a timeout so slow/dead servers don't block the poll cycle.
        let result = await withTaskGroup(of: ServerStatus.self) { group -> ServerStatus in
            group.addTask { @MainActor in
                do {
                    try await connection.connect(config: config, token: token)
                    try await controller.authenticate(token: token)

                    let sessions = try await controller.listSessions()
                    connection.disconnect()
                    return ServerStatus(isLive: true, sessionCount: sessions.count)
                } catch {
                    connection.disconnect()
                    return ServerStatus()
                }
            }

            // Timeout task
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return ServerStatus()
            }

            // Return whichever finishes first
            let first = await group.next() ?? ServerStatus()
            group.cancelAll()
            return first
        }

        // Ensure connection is cleaned up even if timeout won the race
        connection.disconnect()
        return result
    }
}
