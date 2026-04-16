import SwiftUI

@main
struct ClaudeRelayApp: App {
    @State private var showSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                ServerListView()

                if showSplash {
                    SplashScreenView {
                        showSplash = false
                    }
                    .transition(.identity)
                }
            }
            .task { await preloadSpeechModels() }
            .onOpenURL { url in
                handleDeepLink(url)
            }
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "clauderelay",
              url.host == "session",
              let uuidString = url.pathComponents.dropFirst().first,
              let _ = UUID(uuidString: uuidString) else {
            return
        }
        // The primary QR use case (scanning from the attach sheet while
        // connected) is handled inline by QRScannerSheet. Cold-start deep
        // linking (app not connected) would require ServerListView to accept
        // a pending session ID — out of scope for this feature.
    }

    /// Load speech models in the background on launch so the first mic tap is instant.
    private func preloadSpeechModels() async {
        let store = SpeechModelStore.shared
        guard store.modelsReady else { return }

        let transcriber = WhisperTranscriber.shared
        if !transcriber.isLoaded {
            try? await transcriber.loadModel()
        }

        let cleaner = TextCleaner.shared
        if !cleaner.isLoaded {
            cleaner.modelPath = store.llmModelPath
            try? cleaner.loadModel(from: store.llmModelPath)
        }
    }
}
