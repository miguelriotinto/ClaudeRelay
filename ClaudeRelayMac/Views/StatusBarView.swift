import SwiftUI
import ClaudeRelayClient

struct StatusBarView: View {
    @ObservedObject var coordinator: SessionCoordinator

    var body: some View {
        HStack(spacing: 16) {
            // Connection state
            HStack(spacing: 6) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 8, height: 8)
                Text(connectionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Activity for active session
            if let id = coordinator.activeSessionId {
                HStack(spacing: 6) {
                    Image(systemName: activityIcon(id))
                        .foregroundStyle(activityColor(id))
                        .font(.caption)
                    Text(activityLabel(id))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.8))
    }

    private var connectionColor: Color {
        if coordinator.isRecovering { return .orange }
        return coordinator.isConnected ? .green : .red
    }
    private var connectionLabel: String {
        if coordinator.isRecovering { return "Reconnecting..." }
        return coordinator.isConnected ? "Connected" : "Disconnected"
    }
    private func activityIcon(_ id: UUID) -> String {
        if coordinator.isRunningClaude(sessionId: id) {
            return coordinator.sessionsAwaitingInput.contains(id) ?
                "circle.lefthalf.filled" : "circle.fill"
        }
        return "circle"
    }
    private func activityColor(_ id: UUID) -> Color {
        if coordinator.isRunningClaude(sessionId: id) {
            return coordinator.sessionsAwaitingInput.contains(id) ? .orange : .green
        }
        return .secondary
    }
    private func activityLabel(_ id: UUID) -> String {
        if coordinator.isRunningClaude(sessionId: id) {
            return coordinator.sessionsAwaitingInput.contains(id) ?
                "Claude (idle)" : "Claude (active)"
        }
        return coordinator.sessionsAwaitingInput.contains(id) ? "Idle" : "Active"
    }
}
