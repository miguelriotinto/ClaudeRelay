import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Smart Cleanup", isOn: $settings.smartCleanupEnabled)
                    Toggle("Prompt Enhancement", isOn: $settings.promptEnhancementEnabled)
                } header: {
                    Text("Speech to Text")
                } footer: {
                    Text(footerText)
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
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var footerText: String {
        if settings.promptEnhancementEnabled {
            return "Transcribed speech is rewritten as a clear, optimized prompt for Claude Code using the on-device LLM."
        } else if settings.smartCleanupEnabled {
            return "Filler words are removed and punctuation is fixed before pasting into the terminal."
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
