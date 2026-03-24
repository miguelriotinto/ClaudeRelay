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
    @StateObject private var speechRecognizer = SpeechRecognizer()
    @Environment(\.scenePhase) private var scenePhase
    @State private var pulseAnimation = false

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

            // Floating buttons: mic + keyboard toggle
            HStack(spacing: 10) {
                // Mic button
                Button {
                    toggleDictation()
                } label: {
                    Image(systemName: speechRecognizer.isRecording ? "mic.fill" : "mic")
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(speechRecognizer.isRecording
                                    ? Color.red.opacity(0.8)
                                    : Color.gray.opacity(0.5))
                        .clipShape(Circle())
                        .scaleEffect(pulseAnimation && speechRecognizer.isRecording ? 1.15 : 1.0)
                        .animation(
                            speechRecognizer.isRecording
                                ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                                : .default,
                            value: pulseAnimation
                        )
                }

                // Keyboard toggle button (unchanged)
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
                        showKeyBar.toggle()
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
        .onChange(of: coordinator.activeSessionId) { _, _ in
            speechRecognizer.stopRecording()
            pulseAnimation = false
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                speechRecognizer.stopRecording()
                pulseAnimation = false
            }
        }
        .alert(
            permissionAlertTitle,
            isPresented: Binding(
                get: { speechRecognizer.permissionError != nil },
                set: { if !$0 { speechRecognizer.permissionError = nil } }
            ),
            presenting: speechRecognizer.permissionError,
            actions: { error in
                if error != .unavailable {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            },
            message: { error in
                switch error {
                case .microphoneDenied:
                    Text("Voice input needs microphone access. Enable it in Settings.")
                case .speechDenied:
                    Text("Voice input needs speech recognition access. Enable it in Settings.")
                case .unavailable:
                    Text("Speech recognition is not available on this device or for your language.")
                }
            }
        )
    }

    private func statusColor(_ state: RelayConnection.ConnectionState) -> SwiftUI.Color {
        switch state {
        case .connected: return .green
        case .connecting, .reconnecting: return .yellow
        case .disconnected: return .red
        }
    }

    private func toggleDictation() {
        if speechRecognizer.isRecording {
            speechRecognizer.stopRecording()
            pulseAnimation = false
        } else {
            speechRecognizer.startRecording { [coordinator] data in
                guard let id = coordinator.activeSessionId,
                      let vm = coordinator.viewModel(for: id) else { return }
                vm.sendInput(data)
            }
            pulseAnimation = true
        }
    }

    private var permissionAlertTitle: String {
        switch speechRecognizer.permissionError {
        case .microphoneDenied: return "Microphone Access Required"
        case .speechDenied: return "Speech Recognition Required"
        case .unavailable: return "Speech Recognition Unavailable"
        case nil: return ""
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
            isKeyboardVisible.wrappedValue = true
        }

        @objc private func keyboardDidHide() {
            isKeyboardVisible.wrappedValue = false
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            Task { @MainActor in
                viewModel.sendInput(Data(data))
            }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            Task { @MainActor in
                viewModel.sendResize(cols: UInt16(newCols), rows: UInt16(newRows))
                viewModel.terminalReady()
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
