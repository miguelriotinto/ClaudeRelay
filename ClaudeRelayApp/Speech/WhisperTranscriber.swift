import Foundation
import WhisperKit

/// Protocol for speech transcription — enables mock injection in tests.
protocol SpeechTranscribing: Sendable {
    func transcribe(_ audioBuffer: [Float]) async throws -> String
}

/// Wraps WhisperKit to transcribe [Float] audio buffers into text.
/// Shared singleton so the model stays loaded across session switches.
final class WhisperTranscriber: SpeechTranscribing {

    static let shared = WhisperTranscriber()

    private var whisperKit: WhisperKit?
    private(set) var isLoaded = false

    /// Download and load the Whisper small.en model.
    /// WhisperKit manages its own model storage under Application Support.
    /// - Parameter progressCallback: Reports 0.0–1.0 as WhisperKit transitions
    ///   through loading → loaded → prewarming → prewarmed.
    func loadModel(progressCallback: (@Sendable (Double) -> Void)? = nil) async throws {
        // Init without loading so we can attach the state callback first.
        let kit = try await WhisperKit(
            model: "openai_whisper-small.en",
            verbose: false,
            prewarm: false,
            load: false
        )

        if let progressCallback {
            kit.modelStateCallback = { _, newState in
                switch newState {
                case .loading:     progressCallback(0.1)
                case .loaded:      progressCallback(0.5)
                case .prewarming:  progressCallback(0.7)
                case .prewarmed:   progressCallback(1.0)
                default: break
                }
            }
        }

        try await kit.loadModels()
        try await kit.prewarmModels()

        self.whisperKit = kit
        self.isLoaded = true
    }

    /// Transcribe a 16kHz mono Float32 audio buffer.
    /// Returns the best transcription string, or throws on failure.
    func transcribe(_ audioBuffer: [Float]) async throws -> String {
        guard let whisperKit else {
            throw TranscriberError.modelNotLoaded
        }

        let results: [TranscriptionResult] = try await whisperKit.transcribe(audioArray: audioBuffer)

        let text = results
            .map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            throw TranscriberError.emptyTranscription
        }

        return text
    }

    /// Release the model from memory.
    func unload() async {
        await whisperKit?.unloadModels()
        whisperKit = nil
        isLoaded = false
    }
}

enum TranscriberError: Error, LocalizedError {
    case modelNotLoaded
    case emptyTranscription

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "Whisper model not loaded"
        case .emptyTranscription: return "No speech detected"
        }
    }
}
