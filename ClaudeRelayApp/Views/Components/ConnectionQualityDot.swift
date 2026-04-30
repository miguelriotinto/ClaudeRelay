import SwiftUI
import ClaudeRelayKit

struct ConnectionQualityDot: View {
    let quality: ConnectionQuality
    var size: CGFloat = 8
    @State private var blinkOpacity: Double = 1.0

    private var color: Color {
        switch quality {
        case .excellent, .good: return .green
        case .poor, .veryPoor: return .yellow
        case .disconnected: return .red
        }
    }

    private var shouldBlink: Bool {
        quality == .good || quality == .veryPoor
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .fixedSize()
            .opacity(shouldBlink ? blinkOpacity : 1.0)
            .onChange(of: quality) { _, newValue in
                let blink = newValue == .good || newValue == .veryPoor
                if blink {
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
                if shouldBlink {
                    withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                        blinkOpacity = 0.3
                    }
                }
            }
    }
}
