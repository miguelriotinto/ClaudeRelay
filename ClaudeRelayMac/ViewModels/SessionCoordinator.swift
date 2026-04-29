import Foundation
import ClaudeRelayClient
import ClaudeRelayKit

@MainActor
final class SessionCoordinator: SharedSessionCoordinator {

    // MARK: - Mac-Only Published State

    @Published private(set) var isConnected = false
    @Published private(set) var isAuthenticated = false
    @Published var showQRScanner = false

    // MARK: - Dependencies

    private let config: ConnectionConfig
    private var recoveryObservers: [NSObjectProtocol] = []

    // MARK: - Configuration

    override class var keyPrefix: String { "com.clauderelay.mac" }

    override func sessionNamingTheme() -> SessionNamingTheme {
        AppSettings.shared.sessionNamingTheme
    }

    // MARK: - Init

    init(config: ConnectionConfig, token: String) {
        self.config = config
        super.init(connection: RelayConnection(), token: token)
    }

    // MARK: - Start

    func start() async {
        do {
            try await connection.connect(config: config, token: token)
            isConnected = true
            registerRecoveryObservers()
            _ = try await ensureAuthenticated()
            await fetchSessions()
            if activeSessions.isEmpty {
                await createNewSession()
            } else if activeSessionId == nil, let first = activeSessions.first {
                await switchToSession(id: first.id)
            }
        } catch {
            presentError(error.localizedDescription)
        }
    }

    override func didAuthenticate() {
        isAuthenticated = true
    }

    // MARK: - Recovery Observers

    private func registerRecoveryObservers() {
        startNetworkRecovery()
        let wakeObs = NotificationCenter.default.addObserver(
            forName: SleepWakeObserver.systemDidWake,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handleForegroundTransition()
            }
        }
        recoveryObservers = [wakeObs]
    }

    private func unregisterRecoveryObservers() {
        for obs in recoveryObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        recoveryObservers.removeAll()
    }

    // MARK: - Teardown

    override func tearDown() {
        unregisterRecoveryObservers()
        super.tearDown()
    }

    // MARK: - Navigation

    func switchToNextSession() {
        guard let current = activeSessionId,
              let idx = activeSessions.firstIndex(where: { $0.id == current }) else { return }
        let next = (idx + 1) % activeSessions.count
        let target = activeSessions[next].id
        guard target != current else { return }
        Task { await switchToSession(id: target) }
    }

    func switchToPreviousSession() {
        guard let current = activeSessionId,
              let idx = activeSessions.firstIndex(where: { $0.id == current }) else { return }
        let previous = (idx - 1 + activeSessions.count) % activeSessions.count
        let target = activeSessions[previous].id
        guard target != current else { return }
        Task { await switchToSession(id: target) }
    }

    func switchToSession(atIndex index: Int) {
        guard index >= 0, index < activeSessions.count else { return }
        let target = activeSessions[index].id
        guard target != activeSessionId else { return }
        Task { await switchToSession(id: target) }
    }

    // MARK: - Mac-Only Operations

    func resumeActiveSession() async {
        guard let activeId = activeSessionId else { return }
        terminalViewModels[activeId]?.resetForReplay()
        do {
            let controller = try await ensureAuthenticated()
            try await controller.resumeSession(id: activeId)
            wireTerminalOutput(to: activeId)
        } catch {
            presentError(error.localizedDescription)
        }
    }

    func detachSession(id: UUID) async {
        do {
            let controller = try await ensureAuthenticated()
            if activeSessionId == id {
                try await controller.detach()
                terminalViewModels[id]?.prepareForSwitch()
                terminalViewModels[id] = nil
                activeSessionId = nil
            }
        } catch {
            presentError(error.localizedDescription)
        }
    }

    override func terminateSession(id: UUID) async {
        await super.terminateSession(id: id)
        if activeSessionId == nil, let next = activeSessions.first {
            await switchToSession(id: next.id)
        }
    }
}
