import Foundation

/// All runtime-configurable options that control how a transcript is processed
/// and how the continuous pipeline behaves. Pushed from the UI into both
/// engines; captured at the moment work kicks off so mid-session setting
/// changes take effect on the next utterance.
public struct SpeechProcessingOptions: Equatable, Sendable {
    public var smartCleanupEnabled: Bool
    public var promptEnhancementEnabled: Bool
    public var bedrockBearerToken: String
    public var bedrockRegion: String
    public var wakeWord: String
    public var turnEndSilenceTimeout: TimeInterval

    public init(
        smartCleanupEnabled: Bool = true,
        promptEnhancementEnabled: Bool = false,
        bedrockBearerToken: String = "",
        bedrockRegion: String = "us-east-1",
        wakeWord: String = "claude",
        turnEndSilenceTimeout: TimeInterval = 1.5
    ) {
        self.smartCleanupEnabled = smartCleanupEnabled
        self.promptEnhancementEnabled = promptEnhancementEnabled
        self.bedrockBearerToken = bedrockBearerToken
        self.bedrockRegion = bedrockRegion
        self.wakeWord = wakeWord
        self.turnEndSilenceTimeout = turnEndSilenceTimeout
    }
}
