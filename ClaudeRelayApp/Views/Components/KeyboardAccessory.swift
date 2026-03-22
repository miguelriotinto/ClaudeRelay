import SwiftUI

/// A horizontal scrollable bar of special keys for terminal interaction.
struct KeyboardAccessory: View {
    var onKey: (Data) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                // Modifier keys
                keyButton("esc", icon: "escape") { send(0x1B) }
                keyButton("ctrl", icon: "control") { send(0x00) } // Ctrl modifier placeholder
                keyButton("opt", icon: "option") { send(0x00) }
                keyButton("cmd", icon: "command") { send(0x00) }
                keyButton("tab", icon: "arrow.right.to.line") { send(0x09) }

                Divider().frame(height: 24)

                // Ctrl combos
                ctrlComboButton("C", byte: 0x03)   // Ctrl-C (SIGINT)
                ctrlComboButton("R", byte: 0x12)   // Ctrl-R (reverse search)
                ctrlComboButton("A", byte: 0x01)   // Ctrl-A (beginning of line)
                ctrlComboButton("E", byte: 0x05)   // Ctrl-E (end of line)
                ctrlComboButton("D", byte: 0x04)   // Ctrl-D (EOF)
                ctrlComboButton("Z", byte: 0x1A)   // Ctrl-Z (suspend)
                ctrlComboButton("L", byte: 0x0C)   // Ctrl-L (clear)

                Divider().frame(height: 24)

                // Arrow keys
                keyButton(nil, icon: "arrow.up") { send(0x1B, 0x5B, 0x41) }
                keyButton(nil, icon: "arrow.down") { send(0x1B, 0x5B, 0x42) }
                keyButton(nil, icon: "arrow.left") { send(0x1B, 0x5B, 0x44) }
                keyButton(nil, icon: "arrow.right") { send(0x1B, 0x5B, 0x43) }

                Divider().frame(height: 24)

                // Common characters
                charButton("|")
                charButton("/")
                charButton("~")
                charButton("-")
                charButton("_")
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 40)
        .background(Color(.secondarySystemBackground))
    }

    // MARK: - Button builders

    private func keyButton(_ label: String?, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                if let label {
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(.tertiarySystemBackground))
            .cornerRadius(5)
        }
        .buttonStyle(.plain)
    }

    private func ctrlComboButton(_ letter: String, byte: UInt8) -> some View {
        Button { onKey(Data([byte])) } label: {
            HStack(spacing: 1) {
                Image(systemName: "control")
                    .font(.system(size: 10))
                Text(letter)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(Color(.tertiarySystemBackground))
            .cornerRadius(5)
        }
        .buttonStyle(.plain)
    }

    private func charButton(_ char: String) -> some View {
        Button { onKey(Data(char.utf8)) } label: {
            Text(char)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(minWidth: 28)
                .padding(.vertical, 5)
                .background(Color(.tertiarySystemBackground))
                .cornerRadius(5)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func send(_ bytes: UInt8...) {
        onKey(Data(bytes))
    }
}

#Preview {
    KeyboardAccessory { data in
        print("Key: \(data as NSData)")
    }
}
