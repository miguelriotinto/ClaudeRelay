import Foundation
import UIKit

/// Orchestrates the speech pipeline: record -> transcribe -> (local cleanup | cloud enhance) -> output.
/// This is the only class the UI talks to.
@MainActor
final class OnDeviceSpeechEngine: ObservableObject {

    @Published private(set) var state: SpeechEngineState = .idle
    @Published private(set) var modelsReady: Bool = false

    let modelStore: SpeechModelStore

    private let transcriber: any SpeechTranscribing
    private let cleaner: any TextCleaning
    private let cloudEnhancer: CloudPromptEnhancer
    private let capture: AudioCaptureSession

    // Hold typed references for load/unload (protocols don't expose these)
    private let whisperTranscriber: WhisperTranscriber?
    private let textCleaner: TextCleaner?

    private var processingTask: Task<Result<String, Error>, Never>?
    private var memoryWarningObserver: NSObjectProtocol?

    // MARK: - Init

    /// Production initializer.
    convenience init(modelStore: SpeechModelStore? = nil) {
        let store = modelStore ?? .shared
        let transcriber = WhisperTranscriber.shared
        let cleaner = TextCleaner.shared
        self.init(
            transcriber: transcriber,
            cleaner: cleaner,
            cloudEnhancer: CloudPromptEnhancer(),
            capture: AudioCaptureSession(),
            modelStore: store,
            whisperTranscriber: transcriber,
            textCleaner: cleaner
        )
    }

    /// Test initializer -- accepts protocol-typed mocks.
    init(
        transcriber: any SpeechTranscribing,
        cleaner: any TextCleaning,
        cloudEnhancer: CloudPromptEnhancer = CloudPromptEnhancer(),
        capture: AudioCaptureSession,
        modelStore: SpeechModelStore,
        whisperTranscriber: WhisperTranscriber? = nil,
        textCleaner: TextCleaner? = nil
    ) {
        self.transcriber = transcriber
        self.cleaner = cleaner
        self.cloudEnhancer = cloudEnhancer
        self.capture = capture
        self.modelStore = modelStore
        self.whisperTranscriber = whisperTranscriber
        self.textCleaner = textCleaner
        self.modelsReady = modelStore.modelsReady
        observeMemoryWarnings()
    }

    deinit {
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Model Preparation

    func prepareModels() async {
        do {
            try await modelStore.downloadAllModels()
            try await whisperTranscriber?.loadModel()
            textCleaner?.modelPath = modelStore.llmModelPath
            modelsReady = true
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    // MARK: - Recording

    func startRecording() async {
        guard state == .idle else { return }

        do {
            // Load models into memory if cached but not yet loaded (e.g. after app relaunch)
            if modelsReady && whisperTranscriber?.isLoaded != true {
                state = .loadingModel
                try await whisperTranscriber?.loadModel()
                textCleaner?.modelPath = modelStore.llmModelPath
            }

            try capture.start()
            state = .recording
        } catch {
            state = .error(error.localizedDescription)
            Task {
                try? await Task.sleep(for: .seconds(3))
                if case .error = self.state { self.state = .idle }
            }
        }
    }

    /// Stop recording and process the audio.
    /// - `smartCleanup`: use local LLM for filler removal
    /// - `promptEnhancement`: use cloud Haiku for prompt rewriting (overrides cleanup)
    /// - `bearerToken` / `region`: required when promptEnhancement is true
    func stopAndProcess(
        smartCleanup: Bool = true,
        promptEnhancement: Bool = false,
        bearerToken: String = "",
        region: String = "us-east-1"
    ) async -> String? {
        guard state == .recording else { return nil }

        guard let audioBuffer = capture.stop() else {
            state = .idle
            return nil
        }

        let willClean = promptEnhancement || smartCleanup
        let enhancer = cloudEnhancer
        let engine = self
        let task = Task<Result<String, Error>, Never> { [transcriber, cleaner] in
            // Phase 1: Transcribe (always local via Whisper)
            let rawText: String
            do {
                rawText = try await transcriber.transcribe(audioBuffer)
            } catch {
                return .failure(error)
            }

            guard !Task.isCancelled else { return .failure(CancellationError()) }

            // Whisper often hallucinates short phrases ("you", "Thank you.") from silence.
            // Treat transcripts with fewer than 2 words as no speech detected.
            let wordCount = rawText.split(whereSeparator: { $0.isWhitespace }).count
            if wordCount < 2 {
                return .failure(TranscriberError.emptyTranscription)
            }

            // Transition to .cleaning before phase 2 (only when cleanup/enhancement is active)
            if willClean {
                await MainActor.run { engine.state = .cleaning }
            }

            // Phase 2: Process based on settings
            if promptEnhancement {
                // Cloud path: send raw transcript to Bedrock Haiku
                do {
                    return .success(try await enhancer.enhance(rawText, bearerToken: bearerToken, region: region))
                } catch {
                    return .failure(error)
                }
            } else if smartCleanup {
                // Local path: clean filler words with on-device LLM (best-effort)
                do {
                    return .success(try await cleaner.clean(rawText))
                } catch {
                    return .success(rawText)
                }
            } else {
                // Raw passthrough
                return .success(rawText)
            }
        }

        processingTask = task
        state = .transcribing

        let result = await task.value
        processingTask = nil

        switch result {
        case .success(let text):
            state = .idle
            return text
        case .failure(let error):
            // Silence detected — just reset, no error shown.
            if error is CancellationError || (error as? TranscriberError) == .emptyTranscription {
                state = .idle
                return nil
            }
            if state != .idle {
                state = .error(error.localizedDescription)
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    if case .error = state { state = .idle }
                }
            }
            return nil
        }
    }

    func cancel() {
        processingTask?.cancel()
        processingTask = nil
        if capture.isRecording {
            _ = capture.stop()
        }
        state = .idle
    }

    // MARK: - Memory

    private func observeMemoryWarnings() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.textCleaner?.unload()
        }
    }
}
