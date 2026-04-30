import SwiftUI
import ClaudeRelayKit

struct ActivityDot: View {
    let activity: ActivityState
    var size: CGFloat = 8
    @State private var blinkOpacity: Double = 1.0

    private var color: Color {
        switch activity {
        case .active, .idle: return .green
        case .claudeActive, .claudeIdle: return .orange
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .fixedSize()
            .opacity(activity == .claudeIdle ? blinkOpacity : 1.0)
            .onChange(of: activity) { _, newValue in
                if newValue == .claudeIdle {
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
                if activity == .claudeIdle {
                    withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                        blinkOpacity = 0.3
                    }
                }
            }
    }
}
