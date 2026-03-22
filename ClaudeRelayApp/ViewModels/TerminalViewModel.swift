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

    /// Set by SwiftTermView.makeUIView. Does NOT auto-flush — call `terminalReady()` after first layout.
    var onTerminalOutput: ((Data) -> Void)?

    /// Whether the terminal has received its first sizeChanged callback (i.e. is laid out).
    private var terminalSized = false

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
        if terminalSized, let handler = onTerminalOutput {
            handler(data)
        } else {
            pendingOutput.append(data)
        }
    }

    /// Called by the Coordinator after the first `sizeChanged` — terminal is now laid out.
    /// Flushes any buffered scrollback with a reset prefix so it renders at the correct size.
    func terminalReady() {
        guard !terminalSized, let handler = onTerminalOutput else { return }
        terminalSized = true

        if !pendingOutput.isEmpty {
            // Clear screen before replaying scrollback at the correct dimensions.
            // Do NOT use ESC[!p (soft reset) — it triggers DA queries whose responses
            // accumulate in the server's ring buffer on each resume cycle.
            let clear = Data("\u{1b}[H\u{1b}[2J".utf8)
            handler(clear)
            let buffered = pendingOutput
            pendingOutput.removeAll()
            for chunk in buffered {
                handler(chunk)
            }
        }
    }

    /// Clears stale state when switching away from this session.
    /// The old SwiftTermView is destroyed and a fresh one will be created
    /// on next activation, which re-sets `onTerminalOutput`.
    func prepareForSwitch() {
        onTerminalOutput = nil
        terminalSized = false
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
