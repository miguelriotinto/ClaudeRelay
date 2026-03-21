import SwiftUI

/// A horizontal scrollable bar of special keys for terminal interaction.
struct KeyboardAccessory: View {
    /// Callback invoked with the byte sequence to send when a key is tapped.
    var onKey: (Data) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(keys, id: \.label) { key in
                    Button {
                        onKey(key.data)
                    } label: {
                        Text(key.label)
                            .font(.system(.callout, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 44)
        .background(Color(.systemBackground))
    }

    // MARK: - Key Definitions

    private struct SpecialKey {
        let label: String
        let data: Data
    }

    private var keys: [SpecialKey] {
        [
            // Ctrl sends a zero byte (Ctrl-@); the terminal view can interpret
            // a "Ctrl pressed" state. Here we send the common Ctrl-C as an example.
            // In practice, the Ctrl key would act as a modifier.
            SpecialKey(label: "Ctrl", data: Data()),
            SpecialKey(label: "Tab", data: Data([0x09])),
            SpecialKey(label: "Esc", data: Data([0x1B])),
            SpecialKey(label: "\u{2191}", data: Data([0x1B, 0x5B, 0x41])),  // Up arrow: ESC [ A
            SpecialKey(label: "\u{2193}", data: Data([0x1B, 0x5B, 0x42])),  // Down arrow: ESC [ B
            SpecialKey(label: "\u{2190}", data: Data([0x1B, 0x5B, 0x44])),  // Left arrow: ESC [ D
            SpecialKey(label: "\u{2192}", data: Data([0x1B, 0x5B, 0x43])),  // Right arrow: ESC [ C
            SpecialKey(label: "|", data: Data([0x7C])),
            SpecialKey(label: "/", data: Data([0x2F])),
            SpecialKey(label: "~", data: Data([0x7E])),
        ]
    }
}

#Preview {
    KeyboardAccessory { data in
        print("Key pressed: \(data as NSData)")
    }
}
