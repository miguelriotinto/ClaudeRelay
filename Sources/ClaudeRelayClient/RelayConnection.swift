import Foundation
import os.log
import ClaudeRelayKit

private let logger = Logger(subsystem: "com.claude.relay.client", category: "RelayConnection")

/// Manages a WebSocket connection to a ClaudeRelay server.
///
/// Uses `URLSessionWebSocketTask` for transport, which works on both macOS and iOS.
/// Handles connection lifecycle including automatic reconnection with exponential backoff.
@MainActor
public final class RelayConnection: ObservableObject {

    // MARK: - Types

    public enum ConnectionState: Sendable {
        case disconnected
        case connecting
        case connected
        case reconnecting
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

    /// Called after a successful auto-reconnect (exponential backoff).
    /// Use this to re-authenticate and resume the active session.
    /// NOTE: Callers should capture [weak coordinator] in the closure to avoid retain cycles.
    public var onReconnected: (() -> Void)?

    /// Called when a send operation fails, indicating the connection is dead.
    /// Use this to trigger recovery in the coordinator.
    public var onSendFailed: (() -> Void)?

    // MARK: - Private Properties

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var config: ConnectionConfig?
    private var token: String?
    private var reconnectAttempt = 0
    private let maxReconnectDelay: TimeInterval = 30
    private var shouldReconnect = false
    private var isReconnecting = false
    private var connectionGeneration: UInt64 = 0
    private var reconnectGeneration: UInt64 = 0
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var keepaliveTask: Task<Void, Never>?
    private let pingInterval: TimeInterval = 10
    private let windowSize = 6
    private var rttWindow: [TimeInterval?] = []
    private var consecutiveFailures = 0
    private var pendingPongContinuation: CheckedContinuation<Void, Never>?

    // MARK: - Init

    public init() {}

    // MARK: - Public API

    /// Connects to the ClaudeRelay server described by the given configuration.
    public func connect(config: ConnectionConfig, token: String) async throws {
        self.config = config
        self.token = token
        self.shouldReconnect = true
        self.reconnectAttempt = 0

        // Invalidate previous URLSession to free resources.
        urlSession?.invalidateAndCancel()

        // Bump generation so stale receive-loop callbacks become no-ops.
        connectionGeneration &+= 1
        let generation = connectionGeneration

        state = .connecting

        let session = URLSession(configuration: .default)
        self.urlSession = session
        let task = session.webSocketTask(with: config.wsURL)
        self.webSocketTask = task
        task.resume()

        state = .connected
        receiveLoop(generation: generation)
        startQualityMonitor(generation: generation)
    }

    /// Disconnects from the server. Does not attempt reconnection.
    public func disconnect() {
        shouldReconnect = false
        keepaliveTask?.cancel()
        keepaliveTask = nil
        if let c = pendingPongContinuation {
            pendingPongContinuation = nil
            c.resume()
        }
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

    /// Sends an application-level ping (ClientMessage.ping → ServerMessage.pong)
    /// and returns the round-trip time, or nil on failure.
    /// Uses a dedicated pong callback so it doesn't interfere with
    /// onServerMessage (used by SessionController for request/response).
    public func measurePingRTT() async -> TimeInterval? {
        guard webSocketTask != nil, state == .connected else { return nil }
        let start = CFAbsoluteTimeGetCurrent()

        do {
            try await send(.ping)
        } catch {
            return nil
        }

        let gotPong = await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { return false }
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    self.pendingPongContinuation = c
                }
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }

        if !gotPong {
            if let c = pendingPongContinuation {
                pendingPongContinuation = nil
                c.resume()
            }
        }

        return gotPong ? CFAbsoluteTimeGetCurrent() - start : nil
    }

    /// Tears down the current connection and establishes a fresh one immediately.
    /// Preserves the stored config/token. Use this for foreground recovery.
    /// Does NOT enable auto-reconnect — the coordinator owns recovery decisions.
    public func forceReconnect() async throws {
        guard let config = config, let token = token else {
            throw ConnectionError.notConnected
        }
        shouldReconnect = false
        reconnectGeneration &+= 1
        keepaliveTask?.cancel()
        keepaliveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        try await connect(config: config, token: token)
        shouldReconnect = false
    }

    /// Sends a control message (JSON text frame) to the server.
    public func send(_ message: ClientMessage) async throws {
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
            onSendFailed?()
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
                      generation == self.connectionGeneration,
                      self.state == .connected else { return }

                let rtt = await self.measurePingRTT()
                guard !Task.isCancelled, generation == self.connectionGeneration else { return }

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
                    self.keepaliveTask = nil
                    self.shouldReconnect = false
                    self.connectionGeneration &+= 1
                    self.webSocketTask?.cancel(with: .goingAway, reason: nil)
                    self.webSocketTask = nil
                    self.urlSession?.invalidateAndCancel()
                    self.urlSession = nil
                    self.state = .disconnected
                    self.connectionQuality = .disconnected
                    self.onSendFailed?()
                    return
                }

                self.connectionQuality = self.computeQuality()
            }
        }
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
        guard let task = webSocketTask, generation == connectionGeneration else { return }

        task.receive { [weak self] result in
            Task { @MainActor in
                // If the generation has changed, a new connection superseded us — bail out.
                guard let self, generation == self.connectionGeneration else { return }

                switch result {
                case .success(let message):
                    self.reconnectAttempt = 0
                    self.handleWebSocketMessage(message)
                    self.receiveLoop(generation: generation)

                case .failure:
                    self.handleDisconnection()
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
                    if case .pong = serverMessage, let c = pendingPongContinuation {
                        pendingPongContinuation = nil
                        c.resume()
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

    // MARK: - Reconnection

    private func handleDisconnection() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
        webSocketTask = nil

        guard !isReconnecting, shouldReconnect, let config = config, let token = token else {
            if !isReconnecting {
                state = .disconnected
                connectionQuality = .disconnected
                onSendFailed?()
            }
            return
        }

        isReconnecting = true
        state = .reconnecting
        attemptReconnect(config: config, token: token)
    }

    private func attemptReconnect(config: ConnectionConfig, token: String) {
        reconnectAttempt += 1
        let gen = reconnectGeneration

        let exponent = min(reconnectAttempt - 1, 30)
        let baseDelay = min(Double(1 << exponent), maxReconnectDelay)
        let jitter = baseDelay * Double.random(in: -0.25...0.25)
        let delay = max(0.5, baseDelay + jitter)

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            guard let self, self.shouldReconnect, gen == self.reconnectGeneration else {
                self?.isReconnecting = false
                return
            }

            do {
                try await self.connect(config: config, token: token)
                self.isReconnecting = false
                guard gen == self.reconnectGeneration else { return }
                self.onReconnected?()
            } catch {
                self.isReconnecting = false
                guard gen == self.reconnectGeneration else { return }
                self.handleDisconnection()
            }
        }
    }
}
