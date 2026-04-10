import Foundation

/// Pipeline states for the on-device speech engine.
/// UI observes this to drive mic button color and haptics.
enum SpeechEngineState: Equatable {
    case idle
    case loadingModel   // Whisper model loading into memory (first use after launch)
    case recording
    case transcribing
    case cleaning       // Smart cleanup (local LLM) or prompt enhancement (cloud)
    case error(String)
}
