import Foundation

enum SpeechEngineState: Equatable {
    case idle
    case loading
    case recording
    case transcribing
    case cleaning
    case enhancing
    case inserting
    case error(String)

    var isActive: Bool {
        switch self {
        case .idle, .error: return false
        default: return true
        }
    }

    var description: String {
        switch self {
        case .idle: return "Idle"
        case .loading: return "Loading model..."
        case .recording: return "Recording..."
        case .transcribing: return "Transcribing..."
        case .cleaning: return "Cleaning..."
        case .enhancing: return "Enhancing..."
        case .inserting: return "Inserting..."
        case .error(let msg): return "Error: \(msg)"
        }
    }
}
