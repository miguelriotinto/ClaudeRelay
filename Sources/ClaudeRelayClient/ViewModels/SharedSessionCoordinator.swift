import Foundation
import Combine
import ClaudeRelayKit

@MainActor
open class SharedSessionCoordinator: ObservableObject, SessionCoordinating {

    // MARK: - Published State

    @Published public var sessions: [SessionInfo] = []
    @Published public var activeSessionId: UUID?
    @Published public var sessionNames: [UUID: String] = [:]
    @Published public var terminalTitles: [UUID: String] = [:]
    @Published public var claudeSessions: Set<UUID> = []
    @Published public var sessionsAwaitingInput: Set<UUID> = []
    @Published public var isLoading = false
    @Published public private(set) var isRecovering = false
    @Published public var errorMessage: String?
    @Published public var showError = false
    @Published public var connectionTimedOut = false
    @Published public var stolenSessionName: String?
    @Published public var stolenSessionShortId: String?
    @Published public var showSessionStolen = false

    public private(set) var ownedSessionIds: Set<UUID> = []

    public var activeSessions: [SessionInfo] {
        sessions.filter { !$0.state.isTerminal && ownedSessionIds.contains($0.id) }
    }

    // MARK: - Dependencies

    public let connection: RelayConnection
    public let token: String
    public var sessionController: SessionController?
    public var terminalViewModels: [UUID: TerminalViewModel] = [:]
    public var recoveryTask: Task<Void, Never>?
    public var isTornDown = false
    private var lastFetchTime: Date = .distantPast
    private var networkMonitor: NetworkMonitor?
    private var networkObserver: NSObjectProtocol?

    // MARK: - Subclass Hooks

    open class var keyPrefix: String { "com.clauderelay" }

    open func sessionNamingTheme() -> SessionNamingTheme { .gameOfThrones }

    open func didAuthenticate() {}

