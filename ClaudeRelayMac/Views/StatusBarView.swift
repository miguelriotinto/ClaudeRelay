import SwiftUI
import ClaudeRelayClient
import ClaudeRelayKit

struct StatusBarView: View {
    @ObservedObject var coordinator: SessionCoordinator

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                ConnectionQualityDot(quality: coordinator.connection.connectionQuality, size: 6)
                Text(connectionLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let id = coordinator.activeSessionId {
                ActivityDot(activity: activityFor(id), agentId: coordinator.activeAgent(for: id), size: 6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.black)
    }

    private var connectionLabel: String {
        if coordinator.isRecovering { return "Reconnecting..." }
        switch coordinator.connection.connectionQuality {
        case .excellent: return "Excellent"
        case .good:      return "Good"
        case .poor:      return "Poor"
        case .veryPoor:  return "Very Poor"
        case .disconnected: return "Disconnected"
        }
    }
    private func activityFor(_ id: UUID) -> ActivityState {
        if coordinator.isRunningAgent(sessionId: id) {
            return coordinator.sessionsAwaitingInput.contains(id) ? .agentIdle : .agentActive
        }
        return coordinator.sessionsAwaitingInput.contains(id) ? .idle : .active
    }
}
