import SwiftUI
import ClaudeRelayKit

/// Small colored dot visualizing the current `ConnectionQuality`. Used in
/// the status bar on both iOS and macOS.
///
/// Conforms to `Equatable` so SwiftUI can short-circuit redraws inside
/// loops such as `ForEach` and `TimelineView`.
public struct ConnectionQualityDot: View, Equatable {
    public let quality: ConnectionQuality
    public var size: CGFloat

    public init(quality: ConnectionQuality, size: CGFloat = 8) {
        self.quality = quality
        self.size = size
    }

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

    public var body: some View {
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

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.quality == rhs.quality && lhs.size == rhs.size
    }
}
