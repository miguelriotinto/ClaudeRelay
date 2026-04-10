import Foundation
import LLM

/// Protocol for local text cleanup — enables mock injection in tests.
protocol TextCleaning: Sendable {
    func clean(_ text: String) async throws -> String
}

/// Runs a local Qwen 3.5 0.8B GGUF model via llama.cpp (Metal GPU) to clean transcriptions.
/// Only handles filler word removal and punctuation fixes — prompt enhancement is cloud-based.
final class TextCleaner: TextCleaning, @unchecked Sendable {

    private var llm: LLM?
    private var unloadTimer: Task<Void, Never>?
    private(set) var isLoaded = false

    /// Idle timeout before unloading the model to free memory.
    static let idleTimeout: TimeInterval = 30

    /// Minimum word count worth sending through the LLM.
    static let minimumWordCount = 3

    /// Path to the GGUF model file. Set by OnDeviceSpeechEngine after download.
    var modelPath: URL?

    /// Load a GGUF model from disk.
    func loadModel(from path: URL) throws {
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw CleanerError.modelFileNotFound
        }

        guard let model = LLM(from: path, maxTokenCount: 2048) else {
            throw CleanerError.modelNotLoaded
        }

        model.useResolvedTemplate(
            systemPrompt: Self.systemPrompt
        )

        self.llm = model
        self.isLoaded = true
    }

    /// Remove filler words and fix punctuation using the on-device LLM.
    func clean(_ text: String) async throws -> String {
        let wordCount = text.split(separator: " ").count

        // Short inputs don't benefit from LLM processing
        if wordCount < Self.minimumWordCount {
            return text
        }

        // Auto-load on first use
        if llm == nil, let path = modelPath {
            try loadModel(from: path)
        }

        guard let llm else {
            throw CleanerError.modelNotLoaded
        }

        llm.useResolvedTemplate(systemPrompt: Self.systemPrompt)
        resetIdleTimer()

        let prompt = "Clean this transcription:\n\(text)"
        let response = await llm.getCompletion(from: prompt)
        let cleaned = Self.sanitizeResponse(response)

        if Self.looksHallucinated(input: text, output: cleaned) {
            return text
        }

        return cleaned.isEmpty ? text : cleaned
    }

    /// Release the model from memory.
    func unload() {
        unloadTimer?.cancel()
        unloadTimer = nil
        llm = nil
        isLoaded = false
    }

    // MARK: - Private

    private func resetIdleTimer() {
        unloadTimer?.cancel()
        unloadTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.idleTimeout))
            guard !Task.isCancelled else { return }
            self?.unload()
        }
    }

    static let systemPrompt = """
        You are a transcription cleanup engine. You are NOT a chatbot. You are NOT an assistant. \
        Your ONLY job is to clean up speech-to-text output.

        Rules:
        - Remove filler words (um, uh, like, you know, so, basically, actually, literally)
        - Fix punctuation and capitalization
        - Correct obvious misheard words based on context
        - Preserve the speaker's meaning and tone exactly
        - Do NOT add, rephrase, or summarize content
        - Do NOT add any commentary, explanation, or preamble
        - Output ONLY the cleaned text, nothing else
        """

    /// Strip any <think> reasoning blocks from LLM output.
    static func sanitizeResponse(_ response: String) -> String {
        var result = response

        while let thinkStart = result.range(of: "<think>"),
              let thinkEnd = result.range(of: "</think>") {
            result.removeSubrange(thinkStart.lowerBound..<thinkEnd.upperBound)
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Detect likely hallucinated output from the LLM.
    static func looksHallucinated(input: String, output: String) -> Bool {
        if output.count > input.count * 3, output.count > 100 {
            return true
        }
        if output.contains("```") { return true }
        if output.contains("<div") || output.contains("<script") || output.contains("<html") {
            return true
        }
        return false
    }
}

enum CleanerError: Error, LocalizedError {
    case modelNotLoaded
    case modelFileNotFound

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "Cleanup model not loaded"
        case .modelFileNotFound: return "Cleanup model file not found on disk"
        }
    }
}
