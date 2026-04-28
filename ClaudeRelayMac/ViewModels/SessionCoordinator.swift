import Foundation
import SwiftUI
import IOKit
import ClaudeRelayClient
import ClaudeRelayKit

@MainActor
final class SessionCoordinator: ObservableObject {

    // MARK: - Published State

    @Published var sessions: [SessionInfo] = []
    @Published var activeSessionId: UUID?
    @Published var sessionNames: [UUID: String] = [:]
    @Published var terminalTitles: [UUID: String] = [:]
    @Published var claudeSessions: Set<UUID> = []
    @Published var sessionsAwaitingInput: Set<UUID> = []
    @Published var isLoading = false
    @Published private(set) var isRecovering = false
    @Published var errorMessage: String?
    @Published var showError = false
    @Published var connectionTimedOut = false
    @Published var stolenSessionName: String?
    @Published var stolenSessionShortId: String?
    @Published var showSessionStolen = false
    @Published private(set) var isConnected = false
    @Published private(set) var isAuthenticated = false

    /// Sessions owned by this device (non-terminal, claimed via create or attach).
    private(set) var ownedSessionIds: Set<UUID> = []

    var activeSessions: [SessionInfo] {
        sessions.filter { !$0.state.isTerminal && ownedSessionIds.contains($0.id) }
    }

    // MARK: - Dependencies

    let connection: RelayConnection
    let token: String
    private let config: ConnectionConfig
    var sessionController: SessionController?
    var terminalViewModels: [UUID: TerminalViewModel] = [:]
    var recoveryTask: Task<Void, Never>?
    var isTornDown = false
    private var lastFetchTime: Date = .distantPast

    // MARK: - Init

    init(config: ConnectionConfig, token: String) {
        self.config = config
        self.token = token
        self.connection = RelayConnection()

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

    // MARK: - Start

    func start() async {
        do {
            try await connection.connect(config: config, token: token)
            isConnected = true
            _ = try await ensureAuthenticated()
            await fetchSessions()
            // If we have no owned sessions yet, create one.
            if activeSessions.isEmpty {
                await createNewSession()
            } else if activeSessionId == nil, let first = activeSessions.first {
                await switchToSession(id: first.id)
            }
        } catch {
            presentError(error.localizedDescription)
        }
    }

    func tearDown() {
        isTornDown = true
        recoveryTask?.cancel()
        recoveryTask = nil
        if activeSessionId != nil {
            Task { try? await sessionController?.detach() }
        }
        connection.disconnect()
    }

    // MARK: - Names

    func name(for id: UUID) -> String {
        sessionNames[id] ?? id.uuidString.prefix(8).description
    }

    func setName(_ name: String, for id: UUID) {
        sessionNames[id] = name
        Self.saveNames(sessionNames)
        Task {
            try? await sessionController?.renameSession(id: id, name: name)
        }
    }

    func pickDefaultName() -> String {
        // Default name pool — replaced by naming-theme picker in Phase 3.
        let usedNames = Set(sessionNames.values)
        let pool = ["alpha", "beta", "gamma", "delta", "epsilon",
                    "zeta", "eta", "theta", "iota", "kappa"]
        return pool.first { !usedNames.contains($0) } ?? "Session \(sessionNames.count + 1)"
    }

    // MARK: - Persistence

    private static let namesKey = "com.clauderelay.mac.sessionNames"
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

    static func saveNames(_ names: [UUID: String]) {
        let dict = names.reduce(into: [String: String]()) { $0[$1.key.uuidString] = $1.value }
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: namesKey)
        }
    }

    private static let claudeSessionsKey = "com.clauderelay.mac.claudeSessions"
    private static func loadClaudeSessions() -> Set<UUID> {
        guard let arr = UserDefaults.standard.stringArray(forKey: claudeSessionsKey) else { return [] }
        return Set(arr.compactMap { UUID(uuidString: $0) })
    }
    func saveClaudeSessions() {
        let arr = claudeSessions.map { $0.uuidString }
        UserDefaults.standard.set(arr, forKey: Self.claudeSessionsKey)
    }

    /// Device-local ownership key. Uses the Mac's hardware UUID so ownership
    /// doesn't leak between machines if UserDefaults ever sync.
    private static var ownedKey: String {
        let deviceId = macDeviceID()
        return "com.clauderelay.mac.ownedSessions.\(deviceId)"
    }

    private static func macDeviceID() -> String {
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        defer { IOObjectRelease(platformExpert) }
        if platformExpert != 0,
           let serial = IORegistryEntryCreateCFProperty(
               platformExpert,
               kIOPlatformUUIDKey as CFString,
               kCFAllocatorDefault, 0
           )?.takeUnretainedValue() as? String {
            return serial
        }
        return "unknown"
    }

    private static func loadOwned() -> Set<UUID> {
        guard let arr = UserDefaults.standard.stringArray(forKey: ownedKey) else { return [] }
        return Set(arr.compactMap { UUID(uuidString: $0) })
    }

    func saveOwned() {
        let arr = ownedSessionIds.map { $0.uuidString }
        UserDefaults.standard.set(arr, forKey: Self.ownedKey)
    }

    func claimSession(_ id: UUID) {
        guard !ownedSessionIds.contains(id) else { return }
        ownedSessionIds.insert(id)
        saveOwned()
    }

    func unclaimSession(_ id: UUID) {
        ownedSessionIds.remove(id)
        saveOwned()
    }

    // MARK: - Auth

    func ensureAuthenticated() async throws -> SessionController {
        if let controller = sessionController, controller.isAuthenticated {
            return controller
        }
        let controller = sessionController ?? SessionController(connection: connection)
        try await controller.authenticate(token: token)
        sessionController = controller
        isAuthenticated = true
        return controller
    }

    // MARK: - List

    func fetchSessions() async {
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

            // Prune stale state for sessions no longer on the server.
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

    func viewModel(for sessionId: UUID) -> TerminalViewModel? {
        terminalViewModels[sessionId]
    }

    func createdAt(for sessionId: UUID) -> Date? {
        sessions.first { $0.id == sessionId }?.createdAt
    }

    func isRunningClaude(sessionId: UUID) -> Bool {
        claudeSessions.contains(sessionId)
    }

    // MARK: - Activity / Steal / Rename handlers

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

    // MARK: - Wire output

    func wireTerminalOutput(to sessionId: UUID) {
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

    func presentError(_ message: String) {
        errorMessage = message
        showError = true
    }

    // MARK: - Stubs (filled in by Tasks 2.4–2.8)

    func createNewSession() async {
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

    func switchToSession(id: UUID) async {
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

    /// Stub — implemented in Task 3.8.
    /// Note: declared here so the onReconnected closure in init can reference it.
    func handleAutoReconnect() async {
        // Full recovery logic in Task 3.8.
    }
}
