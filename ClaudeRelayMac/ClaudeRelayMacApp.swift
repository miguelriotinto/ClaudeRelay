import SwiftUI
import AppKit

@main
struct ClaudeRelayMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("Claude Relay") {
            MainWindow()
                .frame(minWidth: 800, minHeight: 500)
        }
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            AppCommands()
        }

        MenuBarExtra {
            MenuBarDropdown()
        } label: {
            Image(systemName: "terminal")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .frame(width: 600, height: 400)
        }
    }
}
