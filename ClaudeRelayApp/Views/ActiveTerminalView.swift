import SwiftUI
import SwiftTerm
import ClaudeRelayClient

/// Detail pane: thin toolbar + terminal + optional key bar.
struct ActiveTerminalView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @Binding var columnVisibility: NavigationSplitViewVisibility
    var onDisconnect: () -> Void
    @State private var showKeyBar = false
    @State private var isKeyboardVisible = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                // Terminal or placeholder
                if let id = coordinator.activeSessionId,
                   let vm = coordinator.viewModel(for: id) {
                    SwiftTermView(viewModel: vm, isKeyboardVisible: $isKeyboardVisible)
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

            // Floating keyboard toggle button
            Button {
                if isKeyboardVisible {
                    NotificationCenter.default.post(
                        name: .terminalResignFocus, object: nil
                    )
                } else {
                    NotificationCenter.default.post(
                        name: .terminalRequestFocus, object: nil
                    )
                }
            } label: {
                Image(systemName: isKeyboardVisible
                      ? "keyboard.chevron.compact.down"
                      : "keyboard")
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.gray.opacity(0.5))
                    .clipShape(Circle())
            }
            .padding(.trailing, 16)
            .padding(.bottom, 12)
        }
        .safeAreaInset(edge: .top) {
            // Thin custom toolbar — sits below the status bar automatically
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
        }
        .ignoresSafeArea(.container, edges: .horizontal)
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

// MARK: - Notification for requesting terminal focus

extension Notification.Name {
    static let terminalRequestFocus = Notification.Name("terminalRequestFocus")
    static let terminalResignFocus = Notification.Name("terminalResignFocus")
}

struct SwiftTermView: UIViewRepresentable {
    let viewModel: TerminalViewModel
    @Binding var isKeyboardVisible: Bool

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

        // Hide SwiftTerm's built-in inputAccessoryView — we use a floating button instead.
        _ = terminal.becomeFirstResponder()
        terminal.inputAccessoryView?.isHidden = true
        terminal.inputAccessoryView?.frame.size.height = 0
        terminal.reloadInputViews()

        // Listen for focus/resign requests from the floating keyboard button.
        context.coordinator.focusObserver = NotificationCenter.default.addObserver(
            forName: .terminalRequestFocus, object: nil, queue: .main
        ) { _ in
            _ = terminal.becomeFirstResponder()
        }
        context.coordinator.resignObserver = NotificationCenter.default.addObserver(
            forName: .terminalResignFocus, object: nil, queue: .main
        ) { _ in
            _ = terminal.resignFirstResponder()
        }

        return terminal
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}

    static func dismantleUIView(_ uiView: TerminalView, coordinator: Coordinator) {
        if let observer = coordinator.focusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = coordinator.resignObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        coordinator.removeKeyboardObservers()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel, isKeyboardVisible: $isKeyboardVisible)
    }

    class Coordinator: NSObject, TerminalViewDelegate {
        let viewModel: TerminalViewModel
        var isKeyboardVisible: Binding<Bool>
        var focusObserver: Any?
        var resignObserver: Any?

        init(viewModel: TerminalViewModel, isKeyboardVisible: Binding<Bool>) {
            self.viewModel = viewModel
            self.isKeyboardVisible = isKeyboardVisible
            super.init()

            NotificationCenter.default.addObserver(
                self, selector: #selector(keyboardDidShow),
                name: UIResponder.keyboardDidShowNotification, object: nil
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(keyboardDidHide),
                name: UIResponder.keyboardDidHideNotification, object: nil
            )
        }

        func removeKeyboardObservers() {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func keyboardDidShow() {
            DispatchQueue.main.async { self.isKeyboardVisible.wrappedValue = true }
        }

        @objc private func keyboardDidHide() {
            DispatchQueue.main.async { self.isKeyboardVisible.wrappedValue = false }
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
