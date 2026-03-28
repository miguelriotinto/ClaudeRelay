import SwiftUI

struct SplashScreenView: View {
    @State private var logoScale: CGFloat = 0.6
    @State private var logoOpacity: Double = 0
    @State private var textOpacity: Double = 0
    @State private var finished = false

    let onComplete: () -> Void

    private let brandColor = Color(red: 0.79, green: 0.58, blue: 0.42)

    var body: some View {
        ZStack {
            brandColor.ignoresSafeArea()

            VStack(spacing: 20) {
                Image("SplashLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .scaleEffect(logoScale)
                    .opacity(logoOpacity)

                Text("ClaudeRelay")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .opacity(textOpacity)

                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                    .font(.system(size: 8))
                    .foregroundStyle(.white.opacity(0.6))
                    .opacity(textOpacity)
            }
        }
        .opacity(finished ? 0 : 1)
        .task {
            await animateSequence()
        }
    }

    // MARK: - Animation Sequence

    @MainActor
    private func animateSequence() async {
        // Phase 1: Logo scales up + fades in (0 → 0.8s)
        withAnimation(.spring(duration: 0.8, bounce: 0.3)) {
            logoScale = 1.0
            logoOpacity = 1.0
        }
        try? await Task.sleep(for: .seconds(0.6))

        // Phase 2: Text fades in with slight delay (0.6 → 1.1s)
        withAnimation(.easeOut(duration: 0.5)) {
            textOpacity = 1.0
        }
        try? await Task.sleep(for: .seconds(1.4))

        // Phase 3: Fade out everything (2.0 → 2.7s)
        withAnimation(.easeInOut(duration: 0.7)) {
            finished = true
        }
        try? await Task.sleep(for: .seconds(0.7))

        onComplete()
    }
}
