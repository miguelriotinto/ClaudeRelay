import SwiftUI
import SwiftTerm
import ClaudeRelayClient

/// Detail pane: thin toolbar + terminal + optional key bar.
struct ActiveTerminalView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @Binding var columnVisibility: NavigationSplitViewVisibility
    var onDisconnect: () -> Void
    @State private var showKeyBar = false

    var body: some View {
        VStack(spacing: 0) {
            // Thin custom toolbar
            HStack(spacing: 16) {
                HStack(spacing: 12) {
                    Button { onDisconnect() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .medium))
                    }

                    Button {
                        withAnimation {
                            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                        }
                    } label: {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 16))
                    }

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showKeyBar.toggle()
                        }
                    } label: {
                        Image(systemName: showKeyBar ? "keyboard.fill" : "keyboard")
                            .font(.system(size: 16))
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    if let id = coordinator.activeSessionId {
                        Text(coordinator.name(for: id))
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.primary)
                        Text(id.uuidString.prefix(8))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }

                    if let id = coordinator.activeSessionId,
                       let vm = coordinator.viewModel(for: id) {
                        Circle()
                            .fill(statusColor(vm.connectionState))
                            .frame(width: 8, height: 8)
                    }
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(Color(.systemBackground))

            // Terminal or placeholder
            if let id = coordinator.activeSessionId,
               let vm = coordinator.viewModel(for: id) {
                SwiftTermView(viewModel: vm)
                    .id(id)

                if showKeyBar {
                    KeyboardAccessory { data in
                        vm.sendInput(data)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            } else {
                ContentUnavailableView(
                    "No Active Session",
                    systemImage: "terminal",
                    description: Text("Swipe from the left edge or create a new session.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private func statusColor(_ state: RelayConnection.ConnectionState) -> SwiftUI.Color {
        switch state {
        case .connected: return .green
        case .connecting, .reconnecting: return .yellow
        case .disconnected: return .red
        }
    }
}

// MARK: - SwiftTerm UIViewRepresentable

struct SwiftTermView: UIViewRepresentable {
    let viewModel: TerminalViewModel

    func makeUIView(context: Context) -> TerminalView {
        let terminal = TerminalView(frame: .zero)
        terminal.terminalDelegate = context.coordinator
        terminal.nativeBackgroundColor = .black
        terminal.nativeForegroundColor = .white

        viewModel.onTerminalOutput = { data in
            let bytes = ArraySlice([UInt8](data))
            terminal.feed(byteArray: bytes)
            terminal.setNeedsDisplay()
        }

        // Auto-focus for hardware keyboard input.
        // Hide SwiftTerm's built-in inputAccessoryView — we use our own.
        DispatchQueue.main.async {
            terminal.becomeFirstResponder()
            terminal.inputAccessoryView?.isHidden = true
            terminal.inputAccessoryView?.frame.size.height = 0
            terminal.reloadInputViews()
        }

        return terminal
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

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
