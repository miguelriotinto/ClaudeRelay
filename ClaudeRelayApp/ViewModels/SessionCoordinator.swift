import Foundation
import ClaudeRelayClient
import ClaudeRelayKit

@MainActor
final class SessionCoordinator: SharedSessionCoordinator {

    override class var keyPrefix: String { "com.clauderelay" }

    override func sessionNamingTheme() -> SessionNamingTheme {
        AppSettings.shared.sessionNamingTheme
    }
}
