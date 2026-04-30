import SwiftUI
import ClaudeRelayClient
import ClaudeRelayKit

struct StatusBarView: View {
    @ObservedObject var coordinator: SessionCoordinator

    var body: some View {
        HStack(spacing: 16) {
            // Connection state
            HStack(spacing: 6) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 6, height: 6)
                    .fixedSize()
                Text(connectionLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Activity for active session
            if let id = coordinator.activeSessionId {
                ActivityDot(activity: activityFor(id), size: 6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.black)
    }

    private var connectionColor: Color {
        if coordinator.isRecovering { return .orange }
        return coordinator.isConnected ? .green : .red
    }
    private var connectionLabel: String {
        if coordinator.isRecovering { return "Reconnecting..." }
        return coordinator.isConnected ? "Connected" : "Disconnected"
    }
    private func activityFor(_ id: UUID) -> ActivityState {
        if coordinator.isRunningClaude(sessionId: id) {
            return coordinator.sessionsAwaitingInput.contains(id) ? .claudeIdle : .claudeActive
        }
        return coordinator.sessionsAwaitingInput.contains(id) ? .idle : .active
    }
}
