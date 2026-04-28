import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Keep the app running when the last window closes (menu bar persistence).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// Reopen main window when user clicks the Dock icon while window is hidden.
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
        // Phase 3 will wire sleep/wake observers here.
    }
}
