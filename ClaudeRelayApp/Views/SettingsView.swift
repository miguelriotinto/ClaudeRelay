import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var showTokenRequired = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Smart Cleanup", isOn: $settings.smartCleanupEnabled)
                    Toggle("Prompt Enhancement", isOn: $settings.promptEnhancementEnabled)
                } header: {
                    Text("Speech to Text")
                } footer: {
                    Text(speechFooterText)
                }

                if settings.promptEnhancementEnabled {
                    Section {
                        SecureField("Bearer Token", text: $settings.bedrockBearerToken)
                            .textContentType(.password)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        TextField("Region", text: $settings.bedrockRegion)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    } header: {
                        Text("AWS Bedrock")
                    } footer: {
                        Text("Prompt Enhancement uses Claude Haiku on AWS Bedrock. Paste your bearer token to enable cloud-based prompt rewriting.")
                    }
                }

                Section("General") {
                    Toggle("Haptic Feedback", isOn: $settings.hapticFeedbackEnabled)
                    Picker("Session Names", selection: $settings.sessionNamingTheme) {
                        ForEach(SessionNamingTheme.allCases) { theme in
                            Text(theme.displayName).tag(theme)
                        }
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Build", value: buildNumber)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { handleDone() }
                }
            }
            .alert("Bearer Key is Required", isPresented: $showTokenRequired) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Prompt Enhancement requires an AWS Bedrock bearer token. Please paste your token or disable Prompt Enhancement.")
            }
        }
    }

    private func handleDone() {
        if settings.promptEnhancementEnabled && settings.bedrockBearerToken.trimmingCharacters(in: .whitespaces).isEmpty {
            showTokenRequired = true
        } else {
            dismiss()
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

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–"
    }
}
