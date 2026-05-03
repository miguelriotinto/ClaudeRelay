import SwiftUI

/// Centralized per-agent color mapping used throughout the macOS app UI.
///
/// To add a new coding agent: add a case here AND register the agent in
/// `CodingAgent.all` (ClaudeRelayKit/Models/CodingAgent.swift). No other
/// file needs to change.
enum AgentColorPalette {
    static func color(for agentId: String?) -> Color {
        switch agentId {
        case "claude": return .orange
        case "codex":  return .purple
        default:       return .purple
        }
    }
}
