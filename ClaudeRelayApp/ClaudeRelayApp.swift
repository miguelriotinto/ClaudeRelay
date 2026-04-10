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
        }
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
