import Foundation
import SwiftUI
import CodeRelayClient

/// Manages terminal I/O and connection state for the terminal view.
@MainActor
final class TerminalViewModel: ObservableObject {

    // MARK: - Published State

    @Published var connectionState: RelayConnection.ConnectionState = .disconnected
    @Published var terminalOutput: String = ""

    /// Callback invoked with raw terminal output data. SwiftTermView wires
    /// this up so bytes are fed directly into the TerminalView.
    var onTerminalOutput: ((Data) -> Void)?

    // MARK: - Dependencies

    let connection: RelayConnection
    let sessionId: UUID
    private let bridge: TerminalBridge

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
            // Forward raw bytes to SwiftTerm (if wired up).
            Task { @MainActor in
                self.onTerminalOutput?(data)
            }
            // Also keep the plain-text accumulator for any fallback UI.
            if let text = String(data: data, encoding: .utf8) {
                Task { @MainActor in
                    self.terminalOutput += text
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

    func disconnect() {
        connection.disconnect()
    }
}
