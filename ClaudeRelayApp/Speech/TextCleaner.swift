import Foundation
import LLM

/// Protocol for text cleanup — enables mock injection in tests.
protocol TextCleaning: Sendable {
    func clean(_ text: String, promptImprovement: Bool) async throws -> String
}

/// Runs a local Qwen 3.5 0.8B GGUF model via llama.cpp (Metal GPU) to clean transcriptions.
final class TextCleaner: TextCleaning, @unchecked Sendable {

    private var llm: LLM?
    private var unloadTimer: Task<Void, Never>?
    private(set) var isLoaded = false

    /// Idle timeout before unloading the model to free memory.
    static let idleTimeout: TimeInterval = 30

    /// Path to the GGUF model file. Set by OnDeviceSpeechEngine after download.
    var modelPath: URL?

    /// Load a GGUF model from disk.
    func loadModel(from path: URL) throws {
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw CleanerError.modelFileNotFound
        }

        // LLM.init?(from: URL, ...) is failable and synchronous
        guard let model = LLM(from: path, maxTokenCount: 2048) else {
            throw CleanerError.modelNotLoaded
        }

        // Use Qwen template for proper chat formatting with thinking support
        model.useResolvedTemplate(
            systemPrompt: Self.fillerCleanupSystemPrompt
        )

        self.llm = model
        self.isLoaded = true
    }

    /// Clean transcribed text using the on-device LLM.
    /// When `promptImprovement` is true, rewrites as a clear Claude Code prompt.
    /// When false, removes filler words and fixes punctuation.
    /// Auto-loads the model on first call if a modelPath was set.
    func clean(_ text: String, promptImprovement: Bool = false) async throws -> String {
        // Auto-load on first use (on-demand loading per spec)
        if llm == nil, let path = modelPath {
            try loadModel(from: path)
        }

        guard let llm else {
            throw CleanerError.modelNotLoaded
        }

        // Switch system prompt based on mode
        let systemPrompt = promptImprovement ? Self.promptImprovementSystemPrompt : Self.fillerCleanupSystemPrompt
        llm.useResolvedTemplate(systemPrompt: systemPrompt)

        resetIdleTimer()

        let prompt = Self.buildCleanupPrompt(for: text, promptImprovement: promptImprovement)

        // getCompletion returns the full generated text as a String
        let response = await llm.getCompletion(from: prompt)

        let cleaned = Self.sanitizeResponse(response)
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

    /// Start or restart the idle timer. Unloads model after `idleTimeout` seconds.
    private func resetIdleTimer() {
        unloadTimer?.cancel()
        unloadTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.idleTimeout))
            guard !Task.isCancelled else { return }
            self?.unload()
        }
    }

    /// System prompt for filler cleanup mode (default).
    static let fillerCleanupSystemPrompt = """
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

    /// System prompt for prompt improvement mode.
    static let promptImprovementSystemPrompt = """
        You are a prompt optimization engine. Your ONLY job is to rewrite speech-to-text \
        input into a clear, effective instruction for Claude Code (an AI coding assistant).

        Rules:
        - Rewrite as a direct, specific instruction
        - Remove filler words and hedging
        - Make the intent explicit and actionable
        - Preserve all technical details (file names, function names, error messages)
        - Keep it concise — one clear instruction, not a paragraph
        - Do NOT add information the speaker didn't mention
        - Do NOT add commentary, explanation, or preamble
        - Output ONLY the rewritten prompt, nothing else
        """

    /// Build the user prompt based on mode.
    static func buildCleanupPrompt(for text: String, promptImprovement: Bool = false) -> String {
        if promptImprovement {
            return "Rewrite this as a clear Claude Code prompt:\n\(text)"
        }
        return "Clean this transcription:\n\(text)"
    }

    /// Strip any <think> reasoning blocks or markdown artifacts from LLM output.
    static func sanitizeResponse(_ response: String) -> String {
        var result = response

        // Strip <think>...</think> blocks (Qwen 3.5 thinking mode)
        while let thinkStart = result.range(of: "<think>"),
              let thinkEnd = result.range(of: "</think>") {
            result.removeSubrange(thinkStart.lowerBound..<thinkEnd.upperBound)
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
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
