import SwiftUI
import ClaudeRelayClient

struct SettingsView: View {
    @StateObject private var settings = AppSettings.shared

    var body: some View {
        TabView {
            GeneralSettingsTab(settings: settings)
                .tabItem { Label("General", systemImage: "gear") }

            SpeechSettingsTab()
                .tabItem { Label("Speech", systemImage: "mic") }

            ServersSettingsTab()
                .tabItem { Label("Servers", systemImage: "server.rack") }
        }
        .frame(width: 600, height: 420)
    }
}

private struct GeneralSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Session naming theme", selection: $settings.sessionNamingTheme) {
                    ForEach(SessionNamingTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
            }
            Section("Launch") {
                Toggle("Show window on launch", isOn: $settings.showWindowOnLaunch)
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLoginEnabled },
                    set: { newValue in
                        do {
                            try LaunchAtLogin.setEnabled(newValue)
                            settings.launchAtLoginEnabled = newValue
                        } catch {
                            NSLog("[Mac] LaunchAtLogin toggle failed: \(error)")
                        }
                    }
                ))
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct SpeechSettingsTab: View {
    var body: some View {
        Form {
            Section("Speech-to-Text") {
                Text("Speech engine configuration available in Phase 4.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct ServersSettingsTab: View {
    var body: some View {
        ServerListWindow { _ in
            // No connect action from settings — just manage the list.
        }
    }
}
