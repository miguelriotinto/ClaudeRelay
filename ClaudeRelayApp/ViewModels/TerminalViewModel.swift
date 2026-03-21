import Foundation
import SwiftUI
import ClaudeRelayClient

/// Manages terminal I/O and connection state for the terminal view.
@MainActor
final class TerminalViewModel: ObservableObject {

    // MARK: - Published State

    @Published var connectionState: RelayConnection.ConnectionState = .disconnected
    @Published var terminalOutput: String = ""

    /// Callback invoked with raw terminal output data. SwiftTermView wires
    /// this up so bytes are fed directly into the TerminalView.
    /// Setting this flushes any buffered data that arrived before the view was ready.
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

    let connection: RelayConnection
    let sessionId: UUID
    private let bridge: TerminalBridge
    /// Buffers output that arrives before SwiftTermView is wired up.
    private var pendingOutput: [Data] = []

    // MARK: - Init

    init(connection: RelayConnection, sessionId: UUID) {
        self.connection = connection
        self.sessionId = sessionId
        self.bridge = TerminalBridge(connection: connection)

        // Observe connection state changes.
        connection.$state
            .assign(to: &$connectionState)

        // Wire up terminal output.
        bridge.onOutput = { [weak self] data in
            guard let self = self else { return }
            Task { @MainActor in
                if let handler = self.onTerminalOutput {
                    handler(data)
                } else {
                    self.pendingOutput.append(data)
                }
            }
        }

        bridge.startReceiving()
    }

    // MARK: - Input

    func sendInput(_ data: Data) {
        Task {
            try? await bridge.sendInput(data)
        }
    }

    func sendInput(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        sendInput(data)
    }

    func sendResize(cols: UInt16, rows: UInt16) {
        Task {
            try? await bridge.sendResize(cols: cols, rows: rows)
        }
    }

    // MARK: - Lifecycle

    func detach() {
        Task {
            try? await connection.send(.sessionDetach)
        }
    }

    func disconnect() {
        connection.disconnect()
    }
}
