import Foundation
import SwiftUI
import ClaudeRelayClient

/// Manages terminal I/O state for a single session.
/// The SessionCoordinator pushes output data via `receiveOutput(_:)` and
/// this view model buffers it until SwiftTermView is wired up.
@MainActor
final class TerminalViewModel: ObservableObject {

    // MARK: - Published State

    @Published var connectionState: RelayConnection.ConnectionState = .disconnected

    /// Set by SwiftTermView.makeUIView. Flushes pending output on assignment.
    var onTerminalOutput: ((Data) -> Void)? {
        didSet {
            guard let handler = onTerminalOutput, !pendingOutput.isEmpty else { return }
            let buffered = pendingOutput
            pendingOutput.removeAll()
            for chunk in buffered {
                handler(chunk)
            }
        }
    }

    // MARK: - Dependencies

    let sessionId: UUID
    private let connection: RelayConnection
    private var pendingOutput: [Data] = []

    // MARK: - Init

    init(sessionId: UUID, connection: RelayConnection) {
        self.sessionId = sessionId
        self.connection = connection

        connection.$state
            .assign(to: &$connectionState)
    }

    // MARK: - Output (called by SessionCoordinator)

    /// Receives terminal output from the coordinator's I/O routing.
    func receiveOutput(_ data: Data) {
        if let handler = onTerminalOutput {
            handler(data)
        } else {
            pendingOutput.append(data)
        }
    }

    /// Clears stale state when switching away from this session.
    /// The old SwiftTermView is destroyed and a fresh one will be created
    /// on next activation, which re-sets `onTerminalOutput`.
    func prepareForSwitch() {
        onTerminalOutput = nil
        pendingOutput.removeAll()
    }

    // MARK: - Input

    func sendInput(_ data: Data) {
        Task {
            try? await connection.sendBinary(data)
        }
    }

    func sendInput(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        sendInput(data)
    }

    func sendResize(cols: UInt16, rows: UInt16) {
        Task {
            try? await connection.sendResize(cols: cols, rows: rows)
        }
    }
}
