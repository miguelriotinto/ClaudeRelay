import SwiftUI
import SwiftTerm
import ClaudeRelayClient

/// Detail pane: thin toolbar + terminal or placeholder.
struct ActiveTerminalView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @Binding var columnVisibility: NavigationSplitViewVisibility
    var onDisconnect: () -> Void

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

/// Wraps SwiftTerm's TerminalView inside a UIKit container that handles
/// keyboard avoidance via Auto Layout, bypassing SwiftUI's broken handling
/// of UIKit inputAccessoryView.
struct SwiftTermView: UIViewRepresentable {
    let viewModel: TerminalViewModel

    func makeUIView(context: Context) -> KeyboardAvoidingContainer {
        let container = KeyboardAvoidingContainer()
        container.backgroundColor = .black

        let terminal = TerminalView(frame: .zero)
        terminal.terminalDelegate = context.coordinator
        terminal.nativeBackgroundColor = .black
        terminal.nativeForegroundColor = .white
        terminal.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(terminal)

        let bottom = terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bottom,
        ])

        container.terminal = terminal
        container.bottomConstraint = bottom
        context.coordinator.terminal = terminal

        viewModel.onTerminalOutput = { data in
            let bytes = ArraySlice([UInt8](data))
            terminal.feed(byteArray: bytes)
            terminal.setNeedsDisplay()
        }

        DispatchQueue.main.async {
            terminal.becomeFirstResponder()
        }

        return container
    }

    func updateUIView(_ uiView: KeyboardAvoidingContainer, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    /// Custom container that recalculates keyboard overlap on every layout
    /// pass — handles rotation, split-view resizing, and initial display.
    class KeyboardAvoidingContainer: UIView {
        weak var terminal: TerminalView?
        var bottomConstraint: NSLayoutConstraint?
        private var currentKeyboardFrame: CGRect?

        override init(frame: CGRect) {
            super.init(frame: frame)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(keyboardChanged(_:)),
                name: UIResponder.keyboardWillChangeFrameNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(keyboardHidden(_:)),
                name: UIResponder.keyboardWillHideNotification,
                object: nil
            )
        }

        required init?(coder: NSCoder) { fatalError() }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func keyboardChanged(_ notification: Notification) {
            if let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                currentKeyboardFrame = frame
                updateBottomInset(notification: notification)
            }
        }

        @objc private func keyboardHidden(_ notification: Notification) {
            currentKeyboardFrame = nil
            let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval ?? 0.25
            UIView.animate(withDuration: duration) {
                self.bottomConstraint?.constant = 0
                self.layoutIfNeeded()
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // Defer recalculation so it runs AFTER the rotation animation
            // commits the final frame, not during the in-flight transform.
            DispatchQueue.main.async { [weak self] in
                self?.recalculateInset()
            }
        }

        private func recalculateInset() {
            guard let kbFrame = currentKeyboardFrame, window != nil else { return }
            let containerFrame = convert(bounds, to: nil)
            let overlap = max(0, containerFrame.maxY - kbFrame.origin.y)
            if bottomConstraint?.constant != -overlap {
                bottomConstraint?.constant = -overlap
            }
        }

        private func updateBottomInset(notification: Notification) {
            guard let kbFrame = currentKeyboardFrame, window != nil else { return }

            let containerFrame = convert(bounds, to: nil)
            let overlap = max(0, containerFrame.maxY - kbFrame.origin.y)

            let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval ?? 0.25
            UIView.animate(withDuration: duration) {
                self.bottomConstraint?.constant = -overlap
                self.layoutIfNeeded()
            }
        }
    }

    class Coordinator: NSObject, TerminalViewDelegate {
        let viewModel: TerminalViewModel
        weak var terminal: TerminalView?

        init(viewModel: TerminalViewModel) {
            self.viewModel = viewModel
        }

        // MARK: - TerminalViewDelegate

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
