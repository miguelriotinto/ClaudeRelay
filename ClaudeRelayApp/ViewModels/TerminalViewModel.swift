import Foundation
import Combine
import SwiftUI
import ClaudeRelayClient

/// Manages terminal I/O state for a single session.
/// The SessionCoordinator pushes output data via `receiveOutput(_:)` and
/// this view model buffers it until SwiftTermView is wired up.
@MainActor
final class TerminalViewModel: ObservableObject {

    // MARK: - Published State

    @Published var connectionState: RelayConnection.ConnectionState
    /// Terminal title set by the running process via OSC escape sequences.
    @Published var terminalTitle: String = ""
    /// True when the terminal appears to be waiting for user input (e.g. Claude Code prompt).
    @Published var awaitingInput: Bool = false

    /// Set by SwiftTermView.makeUIView. Does NOT auto-flush — call `terminalReady()` after first layout.
    var onTerminalOutput: ((Data) -> Void)?
    /// Called when the terminal title changes — used to persist titles on the coordinator.
    var onTitleChanged: ((String) -> Void)?
    /// Called when the awaiting-input state changes — persisted on the coordinator.
    var onAwaitingInputChanged: ((Bool) -> Void)?

    /// Whether the terminal has received its first sizeChanged callback (i.e. is laid out).
    private var terminalSized = false

    // MARK: - Dependencies

    let sessionId: UUID
    private let connection: RelayConnection
    private var pendingOutput: [Data] = []

    // MARK: - Input Detection

    /// Whether Claude Code is currently running in this session.
    /// Set by the coordinator — controls the silence threshold for input detection.
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

    // MARK: - Output (called by SessionCoordinator)

    /// Receives terminal output from the coordinator's I/O routing.
    func receiveOutput(_ data: Data) {
        if terminalSized, let handler = onTerminalOutput {
            handler(data)
        } else {
            pendingOutput.append(data)
        }
        detectInputPrompt(data)
    }

    /// Called by the Coordinator after the first `sizeChanged` — terminal is now laid out.
    /// Flushes any buffered scrollback with a reset prefix so it renders at the correct size.
    func terminalReady() {
        guard !terminalSized, let handler = onTerminalOutput else { return }
        terminalSized = true

        if !pendingOutput.isEmpty {
            // Flush buffered scrollback now that the terminal is sized correctly.
            // No escape sequence prefix — deferring until sizeChanged is sufficient
            // to avoid garbled rendering. Avoid ESC[!p which triggers DA responses.
            let buffered = pendingOutput
            pendingOutput.removeAll()
            for chunk in buffered {
                handler(chunk)
            }
        }
    }

    /// Resets terminal content before a scrollback replay (e.g. foreground recovery).
    /// Sends RIS (Reset to Initial State) so the replayed buffer replaces rather than
    /// appends to existing content.
    func resetForReplay() {
        if let handler = onTerminalOutput {
            handler(Data([0x1B, 0x63]))  // ESC c
        }
    }

    /// Clears stale state when switching away from this session.
    /// The old SwiftTermView is destroyed and a fresh one will be created
    /// on next activation, which re-sets `onTerminalOutput`.
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
        if awaitingInput {
            setAwaitingInput(false)
        }
        Task {
            try? await connection.sendBinary(data)
        }
    }

    func sendInput(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        sendInput(data)
    }

    func sendPasteImage(_ imageData: Data) {
        let base64 = imageData.base64EncodedString()
        Task {
            try? await connection.sendPasteImage(base64Data: base64)
        }
    }

    func sendResize(cols: UInt16, rows: UInt16) {
        Task {
            try? await connection.sendResize(cols: cols, rows: rows)
        }
    }

    // MARK: - Input Prompt Detection

    /// Output-silence detector: when terminal output stops flowing, the session
    /// is likely waiting for user input. The coordinator gates flashing on whether
    /// Claude is actually running — normal shell idle doesn't trigger a flash.
    private func detectInputPrompt(_ data: Data) {
        // Cancel any pending "idle" transition — new output arrived.
        promptDebounceTask?.cancel()
        promptDebounceTask = nil

        // New output means not idle.
        if awaitingInput {
            setAwaitingInput(false)
        }

        // After a period of silence, flag as potentially awaiting input.
        // Use a longer threshold when Claude is running to avoid false positives
        // during API calls and tool execution gaps (can take 10-30s).
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
