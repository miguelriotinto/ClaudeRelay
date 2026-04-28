import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var sleepWakeObserver: SleepWakeObserver?
    private var networkMonitor: NetworkMonitor?

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

        Task { @MainActor in
            if !AppSettings.shared.showWindowOnLaunch {
                for window in NSApp.windows where window.canBecomeMain {
                    window.close()
                }
            }
        }
    }
}
