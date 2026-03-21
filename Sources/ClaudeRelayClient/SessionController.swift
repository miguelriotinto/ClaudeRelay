import Foundation
import ClaudeRelayKit

/// Orchestrates authentication and session lifecycle on top of a `RelayConnection`.
@MainActor
public final class SessionController: ObservableObject {

    // MARK: - Types

    public enum SessionError: Error, LocalizedError {
        case authenticationFailed(reason: String)
        case unexpectedResponse(String)
        case timeout

        public var errorDescription: String? {
            switch self {
            case .authenticationFailed(let reason):
                return "Authentication failed: \(reason)"
            case .unexpectedResponse(let detail):
                return "Unexpected server response: \(detail)"
            case .timeout:
                return "The operation timed out."
            }
        }
    }

    // MARK: - Published State

    @Published public private(set) var sessionId: UUID?
    @Published public private(set) var isAuthenticated = false

    // MARK: - Private

    private let connection: RelayConnection
    private var messageContinuation: CheckedContinuation<ServerMessage, Never>?

    // MARK: - Init

    public init(connection: RelayConnection) {
        self.connection = connection
    }

    // MARK: - Authentication

    /// Sends an authentication request and waits for the server response.
    public func authenticate(token: String) async throws {
        try await connection.send(.authRequest(token: token))

        let response = await waitForNextServerMessage()

        switch response {
        case .authSuccess:
            isAuthenticated = true
        case .authFailure(let reason):
            isAuthenticated = false
            throw SessionError.authenticationFailed(reason: reason)
        default:
            throw SessionError.unexpectedResponse(response.typeString)
        }
    }

    // MARK: - Session Lifecycle

    /// Creates a new terminal session on the server. Returns the session UUID.
    @discardableResult
    public func createSession() async throws -> UUID {
        try await connection.send(.sessionCreate)

        let response = await waitForNextServerMessage()

        switch response {
        case .sessionCreated(let id, _, _):
            sessionId = id
            return id
        case .error(_, let message):
            throw SessionError.unexpectedResponse(message)
        default:
            throw SessionError.unexpectedResponse(response.typeString)
        }
    }

    /// Resumes an existing session by its identifier.
    public func resumeSession(id: UUID) async throws {
        try await connection.send(.sessionResume(sessionId: id))

        let response = await waitForNextServerMessage()

        switch response {
        case .sessionResumed(let resumedId):
            sessionId = resumedId
        case .error(_, let message):
            throw SessionError.unexpectedResponse(message)
        default:
            throw SessionError.unexpectedResponse(response.typeString)
        }
    }

    /// Lists all sessions owned by the authenticated token.
    public func listSessions() async throws -> [SessionInfo] {
        try await connection.send(.sessionList)

        let response = await waitForNextServerMessage()

        switch response {
        case .sessionList(let sessions):
            return sessions
        case .error(_, let message):
            throw SessionError.unexpectedResponse(message)
        default:
            throw SessionError.unexpectedResponse(response.typeString)
        }
    }

    /// Detaches from the current session without terminating it.
    public func detach() async throws {
        try await connection.send(.sessionDetach)

        let response = await waitForNextServerMessage()

        switch response {
        case .sessionDetached:
            sessionId = nil
        case .error(_, let message):
            throw SessionError.unexpectedResponse(message)
        default:
            throw SessionError.unexpectedResponse(response.typeString)
        }
    }

    // MARK: - Internal Helpers

    /// Installs a one-shot handler on the connection to capture the next server message
    /// and delivers it via an async continuation.
    private func waitForNextServerMessage() async -> ServerMessage {
        await withCheckedContinuation { continuation in
            let previousHandler = connection.onServerMessage
            connection.onServerMessage = { [weak self] message in
                // Restore the previous handler before resuming.
                self?.connection.onServerMessage = previousHandler
                continuation.resume(returning: message)
            }
        }
    }
}
