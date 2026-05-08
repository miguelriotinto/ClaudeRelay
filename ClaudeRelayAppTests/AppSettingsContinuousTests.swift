import XCTest
@testable import ClaudeRelayApp

@MainActor
final class AppSettingsContinuousTests: XCTestCase {

    func testContinuousListeningDefaultsToFalse() {
        UserDefaults.standard.removeObject(forKey: "continuousListeningEnabled")
        XCTAssertFalse(AppSettings.shared.continuousListeningEnabled)
    }

    func testWakeWordDefaultsToClaude() {
        UserDefaults.standard.removeObject(forKey: "wakeWord")
        XCTAssertEqual(AppSettings.shared.wakeWord, "claude")
    }

    func testTurnEndSilenceTimeoutDefaults() {
        UserDefaults.standard.removeObject(forKey: "turnEndSilenceTimeout")
        XCTAssertEqual(AppSettings.shared.turnEndSilenceTimeout, 1.5, accuracy: 0.01)
    }
}
