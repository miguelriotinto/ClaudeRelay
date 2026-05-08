import Foundation
@testable import ClaudeRelaySpeech

final class MockVAD: VoiceActivityDetecting, @unchecked Sendable {
    var eventsToReturn: [VADEvent] = []
    var processedChunks = 0
    var resetCallCount = 0

    func process(chunk: [Float]) -> VADEvent {
        processedChunks += 1
        guard !eventsToReturn.isEmpty else { return .silenceContinue }
        return eventsToReturn.removeFirst()
    }

    func reset() { resetCallCount += 1 }
}

final class MockTurnEndDetector: TurnEndDetecting, @unchecked Sendable {
    var resultToReturn: TurnEndResult = .speakerDone(confidence: 1.0)
    var predictCallCount = 0

    func predict(utteranceAudio: [Float]) async -> TurnEndResult {
        predictCallCount += 1
        return resultToReturn
    }
}

final class StubSpeechTranscriber: SpeechTranscribing, @unchecked Sendable {
    var result: String = ""
    var shouldThrow = false
    var callCount = 0

    func transcribe(_ audioBuffer: [Float]) async throws -> String {
        callCount += 1
        if shouldThrow { throw TranscriberError.emptyTranscription }
        return result
    }
}

final class StubTextCleaner: TextCleaning, @unchecked Sendable {
    var result: String?
    var callCount = 0

    func clean(_ text: String) async throws -> String {
        callCount += 1
        return result ?? text
    }
}

final class NoopAudioSource: StreamingAudioSourcing, @unchecked Sendable {
    var onChunk: (@Sendable ([Float]) -> Void)?
    var startCallCount = 0
    var stopCallCount = 0

    func start() throws { startCallCount += 1 }
    func stop() { stopCallCount += 1 }
}
