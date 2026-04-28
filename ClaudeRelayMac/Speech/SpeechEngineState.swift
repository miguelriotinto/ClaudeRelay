import Foundation

/// Pipeline states for the on-device speech engine.
/// UI observes this to drive mic button color and indicators.
///
/// Mirrors the iOS `SpeechEngineState` so the `OnDeviceSpeechEngine`
/// orchestrator can be ported verbatim.
enum SpeechEngineState: Equatable {
    case idle
    case loadingModel   // Whisper model loading into memory (first use after launch)
    case recording
    case transcribing
    case cleaning       // Smart cleanup (local LLM) or prompt enhancement (cloud)
    case error(String)

    var isActive: Bool {
        switch self {
        case .idle, .error: return false
        default: return true
        }
    }

    var description: String {
        switch self {
        case .idle:         return "Idle"
        case .loadingModel: return "Loading model..."
        case .recording:    return "Recording..."
        case .transcribing: return "Transcribing..."
        case .cleaning:     return "Processing..."
        case .error(let msg): return "Error: \(msg)"
        }
    }
}
