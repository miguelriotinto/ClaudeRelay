import Foundation
import Combine
import os.log
import ClaudeRelayKit

private let recoveryLog = Logger(subsystem: "com.claude.relay.client", category: "Recovery")

@MainActor
open class SharedSessionCoordinator: ObservableObject, SessionCoordinating {

    // MARK: - Published State

    @Published public var sessions: [SessionInfo] = []
    @Published public var activeSessionId: UUID?
    @Published public var sessionNames: [UUID: String] = [:]
    @Published public var terminalTitles: [UUID: String] = [:]
    @Published public var agentSessions: [UUID: String] = [:]
    @Published public var sessionsAwaitingInput: Set<UUID> = []
    @Published public var isLoading = false
    public enum RecoveryPhase {
        case reconnecting, authenticating, resuming

        public var label: String {
            switch self {
            case .reconnecting:   return "Reconnecting to server…"
            case .authenticating:  return "Authenticating…"
            case .resuming:       return "Restoring session…"
            }
        }
    }

    @Published public var isRecovering = false
    @Published public var recoveryPhase: RecoveryPhase = .reconnecting
    @Published public private(set) var recoveryFailed = false
    @Published public var errorMessage: String?
    @Published public var showError = false
    /// True when recovery could not restore the connection itself (reconnect attempts
    /// all failed). Distinct from `sessionAttachFailed`, which covers the case where
    /// the connection is fine but the session is gone or unusable on the server.
    @Published public var connectionTimedOut = false
    @Published public var stolenSessionName: String?
    @Published public var stolenSessionShortId: String?
    @Published public var showSessionStolen = false
    /// True when an attach/resume failed for application-level reasons (session gone, ownership,
    /// server-side error) rather than because the underlying connection is dead. The UI should
    /// surface this as a recoverable error instead of dismissing the workspace.
    @Published public var sessionAttachFailed = false
    @Published public var sessionAttachError: String?

    public private(set) var ownedSessionIds: Set<UUID> = []

