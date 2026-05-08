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
    private var wakeWordResidue: String = ""

    // MARK: - Init

    public init(
        vad: any VoiceActivityDetecting,
        wakeWordDetector: WakeWordDetector,
        turnEndDetector: any TurnEndDetecting,
        transcriber: any SpeechTranscribing,
        cleaner: any TextCleaning,
        bufferCapacitySeconds: TimeInterval = 10.0,
        sampleRate: Double = 16000
    ) {
        self.vad = vad
        self.wakeWordDetector = wakeWordDetector
        self.turnEndDetector = turnEndDetector
        self.transcriber = transcriber
        self.cleaner = cleaner
        self.audioBuffer = StreamingAudioBuffer(
            capacitySeconds: bufferCapacitySeconds,
            sampleRate: sampleRate
        )
    }

    // MARK: - Lifecycle

    public func enable() async {
        guard state == .idle else { return }
        vad.reset()
        wakeWordDetector.reset()
        state = .listening
    }

    public func disable() async {
        guard state != .idle else { return }
        vad.reset()
        wakeWordDetector.reset()
        state = .idle
    }
}
