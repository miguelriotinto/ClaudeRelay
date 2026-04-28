import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Text("General settings (Phase 3)")
                .tabItem { Label("General", systemImage: "gear") }
        }
    }
}
