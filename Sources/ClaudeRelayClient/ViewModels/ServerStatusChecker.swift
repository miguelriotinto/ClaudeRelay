import Foundation

public struct ServerStatus: Equatable {
    public var isLive: Bool = false
    public init(isLive: Bool = false) {
        self.isLive = isLive
    }
}

@MainActor
public final class ServerStatusChecker: ObservableObject {

    @Published public var statuses: [UUID: ServerStatus] = [:]

    private var pollTask: Task<Void, Never>?
    private let interval: TimeInterval

    public init(interval: TimeInterval = 15) {
        self.interval = interval
    }

    public func startPolling(connections: [ConnectionConfig]) {
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

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    public func refresh(connections: [ConnectionConfig]) {
        startPolling(connections: connections)
    }

    private func checkAll(_ connections: [ConnectionConfig]) async {
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

    @MainActor
    static func probe(config: ConnectionConfig) async -> ServerStatus {
        guard let token = try? AuthManager.shared.loadToken(for: config.id),
              !token.isEmpty else {
            return ServerStatus()
        }

        let connection = RelayConnection()
        let controller = SessionController(connection: connection)

        let result = await withTaskGroup(of: ServerStatus.self) { group -> ServerStatus in
            group.addTask { @MainActor in
                do {
                    try await connection.connect(config: config, token: token)
                    // Auth proves server is live, token is valid, and protocol
                    // version matches. We skip listSessions — the iOS list no
                    // longer displays session count, and the Workspace fetches
                    // real session data when the user actually opens a server.
                    try await controller.authenticate(token: token)
                    connection.disconnect()
                    return ServerStatus(isLive: true)
                } catch {
                    connection.disconnect()
                    return ServerStatus()
                }
            }

            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return ServerStatus()
            }

            let first = await group.next() ?? ServerStatus()
            group.cancelAll()
            return first
        }

        // Cleanup when the 5s timeout racer wins: the real-work task is cancelled
        // mid-flight and never runs its own disconnect. RelayConnection.disconnect
        // is idempotent, so this is a no-op when the real-work task already ran.
        connection.disconnect()
        return result
    }
}
