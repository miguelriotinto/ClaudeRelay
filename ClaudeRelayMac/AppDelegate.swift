import AppKit
import SwiftUI
import ClaudeRelayClient

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var sleepWakeObserver: SleepWakeObserver?
    private var networkMonitor: NetworkMonitor?
    private var windowObserver: Any?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
                break
            }
        }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        sleepWakeObserver = SleepWakeObserver()
        networkMonitor = NetworkMonitor()

        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow else { return }
            window.titlebarAppearsTransparent = true
            window.backgroundColor = .black
        }

        Task { @MainActor in
            for window in NSApp.windows where window.canBecomeMain {
                window.titlebarAppearsTransparent = true
                window.backgroundColor = .black
                if !AppSettings.shared.showWindowOnLaunch {
                    window.close()
                }
            }
        }
    }
}
