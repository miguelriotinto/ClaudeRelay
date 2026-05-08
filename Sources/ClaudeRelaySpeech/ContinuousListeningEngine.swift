import Foundation
import AVFoundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

/// Orchestrates the continuous listening pipeline: VAD → wake-word →
/// recording → turn-end → transcription → cleanup → output.
///
/// The mic stays open across all states while `enable()`d. State transitions
/// are driven by VAD events and detector async callbacks.
@MainActor
public final class ContinuousListeningEngine: ObservableObject {

    @Published public private(set) var state: ContinuousListeningState = .idle

    /// Called with the final, cleaned utterance text after each turn.
    public var onUtteranceReady: ((String) -> Void)?

    // Pipeline collaborators
    private let vad: any VoiceActivityDetecting
    private let wakeWordDetector: WakeWordDetector
    private let turnEndDetector: any TurnEndDetecting
    private let transcriber: any SpeechTranscribing
    private let cleaner: any TextCleaning

    // Audio buffer shared across consumers
    private let audioBuffer: StreamingAudioBuffer

    // Utterance tracking
    private var utteranceStartPosition: Int = 0

    /// Task spawned for wake-word check / turn-end check / transcription.
    /// Tracked so tests can await completion and disable() can cancel cleanly.
    private var pendingTask: Task<Void, Never>?

    private let audioSource: any StreamingAudioSourcing

    // MARK: - Init

    public init(
        vad: any VoiceActivityDetecting,
        wakeWordDetector: WakeWordDetector,
        turnEndDetector: any TurnEndDetecting,
        transcriber: any SpeechTranscribing,
        cleaner: any TextCleaning,
        audioSource: (any StreamingAudioSourcing)? = nil,
        bufferCapacitySeconds: TimeInterval = 10.0,
        sampleRate: Double = 16000
    ) {
        self.vad = vad
        self.wakeWordDetector = wakeWordDetector
        self.turnEndDetector = turnEndDetector
        self.transcriber = transcriber
        self.cleaner = cleaner
        self.audioSource = audioSource ?? StreamingAudioSource()
        self.audioBuffer = StreamingAudioBuffer(
            capacitySeconds: bufferCapacitySeconds,
            sampleRate: sampleRate
        )
        self.audioSource.onChunk = { [weak self] samples in
            guard let self else { return }
            Task { @MainActor [weak self] in
                await self?.ingest(chunk: samples)
            }
        }
    }

    // MARK: - Lifecycle

    public func enable() async {
        guard state == .idle else { return }
        vad.reset()
        wakeWordDetector.reset()
        do {
            try audioSource.start()
            state = .listening
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    public func disable() async {
        guard state != .idle else { return }
        pendingTask?.cancel()
        pendingTask = nil
        audioSource.stop()
        vad.reset()
        wakeWordDetector.reset()
        state = .idle
    }

    // MARK: - Audio ingestion

    /// Process one audio chunk. In production, called from the audio-engine tap;
    /// in tests, called directly with synthetic samples.
    public func ingest(chunk: [Float]) async {
        guard state != .idle else { return }

        audioBuffer.append(chunk)

        // Always feed VAD; its event drives the state machine.
        let event = vad.process(chunk: chunk)

        switch state {
        case .listening:
            if event == .speechStart {
                utteranceStartPosition = audioBuffer.currentPosition
                wakeWordDetector.reset()
                wakeWordDetector.feedAudio(chunk)
                state = .detectingWakeWord
            }

        case .detectingWakeWord:
            wakeWordDetector.feedAudio(chunk)
            if event == .silenceStart {
                // Phrase ended — check if it started with wake word.
                runWakeWordCheck()
            }

        case .recording:
            if event == .silenceStart {
                state = .detectingTurnEnd
                runTurnEndCheck()
            }

        case .detectingTurnEnd:
            // If speech resumes before turn-end prediction finishes, go back to recording.
            if event == .speechStart {
                state = .recording
            }

        case .idle, .transcribing, .cleaning, .outputting, .error:
            break
        }
    }

    /// Await any in-flight async work (wake-word check, turn-end prediction,
    /// transcription, cleanup). Public for tests.
    public func waitForPendingWork() async {
        await pendingTask?.value
    }

    // MARK: - Pipeline steps

    private func runWakeWordCheck() {
        pendingTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.wakeWordDetector.checkForWakeWord()
            guard !Task.isCancelled else { return }
            self.handleWakeWordResult(result)
        }
    }

    private func handleWakeWordResult(_ result: WakeWordResult) {
        switch result {
        case .detected:
            // The first silence already bracketed the phrase, so jump straight
            // to turn-end prediction to decide whether the whole utterance is done.
            state = .detectingTurnEnd
            runTurnEndCheck()
        case .notDetected, .transcriptionFailed:
            wakeWordDetector.reset()
            state = .listening
        }
    }

    private func runTurnEndCheck() {
        pendingTask = Task { [weak self] in
            guard let self else { return }
            let utterance = self.audioBuffer.audioSince(position: self.utteranceStartPosition)
            let result = await self.turnEndDetector.predict(utteranceAudio: utterance)
            guard !Task.isCancelled else { return }
            self.handleTurnEndResult(result, utterance: utterance)
        }
    }

    private func handleTurnEndResult(_ result: TurnEndResult, utterance: [Float]) {
        switch result {
        case .speakerDone:
            runTranscription(utterance: utterance)
        case .speakerContinuing:
            state = .recording
        }
    }

    private func runTranscription(utterance: [Float]) {
        state = .transcribing
        pendingTask = Task { [weak self] in
            guard let self else { return }
            let rawText: String
            do {
                rawText = try await self.transcriber.transcribe(utterance)
            } catch {
                guard !Task.isCancelled else { return }
                self.state = .listening
                return
            }
            guard !Task.isCancelled else { return }

            self.state = .cleaning
            let cleaned: String
            do {
                cleaned = try await self.cleaner.clean(rawText)
            } catch {
                guard !Task.isCancelled else { return }
                cleaned = rawText
            }
            guard !Task.isCancelled else { return }

            self.state = .outputting
            self.onUtteranceReady?(cleaned)
            self.wakeWordDetector.reset()
            self.vad.reset()
            self.state = .listening
        }
    }
}
