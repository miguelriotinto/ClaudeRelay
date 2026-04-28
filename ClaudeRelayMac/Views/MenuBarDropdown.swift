import SwiftUI

struct MenuBarDropdown: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude Relay")
                .font(.headline)
            Divider()
            Button("Open Window") {
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 240)
    }
}
