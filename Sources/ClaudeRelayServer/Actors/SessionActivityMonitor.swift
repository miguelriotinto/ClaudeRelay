import Foundation
import ClaudeRelayKit

/// Monitors terminal output for a single session and maintains its `ActivityState`.
///
/// Runs inside the owning `PTYSession` actor's isolation domain — NOT a separate actor.
/// This avoids async overhead on the hot path (every output chunk goes through here).
///
/// Detection logic (ported from iOS `TerminalViewModel` + `SessionCoordinator`):
/// - **Claude entry**: OSC title containing "claude" (case-insensitive)
/// - **Claude exit**: shell prompt appearance or alternate screen buffer exit
/// - **Silence/idle**: no output for configurable threshold (different for Claude vs shell)
public final class SessionActivityMonitor: @unchecked Sendable {

    // MARK: - State

    /// Current activity state. Read from any context; mutated only via `processOutput`/`recordInput`.
    public private(set) var state: ActivityState = .active

    /// Whether Claude Code is currently detected as running.
    private var isClaudeRunning = false

    // MARK: - Configuration

    private let silenceThreshold: TimeInterval
    private let claudeSilenceThreshold: TimeInterval
    private let onChange: @Sendable (ActivityState) -> Void

    // MARK: - Internals

    private var silenceTimer: DispatchWorkItem?
    private let timerQueue = DispatchQueue(label: "com.claude.relay.activity-monitor")
    private var cancelled = false

    /// ESC [ ? 1049 l — leave alternate screen buffer.
    private static let leaveAlternateScreen = Data([0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x34, 0x39, 0x6C])

    /// Comprehensive ANSI/VT escape sequence stripper.
    private static let ansiEscapePattern = #/\x1B(?:\[[\x20-\x3F]*[\x40-\x7E]|\][^\x07\x1B]*(?:\x07|\x1B\\)|\([A-B0-2]|[=>])/#

    // MARK: - Init

    public init(
        silenceThreshold: TimeInterval = 1.0,
        claudeSilenceThreshold: TimeInterval = 2.0,
        onChange: @escaping @Sendable (ActivityState) -> Void
    ) {
        self.silenceThreshold = silenceThreshold
        self.claudeSilenceThreshold = claudeSilenceThreshold
        self.onChange = onChange
    }

    // MARK: - Process Output

    /// Analyze a chunk of PTY output. Called from `PTYSession.handleOutput()`.
    public func processOutput(_ data: Data) {
        guard !cancelled else { return }

        // 1. Detect alternate screen buffer exit (strong Claude exit signal).
        if isClaudeRunning, data.range(of: Self.leaveAlternateScreen) != nil {
            exitClaude()
        }

        // 2. Extract and analyze OSC title sequences for Claude entry.
        detectTitleChange(in: data)

        // 3. Strip ANSI and analyze clean text for shell prompt (Claude exit).
        var hasVisibleContent = true
        if let raw = String(data: data, encoding: .utf8) {
            let clean = raw.replacing(Self.ansiEscapePattern, with: "")
            analyzeCleanOutput(clean)

            // When Claude is running, only count output with visible content as activity.
            // TUI frameworks (ink/React) send periodic escape sequences (cursor moves,
            // screen redraws) that don't represent meaningful output change — these
            // should not reset the silence timer.
            if isClaudeRunning {
                hasVisibleContent = !clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }

        // 4. Only transition to active state and reset the silence timer for
        // meaningful visible content. Escape-sequence-only output (TUI cursor
        // moves, screen redraws) must NOT break idle detection — otherwise the
        // state bounces to .claudeActive on every noise chunk but the silence
        // timer is never reset, permanently destroying the idle signal.
        if hasVisibleContent {
            let activeState: ActivityState = isClaudeRunning ? .claudeActive : .active
            transition(to: activeState)
            resetSilenceTimer()
        }
    }

    /// Called when the client sends input to this session.
    public func recordInput() {
        guard !cancelled else { return }
        let activeState: ActivityState = isClaudeRunning ? .claudeActive : .active
        transition(to: activeState)
        resetSilenceTimer()
    }

    /// Stop monitoring. Called on session termination.
    public func cancel() {
        cancelled = true
        silenceTimer?.cancel()
        silenceTimer = nil
    }

    // MARK: - Detection Logic

    /// Scan for OSC title set sequences: ESC ] 0 ; <title> BEL (or ESC ] 2 ; <title> BEL)
    private func detectTitleChange(in data: Data) {
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count - 4 {
            if bytes[i] == 0x1B, bytes[i + 1] == 0x5D {
                let paramStart = i + 2
                if paramStart < bytes.count,
                   (bytes[paramStart] == 0x30 || bytes[paramStart] == 0x32),
                   paramStart + 1 < bytes.count, bytes[paramStart + 1] == 0x3B {
                    let titleStart = paramStart + 2
                    var titleEnd = titleStart
                    while titleEnd < bytes.count && bytes[titleEnd] != 0x07 {
                        if bytes[titleEnd] == 0x1B, titleEnd + 1 < bytes.count, bytes[titleEnd + 1] == 0x5C {
                            break
                        }
                        titleEnd += 1
                    }
                    if titleEnd > titleStart, let title = String(bytes: bytes[titleStart..<titleEnd], encoding: .utf8) {
                        handleTitle(title)
                    }
                    i = titleEnd + 1
                    continue
                }
            }
            i += 1
        }
    }

    private func handleTitle(_ title: String) {
        if title.localizedCaseInsensitiveContains("claude") {
            if !isClaudeRunning {
                isClaudeRunning = true
                transition(to: .claudeActive)
                resetSilenceTimer()
            }
        }
    }

    private func analyzeCleanOutput(_ text: String) {
        guard isClaudeRunning else { return }
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let lastLine = lines.last, Self.looksLikeShellPrompt(lastLine) {
            exitClaude()
        }
    }

    private func exitClaude() {
        isClaudeRunning = false
        transition(to: .active)
        resetSilenceTimer()
    }

    /// Heuristic: does this ANSI-stripped line look like a shell prompt?
    public static func looksLikeShellPrompt(_ line: String) -> Bool {
        guard line.count >= 2, line.count <= 120 else { return false }
        guard line.hasSuffix("$") || line.hasSuffix("%") || line.hasSuffix("#") else { return false }
        if line.hasPrefix("  ") || line.hasPrefix("\t") { return false }
        return true
    }

    // MARK: - Silence Timer

    private func resetSilenceTimer() {
        silenceTimer?.cancel()
        let threshold = isClaudeRunning ? claudeSilenceThreshold : silenceThreshold
        let isClaudeRunningCapture = isClaudeRunning
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.cancelled else { return }
            let idleState: ActivityState = isClaudeRunningCapture ? .claudeIdle : .idle
            self.transition(to: idleState)
        }
        silenceTimer = item
        timerQueue.asyncAfter(deadline: .now() + threshold, execute: item)
    }

    // MARK: - State Transition

    private func transition(to newState: ActivityState) {
        guard newState != state else { return }
        let oldState = state
        state = newState
        RelayLogger.log(.debug, category: "activity", "State: \(oldState.rawValue) → \(newState.rawValue)")
        onChange(newState)
    }
}
