import Foundation
import os.log
import ClaudeRelayKit

private let logger = Logger(subsystem: "com.claude.relay.client", category: "RelayConnection")

/// Manages a WebSocket connection to a ClaudeRelay server with connection quality monitoring.
///
/// Uses `URLSessionWebSocketTask` for transport. Monitors health via application-level
/// ping/pong on a 10-second interval. Recovery is owned exclusively by
/// `SharedSessionCoordinator` — this class never auto-reconnects on its own.
/// When the socket dies, it fires `onSendFailed` and lets the coordinator drive recovery.
@MainActor
public final class RelayConnection: ObservableObject {

    // MARK: - Types

    public enum ConnectionState: Sendable {
        case disconnected
        case connecting
        case connected
    }

    public enum ConnectionError: Error, LocalizedError {
        case notConnected
        case encodingFailed
        case invalidMessage(String)

        public var errorDescription: String? {
            switch self {
            case .notConnected:
                return "Not connected to server."
            case .encodingFailed:
                return "Failed to encode message."
            case .invalidMessage(let detail):
                return "Invalid message received: \(detail)"
            }
        }
    }

    // MARK: - Published State

    @Published public private(set) var state: ConnectionState = .disconnected
    @Published public private(set) var connectionQuality: ConnectionQuality = .disconnected

    // MARK: - Callbacks

    /// Called when a control (JSON) message is received from the server.
    public var onServerMessage: ((ServerMessage) -> Void)?

    /// Called when terminal output (binary) data is received from the server.
    public var onTerminalOutput: ((Data) -> Void)?

    /// Called when the server pushes an activity state change for any session.
    public var onSessionActivity: ((UUID, ActivityState) -> Void)?

    /// Called when the server notifies that another device attached to one of our sessions.
    public var onSessionStolen: ((UUID) -> Void)?

    /// Push callback: server renamed a session (another device renamed it).
    public var onSessionRenamed: ((UUID, String) -> Void)?

    /// Called when a user-visible send operation fails or the receive loop ends,
    /// indicating the connection is likely dead. The coordinator drives recovery.
    /// Internal pings (keepalive / liveness probes) do NOT trigger this — only
    /// user-initiated commands and the explicit death detector in the quality monitor.
    public var onSendFailed: (() -> Void)?

    // MARK: - Private Properties

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var config: ConnectionConfig?
    private var token: String?
    /// Monotonically increasing counter bumped each time a new WebSocket connection is established.
    /// Used by SessionController to detect stale auth state after reconnection, and by the
    /// receive loop / quality monitor to ignore callbacks from superseded connections.
    public private(set) var generation: UInt64 = 0
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var keepaliveTask: Task<Void, Never>?
    private let pingInterval: TimeInterval = 10
    private let windowSize = 6
    private var rttWindow: [TimeInterval?] = []
    private var consecutiveFailures = 0

    // Ping/pong plumbing — single slot, protected by activePing dedup.
    private var pendingPongContinuation: CheckedContinuation<Bool, Never>?
    /// Dedups concurrent `measurePingRTT()` callers onto a single in-flight ping.
    /// Overlapping pings would otherwise race for the single pong slot and leak
    /// non-cancellable continuations.
    private var activePing: Task<TimeInterval?, Never>?

    // MARK: - Init

    public init() {}

    // MARK: - Public API

    /// Connects to the ClaudeRelay server described by the given configuration.
    /// Does NOT enable any auto-reconnect behaviour — the coordinator owns recovery.
    public func connect(config: ConnectionConfig, token: String) async throws {
        self.config = config
        self.token = token

        // Resume any stale pong continuation from a previous connection before
        // we tear the socket down (pongs from the old socket will never arrive
        // after cancel, so we must not leave a continuation dangling).
        resolvePendingPong(gotPong: false)

        // Cancel old transport if any.
        urlSession?.invalidateAndCancel()
        urlSession = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil

        // Bump generation so stale receive-loop / keepalive callbacks become no-ops.
        generation &+= 1
        let gen = generation

        state = .connecting

        let session = URLSession(configuration: .default)
        self.urlSession = session
        let task = session.webSocketTask(with: config.wsURL)
        self.webSocketTask = task
        task.resume()

        state = .connected
        receiveLoop(generation: gen)
        startQualityMonitor(generation: gen)
    }

