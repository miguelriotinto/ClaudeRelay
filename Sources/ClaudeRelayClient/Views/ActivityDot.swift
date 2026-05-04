import SwiftUI
import ClaudeRelayKit

/// Small colored dot visualizing the current `ActivityState` for a session.
/// When an agent is running the color is resolved via `AgentColorPalette`.
///
/// Conforms to `Equatable` so SwiftUI can short-circuit redraws inside
/// loops such as `ForEach` and `TimelineView`.
public struct ActivityDot: View, Equatable {
    public let activity: ActivityState
    public var agentId: String?
    public var size: CGFloat

    public init(activity: ActivityState, agentId: String? = nil, size: CGFloat = 8) {
        self.activity = activity
        self.agentId = agentId
        self.size = size
    }

    @State private var blinkOpacity: Double = 1.0

    private var color: Color {
        switch activity {
        case .active, .idle: return .green
        case .agentActive, .agentIdle:
            return AgentColorPalette.color(for: agentId)
        }
    }

    public var body: some View {
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

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.activity == rhs.activity
            && lhs.agentId == rhs.agentId
            && lhs.size == rhs.size
    }
}
