import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("smartCleanupEnabled") var smartCleanupEnabled = true
    @AppStorage("promptEnhancementEnabled") var promptEnhancementEnabled = false
    @AppStorage("bedrockBearerToken") var bedrockBearerToken = ""
    @AppStorage("bedrockRegion") var bedrockRegion = "us-east-1"
    @AppStorage("hapticFeedbackEnabled") var hapticFeedbackEnabled = true
}
