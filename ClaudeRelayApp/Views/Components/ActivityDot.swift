import SwiftUI
import ClaudeRelayKit

struct ActivityDot: View {
    let activity: ActivityState
    var agentId: String?
    var size: CGFloat = 8
    @State private var blinkOpacity: Double = 1.0

    private var color: Color {
        switch activity {
        case .active, .idle: return .green
        case .agentActive, .agentIdle:
            return AgentColorPalette.color(for: agentId)
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .fixedSize()
            .opacity(activity == .agentIdle ? blinkOpacity : 1.0)
            .onChange(of: activity) { _, newValue in
                if newValue == .agentIdle {
                    withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                        blinkOpacity = 0.3
                    }
                } else {
                    withAnimation(.default) {
                        blinkOpacity = 1.0
                    }
                }
            }
            .onAppear {
                if activity == .agentIdle {
                    withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                        blinkOpacity = 0.3
                    }
                }
            }
    }
}