    public var activeSessions: [SessionInfo] {
        sessions
            .filter { !$0.state.isTerminal && ownedSessionIds.contains($0.id) }
            .sorted { $0.createdAt < $1.createdAt }
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
    /// Shared in-flight auth task. Concurrent callers to `ensureAuthenticated` await
    /// the same attempt instead of racing to send duplicate `auth_request`s (which
    /// the server rejects with "Already authenticated" on the second one).
    private var authTask: Task<SessionController, Error>?
    /// Sessions whose terminal view has already received the initial ring-buffer
    /// replay on first attach. On subsequent resume (tab switch back), the client
    /// asks the server to skip the replay so scrollback isn't duplicated/truncated.
    private var sessionsWithLiveTerminal: Set<UUID> = []
    /// Platform-specific cache of native terminal views (NSView on macOS, UIView
    /// on iOS). Kept alive across session switches so SwiftTerm's internal
    /// scrollback persists. The coordinator owns these; platform hosts look up
    /// or install entries via `terminalViewForSession`.
    public var cachedTerminalViews: [UUID: AnyObject] = [:]
    /// LRU order of session ids for the terminal cache. Most-recently used at the end.
    /// When the cache exceeds `terminalCacheLimit`, the front (oldest) is evicted —
    /// except the currently active session, which is never evicted.
    private var terminalLRU: [UUID] = []
    /// Maximum number of cached live terminal views. Beyond this, the
    /// least-recently-used one is evicted (its SwiftTerm scrollback goes;
    /// subsequent attach replays from the server's ring buffer).
    private static let terminalCacheLimit: Int = 8

    // MARK: - Recovery Control

    /// Monotonic token bumped at the start of every recovery pass. A scheduled
    /// `onSendFailed`-triggered recovery only runs if the token it captured still
    /// matches — prevents a failed recovery from immediately queueing another.
    private var recoveryGeneration: UInt64 = 0
    /// Timestamp of the last recovery completion (success or failure). Used to
    /// enforce a cooldown on auto-triggered recoveries via `onSendFailed`.
    private var lastRecoveryEndedAt: Date = .distantPast
    /// Consecutive auto-triggered recovery failures. Reset on success or on any
    /// user-initiated recovery (foreground, network restored, explicit action).
    private var consecutiveAutoRecoveryFailures = 0
    /// Minimum delay between `onSendFailed`-triggered recoveries, in seconds.
    private let autoRecoveryCooldown: TimeInterval = 3
    /// After this many back-to-back auto-recovery failures we stop responding to
    /// `onSendFailed` until an explicit user/foreground/network signal arrives.
    private let maxAutoRecoveryFailures = 3
    /// True when auto-retry has been circuit-broken. Cleared on explicit recovery entry.
    private var autoRecoverySuspended = false
    /// Synchronous entry lock, distinct from `isRecovering` (which is set after
    /// `await isAlive()`). Prevents concurrent recovery dispatches from racing
    /// across the suspension point at the top of `handleForegroundTransition`.
    private var isRecoveryDispatched = false
    /// Timestamp set by `cancelRecovery`. `triggerUserRecovery` ignores calls
    /// within 1 s of a cancel to avoid sheet-dismiss → scenePhase → re-trigger.
    private var lastCancelledAt: Date = .distantPast

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
                self?.triggerUserRecovery()
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
        agentSessions = Self.loadAgentSessions()

        connection.onSessionActivity = { [weak self] sessionId, activity, agent in
            Task { @MainActor [weak self] in
                self?.handleActivityUpdate(sessionId: sessionId, activity: activity, agent: agent)
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
        connection.onSendFailed = { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleAutoRecovery()
            }
        }
    }

    /// Auto-triggered recovery entry point (called from `onSendFailed`).
    /// Gated by: torn-down state, already-recovering, auto-suspend (circuit broken),
    /// and a cooldown since the last recovery ended. User-initiated recovery
    /// (foreground/network/explicit) goes through `handleForegroundTransition`
    /// directly, bypassing these gates — see `triggerUserRecovery`.
    private func scheduleAutoRecovery() {
        guard !isTornDown else { return }
        guard !isRecoveryDispatched else {
            recoveryLog.debug("scheduleAutoRecovery: already dispatched, ignoring")
            return
        }
        guard !autoRecoverySuspended else {
            recoveryLog.info("scheduleAutoRecovery: auto-suspend active — awaiting user signal")
            return
        }
        let elapsed = Date().timeIntervalSince(lastRecoveryEndedAt)
        guard elapsed >= autoRecoveryCooldown else {
            recoveryLog.debug("scheduleAutoRecovery: cooldown (\(elapsed, format: .fixed(precision: 2))s < \(self.autoRecoveryCooldown)s)")
            return
        }
        recoveryLog.info("scheduleAutoRecovery: queuing recovery attempt")
        isRecoveryDispatched = true
        recoveryTask = Task { [weak self] in
            await self?.handleForegroundTransition(userInitiated: false)
        }
    }

    /// Explicit user-initiated recovery: foreground, network restored, QR rescan, etc.
    /// Clears the auto-suspend circuit breaker so auto-retry resumes after this attempt.
    public func triggerUserRecovery() {
        guard !isTornDown else { return }
        guard !isRecoveryDispatched else {
            recoveryLog.debug("triggerUserRecovery: already dispatched, ignoring")
            return
        }
        if Date().timeIntervalSince(lastCancelledAt) < 1 {
            recoveryLog.debug("triggerUserRecovery: within cancel debounce, ignoring")
            return
        }
        autoRecoverySuspended = false
        consecutiveAutoRecoveryFailures = 0
        isRecoveryDispatched = true
        recoveryTask = Task { [weak self] in
            await self?.handleForegroundTransition(userInitiated: true)
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

    private static var agentSessionsKey: String { "\(keyPrefix).agentSessions" }

    static func loadAgentSessions() -> [UUID: String] {
        guard let data = UserDefaults.standard.data(forKey: agentSessionsKey),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict.reduce(into: [UUID: String]()) { result, pair in
            if let uuid = UUID(uuidString: pair.key) {
                result[uuid] = pair.value
            }
        }
    }

    public func saveAgentSessions() {
        let dict = agentSessions.reduce(into: [String: String]()) { $0[$1.key.uuidString] = $1.value }
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: Self.agentSessionsKey)
        }
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
        if let controller = sessionController, controller.isAuthValid {
            return controller
        }
        if let existing = authTask {
            return try await existing.value
        }
        let task = Task<SessionController, Error> { [weak self] in
            guard let self else { throw SessionController.SessionError.timeout }
            let controller = self.sessionController ?? SessionController(connection: self.connection)
            try await controller.authenticate(token: self.token)
            self.sessionController = controller
            self.didAuthenticate()
            return controller
        }
        authTask = task
        defer { if authTask == task { authTask = nil } }
        return try await task.value
    }

    /// Runs a closure that requires an authenticated controller. If the server
    /// replies "Not authenticated" (stale auth), resets auth and retries once.
    public func withAuth<T>(_ body: (SessionController) async throws -> T) async throws -> T {
        let controller = try await ensureAuthenticated()
        do {
            return try await body(controller)
        } catch let error as SessionController.SessionError where error.isNotAuthenticated {
            sessionController?.resetAuth()
            let retryController = try await ensureAuthenticated()
            return try await body(retryController)
        }
    }

    // MARK: - Session List

    public func fetchSessions() async {
        let now = Date()
        guard now.timeIntervalSince(lastFetchTime) >= 0.5 else { return }
        lastFetchTime = now

        isLoading = true
        defer { isLoading = false }

        do {
            sessions = try await withAuth { try await $0.listSessions() }

            for session in sessions {
                if let serverName = session.name {
                    sessionNames[session.id] = serverName
                }
            }
            Self.saveNames(sessionNames)

            for session in sessions {
                let activity = session.activity ?? .idle
                handleActivityUpdate(sessionId: session.id, activity: activity, agent: session.agent)
            }

            let serverIds = Set(sessions.map { $0.id })
            let staleAgentIds = Set(agentSessions.keys).subtracting(serverIds)
            if !staleAgentIds.isEmpty {
                for id in staleAgentIds { agentSessions.removeValue(forKey: id) }
                sessionsAwaitingInput.subtract(staleAgentIds)
                saveAgentSessions()
            }
            let staleOwned = ownedSessionIds.subtracting(serverIds)
            if !staleOwned.isEmpty {
                ownedSessionIds.subtract(staleOwned)
                saveOwned()
            }
            // Evict cached terminal views for sessions that no longer exist
            // on the server (exited, terminated elsewhere, server restarted).
            let staleCached = Set(cachedTerminalViews.keys).subtracting(serverIds)
            for id in staleCached { evictTerminal(for: id) }
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

    public func activeAgent(for sessionId: UUID) -> String? {
        agentSessions[sessionId]
    }

    public func isRunningAgent(sessionId: UUID) -> Bool {
        agentSessions[sessionId] != nil
    }

    // MARK: - Create

    public func createNewSession() async {
        guard !isRecovering else { return }
        let previousId = activeSessionId
        do {
            let (name, sessionId) = try await withAuth { controller in
                if previousId != nil {
                    try? await controller.detach()
                }
                let name = self.pickDefaultName()
                let sessionId = try await controller.createSession(name: name)
                return (name, sessionId)
            }

            if let currentId = previousId {
                terminalViewModels[currentId]?.prepareForSwitch()
                terminalViewModels[currentId] = nil
            }

            claimSession(sessionId)
            sessionNames[sessionId] = name
            Self.saveNames(sessionNames)

            let vm = TerminalViewModel(sessionId: sessionId, connection: connection)
            terminalViewModels[sessionId] = vm
            wireTerminalOutput(to: sessionId)
            activeSessionId = sessionId
            touchTerminalLRU(sessionId)
            enforceTerminalCacheLimit()

            await fetchSessions()
        } catch {
            presentError(error.localizedDescription)
        }
    }

    // MARK: - Switch

    public func switchToSession(id: UUID) async {
        guard !isRecovering, id != activeSessionId else { return }
        let previousId = activeSessionId
        let haveLiveTerminal = sessionsWithLiveTerminal.contains(id)
        do {
            try await withAuth { controller in
                if previousId != nil {
                    try? await controller.detach()
                }
                // If we already have a live terminal with full scrollback for
                // this session, ask the server to skip its ring-buffer replay —
                // otherwise output gets duplicated (or truncated to the last
                // `scrollbackSize` bytes, losing history from before the cap).
                try await controller.resumeSession(id: id, skipReplay: haveLiveTerminal)
            }

            // Keep the previous session's view model alive so its cached native
            // terminal view retains scrollback. prepareForSwitch clears pending
            // output + callbacks so the detached VM stops receiving live data.
            if let currentId = previousId, currentId != id {
                terminalViewModels[currentId]?.prepareForSwitch()
            }

            // For the incoming session: create the VM if missing, or reset its
            // buffering state so a freshly-built terminal view (on platforms
            // that rebuild on session change) can re-drain pending output.
            if terminalViewModels[id] == nil {
                terminalViewModels[id] = TerminalViewModel(sessionId: id, connection: connection)
            } else {
                terminalViewModels[id]?.prepareForSwitch()
            }

            wireTerminalOutput(to: id)
            activeSessionId = id
            touchTerminalLRU(id)
            enforceTerminalCacheLimit()

            await fetchSessions()
        } catch {
            presentError(error.localizedDescription)
        }
    }

    // MARK: - Attach

    public func fetchAttachableSessions() async -> [SessionInfo] {
        do {
            let all = try await withAuth { try await $0.listAllSessions() }
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
            let controller = try await withAuth { controller in
                if previousId != nil {
                    try? await controller.detach()
                }
                try await controller.attachSession(id: id)
                return controller
            }

            if let currentId = previousId, currentId != id {
                terminalViewModels[currentId]?.prepareForSwitch()
                terminalViewModels[currentId] = nil
            }

            claimSession(id)
            let vm = TerminalViewModel(sessionId: id, connection: connection)
            terminalViewModels[id] = vm
            wireTerminalOutput(to: id)
            activeSessionId = id
            touchTerminalLRU(id)
            enforceTerminalCacheLimit()

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
            recoveryLog.error("attachRemoteSession failed for \(id): \(error.localizedDescription, privacy: .public)")
            if let previousId {
                try? await sessionController?.resumeSession(id: previousId)
                wireTerminalOutput(to: previousId)
            }
            if Self.isApplicationLevelError(error) {
                sessionAttachError = friendlyAttachErrorMessage(error)
                sessionAttachFailed = true
            } else {
                presentError(error.localizedDescription)
            }
        }
    }

    private static func isApplicationLevelError(_ error: Error) -> Bool {
        if let sessionErr = error as? SessionController.SessionError {
            switch sessionErr {
            case .unexpectedResponse, .authenticationFailed, .versionIncompatible:
                return true
            case .timeout:
                return false
            }
        }
        if let connErr = error as? RelayConnection.ConnectionError {
            switch connErr {
            case .invalidMessage:
                return true
            case .notConnected, .encodingFailed:
                return false
            }
        }
        return false
    }

    private func friendlyAttachErrorMessage(_ error: Error) -> String {
        if let sessionErr = error as? SessionController.SessionError,
           case .unexpectedResponse(let detail) = sessionErr {
            if detail.localizedCaseInsensitiveContains("not found") {
                return "This session no longer exists on the server."
            }
            if detail.localizedCaseInsensitiveContains("invalid") || detail.localizedCaseInsensitiveContains("terminal") {
                return "This session has ended and cannot be reattached."
            }
            return detail
        }
        return error.localizedDescription
    }

    // MARK: - Terminate

    open func terminateSession(id: UUID) async {
        guard !isRecovering else { return }
        do {
            try await connection.send(.sessionTerminate(sessionId: id))
            if activeSessionId == id {
                activeSessionId = nil
            }
            evictTerminal(for: id)
            agentSessions.removeValue(forKey: id)
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

    private func handleActivityUpdate(sessionId: UUID, activity: ActivityState, agent: String? = nil) {
        var changed = false
        if activity.isAgentRunning, let agentId = agent {
            if agentSessions[sessionId] != agentId {
                agentSessions[sessionId] = agentId
                terminalViewModels[sessionId]?.isAgentActive = true
                changed = true
            }
        } else {
            if agentSessions.removeValue(forKey: sessionId) != nil {
                terminalViewModels[sessionId]?.isAgentActive = false
                changed = true
            }
        }
        if changed { saveAgentSessions() }

        if activity == .agentIdle {
            sessionsAwaitingInput.insert(sessionId)
        } else {
            sessionsAwaitingInput.remove(sessionId)
        }
    }

    private func handleSessionStolen(sessionId: UUID) {
        let sessionName = name(for: sessionId)
        let shortId = String(sessionId.uuidString.prefix(8))

        if activeSessionId == sessionId {
            activeSessionId = nil
        }
        evictTerminal(for: sessionId)
        agentSessions.removeValue(forKey: sessionId)
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
        if agentSessions[sessionId] != nil {
            terminalViewModels[sessionId]?.isAgentActive = true
        }
        connection.onTerminalOutput = { [weak self] data in
            self?.terminalViewModels[sessionId]?.receiveOutput(data)
        }
        terminalViewModels[sessionId]?.onTitleChanged = { [weak self] title in
            self?.terminalTitles[sessionId] = title
        }
    }

    // MARK: - Terminal View Cache

    /// Called by the platform host when it creates (or retrieves) a native
    /// terminal view for a session. After the first call for a given id, any
    /// subsequent `switchToSession` will ask the server to skip the replay.
    public func registerLiveTerminal(for sessionId: UUID, view: AnyObject) {
        cachedTerminalViews[sessionId] = view
        sessionsWithLiveTerminal.insert(sessionId)
        touchTerminalLRU(sessionId)
        enforceTerminalCacheLimit()
    }

    /// Mark this session as the most-recently-used.
    private func touchTerminalLRU(_ id: UUID) {
        terminalLRU.removeAll(where: { $0 == id })
        terminalLRU.append(id)
    }

    /// If we're over the cache limit, evict the LRU entry, skipping the active session.
    /// If every remaining entry is the active session, we stop — we never evict the
    /// session the user is currently looking at, even if the cache is technically
    /// one over the limit.
    private func enforceTerminalCacheLimit() {
        while cachedTerminalViews.count > Self.terminalCacheLimit {
            guard let victim = terminalLRU.first(where: { $0 != activeSessionId }) else {
                return
            }
            evictTerminal(for: victim)
        }
    }

    /// Lookup the cached native view for a session, if any.
    public func cachedTerminalView(for sessionId: UUID) -> AnyObject? {
        cachedTerminalViews[sessionId]
    }

    /// Drop all cached state tied to a single session. Used when a session is
    /// terminated, stolen, or the workspace is torn down.
    public func evictTerminal(for sessionId: UUID) {
        cachedTerminalViews.removeValue(forKey: sessionId)
        sessionsWithLiveTerminal.remove(sessionId)
        terminalViewModels.removeValue(forKey: sessionId)
        terminalLRU.removeAll(where: { $0 == sessionId })
    }

    public func presentError(_ message: String) {
        errorMessage = message
        showError = true
    }

    // MARK: - Recovery

    public func handleForegroundTransition() async {
        await handleForegroundTransition(userInitiated: true)
    }

    /// - Parameter userInitiated: true when triggered by an explicit user-intent
    ///   signal (scenePhase active, network restored, manual retry). Such signals
    ///   clear the auto-suspend circuit breaker. Auto-triggered calls (send failed)
    ///   increment the failure counter on loss.
    public func handleForegroundTransition(userInitiated: Bool) async {
        defer { isRecoveryDispatched = false }
        guard !isTornDown else { return }
        guard !isRecovering else {
            recoveryLog.debug("handleForegroundTransition: already recovering, skipping")
            return
        }

        let alive = await connection.isAlive()
        if alive {
            recoveryLog.info("handleForegroundTransition: connection alive, fetching sessions")
            await fetchSessions()
            return
        }

        recoveryGeneration &+= 1
        let myGeneration = recoveryGeneration
        recoveryLog.info("Recovery start gen=\(myGeneration) userInitiated=\(userInitiated)")

        recoveryPhase = .reconnecting
        recoveryFailed = false
        isRecovering = true
        defer {
            isRecovering = false
            lastRecoveryEndedAt = Date()
        }

        let delays: [UInt64] = [0, 1, 2, 4]
        var reconnected = false
        for (attempt, delay) in delays.enumerated() {
            guard !isTornDown, myGeneration == recoveryGeneration, !Task.isCancelled else {
                recoveryLog.info("Recovery aborted during reconnect (gen=\(myGeneration))")
                return
            }
            if delay > 0 {
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    recoveryLog.info("Recovery cancelled during backoff (gen=\(myGeneration))")
                    return
                }
                guard !isTornDown, myGeneration == recoveryGeneration else { return }
            }

            do {
                try await connection.forceReconnect()
                reconnected = true
                break
            } catch is CancellationError {
                recoveryLog.info("Recovery cancelled during forceReconnect (gen=\(myGeneration))")
                return
            } catch {
                recoveryLog.error("forceReconnect attempt \(attempt + 1) failed: \(error.localizedDescription, privacy: .public)")
                if attempt == delays.count - 1 {
                    guard !isTornDown, myGeneration == recoveryGeneration else { return }
                    recoveryFailed = true
                    connectionTimedOut = true
                    recordAutoRecoveryOutcome(success: false, userInitiated: userInitiated)
                    return
                }
            }
        }

        guard reconnected, !isTornDown, myGeneration == recoveryGeneration else { return }
        await restoreSession(generation: myGeneration, userInitiated: userInitiated)
    }

    /// Records the outcome of a recovery pass and updates the circuit breaker.
    private func recordAutoRecoveryOutcome(success: Bool, userInitiated: Bool) {
        if success {
            consecutiveAutoRecoveryFailures = 0
            autoRecoverySuspended = false
            recoveryLog.info("Recovery succeeded — counters reset")
            return
        }
        if userInitiated {
            // User signalled they want a retry; don't count toward auto-suspend.
            recoveryLog.info("User-initiated recovery failed — not counting toward auto-suspend")
            return
        }
        consecutiveAutoRecoveryFailures += 1
        recoveryLog.info("Auto-recovery failure \(self.consecutiveAutoRecoveryFailures)/\(self.maxAutoRecoveryFailures)")
        if consecutiveAutoRecoveryFailures >= maxAutoRecoveryFailures {
            autoRecoverySuspended = true
            recoveryLog.error("Auto-recovery suspended after \(self.maxAutoRecoveryFailures) consecutive failures")
        }
    }

    /// Restores auth + active session on the current connection.
    /// Caller is responsible for setting/clearing `isRecovering` around this call.
    public func restoreSession(generation: UInt64, userInitiated: Bool) async {
        recoveryPhase = .authenticating
        sessionController?.resetAuth()
        do {
            let controller = try await ensureAuthenticated()
            guard !isTornDown, generation == recoveryGeneration else { return }
            if let activeId = activeSessionId {
                recoveryPhase = .resuming
                terminalViewModels[activeId]?.resetForReplay()
                try await controller.resumeSession(id: activeId)
                guard !isTornDown, generation == recoveryGeneration else { return }
                wireTerminalOutput(to: activeId)
            }
        } catch is CancellationError {
            recoveryLog.info("restoreSession cancelled (gen=\(generation))")
            return
        } catch {
            recoveryLog.error("restoreSession failed (gen=\(generation)): \(error.localizedDescription, privacy: .public)")
            guard !isTornDown, generation == recoveryGeneration else { return }
            recoveryFailed = true
            if Self.isApplicationLevelError(error) {
                // Session no longer exists / invalid transition / etc. The socket
                // itself is fine — clear the active session and surface a recoverable
                // error. Don't tear the workspace down via connectionTimedOut.
                if let activeId = activeSessionId {
                    evictTerminal(for: activeId)
                    activeSessionId = nil
                }
                sessionAttachError = friendlyAttachErrorMessage(error)
                sessionAttachFailed = true
            } else {
                connectionTimedOut = true
            }
            recordAutoRecoveryOutcome(success: false, userInitiated: userInitiated)
            return
        }

        recoveryLog.info("restoreSession success (gen=\(generation))")
        recordAutoRecoveryOutcome(success: true, userInitiated: userInitiated)
        guard !isTornDown, generation == recoveryGeneration else { return }
        await fetchSessions()
    }

    /// Cancels any in-flight recovery and clears recovery UI state.
    /// Bumps the generation so in-flight tasks bail at their next checkpoint.
    public func cancelRecovery() {
        recoveryLog.info("cancelRecovery requested")
        recoveryGeneration &+= 1
        recoveryTask?.cancel()
        recoveryTask = nil
        authTask?.cancel()
        authTask = nil
        isRecovering = false
        isRecoveryDispatched = false
        recoveryFailed = true
        let now = Date()
        lastRecoveryEndedAt = now
        lastCancelledAt = now
        // Explicit cancel means the user doesn't want us re-entering auto-recovery
        // immediately on the next send failure — let them re-enter via scenePhase
        // or a fresh network restore.
        autoRecoverySuspended = true
    }

    // MARK: - Cleanup

    open func tearDown() {
        isTornDown = true
        isRecoveryDispatched = false
        stopNetworkRecovery()
        recoveryTask?.cancel()
        recoveryTask = nil
        authTask?.cancel()
        authTask = nil
        if activeSessionId != nil {
            Task { try? await sessionController?.detach() }
        }
        cachedTerminalViews.removeAll()
        sessionsWithLiveTerminal.removeAll()
        connection.disconnect()
    }
}
