import Foundation

/// State machine for the on-device speech pipeline.
/// Used by OnDeviceSpeechEngine and observed by the UI.
enum SpeechEngineState: Equatable {
    case idle
    case recording
    case transcribing
    case cleaning
    case error(String)
}
