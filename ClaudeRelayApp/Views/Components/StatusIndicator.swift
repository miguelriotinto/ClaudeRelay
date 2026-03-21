import SwiftUI
import ClaudeRelayClient

/// A small colored dot with a label indicating the current connection state.
struct StatusIndicator: View {
    let state: RelayConnection.ConnectionState

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var color: Color {
        switch state {
        case .connected:
            return .green
        case .connecting, .reconnecting:
            return .yellow
        case .disconnected:
            return .red
        }
    }

    private var label: String {
        switch state {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting"
        case .reconnecting:
            return "Reconnecting"
        case .disconnected:
            return "Disconnected"
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        StatusIndicator(state: .connected)
        StatusIndicator(state: .reconnecting)
        StatusIndicator(state: .disconnected)
    }
}
