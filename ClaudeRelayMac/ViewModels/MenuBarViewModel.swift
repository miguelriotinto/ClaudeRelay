import Foundation
import SwiftUI
import ClaudeRelayClient
import ClaudeRelayKit

/// Singleton that the menu bar dropdown and main window both write to.
/// When the main window connects, it registers its coordinator here.
@MainActor
final class ActiveCoordinatorRegistry: ObservableObject {
    static let shared = ActiveCoordinatorRegistry()

    @Published private(set) var coordinator: SessionCoordinator?
    @Published private(set) var serverName: String?

    private init() {}

    func register(coordinator: SessionCoordinator, serverName: String) {
        self.coordinator = coordinator
        self.serverName = serverName
    }

    func clear() {
        coordinator = nil
        serverName = nil
    }
}

/// Menu bar dropdown's view model — derived from ActiveCoordinatorRegistry.
@MainActor
final class MenuBarViewModel: ObservableObject {
    @Published private(set) var connectionLabel: String = "Not connected"
    @Published private(set) var connectionColor: Color = .secondary
    @Published private(set) var sessions: [SessionInfo] = []
    @Published private(set) var activityStates: [UUID: ActivityState] = [:]
    @Published private(set) var agentIds: [UUID: String] = [:]
    @Published private(set) var activeSessionId: UUID?

    private var registryTask: Task<Void, Never>?
    private var coordinatorTasks: [Task<Void, Never>] = []

    init() {
        observeRegistry()
    }

    private func observeRegistry() {
        registryTask?.cancel()
        let registry = ActiveCoordinatorRegistry.shared
        registryTask = Task { [weak self] in
            for await coordinator in registry.$coordinator.values {
                guard let self else { return }
                self.cancelCoordinatorTasks()
                if let coordinator {
                    self.connectionLabel = registry.serverName ?? "Connected"
                    self.connectionColor = coordinator.isConnected ? .green : .orange
                    self.followCoordinator(coordinator)
                } else {
                    self.connectionLabel = "Not connected"
                    self.connectionColor = .secondary
                    self.sessions = []
                    self.activityStates = [:]
                    self.agentIds = [:]
                    self.activeSessionId = nil
                }
            }
        }
    }

    private func cancelCoordinatorTasks() {
        for task in coordinatorTasks { task.cancel() }
        coordinatorTasks.removeAll()
    }

    /// Spawns three independent tasks observing the coordinator's published
    /// state. Each task runs until the coordinator is replaced (new coordinator
    /// or nil), at which point cancelCoordinatorTasks() cancels them.
    private func followCoordinator(_ coordinator: SessionCoordinator) {
        // Cancel any pre-existing follow tasks before spawning new ones — avoids
        // stacking three tasks per coordinator swap during rapid reconnects.
        cancelCoordinatorTasks()

        let sessionsTask = Task { [weak self] in
            for await s in coordinator.$sessions.values {
                guard let self else { return }
                self.sessions = s.filter { !$0.state.isTerminal }
                self.recomputeActivityStates(coordinator: coordinator)
            }
        }
        let activeTask = Task { [weak self] in
            for await id in coordinator.$activeSessionId.values {
                guard let self else { return }
                self.activeSessionId = id
            }
        }
        let agentTask = Task { [weak self] in
            for await _ in coordinator.$agentSessions.values {
                guard let self else { return }
                self.recomputeActivityStates(coordinator: coordinator)
            }
        }
        coordinatorTasks = [sessionsTask, activeTask, agentTask]
    }

    private func recomputeActivityStates(coordinator: SessionCoordinator) {
        var states: [UUID: ActivityState] = [:]
        var ids: [UUID: String] = [:]
        for session in sessions {
            let awaiting = coordinator.sessionsAwaitingInput.contains(session.id)
            if let agentId = coordinator.activeAgent(for: session.id) {
                states[session.id] = awaiting ? .agentIdle : .agentActive
                ids[session.id] = agentId
            } else {
                states[session.id] = awaiting ? .idle : .active
            }
        }
        activityStates = states
        agentIds = ids
    }

    deinit {
        registryTask?.cancel()
        for task in coordinatorTasks { task.cancel() }
    }
}
