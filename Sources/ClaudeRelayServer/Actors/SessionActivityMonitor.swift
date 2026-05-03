import Foundation
import ClaudeRelayKit

/// Monitors terminal output for a single session and maintains its `ActivityState`.
///
/// Runs inside the owning `PTYSession` actor's isolation domain — NOT a separate actor.
/// This avoids async overhead on the hot path (every output chunk goes through here).
///
/// Detection mechanisms (in priority order):
/// 1. **Foreground process polling**: tcgetpgrp + KERN_PROCARGS2 with parent chain walk
/// 2. **OSC title sequences**: fallback when shell sets title containing an agent keyword
///
/// Exit is debounced: requires two consecutive non-agent signals to prevent false
/// exits during momentary tool-launch process group changes.
public final class SessionActivityMonitor: @unchecked Sendable {

    // MARK: - State

    /// Current activity state. Read from any context; mutated only via `processOutput`/`recordInput`.
    public private(set) var state: ActivityState = .active

    /// The coding agent currently detected as running, or nil.
    public private(set) var activeAgent: CodingAgent?

    // MARK: - Configuration

    private let silenceThreshold: TimeInterval
    private let agentSilenceThreshold: TimeInterval
    private let onChange: @Sendable (ActivityState, CodingAgent?) -> Void

    /// Called by the silence timer from `timerQueue`. The owner (PTYSession) sets
    /// this to a closure that re-enters the actor and calls `applySilenceTimeout()`,
    /// ensuring all state mutations happen on a single isolation domain.
    public var onSilenceTimeout: (@Sendable () -> Void)?

    // MARK: - Internals

    private var silenceTimer: DispatchWorkItem?
    private let timerQueue = DispatchQueue(label: "com.claude.relay.activity-monitor")
    private var cancelled = false

    /// Exit debounce: counts consecutive non-agent signals from **any source**
    /// (foreground-process poll and/or OSC title change). The two inputs share a
    /// single counter, so exit fires when any two consecutive non-agent signals
    /// arrive — e.g. poll+poll, title+title, or poll+title in either order.
    /// Any agent-positive signal resets the counter to 0.
    private var consecutiveNoAgentPolls = 0
    private static let exitDebounceThreshold = 2

    /// Comprehensive ANSI/VT escape sequence stripper.
    private static let ansiEscapePattern = #/\x1B(?:\[[\x20-\x3F]*[\x40-\x7E]|\][^\x07\x1B]*(?:\x07|\x1B\\)|\([A-B0-2]|[=>])/#

    // MARK: - Init

    public init(
        silenceThreshold: TimeInterval = 1.0,
        agentSilenceThreshold: TimeInterval = 2.0,
        onChange: @escaping @Sendable (ActivityState, CodingAgent?) -> Void
    ) {
        self.silenceThreshold = silenceThreshold
        self.agentSilenceThreshold = agentSilenceThreshold
        self.onChange = onChange
    }

    // MARK: - Process Output

    /// Analyze a chunk of PTY output. Called from `PTYSession.handleOutput()`.
    public func processOutput(_ data: Data) {
        guard !cancelled else { return }

        // Always scan for OSC title so agent-entry detection still works.
        detectTitleChange(in: data)

        // Fast path: when no agent is running, *any* output is activity. We
        // don't need UTF-8 decoding or ANSI stripping — that work is only
        // needed to distinguish meaningful output from ink/React redraws
        // while an agent is running.
        if activeAgent == nil {
            transition(to: .active)
            resetSilenceTimer()
            return
        }

        // Agent path: only count visible content (skip pure escape-sequence
        // redraws). Decode + ANSI-strip only in this branch.
        var hasVisibleContent = true
        if let raw = String(data: data, encoding: .utf8) {
            let clean = raw.replacing(Self.ansiEscapePattern, with: "")
            hasVisibleContent = !clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if hasVisibleContent {
            transition(to: .agentActive)
            resetSilenceTimer()
        }
    }

    /// Called when the client sends input to this session.
    public func recordInput() {
        guard !cancelled else { return }
        let activeState: ActivityState = activeAgent != nil ? .agentActive : .active
        transition(to: activeState)
        resetSilenceTimer()
    }

    /// Force agent exit and transition to idle. Called when the PTY process exits —
    /// regardless of what the monitor thinks, an agent cannot be running if the shell is dead.
    /// Emits a final state change so clients see the definitive "not running" state.
    public func forceExit() {
        guard !cancelled else { return }
        silenceTimer?.cancel()
        silenceTimer = nil
        if activeAgent != nil {
            activeAgent = nil
            consecutiveNoAgentPolls = 0
        }
        transition(to: .idle)
    }

    /// Stop monitoring. Called on session termination.
    public func cancel() {
        cancelled = true
        silenceTimer?.cancel()
        silenceTimer = nil
    }

    // MARK: - Foreground Process Detection

    /// Called by PTYSession's foreground poll timer with the detected agent
    /// (or nil if no agent was found in the process chain).
    ///
    /// Entry is immediate (single poll confirms). Exit is debounced: requires
    /// `exitDebounceThreshold` consecutive non-agent signals (counted across
    /// this poll path and the OSC title path combined) to guard against
    /// momentary process group changes during tool launches.
    public func updateForegroundProcess(agent: CodingAgent?) {
        guard !cancelled else { return }
        if let agent {
            consecutiveNoAgentPolls = 0
            if activeAgent?.id != agent.id {
                activeAgent = agent
                transition(to: .agentActive)
                resetSilenceTimer()
            }
        } else if activeAgent != nil {
            consecutiveNoAgentPolls += 1
            if consecutiveNoAgentPolls >= Self.exitDebounceThreshold {
                exitAgent()
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
        if let agent = CodingAgent.matching(title: title) {
            consecutiveNoAgentPolls = 0
            if activeAgent?.id != agent.id {
                activeAgent = agent
                transition(to: .agentActive)
                resetSilenceTimer()
            }
        } else if activeAgent != nil {
            consecutiveNoAgentPolls += 1
            if consecutiveNoAgentPolls >= Self.exitDebounceThreshold {
                exitAgent()
            }
        }
    }

    private func exitAgent() {
        activeAgent = nil
        consecutiveNoAgentPolls = 0
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

    /// Called from the owning actor when the silence timer fires. Computes the
    /// idle state using the current `activeAgent` flag — safe because the
    /// actor serializes this call with all other state mutations.
    public func applySilenceTimeout() {
        guard !cancelled else { return }
        let idleState: ActivityState = activeAgent != nil ? .agentIdle : .idle
        transition(to: idleState)
    }

    private func resetSilenceTimer() {
        silenceTimer?.cancel()
        let threshold = activeAgent != nil ? agentSilenceThreshold : silenceThreshold
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.cancelled else { return }
            if let callback = self.onSilenceTimeout {
                callback()
            } else {
                let idleState: ActivityState = self.activeAgent != nil ? .agentIdle : .idle
                self.transition(to: idleState)
            }
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
        onChange(newState, activeAgent)
    }
}
