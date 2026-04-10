import Foundation
import LLM

/// Protocol for text cleanup — enables mock injection in tests.
protocol TextCleaning: Sendable {
    func clean(_ text: String, smartCleanup: Bool, promptEnhancement: Bool) async throws -> String
}

/// Runs a local Gemma 2 2B IT GGUF model via llama.cpp (Metal GPU) to clean transcriptions.
final class TextCleaner: TextCleaning, @unchecked Sendable {

    private var llm: LLM?
    private var unloadTimer: Task<Void, Never>?
    private(set) var isLoaded = false

    /// Idle timeout before unloading the model to free memory.
    static let idleTimeout: TimeInterval = 30

    /// Path to the GGUF model file. Set by OnDeviceSpeechEngine after download.
    var modelPath: URL?

    /// Minimum word count worth sending through the LLM.
    /// Shorter inputs are returned as-is to avoid hallucination.
    static let minimumWordCount = 3

    /// Load a GGUF model from disk.
    func loadModel(from path: URL) throws {
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw CleanerError.modelFileNotFound
        }

        guard let model = LLM(from: path, maxTokenCount: 2048) else {
            throw CleanerError.modelNotLoaded
        }

        model.useResolvedTemplate(
            systemPrompt: Self.fillerCleanupSystemPrompt
        )

        self.llm = model
        self.isLoaded = true
    }

    /// Process transcribed text based on the user's settings.
    /// - `smartCleanup` ON: remove filler words and fix punctuation via LLM.
    /// - `promptEnhancement` ON: rewrite as a clear Claude Code prompt via LLM (overrides cleanup).
    /// - Both OFF: return raw text untouched.
    func clean(_ text: String, smartCleanup: Bool = true, promptEnhancement: Bool = false) async throws -> String {
        // Neither feature enabled — pass through raw text
        guard smartCleanup || promptEnhancement else {
            return text
        }

        let wordCount = text.split(separator: " ").count

        // Short inputs don't benefit from LLM processing — return as-is
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

        // Prompt enhancement takes priority over cleanup
        let systemPrompt = promptEnhancement ? Self.promptEnhancementSystemPrompt : Self.fillerCleanupSystemPrompt
        llm.useResolvedTemplate(systemPrompt: systemPrompt)

        resetIdleTimer()

        let prompt = Self.buildCleanupPrompt(for: text, promptEnhancement: promptEnhancement)
        let response = await llm.getCompletion(from: prompt)
        let cleaned = Self.sanitizeResponse(response)

        // Hallucination guard: if the output is wildly different, return raw text
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

    /// Start or restart the idle timer. Unloads model after `idleTimeout` seconds.
    private func resetIdleTimer() {
        unloadTimer?.cancel()
        unloadTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.idleTimeout))
            guard !Task.isCancelled else { return }
            self?.unload()
        }
    }

    /// System prompt for filler cleanup mode.
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

    /// System prompt for prompt enhancement mode.
    static let promptEnhancementSystemPrompt = """
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
    static func buildCleanupPrompt(for text: String, promptEnhancement: Bool = false) -> String {
        if promptEnhancement {
            return "Rewrite this as a clear Claude Code prompt:\n\(text)"
        }
        return "Clean this transcription:\n\(text)"
    }

    /// Strip any <think> reasoning blocks or markdown artifacts from LLM output.
    static func sanitizeResponse(_ response: String) -> String {
        var result = response

        // Strip <think>...</think> blocks (thinking mode models)
        while let thinkStart = result.range(of: "<think>"),
              let thinkEnd = result.range(of: "</think>") {
            result.removeSubrange(thinkStart.lowerBound..<thinkEnd.upperBound)
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Detect likely hallucinated output from the LLM.
    /// Returns true if the output is suspiciously different from the input.
    static func looksHallucinated(input: String, output: String) -> Bool {
        // Output vastly longer than input — model is fabricating
        if output.count > input.count * 3, output.count > 100 {
            return true
        }

        // Contains code fences — model generated code instead of cleaning text
        if output.contains("```") {
            return true
        }

        // Contains HTML tags — model generated markup
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
