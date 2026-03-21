import Foundation
import ClaudeRelayKit

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

    // MARK: - Private Properties

    private var webSocketTask: URLSessionWebSocketTask?
    private var config: ConnectionConfig?
    private var token: String?
    private var reconnectAttempt = 0
    private let maxReconnectDelay: TimeInterval = 30
    private var shouldReconnect = false
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

        state = .connecting

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: config.wsURL)
        self.webSocketTask = task
        task.resume()

        state = .connected
        receiveLoop()
    }

    /// Disconnects from the server. Does not attempt reconnection.
    public func disconnect() {
        shouldReconnect = false
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        state = .disconnected
    }

    /// Checks whether the WebSocket is still alive by sending a ping.
    public func isAlive() async -> Bool {
        guard let task = webSocketTask, state == .connected else { return false }
        return await withCheckedContinuation { continuation in
            task.sendPing { error in
                continuation.resume(returning: error == nil)
            }
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

    private func receiveLoop() {
        guard let task = webSocketTask else { return }

        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self = self else { return }

                switch result {
                case .success(let message):
                    self.reconnectAttempt = 0
                    self.handleWebSocketMessage(message)
                    self.receiveLoop()

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
                print("[RelayConnection] Failed to decode: \(error)")
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

        guard shouldReconnect, let config = config, let token = token else {
            state = .disconnected
            return
        }

        state = .reconnecting
        attemptReconnect(config: config, token: token)
    }

    private func attemptReconnect(config: ConnectionConfig, token: String) {
        reconnectAttempt += 1

        // Exponential backoff: 1s, 2s, 4s, 8s, ... capped at maxReconnectDelay.
        let delay = min(pow(2.0, Double(reconnectAttempt - 1)), maxReconnectDelay)

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            guard let self = self, self.shouldReconnect else { return }

            do {
                try await self.connect(config: config, token: token)
            } catch {
                self.handleDisconnection()
            }
        }
    }
}
