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
    /// Called with ANSI-stripped output text for shell prompt capture and Claude exit detection.
    var onCleanOutput: ((String) -> Void)?

    /// Whether the terminal has received its first sizeChanged callback (i.e. is laid out).
    private var terminalSized = false

    // MARK: - Dependencies

    let sessionId: UUID
    private let connection: RelayConnection
    private var pendingOutput: [Data] = []

    // MARK: - Input Detection

    private var promptDebounceTask: Task<Void, Never>?

    /// Comprehensive ANSI/VT escape sequence stripper.
    /// Covers: CSI (incl. ?/> private params), OSC (BEL and ST terminators),
    /// character set selection, and two-byte sequences (keypad mode, etc.).
    private static let ansiEscapePattern = /\x1B(?:\[[0-9;?]*[A-Za-z]|\][^\x07\x1B]*(?:\x07|\x1B\\)|\([A-B0-2]|[=>])/

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

        // Strip ANSI escape sequences for clean output consumers.
        if let raw = String(data: data, encoding: .utf8) {
            let clean = raw.replacing(Self.ansiEscapePattern, with: "")
            onCleanOutput?(clean)
        }

        // After 1 second of silence, flag as potentially awaiting input.
        promptDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1000))
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
