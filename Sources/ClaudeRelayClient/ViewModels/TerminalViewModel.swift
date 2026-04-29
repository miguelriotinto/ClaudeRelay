import Foundation
import Combine

/// Manages terminal I/O state for a single session.
///
/// The `SessionCoordinator` pushes output bytes in via `receiveOutput(_:)`;
/// this view model buffers them until the terminal view reports it has been
/// laid out (`terminalReady()`), then flushes and starts forwarding live.
///
/// ## Lifecycle
///
/// 1. A view creates the VM with `init(sessionId:connection:)`.
/// 2. The terminal view (SwiftTerm bridge) installs `onTerminalOutput`,
///    `onTitleChanged`, `onAwaitingInputChanged`.
/// 3. On the first `sizeChanged` delegate callback, the view calls
///    `terminalReady()` to drain any buffered scrollback.
/// 4. When switching away, the view calls `prepareForSwitch()` to clear
///    callbacks and debounce tasks.
@MainActor
public final class TerminalViewModel: ObservableObject {

    // MARK: - Published State

    @Published public var connectionState: RelayConnection.ConnectionState
    /// Terminal title set by the running process via OSC escape sequences.
    @Published public var terminalTitle: String = ""
    /// True when output has been silent long enough that the session is likely
    /// waiting for user input. Driven by `detectInputPrompt(_:)`.
    @Published public var awaitingInput: Bool = false

    /// Installed by the terminal view. Receives live bytes after `terminalReady()`.
    public var onTerminalOutput: ((Data) -> Void)?
    /// Installed by the terminal view. Fires when the running process sets an OSC title.
    public var onTitleChanged: ((String) -> Void)?
    /// Installed by the terminal view. Fires when `awaitingInput` transitions.
    public var onAwaitingInputChanged: ((Bool) -> Void)?

    private var terminalSized = false

    // MARK: - Dependencies

    public let sessionId: UUID
    private let connection: RelayConnection
    private var pendingOutput: [Data] = []

    // MARK: - Input Detection

    /// Set by the coordinator when Claude is actively running in this session.
    /// Controls the silence threshold used for input-awaiting detection — a
    /// longer window avoids false positives during API-call/tool-execution gaps.
    public var isClaudeActive = false
    private var promptDebounceTask: Task<Void, Never>?

    // MARK: - Init

    public init(sessionId: UUID, connection: RelayConnection) {
        self.sessionId = sessionId
        self.connection = connection
        self.connectionState = connection.state

        connection.$state
            .removeDuplicates()
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .assign(to: &$connectionState)
    }

    // MARK: - Output

    /// Receives terminal output from the coordinator's I/O routing.
    public func receiveOutput(_ data: Data) {
        if terminalSized, let handler = onTerminalOutput {
            handler(data)
        } else {
            pendingOutput.append(data)
        }
        detectInputPrompt(data)
    }

    /// Call once after the terminal view's first `sizeChanged` callback.
    /// Flushes any scrollback that arrived while the view was still laying out.
    public func terminalReady() {
        guard !terminalSized, let handler = onTerminalOutput else { return }
        terminalSized = true
        let buffered = pendingOutput
        pendingOutput.removeAll()
        for chunk in buffered { handler(chunk) }
    }

    /// Sends RIS (`ESC c`) so a subsequent scrollback replay replaces the
    /// existing buffer rather than appending to it. Used during foreground
    /// recovery after reconnection.
    public func resetForReplay() {
        onTerminalOutput?(Data([0x1B, 0x63]))
    }

    /// Called by the view when switching away from this session. Clears the
    /// callbacks (the old terminal view is about to be destroyed) and any
    /// pending debounce task.
    public func prepareForSwitch() {
        promptDebounceTask?.cancel()
        promptDebounceTask = nil
        onTerminalOutput = nil
        onTitleChanged = nil
        onAwaitingInputChanged = nil
        terminalSized = false
        pendingOutput.removeAll()
    }

    // MARK: - Input

    public func sendInput(_ data: Data) {
        if awaitingInput { setAwaitingInput(false) }
        Task { try? await connection.sendBinary(data) }
    }

    public func sendInput(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        sendInput(data)
    }

    public func sendPasteImage(_ imageData: Data) {
        let base64 = imageData.base64EncodedString()
        Task { try? await connection.sendPasteImage(base64Data: base64) }
    }

    public func sendResize(cols: UInt16, rows: UInt16) {
        Task { try? await connection.sendResize(cols: cols, rows: rows) }
    }

    // MARK: - Input Prompt Detection

    /// Output-silence detector: if no output has arrived for `threshold`
    /// after the last chunk, mark the session as awaiting input. The coordinator
    /// decides whether to surface this in the UI (e.g. attention-flash a tab).
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
