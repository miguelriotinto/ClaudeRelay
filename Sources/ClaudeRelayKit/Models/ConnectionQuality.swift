import Foundation

public enum ConnectionQuality: String, Sendable, Equatable {
    case excellent
    case good
    case poor
    case veryPoor
    case disconnected

    public init(medianRTT: TimeInterval, successRate: Double) {
        if successRate < 0.5 {
            self = .veryPoor
        } else if medianRTT < 0.1 && successRate >= 1.0 {
            self = .excellent
        } else if medianRTT < 0.3 && successRate >= 0.83 {
            self = .good
        } else if medianRTT < 0.8 && successRate >= 0.5 {
            self = .poor
        } else {
            self = .veryPoor
        }
    }
}
