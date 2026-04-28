import Foundation
import Combine
import SwiftUI
import ClaudeRelayClient

@MainActor
final class TerminalViewModel: ObservableObject {

    // MARK: - Published State

    @Published var connectionState: RelayConnection.ConnectionState
    @Published var terminalTitle: String = ""
    @Published var awaitingInput: Bool = false

    // MARK: - Callbacks (set by TerminalContainerView)

    var onTerminalOutput: ((Data) -> Void)?
    var onTitleChanged: ((String) -> Void)?
    var onAwaitingInputChanged: ((Bool) -> Void)?

    // MARK: - Dependencies

    let sessionId: UUID
    private let connection: RelayConnection
    private var pendingOutput: [Data] = []
    private var terminalSized = false

    // MARK: - Input detection

    var isClaudeActive = false
    private var promptDebounceTask: Task<Void, Never>?

    // MARK: - Init

    init(sessionId: UUID, connection: RelayConnection) {
        self.sessionId = sessionId
        self.connection = connection
        self.connectionState = connection.state

        connection.$state
            .removeDuplicates()
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .assign(to: &$connectionState)
    }

    // MARK: - Output

    func receiveOutput(_ data: Data) {
        if terminalSized, let handler = onTerminalOutput {
            handler(data)
        } else {
            pendingOutput.append(data)
        }
        detectInputPrompt(data)
    }

    /// Called after the first sizeChanged delegate callback from SwiftTerm.
    func terminalReady() {
        guard !terminalSized, let handler = onTerminalOutput else { return }
        terminalSized = true
        let buffered = pendingOutput
        pendingOutput.removeAll()
        for chunk in buffered { handler(chunk) }
    }

    /// Resets terminal for scrollback replay (foreground recovery).
    func resetForReplay() {
        if let handler = onTerminalOutput {
            handler(Data([0x1B, 0x63])) // ESC c — Reset to Initial State
        }
    }

    func prepareForSwitch() {
        promptDebounceTask?.cancel()
        promptDebounceTask = nil
        onTerminalOutput = nil
        onTitleChanged = nil
        onAwaitingInputChanged = nil
        terminalSized = false
        pendingOutput.removeAll()
    }

    // MARK: - Input

    func sendInput(_ data: Data) {
        if awaitingInput { setAwaitingInput(false) }
        Task { try? await connection.sendBinary(data) }
    }

    func sendInput(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        sendInput(data)
    }

    func sendPasteImage(_ imageData: Data) {
        let base64 = imageData.base64EncodedString()
        Task { try? await connection.sendPasteImage(base64Data: base64) }
    }

    func sendResize(cols: UInt16, rows: UInt16) {
        Task { try? await connection.sendResize(cols: cols, rows: rows) }
    }

    // MARK: - Prompt detection

    private func detectInputPrompt(_ data: Data) {
        promptDebounceTask?.cancel()
        promptDebounceTask = nil
        if awaitingInput { setAwaitingInput(false) }

        let threshold: Duration = isClaudeActive ? .milliseconds(2000) : .milliseconds(1000)
        promptDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: threshold)
            guard !Task.isCancelled else { return }
            self?.setAwaitingInput(true)
        }
    }

    private func setAwaitingInput(_ value: Bool) {
        guard awaitingInput != value else { return }
        awaitingInput = value
        onAwaitingInputChanged?(value)
    }
}
