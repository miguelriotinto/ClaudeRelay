import Foundation
import ClaudeRelayClient
import ClaudeRelayKit

/// iOS-specific `SessionCoordinator`. Deliberately thin — the iOS app's
/// workspace-level glue (scenePhase, keyboard, etc.) lives in SwiftUI views,
/// so this subclass only exists to provide a concrete type alongside the
/// macOS variant (`ClaudeRelayMac/ViewModels/SessionCoordinator.swift`),
/// which adds sleep/wake observers and tab navigation hooks.
@MainActor
final class SessionCoordinator: SharedSessionCoordinator {

    override class var keyPrefix: String { "com.clauderelay" }

    override func sessionNamingTheme() -> SessionNamingTheme {
        AppSettings.shared.sessionNamingTheme
    }
}
