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

    /// Resets authentication state so the next operation will re-authenticate.
    /// Call this after the underlying connection has been re-established.
    public func resetAuth() {
        isAuthenticated = false
        sessionId = nil
    }

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
        let response = try await sendAndWaitForResponse(.sessionCreate())

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

    /// Attaches to a session that may still be active on another connection.
    /// Unlike resume, this does not require the session to be detached first.
    public func attachSession(id: UUID) async throws {
        let response = try await sendAndWaitForResponse(.sessionAttach(sessionId: id))

        switch response {
        case .sessionAttached(let attachedId, _):
            sessionId = attachedId
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

    /// Lists all sessions across all tokens. Used for cross-device attach.
    public func listAllSessions() async throws -> [SessionInfo] {
        let response = try await sendAndWaitForResponse(.sessionListAll)

        switch response {
        case .sessionListAll(let sessions):
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
        "session_list_result", "session_list_all_result",
        "error"
    ]

    /// Installs a single response handler synchronously on MainActor, then sends.
    /// The handler resumes the continuation if available, or stores the value for
    /// the synchronous check after send. No handler reinstallation needed.
    private func sendAndWaitForResponse(_ message: ClientMessage) async throws -> ServerMessage {
        let previousHandler = connection.onServerMessage
        defer { connection.onServerMessage = previousHandler }

        let guard_ = ResumeGuard()

        // 1) Install handler SYNCHRONOUSLY on MainActor — guaranteed in place
        //    before any suspension point. Handler either resumes the continuation
        //    (if we're waiting) or stores the value (if response beats the await).
        connection.onServerMessage = { serverMessage in
            guard Self.responseTypes.contains(serverMessage.typeString) else {
                previousHandler?(serverMessage)
                return
            }
            if guard_.continuation != nil {
                guard_.resume(returning: serverMessage)
            } else {
                guard_.pendingValue = serverMessage
            }
        }

        // 2) Send the message.
        try await connection.send(message)

        // 3) If the response already arrived during send, return it.
        if let value = guard_.pendingValue {
            return value
        }

        // 4) Otherwise wait for it with a timeout.
        return try await withCheckedThrowingContinuation { continuation in
            guard_.continuation = continuation

            // Check again — response may have arrived between step 3 and here.
            if let value = guard_.pendingValue {
                guard_.resume(returning: value)
                return
            }

            guard_.timeoutTask = Task { @MainActor [guard_] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard_.resume(throwing: SessionError.timeout)
            }
        }
    }
}

// MARK: - Resume Guard

/// Ensures a `CheckedContinuation` is resumed exactly once.
/// All access must be on `@MainActor`.
@MainActor
private final class ResumeGuard {
    var continuation: CheckedContinuation<ServerMessage, Error>?
    var pendingValue: ServerMessage?
    var timeoutTask: Task<Void, Never>?
    private var resumed = false

    func resume(returning value: ServerMessage) {
        guard !resumed else { return }
        resumed = true
        timeoutTask?.cancel()
        continuation?.resume(returning: value)
        continuation = nil
    }

    func resume(throwing error: Error) {
        guard !resumed else { return }
        resumed = true
        timeoutTask?.cancel()
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
