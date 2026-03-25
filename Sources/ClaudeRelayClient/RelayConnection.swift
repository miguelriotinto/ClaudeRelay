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

    // MARK: - Callbacks

    /// Called when a control (JSON) message is received from the server.
    public var onServerMessage: ((ServerMessage) -> Void)?

    /// Called when terminal output (binary) data is received from the server.
    public var onTerminalOutput: ((Data) -> Void)?

    /// Called after a successful auto-reconnect (exponential backoff).
    /// Use this to re-authenticate and resume the active session.
    /// NOTE: Callers should capture [weak coordinator] in the closure to avoid retain cycles.
    public var onReconnected: (() -> Void)?

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
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

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
    }

    /// Disconnects from the server. Does not attempt reconnection.
    public func disconnect() {
        shouldReconnect = false
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        state = .disconnected
    }

    /// Checks whether the WebSocket is still alive by sending a ping.
    /// Returns false if no pong is received within 3 seconds.
    public func isAlive() async -> Bool {
        guard let task = webSocketTask, state == .connected else { return false }
        // Race ping against a 3-second timeout. AsyncStream is used instead of
        // CheckedContinuation because sendPing's callback can fire multiple times
        // (e.g., once on pong, again when URLSession.invalidateAndCancel() runs
        // during disconnect). Extra yields after finish() are safely ignored.
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                let stream = AsyncStream<Bool> { continuation in
                    task.sendPing { error in
                        continuation.yield(error == nil)
                        continuation.finish()
                    }
                }
                for await value in stream { return value }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    /// Tears down the current connection and establishes a fresh one immediately.
    /// Preserves the stored config/token. Use this for foreground recovery.
    public func forceReconnect() async throws {
        guard let config = config, let token = token else {
            throw ConnectionError.notConnected
        }
        // Suppress auto-reconnect to avoid racing with our manual reconnect
        shouldReconnect = false
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        try await connect(config: config, token: token)
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

        try await task.send(.string(jsonString))
    }

    /// Sends raw terminal input as a binary WebSocket frame.
    public func sendBinary(_ data: Data) async throws {
        guard let task = webSocketTask else {
            throw ConnectionError.notConnected
        }

        try await task.send(.data(data))
    }

    /// Sends a terminal resize command to the server.
    public func sendResize(cols: UInt16, rows: UInt16) async throws {
        try await send(.resize(cols: cols, rows: rows))
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
                    onServerMessage?(serverMessage)
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
        webSocketTask = nil

        guard !isReconnecting, shouldReconnect, let config = config, let token = token else {
            if !isReconnecting { state = .disconnected }
            return
        }

        isReconnecting = true
        state = .reconnecting
        attemptReconnect(config: config, token: token)
    }

    private func attemptReconnect(config: ConnectionConfig, token: String) {
        reconnectAttempt += 1

        // Exponential backoff with jitter: base delay 1s, 2s, 4s, 8s, ...
        // capped at maxReconnectDelay, plus ±25% random jitter.
        let exponent = min(reconnectAttempt - 1, 30)
        let baseDelay = min(Double(1 << exponent), maxReconnectDelay)
        let jitter = baseDelay * Double.random(in: -0.25...0.25)
        let delay = max(0.5, baseDelay + jitter)

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            guard let self, self.shouldReconnect else {
                self?.isReconnecting = false
                return
            }

            do {
                try await self.connect(config: config, token: token)
                self.isReconnecting = false
                self.onReconnected?()
            } catch {
                self.isReconnecting = false
                self.handleDisconnection()
            }
        }
    }
}
