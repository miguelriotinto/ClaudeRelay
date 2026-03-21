import SwiftUI
import CodeRelayClient

/// Full-screen terminal view with status overlay and keyboard accessory.
///
/// This uses a placeholder for the actual terminal rendering. When the user opens
/// the project in Xcode and adds the SwiftTerm SPM package, the
/// `TerminalPlaceholder` can be replaced with a real `SwiftTermView` wrapped in
/// a `UIViewRepresentable`.
struct TerminalContainerView: View {
    @StateObject private var viewModel: TerminalViewModel

    init(connection: RelayConnection, sessionId: UUID) {
        _viewModel = StateObject(wrappedValue: TerminalViewModel(
            connection: connection,
            sessionId: sessionId
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Terminal area
            TerminalPlaceholder(output: viewModel.terminalOutput)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) {
                    StatusIndicator(state: viewModel.connectionState)
                        .padding(8)
                }

            // Keyboard accessory bar
            KeyboardAccessory { data in
                viewModel.sendInput(data)
            }
        }
        .navigationTitle("Terminal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Disconnect") {
                    viewModel.disconnect()
                }
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }
}

// MARK: - Terminal Placeholder

/// A placeholder UIViewRepresentable that displays terminal output as text.
/// Replace this with a SwiftTerm-backed view once the package is added in Xcode.
struct TerminalPlaceholder: UIViewRepresentable {
    let output: String

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.backgroundColor = .black
        textView.textColor = .green
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.text = output.isEmpty
            ? "Terminal View - Connect SwiftTerm here\n\nWaiting for output..."
            : output
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        textView.text = output.isEmpty
            ? "Terminal View - Connect SwiftTerm here\n\nWaiting for output..."
            : output
        // Auto-scroll to bottom on new output.
        if !output.isEmpty {
            let bottom = NSRange(location: textView.text.count - 1, length: 1)
            textView.scrollRangeToVisible(bottom)
        }
    }
}
