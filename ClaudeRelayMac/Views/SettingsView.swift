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

            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 500)
        .background(.black)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Settings Section Helpers

private struct SettingsSectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.top, 12)
    }
}

private struct SettingsSectionFooter: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)
    }
}

private struct SettingsRow<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        HStack {
            content
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct SettingsGroup<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct SettingsGroupRow<Content: View>: View {
    var showDivider: Bool = true
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                content
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if showDivider {
                Divider().padding(.leading, 12)
            }
        }
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @StateObject private var settings = AppSettings.shared
    @State private var isCapturing = false
    @State private var capturedModifiers: NSEvent.ModifierFlags = []
    @State private var capturedKey: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionHeader(title: "Appearance")
                SettingsGroup {
                    SettingsGroupRow(showDivider: false) {
                        Text("Session naming theme")
                        Spacer()
                        Picker("", selection: $settings.sessionNamingTheme) {
                            ForEach(SessionNamingTheme.allCases) { theme in
                                Text(theme.displayName).tag(theme)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }

                SettingsSectionHeader(title: "Recording Shortcut")
                SettingsGroup {
                    SettingsGroupRow {
                        Text("Enable shortcut")
                        Spacer()
                        Toggle("", isOn: $settings.recordingShortcutEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    if settings.recordingShortcutEnabled {
                        if isCapturing {
                            SettingsGroupRow(showDivider: false) {
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
                            }
                        } else {
                            SettingsGroupRow(showDivider: false) {
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
                if settings.recordingShortcutEnabled && !isCapturing {
                    if settings.recordingShortcutKey.isEmpty {
                        SettingsSectionFooter(text: "Click Change and press a modifier + letter combination (e.g. ⌘⌥R).")
                    } else {
                        SettingsSectionFooter(text: "Press \(settings.shortcutDisplayString) to toggle speech recording.")
                    }
                }

                SettingsSectionHeader(title: "Launch")
                SettingsGroup {
                    SettingsGroupRow {
                        Text("Auto connect on launch")
                        Spacer()
                        Toggle("", isOn: $settings.autoConnectEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    SettingsGroupRow {
                        Text("Show window on launch")
                        Spacer()
                        Toggle("", isOn: $settings.showWindowOnLaunch)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    SettingsGroupRow(showDivider: false) {
                        Text("Launch at login")
                        Spacer()
                        Toggle("", isOn: Binding(
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
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                }
                SettingsSectionFooter(text: "Automatically reconnect to the last server on launch.")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .background(.black)
    }
}

// MARK: - Speech

private struct SpeechSettingsTab: View {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var store = SpeechModelStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionHeader(title: "Models")
                SettingsGroup {
                    if store.modelsReady {
                        SettingsGroupRow {
                            Label("Models downloaded", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Spacer()
                        }
                        SettingsGroupRow(showDivider: false) {
                            Button("Delete Models") {
                                store.deleteModels()
                            }
                            Spacer()
                        }
                    } else {
                        SettingsGroupRow(showDivider: false) {
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
                            Spacer()
                        }
                    }
                }

                SettingsSectionHeader(title: "Speech to Text")
                SettingsGroup {
                    SettingsGroupRow {
                        Text("Smart cleanup (local LLM)")
                        Spacer()
                        Toggle("", isOn: $settings.smartCleanupEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    SettingsGroupRow(showDivider: false) {
                        Text("Prompt enhancement (Bedrock Haiku)")
                        Spacer()
                        Toggle("", isOn: $settings.promptEnhancementEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
                SettingsSectionFooter(text: speechFooterText)

                if settings.promptEnhancementEnabled {
                    SettingsSectionHeader(title: "AWS Bedrock")
                    SettingsGroup {
                        SettingsGroupRow {
                            Text("Bearer Token")
                            Spacer()
                            SecureField("", text: $settings.bedrockBearerToken)
                                .textContentType(.password)
                                .frame(maxWidth: 250)
                        }
                        SettingsGroupRow(showDivider: false) {
                            Text("Region")
                            Spacer()
                            TextField("", text: $settings.bedrockRegion)
                                .frame(maxWidth: 250)
                        }
                    }
                    SettingsSectionFooter(text: "Prompt Enhancement uses Claude Haiku on AWS Bedrock. Paste your bearer token to enable cloud-based prompt rewriting.")
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .background(.black)
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

// MARK: - About

private struct AboutSettingsTab: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionHeader(title: "ClaudeDock")
                SettingsGroup {
                    SettingsGroupRow {
                        Text("Version")
                        Spacer()
                        Text(appVersion).foregroundStyle(.secondary)
                    }
                    SettingsGroupRow(showDivider: false) {
                        Text("Build")
                        Spacer()
                        Text(buildNumber).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .background(.black)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–"
    }
}
