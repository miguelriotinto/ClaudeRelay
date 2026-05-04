import SwiftUI
import ClaudeRelayClient
import ClaudeRelaySpeech

@main
struct ClaudeRelayApp: App {

    /// Platform-scoped server bookmark storage. The legacy key migrates
    /// existing users from the old `com.coderemote.*` prefix transparently.
    static let savedConnections = SavedConnectionStore(
        key: "com.clauderelay.ios.savedConnections",
        legacyKeys: ["com.coderemote.savedConnections"]
    )

    @State private var showSplash = true
    @State private var pendingSessionId: UUID?
    @State private var preloadTask: Task<Void, Never>?

    var body: some Scene {
        WindowGroup {
            ZStack {
                ServerListView(pendingSessionId: $pendingSessionId)

                if showSplash {
                    SplashScreenView {
                        showSplash = false
                    }
                    .transition(.identity)
                }
            }
            .task {
                let task = Task { await preloadSpeechModels() }
                preloadTask = task
                await task.value
            }
            .onDisappear {
                preloadTask?.cancel()
                preloadTask = nil
            }
            .onOpenURL { url in
                handleDeepLink(url)
            }
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "clauderelay",
              url.host == "session",
              let uuidString = url.pathComponents.dropFirst().first,
              let sessionId = UUID(uuidString: uuidString) else {
            return
        }
        pendingSessionId = sessionId
    }

    @MainActor
    private func preloadSpeechModels() async {
        let store = SpeechModelStore.shared

        if !store.modelsReady {
            try? await store.downloadAllModels()
        }

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
