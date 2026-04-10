import Foundation

/// Calls AWS Bedrock Converse API with Claude Haiku to enhance transcribed speech into
/// a clear, actionable prompt. Requires a bearer token for authentication.
final class CloudPromptEnhancer: Sendable {

    /// Bedrock cross-region inference profile for Claude Haiku.
    /// On-demand throughput requires an inference profile ID, not the raw model ID.
    private static let modelId = "us.anthropic.claude-haiku-4-5-20251001-v1:0"

    /// System prompt that guides Haiku to enhance while staying faithful to intent.
    static let systemPrompt = """
        You are a prompt enhancement engine. Your job is to take rough speech-to-text input \
        and sharpen it into a clear, well-structured instruction — while staying faithful \
        to the speaker's original intent.

        Rules:
        - Stay close to the original meaning — enhance clarity, do not change the task
        - Remove filler words, hesitation, and vague hedging
        - Make implicit expectations explicit (e.g. "do a review" → "review and identify issues")
        - Add reasonable scope qualifiers when the speaker's intent is obvious \
        (e.g. "improve performance" → "identify performance improvement opportunities")
        - Preserve ALL technical details exactly (file names, function names, error messages, paths)
        - Keep it concise — one focused instruction, not a paragraph
        - Do NOT invent requirements the speaker did not mention
        - Do NOT add commentary, explanation, or preamble
        - Output ONLY the enhanced prompt, nothing else

        Example:
        Input: "please do a review of this repo and improve the performance"
        Output: "Review the repository and identify simple performance improvement opportunities. \
        Focus on obvious inefficiencies and provide concise, actionable suggestions."
        """

    /// Enhance a transcribed text into a clear prompt using Bedrock Haiku.
    /// - Parameters:
    ///   - text: Raw transcription from Whisper.
    ///   - bearerToken: AWS Bedrock bearer token.
    ///   - region: AWS region (e.g. "us-east-1").
    /// - Returns: The enhanced prompt string.
    func enhance(_ text: String, bearerToken: String, region: String) async throws -> String {
        guard !bearerToken.isEmpty else {
            throw EnhancerError.missingBearerToken
        }

        let endpoint = URL(
            string: "https://bedrock-runtime.\(region).amazonaws.com/model/\(Self.modelId)/converse"
        )!

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let body: [String: Any] = [
            "system": [
                ["text": Self.systemPrompt]
            ],
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["text": "Enhance this into a clear prompt:\n\(text)"]
                    ]
                ]
            ],
            "inferenceConfig": [
                "maxTokens": 512,
                "temperature": 0.3
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw EnhancerError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw EnhancerError.bedrockError(statusCode: httpResponse.statusCode, message: body)
        }

        return try parseResponse(data)
    }

    /// Parse the Bedrock Converse API response to extract the assistant's text.
    private func parseResponse(_ data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = json["output"] as? [String: Any],
              let message = output["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]],
              let firstBlock = content.first,
              let text = firstBlock["text"] as? String else {
            throw EnhancerError.invalidResponse
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum EnhancerError: Error, LocalizedError {
    case missingBearerToken
    case invalidResponse
    case bedrockError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .missingBearerToken:
            return "Bearer token not configured. Add it in Settings."
        case .invalidResponse:
            return "Invalid response from Bedrock"
        case .bedrockError(let code, let message):
            let truncated = message.prefix(200)
            return "Bedrock error \(code): \(truncated)"
        }
    }
}
