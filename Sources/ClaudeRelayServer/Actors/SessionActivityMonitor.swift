import Foundation
import ClaudeRelayKit

/// Monitors terminal output for a single session and maintains its `ActivityState`.
///
/// Runs inside the owning `PTYSession` actor's isolation domain — NOT a separate actor.
/// This avoids async overhead on the hot path (every output chunk goes through here).
///
/// Detection mechanisms (in priority order):
/// 1. **Foreground process polling**: tcgetpgrp + KERN_PROCARGS2 with parent chain walk
/// 2. **OSC title sequences**: fallback when shell sets title containing "claude"
///
/// Exit is debounced: requires two consecutive non-Claude signals to prevent false
/// exits during momentary tool-launch process group changes.
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

    /// Exit debounce: counts consecutive non-Claude signals. Must reach threshold
    /// before declaring Claude exited.
    private var consecutiveNonClaudePolls = 0
    private static let exitDebounceThreshold = 2

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

        // 1. Alt-screen exit is NOT treated as a definitive Claude exit signal.
        //    Claude spawns tools (vim, less, man) that use alternate screen — when
        //    those tools exit, this sequence fires but Claude is still running.
        //    Exit is now handled exclusively by the debounced foreground poll.

        // 2. Extract and analyze OSC title sequences for Claude entry.
        detectTitleChange(in: data)

        // 3. Strip ANSI and determine if there is visible content.
        var hasVisibleContent = true
        if let raw = String(data: data, encoding: .utf8) {
            let clean = raw.replacing(Self.ansiEscapePattern, with: "")

            // When Claude is running, only count output with visible content as activity.
            // TUI frameworks (ink/React) send periodic escape sequences (cursor moves,
            // screen redraws) that don't represent meaningful output change.
            if isClaudeRunning {
                hasVisibleContent = !clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }

        // 4. Only transition to active state and reset the silence timer for
        // meaningful visible content. Escape-sequence-only output must NOT
        // break idle detection.
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

    // MARK: - Foreground Process Detection

    /// Called by PTYSession's foreground poll timer with the result of process
    /// detection (including parent chain walk).
    ///
    /// Entry is immediate (single poll confirms). Exit is debounced: requires
    /// `exitDebounceThreshold` consecutive non-Claude polls to guard against
    /// momentary process group changes during tool launches.
    public func updateForegroundProcess(isClaude: Bool) {
        guard !cancelled else { return }
        if isClaude {
            consecutiveNonClaudePolls = 0
            if !isClaudeRunning {
                isClaudeRunning = true
                transition(to: .claudeActive)
                resetSilenceTimer()
            }
        } else if isClaudeRunning {
            consecutiveNonClaudePolls += 1
            if consecutiveNonClaudePolls >= Self.exitDebounceThreshold {
                exitClaude()
            }
        }
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
            consecutiveNonClaudePolls = 0
            if !isClaudeRunning {
                isClaudeRunning = true
                transition(to: .claudeActive)
                resetSilenceTimer()
            }
        } else if isClaudeRunning {
            // Non-Claude title increments the debounce counter. Combined with
            // process poll, two consecutive non-Claude signals confirm exit.
            consecutiveNonClaudePolls += 1
            if consecutiveNonClaudePolls >= Self.exitDebounceThreshold {
                exitClaude()
            }
        }
    }

    private func exitClaude() {
        isClaudeRunning = false
        consecutiveNonClaudePolls = 0
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
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.cancelled else { return }
            let idleState: ActivityState = self.isClaudeRunning ? .claudeIdle : .idle
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
