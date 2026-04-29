import SwiftUI
import ClaudeRelayClient
import ClaudeRelaySpeech

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
    @State private var isCapturing = false
    @State private var capturedModifiers: NSEvent.ModifierFlags = []
    @State private var capturedKey: String = ""

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Session naming theme", selection: $settings.sessionNamingTheme) {
                    ForEach(SessionNamingTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
            }
            Section("Recording Shortcut") {
                Toggle("Enable shortcut", isOn: $settings.recordingShortcutEnabled)
                if settings.recordingShortcutEnabled {
                    if isCapturing {
                        VStack(spacing: 8) {
                            Text("Press your shortcut...")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(capturedModifiers.isEmpty && capturedKey.isEmpty
                                 ? "Waiting..."
                                 : capturedModifiers.symbolString + capturedKey.uppercased())
                                .font(.system(.title, design: .rounded, weight: .medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 8))
                            KeyCaptureView(
                                capturedModifiers: $capturedModifiers,
                                capturedKey: $capturedKey,
                                isCapturing: $isCapturing,
                                onCommit: { modifiers, key in
                                    settings.shortcutModifierFlags = modifiers
                                    settings.recordingShortcutKey = key
                                }
                            )
                            .frame(width: 0, height: 0)
                            Button("Cancel") {
                                isCapturing = false
                            }
                            .font(.subheadline)
                        }
                        .padding(.vertical, 4)
                    } else {
                        HStack {
                            Text("Key Combination")
                            Spacer()
                            Text(settings.shortcutDisplayString.isEmpty ? "None" : settings.shortcutDisplayString)
                                .foregroundStyle(.secondary)
                            Button("Change") {
                                capturedModifiers = []
                                capturedKey = ""
                                isCapturing = true
                            }
                        }
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
    @StateObject private var settings = AppSettings.shared
    @StateObject private var store = SpeechModelStore.shared

    var body: some View {
        Form {
            Section("Models") {
                if store.modelsReady {
                    Label("Models downloaded", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("Delete Models") {
                        store.deleteModels()
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Speech models need to be downloaded before first use (~1 GB).")
                            .foregroundStyle(.secondary)
                        Button(store.downloadProgress == nil ? "Download Models" : "Downloading...") {
                            Task { try? await store.downloadAllModels() }
                        }
                        .disabled(store.downloadProgress != nil)
                        if let progress = store.downloadProgress {
                            ProgressView(value: progress)
                        }
                    }
                }
            }
            Section("Transcription") {
                Toggle("Smart cleanup (local LLM)", isOn: $settings.smartCleanupEnabled)
                Toggle("Prompt enhancement (Bedrock Haiku)", isOn: $settings.promptEnhancementEnabled)
                if settings.promptEnhancementEnabled {
                    SecureField("Bedrock Bearer Token", text: $settings.bedrockBearerToken)
                        .textContentType(.password)
                    TextField("AWS Region", text: $settings.bedrockRegion)
                }
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
