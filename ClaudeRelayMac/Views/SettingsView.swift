import SwiftUI
import ClaudeRelayClient
import ClaudeRelaySpeech

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gear") }

            SpeechSettingsTab()
                .tabItem { Label("Speech", systemImage: "mic") }

            ServersSettingsTab()
                .tabItem { Label("Servers", systemImage: "server.rack") }

            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 460)
        .preferredColorScheme(.dark)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @StateObject private var settings = AppSettings.shared
    @State private var isCapturing = false
    @State private var capturedModifiers: NSEvent.ModifierFlags = []
    @State private var capturedKey: String = ""

    var body: some View {
        Form {
            Section {
                Picker("Session naming theme", selection: $settings.sessionNamingTheme) {
                    ForEach(SessionNamingTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
            } header: {
                Text("Appearance")
            }

            Section {
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
                            Button("Cancel") { isCapturing = false }
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
            } header: {
                Text("Recording Shortcut")
            } footer: {
                if settings.recordingShortcutEnabled && !isCapturing {
                    if settings.recordingShortcutKey.isEmpty {
                        Text("Click Change and press a modifier + letter combination (e.g. ⌘⌥R).")
                    } else {
                        Text("Press \(settings.shortcutDisplayString) to toggle speech recording.")
                    }
                }
            }

            Section {
                Toggle("Auto connect on launch", isOn: $settings.autoConnectEnabled)
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
            } header: {
                Text("Launch")
            } footer: {
                Text("Automatically reconnect to the last server on launch.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Speech

private struct SpeechSettingsTab: View {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var store = SpeechModelStore.shared
    @State private var showTokenRequired = false

    var body: some View {
        Form {
            Section {
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
            } header: {
                Text("Models")
            }

            Section {
                Toggle("Smart cleanup (local LLM)", isOn: $settings.smartCleanupEnabled)
                Toggle("Prompt enhancement (Bedrock Haiku)", isOn: $settings.promptEnhancementEnabled)
            } header: {
                Text("Speech to Text")
            } footer: {
                Text(speechFooterText)
            }

            if settings.promptEnhancementEnabled {
                Section {
                    SecureField("Bearer Token", text: $settings.bedrockBearerToken)
                        .textContentType(.password)
                    TextField("Region", text: $settings.bedrockRegion)
                } header: {
                    Text("AWS Bedrock")
                } footer: {
                    Text("Prompt Enhancement uses Claude Haiku on AWS Bedrock. Paste your bearer token to enable cloud-based prompt rewriting.")
                }
            }
        }
        .formStyle(.grouped)
        .alert("Bearer Token Required", isPresented: $showTokenRequired) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Prompt Enhancement requires an AWS Bedrock bearer token. Paste your token or disable Prompt Enhancement.")
        }
    }

    private var speechFooterText: String {
        if settings.promptEnhancementEnabled {
            return "Transcribed speech is sent to Claude Haiku on AWS Bedrock and rewritten as an optimized prompt."
        } else if settings.smartCleanupEnabled {
            return "Filler words are removed and punctuation is fixed locally on-device before pasting into the terminal."
        } else {
            return "Raw transcription is pasted directly into the terminal with no processing."
        }
    }
}

// MARK: - Servers

private struct ServersSettingsTab: View {
    var body: some View {
        ServerListWindow { _ in }
    }
}

// MARK: - About

private struct AboutSettingsTab: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Build", value: buildNumber)
            } header: {
                Text("ClaudeDock")
            }
        }
        .formStyle(.grouped)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–"
    }
}
