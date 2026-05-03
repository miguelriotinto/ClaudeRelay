import SwiftUI

/// Centralized per-agent color mapping used throughout the iOS app UI.
///
/// To add a new coding agent: add a case here AND register the agent in
/// `CodingAgent.all` (ClaudeRelayKit/Models/CodingAgent.swift). No other
/// file needs to change.
enum AgentColorPalette {
    static func color(for agentId: String?) -> Color {
        switch agentId {
        case "claude": return .orange
        case "codex":  return magenta
        default:       return .purple
        }
    }

    /// SwiftUI doesn't ship `.magenta`, so we define a vibrant magenta that
    /// reads well on the black terminal chrome.
    static let magenta = Color(red: 1.0, green: 0.0, blue: 0.65)
}
