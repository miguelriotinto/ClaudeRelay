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

    // MARK: - Init

    public init(connection: RelayConnection) {
        self.connection = connection
    }

    // MARK: - Authentication

    /// Sends an authentication request and waits for the server response.
    public func authenticate(token: String) async throws {
        let response = try await sendAndWaitForResponse(.authRequest(token: token))

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
        let response = try await sendAndWaitForResponse(.sessionCreate)

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
        let response = try await sendAndWaitForResponse(.sessionResume(sessionId: id))

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
        let response = try await sendAndWaitForResponse(.sessionList)

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
        let response = try await sendAndWaitForResponse(.sessionDetach)

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

    /// Response message types we expect from command requests.
    private static let responseTypes: Set<String> = [
        "auth_success", "auth_failure",
        "session_created", "session_attached", "session_resumed", "session_detached",
        "session_list",
        "error",
    ]

    /// Installs the response handler FIRST, then sends the message, to avoid a race
    /// where the server responds before the handler is installed.
    private func sendAndWaitForResponse(_ message: ClientMessage) async throws -> ServerMessage {
        return try await withCheckedThrowingContinuation { continuation in
            let previousHandler = connection.onServerMessage

            // Install handler BEFORE sending to avoid race condition.
            connection.onServerMessage = { [weak self] serverMessage in
                guard Self.responseTypes.contains(serverMessage.typeString) else {
                    // Not a command response — forward and keep waiting.
                    previousHandler?(serverMessage)
                    return
                }
                // Restore the previous handler before resuming.
                self?.connection.onServerMessage = previousHandler
                continuation.resume(returning: serverMessage)
            }

            // Now send the message.
            Task { [weak self] in
                do {
                    try await self?.connection.send(message)
                } catch {
                    // Restore handler and fail.
                    self?.connection.onServerMessage = previousHandler
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
