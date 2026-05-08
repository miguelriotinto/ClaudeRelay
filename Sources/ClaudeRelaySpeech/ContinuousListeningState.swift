import Foundation

/// State machine for the continuous listening pipeline.
/// UI observes this to drive ambient indicators.
public enum ContinuousListeningState: Equatable, Sendable {
    case idle
    case listening              // mic open, waiting for speech
    case detectingWakeWord      // speech heard, checking for "Claude"
    case recording              // wake-word matched, capturing utterance
    case detectingTurnEnd       // checking if speaker is done
    case transcribing           // running WhisperKit on full utterance
    case cleaning               // text cleanup
    case outputting             // delivering to terminal
    case error(String)

    /// True when the engine is doing anything (opposite of idle/error).
    public var isActive: Bool {
        switch self {
        case .idle, .error: return false
        default: return true
        }
    }

    /// True when we are actively accumulating the user's utterance audio.
    public var isCapturing: Bool {
        switch self {
        case .recording, .detectingTurnEnd: return true
        default: return false
        }
    }

    public var description: String {
        switch self {
        case .idle:                 return "Idle"
        case .listening:            return "Listening"
        case .detectingWakeWord:    return "Checking wake word"
        case .recording:            return "Recording"
        case .detectingTurnEnd:     return "Checking turn end"
        case .transcribing:         return "Transcribing"
        case .cleaning:             return "Cleaning"
        case .outputting:           return "Outputting"
        case .error(let msg):       return "Error: \(msg)"
        }
    }
}
