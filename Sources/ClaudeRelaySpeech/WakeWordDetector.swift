import Foundation

/// Result of a single wake-word check.
public enum WakeWordResult: Equatable, Sendable {
    /// Wake word was found at the start of the transcription.
    /// `residueText` is the rest of the transcription after the wake word.
    case detected(residueText: String)
    case notDetected
    case transcriptionFailed
}

/// Listens for a wake word (e.g., "Claude") at the start of a spoken phrase.
///
/// Usage:
///   1. Call `feedAudio(_:)` with speech chunks while VAD reports speech.
///   2. When VAD reports silence or max window reached, call `checkForWakeWord()`.
///   3. If `.detected`, transition to recording state.
///   4. If `.notDetected`, call `reset()` before the next speech segment.
@MainActor
public final class WakeWordDetector {

    public let keyword: String
    public let maxListenWindowSeconds: TimeInterval

    private let transcriber: any SpeechTranscribing
    private let sampleRate: Double

    private var accumulator: [Float] = []

    public init(
        transcriber: any SpeechTranscribing,
        keyword: String = "claude",
        maxListenWindowSeconds: TimeInterval = 3.0,
        sampleRate: Double = 16000
    ) {
        self.transcriber = transcriber
        self.keyword = keyword.lowercased()
        self.maxListenWindowSeconds = maxListenWindowSeconds
        self.sampleRate = sampleRate
    }

    /// Append audio samples from the current speech segment.
    /// Automatically trims to the most recent `maxListenWindowSeconds`.
    public func feedAudio(_ samples: [Float]) {
        accumulator.append(contentsOf: samples)
        let maxSamples = Int(maxListenWindowSeconds * sampleRate)
        if accumulator.count > maxSamples {
            accumulator.removeFirst(accumulator.count - maxSamples)
        }
    }

    /// Run transcription and fuzzy-match the wake word at the start.
    public func checkForWakeWord() async -> WakeWordResult {
        guard !accumulator.isEmpty else { return .notDetected }

        let audio = accumulator
        let transcribed: String
        do {
            transcribed = try await transcriber.transcribe(audio)
        } catch {
            return .transcriptionFailed
        }

        return Self.match(transcript: transcribed, keyword: keyword)
    }

    /// Clear accumulated audio — call after .notDetected or after a
    /// successful detection transition.
    public func reset() {
        accumulator.removeAll(keepingCapacity: true)
    }

    // MARK: - Matching

    static func match(transcript: String, keyword: String) -> WakeWordResult {
        let normalized = transcript
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return .notDetected }

        let words = normalized.split(whereSeparator: { !$0.isLetter })
        guard let first = words.first else { return .notDetected }
        let firstWord = String(first)

        let distance = levenshtein(firstWord, keyword)
        let allowed = 1
        guard distance <= allowed else { return .notDetected }

        let residueWords = words.dropFirst().map(String.init)
        let residue = residueWords.joined(separator: " ")
        return .detected(residueText: residue)
    }

    /// Classic Levenshtein edit distance. Exposed for testing.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let n = aChars.count
        let m = bChars.count
        if n == 0 { return m }
        if m == 0 { return n }

        var previous = Array(0...m)
        var current = Array(repeating: 0, count: m + 1)

        for i in 1...n {
            current[0] = i
            for j in 1...m {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,       // deletion
                    current[j - 1] + 1,    // insertion
                    previous[j - 1] + cost // substitution
                )
            }
            swap(&previous, &current)
        }
        return previous[m]
    }
}
