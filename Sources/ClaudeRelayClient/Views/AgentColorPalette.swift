import SwiftUI

/// Centralized per-agent color mapping used throughout both the iOS and
/// macOS apps.
///
/// To add a new coding agent: add a case here AND register the agent in
/// `CodingAgent.all` (ClaudeRelayKit/Models/CodingAgent.swift). No other
/// file needs to change.
public enum AgentColorPalette {
    public static func color(for agentId: String?) -> Color {
        switch agentId {
        case "claude": return .orange
        case "codex":  return Color(red: 84/255, green: 132/255, blue: 137/255)
        default:       return Color(red: 84/255, green: 132/255, blue: 137/255)
        }
    }
}
