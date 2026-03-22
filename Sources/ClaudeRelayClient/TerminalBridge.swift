import Foundation
import ClaudeRelayKit

/// Bridges WebSocket connection to terminal I/O.
///
/// This layer sits between `RelayConnection` (network) and the terminal view (UI).
/// SwiftTerm integration will be connected in the iOS app target, not here.
public final class TerminalBridge {

    // MARK: - Properties

    private let connection: RelayConnection

    /// Called when terminal output data arrives from the server.
    public var onOutput: ((Data) -> Void)?

    // MARK: - Init

    public init(connection: RelayConnection) {
        self.connection = connection
    }

    // MARK: - Input

    /// Sends terminal input data to the server as a binary WebSocket frame.
    @MainActor
    public func sendInput(_ data: Data) async throws {
        try await connection.sendBinary(data)
    }

    /// Notifies the server that the terminal was resized.
    @MainActor
    public func sendResize(cols: UInt16, rows: UInt16) async throws {
        try await connection.sendResize(cols: cols, rows: rows)
    }

    // MARK: - Output

    /// Starts receiving terminal output from the connection.
    ///
    /// Call this once after the connection is established to wire up the
    /// `onTerminalOutput` callback to this bridge's `onOutput` handler.
    @MainActor
    public func startReceiving() {
        connection.onTerminalOutput = { [weak self] data in
            self?.onOutput?(data)
        }
    }
}