    /// Disconnects from the server. Does not attempt reconnection.
    public func disconnect() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
        resolvePendingPong(gotPong: false)
        activePing?.cancel()
        activePing = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        state = .disconnected
        connectionQuality = .disconnected
    }

    /// Checks whether the WebSocket is still alive by sending a ping.
    public func isAlive() async -> Bool {
        return await measurePingRTT() != nil
    }

    /// Sends an application-level ping and returns the round-trip time, or nil on failure.
    ///
    /// Concurrent callers share a single in-flight ping. This prevents the single
    /// `pendingPongContinuation` slot from being stomped by overlapping pings (which
    /// would leak non-cancellable continuations and hang the keepalive task).
    public func measurePingRTT() async -> TimeInterval? {
        if let existing = activePing {
            return await existing.value
        }
        let task = Task<TimeInterval?, Never> { [weak self] in
            await self?.performPing() ?? nil
        }
        activePing = task
        let result = await task.value
        if activePing == task { activePing = nil }
        return result
    }

    /// Tears down the current connection and establishes a fresh one immediately.
    /// Preserves the stored config/token. Used by the coordinator during foreground recovery.
    public func forceReconnect() async throws {
        guard let config = config, let token = token else {
            throw ConnectionError.notConnected
        }
        try await connect(config: config, token: token)
    }

    /// Sends a user-initiated control message (JSON text frame). Fires `onSendFailed`
    /// on transport error so the coordinator can start recovery.
    public func send(_ message: ClientMessage) async throws {
        try await sendClientMessage(message, notifyOnFailure: true)
    }

    /// Internal send that does NOT fire `onSendFailed` on transport error.
    /// Used for liveness probes (pings) so a failed probe doesn't itself schedule
    /// recovery — the quality monitor aggregates failures and decides when to fire.
    private func sendInternal(_ message: ClientMessage) async throws {
        try await sendClientMessage(message, notifyOnFailure: false)
    }

    private func sendClientMessage(_ message: ClientMessage, notifyOnFailure: Bool) async throws {
        guard let task = webSocketTask else {
            throw ConnectionError.notConnected
        }

        let envelope = MessageEnvelope.client(message)
        let data = try encoder.encode(envelope)
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw ConnectionError.encodingFailed
        }

        do {
            try await task.send(.string(jsonString))
        } catch {
            if notifyOnFailure {
                onSendFailed?()
            }
            throw error
        }
    }

    /// Sends raw terminal input as a binary WebSocket frame.
    public func sendBinary(_ data: Data) async throws {
        guard let task = webSocketTask else {
            throw ConnectionError.notConnected
        }

        do {
            try await task.send(.data(data))
        } catch {
            onSendFailed?()
            throw error
        }
    }

    /// Sends a terminal resize command to the server.
    public func sendResize(cols: UInt16, rows: UInt16) async throws {
        try await send(.resize(cols: cols, rows: rows))
    }

    /// Sends base64-encoded image data to be pasted on the server's clipboard.
    public func sendPasteImage(base64Data: String) async throws {
        try await send(.pasteImage(data: base64Data))
    }

    // MARK: - Ping Implementation

    /// Performs a single ping/pong exchange. Called only from `measurePingRTT` —
    /// callers must not invoke this directly (dedup is enforced by `activePing`).
    private func performPing() async -> TimeInterval? {
        guard webSocketTask != nil, state == .connected else { return nil }
        let start = CFAbsoluteTimeGetCurrent()

        do {
            try await sendInternal(.ping)
        } catch {
            return nil
        }

        let gotPong = await waitForPong(timeout: .seconds(5))
        return gotPong ? CFAbsoluteTimeGetCurrent() - start : nil
    }

    /// Awaits a pong within the given timeout. Uses `withTaskCancellationHandler` so
    /// the continuation is resolved promptly when the task is cancelled, avoiding the
    /// classic "continuation leak on cancel" trap with `withCheckedContinuation`.
    private func waitForPong(timeout: Duration) async -> Bool {
        // Racing timer: resolves the continuation with `false` if no pong arrives.
        let timerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.resolvePendingPong(gotPong: false)
        }

        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                // Evict any prior continuation (shouldn't happen because of activePing
                // dedup, but defensive — resume it with false so it doesn't leak).
                if let existing = pendingPongContinuation {
                    pendingPongContinuation = nil
                    existing.resume(returning: false)
                }
                pendingPongContinuation = c
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolvePendingPong(gotPong: false)
            }
        }

        timerTask.cancel()
        return result
    }

    /// Resolves the pending pong continuation with the given result.
    /// Safe to call multiple times — becomes a no-op if there's no pending continuation.
    private func resolvePendingPong(gotPong: Bool) {
        guard let c = pendingPongContinuation else { return }
        pendingPongContinuation = nil
        c.resume(returning: gotPong)
    }

    // MARK: - Connection Quality Monitor

    private func startQualityMonitor(generation: UInt64) {
        keepaliveTask?.cancel()
        rttWindow.removeAll()
        consecutiveFailures = 0
        connectionQuality = .excellent

        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(10 * 1_000_000_000))
                guard !Task.isCancelled,
                      let self,
                      generation == self.generation,
                      self.state == .connected else { return }

                let rtt = await self.measurePingRTT()
                guard !Task.isCancelled, generation == self.generation else { return }

                self.rttWindow.append(rtt)
                if self.rttWindow.count > self.windowSize {
                    self.rttWindow.removeFirst()
                }

                if rtt == nil {
                    self.consecutiveFailures += 1
                } else {
                    self.consecutiveFailures = 0
                }

                if self.consecutiveFailures >= 3 {
                    logger.warning("Three consecutive pings failed — connection dead, notifying coordinator")
                    self.markConnectionDead()
                    return
                }

                self.connectionQuality = self.computeQuality()
            }
        }
    }

    /// Marks the current connection as dead: cancels the websocket, bumps generation
    /// so stale callbacks are rejected, and notifies the coordinator. The coordinator
    /// owns recovery — this class never self-reconnects.
    private func markConnectionDead() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
        resolvePendingPong(gotPong: false)
        activePing?.cancel()
        activePing = nil
        generation &+= 1
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        state = .disconnected
        connectionQuality = .disconnected
        onSendFailed?()
    }

    private func computeQuality() -> ConnectionQuality {
        guard !rttWindow.isEmpty else { return .excellent }
        let successes = rttWindow.compactMap { $0 }
        let successRate = Double(successes.count) / Double(rttWindow.count)
        guard !successes.isEmpty else { return .veryPoor }
        let sorted = successes.sorted()
        let median = sorted[sorted.count / 2]
        return ConnectionQuality(medianRTT: median, successRate: successRate)
    }

    // MARK: - Receive Loop

    private func receiveLoop(generation: UInt64) {
        guard let task = webSocketTask, generation == self.generation else { return }

        task.receive { [weak self] result in
            Task { @MainActor in
                // If the generation has changed, a new connection superseded us — bail out.
                guard let self, generation == self.generation else { return }

                switch result {
                case .success(let message):
                    self.handleWebSocketMessage(message)
                    self.receiveLoop(generation: generation)

                case .failure:
                    self.handleReceiveFailure()
                }
            }
        }
    }

    private func handleWebSocketMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            guard let data = text.data(using: .utf8) else { return }
            do {
                let envelope = try decoder.decode(MessageEnvelope.self, from: data)
                if case .server(let serverMessage) = envelope {
                    if case .pong = serverMessage {
                        resolvePendingPong(gotPong: true)
                        return
                    }

                    onServerMessage?(serverMessage)

                    switch serverMessage {
                    case .sessionActivity(let sessionId, let activity):
                        onSessionActivity?(sessionId, activity)
                    case .sessionStolen(let sessionId):
                        onSessionStolen?(sessionId)
                    case .sessionRenamed(let sessionId, let name):
                        onSessionRenamed?(sessionId, name)
                    default:
                        break
                    }
                }
            } catch {
                logger.warning("Failed to decode: \(error.localizedDescription, privacy: .public)")
            }

        case .data(let data):
            onTerminalOutput?(data)

        @unknown default:
            break
        }
    }

    /// Called when the receive loop fails — connection is dead at the transport layer.
    /// Notifies the coordinator; no self-reconnect.
    private func handleReceiveFailure() {
        // Only act if this is still the active connection.
        keepaliveTask?.cancel()
        keepaliveTask = nil
        resolvePendingPong(gotPong: false)
        activePing?.cancel()
        activePing = nil
        webSocketTask = nil
        state = .disconnected
        connectionQuality = .disconnected
        onSendFailed?()
    }
}
