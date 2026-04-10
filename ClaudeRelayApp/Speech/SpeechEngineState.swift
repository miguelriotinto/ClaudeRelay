import Foundation

/// Pipeline states for the on-device speech engine.
/// UI observes this to drive mic button color and haptics.
enum SpeechEngineState: Equatable {
    case idle
    case recording
    case transcribing
    case cleaning
    case error(String)
}
