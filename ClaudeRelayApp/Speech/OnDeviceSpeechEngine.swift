import Foundation
import UIKit

/// Orchestrates the on-device speech pipeline: record -> transcribe -> clean -> output.
/// This is the only class the UI talks to.
@MainActor
final class OnDeviceSpeechEngine: ObservableObject {

    @Published private(set) var state: SpeechEngineState = .idle
    @Published private(set) var modelsReady: Bool = false

    let modelStore: SpeechModelStore

    private let transcriber: any SpeechTranscribing
    private let cleaner: any TextCleaning
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
        let transcriber = WhisperTranscriber()
        let cleaner = TextCleaner()
        self.init(
            transcriber: transcriber,
            cleaner: cleaner,
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
        capture: AudioCaptureSession,
        modelStore: SpeechModelStore,
        whisperTranscriber: WhisperTranscriber? = nil,
        textCleaner: TextCleaner? = nil
    ) {
        self.transcriber = transcriber
        self.cleaner = cleaner
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

    func startRecording() async throws {
        guard state == .idle else { return }

        // Load models into memory if cached but not yet loaded (e.g. after app relaunch)
        if modelsReady && whisperTranscriber?.isLoaded != true {
            try await whisperTranscriber?.loadModel()
            textCleaner?.modelPath = modelStore.llmModelPath
        }

        try capture.start()
        state = .recording
    }

    func stopAndProcess(smartCleanup: Bool = true, promptEnhancement: Bool = false) async -> String? {
        guard state == .recording else { return nil }

        guard let audioBuffer = capture.stop() else {
            state = .idle
            return nil
        }

        let needsLLM = smartCleanup || promptEnhancement

        let task = Task<Result<String, Error>, Never> { [transcriber, cleaner] in
            // Phase 1: Transcribe
            let rawText: String
            do {
                rawText = try await transcriber.transcribe(audioBuffer)
            } catch {
                return .failure(error)
            }

            guard !Task.isCancelled else { return .failure(CancellationError()) }

            // Phase 2: Clean/enhance (best-effort -- return raw text if LLM fails)
            guard needsLLM else { return .success(rawText) }
            do {
                return .success(try await cleaner.clean(rawText, smartCleanup: smartCleanup, promptEnhancement: promptEnhancement))
            } catch {
                return .success(rawText)
            }
        }

        processingTask = task
        state = .transcribing

        // Approximate state transition to .cleaning
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if state == .transcribing { state = .cleaning }
        }

        let result = await task.value
        processingTask = nil

        switch result {
        case .success(let text):
            state = .idle
            return text
        case .failure(let error):
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
