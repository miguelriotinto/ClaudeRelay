import SwiftUI
import SwiftTerm
import ClaudeRelayClient

/// Full-screen terminal view with status overlay and keyboard accessory.
///
/// Uses SwiftTerm's `TerminalView` for real terminal emulation including
/// cursor positioning, colors, and scrollback.
struct TerminalContainerView: View {
    @StateObject private var viewModel: TerminalViewModel

    init(connection: RelayConnection, sessionId: UUID) {
        _viewModel = StateObject(wrappedValue: TerminalViewModel(
            connection: connection,
            sessionId: sessionId
        ))
    }

    var body: some View {
        SwiftTermView(viewModel: viewModel)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                StatusIndicator(state: viewModel.connectionState)
                    .padding(8)
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
        .onDisappear {
            viewModel.detach()
        }
    }
}

// MARK: - SwiftTerm UIViewRepresentable

/// Wraps SwiftTerm's `TerminalView` for use in SwiftUI.
struct SwiftTermView: UIViewRepresentable {
    let viewModel: TerminalViewModel

    func makeUIView(context: Context) -> TerminalView {
        let terminal = TerminalView(frame: .zero)
        terminal.terminalDelegate = context.coordinator

        // Configure appearance
        terminal.nativeBackgroundColor = .black
        terminal.nativeForegroundColor = .white

        // Wire up output from server -> terminal
        viewModel.onTerminalOutput = { data in
            let bytes = ArraySlice([UInt8](data))
            terminal.feed(byteArray: bytes)
        }

        return terminal
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    // MARK: - Coordinator (TerminalViewDelegate)

    class Coordinator: NSObject, TerminalViewDelegate {
        let viewModel: TerminalViewModel

        init(viewModel: TerminalViewModel) {
            self.viewModel = viewModel
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            Task { @MainActor in
                viewModel.sendInput(Data(data))
            }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            Task { @MainActor in
                viewModel.sendResize(cols: UInt16(newCols), rows: UInt16(newRows))
            }
        }

        func scrolled(source: TerminalView, position: Double) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