    public func startNetworkRecovery() {
        guard networkMonitor == nil else { return }
        let monitor = NetworkMonitor()
        networkMonitor = monitor
        networkObserver = NotificationCenter.default.addObserver(
            forName: NetworkMonitor.connectivityRestored,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handleForegroundTransition()
            }
        }
    }

    private func stopNetworkRecovery() {
        if let obs = networkObserver {
            NotificationCenter.default.removeObserver(obs)
            networkObserver = nil
        }
        networkMonitor = nil
    }

    // MARK: - Init

    public init(connection: RelayConnection, token: String) {
        self.connection = connection
        self.token = token
        sessionNames = Self.loadNames()
        ownedSessionIds = Self.loadOwned()
        claudeSessions = Self.loadClaudeSessions()

        connection.onReconnected = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.handleAutoReconnect()
            }
        }
        connection.onSessionActivity = { [weak self] sessionId, activity in
            Task { @MainActor [weak self] in
                self?.handleActivityUpdate(sessionId: sessionId, activity: activity)
            }
        }
        connection.onSessionStolen = { [weak self] sessionId in
            Task { @MainActor [weak self] in
                self?.handleSessionStolen(sessionId: sessionId)
            }
        }
        connection.onSessionRenamed = { [weak self] sessionId, name in
            Task { @MainActor [weak self] in
                self?.handleSessionRenamed(sessionId: sessionId, name: name)
            }
        }
    }

    // MARK: - Names

    public func name(for id: UUID) -> String {
        sessionNames[id] ?? id.uuidString.prefix(8).description
    }

    public func setName(_ name: String, for id: UUID) {
        sessionNames[id] = name
        Self.saveNames(sessionNames)
        Task {
            try? await sessionController?.renameSession(id: id, name: name)
        }
    }

    public func pickDefaultName() -> String {
        SessionNaming.pickDefaultName(
            usedNames: Set(sessionNames.values),
            theme: sessionNamingTheme(),
            fallbackIndex: sessionNames.count + 1
        )
    }

    // MARK: - Persistence

    private static var namesKey: String { "\(keyPrefix).sessionNames" }

    static func loadNames() -> [UUID: String] {
        guard let data = UserDefaults.standard.data(forKey: namesKey),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict.reduce(into: [:]) { result, pair in
            if let uuid = UUID(uuidString: pair.key) {
                result[uuid] = pair.value
            }
        }
    }

    public static func saveNames(_ names: [UUID: String]) {
        let dict = names.reduce(into: [String: String]()) { $0[$1.key.uuidString] = $1.value }
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: namesKey)
        }
    }

    private static var claudeSessionsKey: String { "\(keyPrefix).claudeSessions" }

    static func loadClaudeSessions() -> Set<UUID> {
        guard let arr = UserDefaults.standard.stringArray(forKey: claudeSessionsKey) else { return [] }
        return Set(arr.compactMap { UUID(uuidString: $0) })
    }

    public func saveClaudeSessions() {
        let arr = claudeSessions.map { $0.uuidString }
        UserDefaults.standard.set(arr, forKey: Self.claudeSessionsKey)
    }

    // MARK: - Ownership

    private static var ownedKey: String {
        "\(keyPrefix).ownedSessions.\(DeviceIdentifier().currentID)"
    }

    static func loadOwned() -> Set<UUID> {
        guard let arr = UserDefaults.standard.stringArray(forKey: ownedKey) else { return [] }
        return Set(arr.compactMap { UUID(uuidString: $0) })
    }

    public func saveOwned() {
        let arr = ownedSessionIds.map { $0.uuidString }
        UserDefaults.standard.set(arr, forKey: Self.ownedKey)
    }

    public func claimSession(_ id: UUID) {
        guard !ownedSessionIds.contains(id) else { return }
        ownedSessionIds.insert(id)
        saveOwned()
    }

    public func unclaimSession(_ id: UUID) {
        ownedSessionIds.remove(id)
        saveOwned()
    }

    // MARK: - Auth

    public func ensureAuthenticated() async throws -> SessionController {
        if let controller = sessionController, controller.isAuthenticated {
            return controller
        }
        let controller = sessionController ?? SessionController(connection: connection)
        try await controller.authenticate(token: token)
        sessionController = controller
        didAuthenticate()
        return controller
    }

    // MARK: - Session List

    public func fetchSessions() async {
        let now = Date()
        guard now.timeIntervalSince(lastFetchTime) >= 0.5 else { return }
        lastFetchTime = now

        isLoading = true
        defer { isLoading = false }

        do {
            let controller = try await ensureAuthenticated()
            sessions = try await controller.listSessions()

            for session in sessions {
                if let serverName = session.name {
                    sessionNames[session.id] = serverName
                }
            }
            Self.saveNames(sessionNames)

            for session in sessions {
                let activity = session.activity ?? .idle
                handleActivityUpdate(sessionId: session.id, activity: activity)
            }

            let serverIds = Set(sessions.map { $0.id })
            let staleActivity = claudeSessions.subtracting(serverIds)
            if !staleActivity.isEmpty {
                claudeSessions.subtract(staleActivity)
                sessionsAwaitingInput.subtract(staleActivity)
                saveClaudeSessions()
            }
            let staleOwned = ownedSessionIds.subtracting(serverIds)
            if !staleOwned.isEmpty {
                ownedSessionIds.subtract(staleOwned)
                saveOwned()
            }
            let staleNames = Set(sessionNames.keys).subtracting(serverIds)
            if !staleNames.isEmpty {
                for id in staleNames { sessionNames.removeValue(forKey: id) }
                Self.saveNames(sessionNames)
            }
        } catch {
            // Non-critical refresh.
        }
    }

    // MARK: - Access

    public func viewModel(for sessionId: UUID) -> TerminalViewModel? {
        terminalViewModels[sessionId]
    }

    public func createdAt(for sessionId: UUID) -> Date? {
        sessions.first { $0.id == sessionId }?.createdAt
    }

    public func isRunningClaude(sessionId: UUID) -> Bool {
        claudeSessions.contains(sessionId)
    }

    // MARK: - Create

    public func createNewSession() async {
        guard !isRecovering else { return }
        do {
            let controller = try await ensureAuthenticated()

            if let currentId = activeSessionId {
                try? await controller.detach()
                terminalViewModels[currentId]?.prepareForSwitch()
                terminalViewModels[currentId] = nil
            }

            let name = pickDefaultName()
            let sessionId = try await controller.createSession(name: name)
            claimSession(sessionId)
            sessionNames[sessionId] = name
            Self.saveNames(sessionNames)

            let vm = TerminalViewModel(sessionId: sessionId, connection: connection)
            terminalViewModels[sessionId] = vm
            wireTerminalOutput(to: sessionId)
            activeSessionId = sessionId

            await fetchSessions()
        } catch {
            presentError(error.localizedDescription)
        }
    }

    // MARK: - Switch

    public func switchToSession(id: UUID) async {
        guard !isRecovering, id != activeSessionId else { return }
        do {
            let controller = try await ensureAuthenticated()

            if let currentId = activeSessionId {
                try? await controller.detach()
                terminalViewModels[currentId]?.prepareForSwitch()
                terminalViewModels[currentId] = nil
            }

            try await controller.resumeSession(id: id)

            if terminalViewModels[id] == nil {
                terminalViewModels[id] = TerminalViewModel(sessionId: id, connection: connection)
            } else {
                terminalViewModels[id]?.prepareForSwitch()
            }

            wireTerminalOutput(to: id)
            activeSessionId = id

            await fetchSessions()
        } catch {
            presentError(error.localizedDescription)
        }
    }

    // MARK: - Attach

    public func fetchAttachableSessions() async -> [SessionInfo] {
        do {
            let controller = try await ensureAuthenticated()
            let all = try await controller.listAllSessions()
            return all.filter { session in
                !session.state.isTerminal && !ownedSessionIds.contains(session.id)
            }
        } catch {
            return []
        }
    }

    public func attachRemoteSession(id: UUID, serverName: String? = nil) async {
        guard !isRecovering else { return }
        let previousId = activeSessionId
        do {
            let controller = try await ensureAuthenticated()

            if previousId != nil {
                try? await controller.detach()
            }

            try await controller.attachSession(id: id)

            if let currentId = previousId, currentId != id {
                terminalViewModels[currentId]?.prepareForSwitch()
                terminalViewModels[currentId] = nil
            }

            claimSession(id)
            let vm = TerminalViewModel(sessionId: id, connection: connection)
            terminalViewModels[id] = vm
            wireTerminalOutput(to: id)
            activeSessionId = id

            if let serverName {
                sessionNames[id] = serverName
                Self.saveNames(sessionNames)
            } else if sessionNames[id] == nil {
                let name = pickDefaultName()
                sessionNames[id] = name
                Self.saveNames(sessionNames)
                try? await controller.renameSession(id: id, name: name)
            }

            await fetchSessions()
        } catch {
            if let previousId {
                try? await sessionController?.resumeSession(id: previousId)
                wireTerminalOutput(to: previousId)
            }
            presentError(error.localizedDescription)
        }
    }

    // MARK: - Terminate

    open func terminateSession(id: UUID) async {
        guard !isRecovering else { return }
        do {
            try await connection.send(.sessionTerminate(sessionId: id))
            if activeSessionId == id {
                activeSessionId = nil
                terminalViewModels[id] = nil
            }
            claudeSessions.remove(id)
            unclaimSession(id)
            sessionNames.removeValue(forKey: id)
            terminalTitles.removeValue(forKey: id)
            sessionsAwaitingInput.remove(id)
            Self.saveNames(sessionNames)
            await fetchSessions()
        } catch {
            presentError(error.localizedDescription)
        }
    }

    // MARK: - Activity / Steal / Rename Handlers

    private func handleActivityUpdate(sessionId: UUID, activity: ActivityState) {
        var claudeChanged = false
        if activity.isClaudeRunning {
            if !claudeSessions.contains(sessionId) {
                claudeSessions.insert(sessionId)
                terminalViewModels[sessionId]?.isClaudeActive = true
                claudeChanged = true
            }
        } else {
            if claudeSessions.contains(sessionId) {
                claudeSessions.remove(sessionId)
                terminalViewModels[sessionId]?.isClaudeActive = false
                claudeChanged = true
            }
        }
        if claudeChanged { saveClaudeSessions() }

        if activity == .claudeIdle {
            sessionsAwaitingInput.insert(sessionId)
        } else {
            sessionsAwaitingInput.remove(sessionId)
        }
    }

    private func handleSessionStolen(sessionId: UUID) {
        let sessionName = name(for: sessionId)
        let shortId = String(sessionId.uuidString.prefix(8))

        if activeSessionId == sessionId {
            terminalViewModels[sessionId] = nil
            activeSessionId = nil
        }
        claudeSessions.remove(sessionId)
        sessionsAwaitingInput.remove(sessionId)

        stolenSessionName = sessionName
        stolenSessionShortId = shortId
        showSessionStolen = true

        Task { await fetchSessions() }
    }

    private func handleSessionRenamed(sessionId: UUID, name: String) {
        sessionNames[sessionId] = name
        Self.saveNames(sessionNames)
    }

    // MARK: - Wire Output (subclasses may override to add platform callbacks)

    open func wireTerminalOutput(to sessionId: UUID) {
        if claudeSessions.contains(sessionId) {
            terminalViewModels[sessionId]?.isClaudeActive = true
        }
        connection.onTerminalOutput = { [weak self] data in
            self?.terminalViewModels[sessionId]?.receiveOutput(data)
        }
        terminalViewModels[sessionId]?.onTitleChanged = { [weak self] title in
            self?.terminalTitles[sessionId] = title
        }
    }

    public func presentError(_ message: String) {
        errorMessage = message
        showError = true
    }

    // MARK: - Recovery

    public func handleForegroundTransition() async {
        guard !isRecovering, !isTornDown else { return }

        let alive = await connection.isAlive()
        if alive {
            await fetchSessions()
            return
        }

        isRecovering = true
        defer { isRecovering = false }

        do {
            try await connection.forceReconnect()
        } catch {
            guard !isTornDown else { return }
            if !(error is CancellationError) {
                connectionTimedOut = true
            }
            return
        }

        guard !isTornDown else { return }
        await restoreSession()
    }

    public func handleAutoReconnect() async {
        isRecovering = true
        defer { isRecovering = false }
        await restoreSession()
    }

    public func restoreSession() async {
        sessionController?.resetAuth()
        do {
            let controller = try await ensureAuthenticated()
            guard !isTornDown else { return }
            if let activeId = activeSessionId {
                terminalViewModels[activeId]?.resetForReplay()
                try await controller.resumeSession(id: activeId)
                wireTerminalOutput(to: activeId)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !isTornDown else { return }
            if activeSessionId != nil {
                activeSessionId = nil
            }
            connectionTimedOut = true
            return
        }

        if !isTornDown {
            await fetchSessions()
        }
    }

    // MARK: - Cleanup

    open func tearDown() {
        isTornDown = true
        stopNetworkRecovery()
        recoveryTask?.cancel()
        recoveryTask = nil
        if activeSessionId != nil {
            Task { try? await sessionController?.detach() }
        }
        connection.disconnect()
    }
}
