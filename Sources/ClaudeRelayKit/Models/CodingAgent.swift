import Foundation

/// Describes a coding agent CLI that Claude Relay can detect running inside a PTY session.
///
/// The server's foreground-process poller walks the process tree looking for
/// process names matching any registered agent. OSC title sequences provide
/// a fallback detection path.
public struct CodingAgent: Codable, Equatable, Hashable, Sendable {
    /// Stable identifier used on the wire protocol and in persisted state.
    public let id: String
    /// Human-readable name shown in UI where space permits.
    public let displayName: String
    /// Lowercase executable names to match. A process matches if its name
    /// equals an entry or starts with `"<entry>-"` (e.g. "claude-code" matches "claude").
    public let processNames: [String]
    /// Case-insensitive substrings to match against OSC title sequences.
    public let titleKeywords: [String]

    public init(id: String, displayName: String, processNames: [String], titleKeywords: [String]) {
        self.id = id
        self.displayName = displayName
        self.processNames = processNames
        self.titleKeywords = titleKeywords
    }

    public func matchesProcessName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return processNames.contains { lower == $0 || lower.hasPrefix($0 + "-") || lower.hasPrefix($0 + ".") }
    }

    public func matchesTitle(_ title: String) -> Bool {
        titleKeywords.contains { title.localizedCaseInsensitiveContains($0) }
    }

    // MARK: - Registry

    public static let claude = CodingAgent(
        id: "claude", displayName: "Claude Code",
        processNames: ["claude"], titleKeywords: ["claude"]
    )

    public static let codex = CodingAgent(
        id: "codex", displayName: "Codex",
        processNames: ["codex"], titleKeywords: ["codex"]
    )

    public static let all: [CodingAgent] = [.claude, .codex]

    /// Look up an agent by its wire-protocol ID.
    public static func find(id: String) -> CodingAgent? {
        all.first { $0.id == id }
    }

    /// Find the first agent whose process name matches.
    public static func matching(processName: String) -> CodingAgent? {
        all.first { $0.matchesProcessName(processName) }
    }

    /// Find the first agent whose title keyword matches.
    public static func matching(title: String) -> CodingAgent? {
        all.first { $0.matchesTitle(title) }
    }
}
