import SwiftUI

@main
struct ClaudeRelayApp: App {
    @State private var showSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                ConnectionView()

                if showSplash {
                    SplashScreenView {
                        showSplash = false
                    }
                    .transition(.identity)
                }
            }
        }
    }
}
