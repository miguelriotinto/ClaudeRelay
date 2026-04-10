import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("promptImprovementEnabled") var promptImprovementEnabled = false
}
