import SwiftUI
import SwiftTerm
import ClaudeRelayClient
import GameController

/// Detail pane: thin toolbar + terminal + optional key bar.
struct ActiveTerminalView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @Binding var columnVisibility: NavigationSplitViewVisibility
    var onDisconnect: () -> Void
    @State private var showKeyBar = false
    @State private var isKeyboardVisible = false
    @State private var hasHardwareKeyboard = GCKeyboard.coalesced != nil
    @StateObject private var speechEngine = OnDeviceSpeechEngine()
    @Environment(\.scenePhase) private var scenePhase

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

            // Floating buttons: mic + keyboard toggle (only when a terminal session is active)
            if coordinator.activeSessionId != nil {
                HStack(spacing: 10) {
                    MicButton(engine: speechEngine, settings: AppSettings.shared, coordinator: coordinator)

                    Button {
                        if AppSettings.shared.hapticFeedbackEnabled {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
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
                    .disabled(hasHardwareKeyboard)
                    .opacity(hasHardwareKeyboard ? 0.35 : 1.0)
                }
                .padding(.trailing, 16)
                .padding(.bottom, 12)
            }
        }
        .safeAreaInset(edge: .top) {
            // Thin custom toolbar — sits below the status bar automatically
            HStack(spacing: 16) {
                HStack(spacing: 12) {
                    Button {
                        if AppSettings.shared.hapticFeedbackEnabled {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                        onDisconnect()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .medium))
                    }

                    Button {
                        if AppSettings.shared.hapticFeedbackEnabled {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                        withAnimation {
                            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                        }
                    } label: {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 16))
                    }

                    Button {
                        if AppSettings.shared.hapticFeedbackEnabled {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                        showKeyBar.toggle()
                    } label: {
                        Image(systemName: showKeyBar ? "fn" : "fn")
                            .font(.system(size: 16))
                            .fontWeight(showKeyBar ? .bold : .regular)
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    if let id = coordinator.activeSessionId {
                        Text("[\(coordinator.activeSessions.count)]")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if let createdAt = coordinator.createdAt(for: id) {
                            SessionUptimeView(since: createdAt)
                        }
                        Text(coordinator.name(for: id))
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.primary)
                        Text(id.uuidString.prefix(8))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        if let vm = coordinator.viewModel(for: id) {
                            Circle()
                                .fill(statusColor(vm.connectionState))
                                .frame(width: 8, height: 8)
                        }
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
            speechEngine.cancel()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                speechEngine.cancel()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidConnect)) { _ in
            hasHardwareKeyboard = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidDisconnect)) { _ in
            hasHardwareKeyboard = GCKeyboard.coalesced != nil
        }
        .alert(
            "Speech Error",
            isPresented: Binding(
                get: { if case .error = speechEngine.state { return true } else { return false } },
                set: { _ in }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            if case .error(let msg) = speechEngine.state {
                Text(msg)
            }
        }
        .overlay {
            if let progress = speechEngine.modelLoadProgress {
                ModelLoadingOverlay(progress: progress)
            }
        }
    }

    private func statusColor(_ state: RelayConnection.ConnectionState) -> SwiftUI.Color {
        switch state {
        case .connected: return .green
        case .connecting, .reconnecting: return .yellow
        case .disconnected: return .red
        }
    }

}

// MARK: - Model Loading Overlay

private struct ModelLoadingOverlay: View {
    let progress: Double

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "waveform")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)

                Text("Loading Speech Models")
                    .font(.headline)

                ProgressView(value: progress, total: 1.0)
                    .progressViewStyle(.linear)
                    .animation(.easeInOut(duration: 0.3), value: progress)

                Text("\(Int(progress * 100))%")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.2), value: Int(progress * 100))

                Text(progress < 0.8 ? "Loading Whisper…" : "Loading cleanup model…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(24)
            .frame(width: 260)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .transition(.opacity)
    }
}

// MARK: - Mic Button (on-device speech engine)

private struct MicButton: View {
    @ObservedObject var engine: OnDeviceSpeechEngine
    @ObservedObject var settings: AppSettings
    let coordinator: SessionCoordinator
    @State private var showDownloadAlert = false

    var body: some View {
        Button {
            handleTap()
        } label: {
            Group {
                if let progress = engine.modelStore.downloadProgress {
                    ZStack {
                        Circle()
                            .stroke(Color.gray.opacity(0.3), lineWidth: 3)
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(Color.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.3), value: progress)
                    }
                    .frame(width: 24, height: 24)
                } else {
                    Image(systemName: buttonIcon)
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 44, height: 44)
            .background(buttonColor)
            .clipShape(Circle())
        }
        .disabled(isButtonDisabled)
        .alert("Download Speech Models?", isPresented: $showDownloadAlert) {
            Button("Download") {
                Task { await engine.prepareModels() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("On-device voice recognition requires a one-time download (~1 GB). This enables offline, private speech-to-text.")
        }
    }

    private func handleTap() {
        switch engine.state {
        case .idle:
            guard engine.modelsReady else {
                showDownloadAlert = true
                return
            }
            if settings.hapticFeedbackEnabled {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            Task { await engine.startRecording() }

        case .recording:
            if settings.hapticFeedbackEnabled {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            Task {
                if let text = await engine.stopAndProcess(
                    smartCleanup: settings.smartCleanupEnabled,
                    promptEnhancement: settings.promptEnhancementEnabled,
                    bearerToken: settings.bedrockBearerToken,
                    region: settings.bedrockRegion
                ) {
                    if settings.hapticFeedbackEnabled {
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    }
                    guard let id = coordinator.activeSessionId,
                          let vm = coordinator.viewModel(for: id) else { return }
                    vm.sendInput(text)
                } else {
                    if settings.hapticFeedbackEnabled {
                        UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    }
                }
            }

        case .error:
            engine.cancel()

        default:
            break // Button is disabled in other states
        }
    }

    private var isButtonDisabled: Bool {
        switch engine.state {
        case .loadingModel, .transcribing, .cleaning:
            return true
        default:
            return engine.modelStore.downloadProgress != nil
        }
    }

    private var buttonIcon: String {
        switch engine.state {
        case .idle, .loadingModel: return "mic"
        case .recording: return "mic.fill"
        case .transcribing: return "waveform"
        case .cleaning: return "sparkles"
        case .error: return "mic"
        }
    }

    private var buttonColor: SwiftUI.Color {
        switch engine.state {
        case .idle, .loadingModel: return Color.gray.opacity(0.5)
        case .recording: return Color.red.opacity(0.8)
        case .transcribing, .cleaning: return Color.yellow.opacity(0.8)
        case .error: return Color.red.opacity(0.8)
        }
    }
}

// MARK: - SwiftTerm UIViewRepresentable

// MARK: - Notification for requesting terminal focus

extension Notification.Name {
    static let terminalRequestFocus = Notification.Name("terminalRequestFocus")
    static let terminalResignFocus = Notification.Name("terminalResignFocus")
}

// MARK: - TerminalView subclass for hardware keyboard commands

/// Adds explicit UIKeyCommand entries for Cmd+C / Cmd+V / Cmd+X so that
/// copy-paste works reliably when a hardware keyboard is connected.
/// SwiftTerm implements the `copy(_:)` / `paste(_:)` methods but does not
/// register key commands, so the system never dispatches them on iOS.
private class RelayTerminalView: TerminalView {
    // SwiftTerm declares `hasText` as `public` (not `open`), so Swift prevents a
    // direct override. We use the Objective-C runtime to add our own implementation
    // to this subclass, making `hasText` always return true. Without this, the
    // software keyboard stops calling `deleteBackward()` on long-press once
    // SwiftTerm's internal text buffer is empty — but in a terminal, backspace
    // should always repeat since it sends escape codes to the remote shell.
    //
    // IMPORTANT: This must be triggered from didMoveToWindow(), not keyCommands.
    // keyCommands is only queried when a hardware keyboard is present — on a
    // software-only keyboard the override would never be installed.
    private static var hasTextOverrideInstalled = false
    private static func installRuntimeOverrides() {
        guard !hasTextOverrideInstalled else { return }
        hasTextOverrideInstalled = true

        // 1. Override hasText → always true so iOS keeps firing deleteBackward on repeat.
        let sel = sel_registerName("hasText")
        let imp = imp_implementationWithBlock({ (_: AnyObject) -> Bool in
            true
        } as @convention(block) (AnyObject) -> Bool)
        // "B16@0:8" = returns Bool, total frame 16, self at 0, _cmd at 8
        class_replaceMethod(RelayTerminalView.self, sel, imp, "B16@0:8")

        // 2. Override deleteBackward to notify inputDelegate even when the internal
        //    text buffer is empty. SwiftTerm's "buffer empty" path sends the backspace
        //    escape code but skips beginTextInputEdit/endTextInputEdit, so iOS's text
        //    system never sees activity and stops key repeat.
        let delSel = sel_registerName("deleteBackward")
        if let origMethod = class_getInstanceMethod(TerminalView.self, delSel) {
            let origImp = method_getImplementation(origMethod)
            typealias DeleteFn = @convention(c) (AnyObject, Selector) -> Void
            let delImp = imp_implementationWithBlock({ (self_: AnyObject) -> Void in
                if let textInput = self_ as? UITextInput {
                    textInput.inputDelegate?.textWillChange(textInput)
                }
                let fn = unsafeBitCast(origImp, to: DeleteFn.self)
                fn(self_, delSel)
                if let textInput = self_ as? UITextInput {
                    textInput.inputDelegate?.textDidChange(textInput)
                }
            } as @convention(block) (AnyObject) -> Void)
            // "v16@0:8" = returns void, total frame 16, self at 0, _cmd at 8
            class_replaceMethod(RelayTerminalView.self, delSel, delImp, "v16@0:8")
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            Self.installRuntimeOverrides()
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        var commands = super.keyCommands ?? []
        commands.append(contentsOf: [
            UIKeyCommand(input: "c", modifierFlags: .command, action: #selector(copy(_:))),
            UIKeyCommand(input: "v", modifierFlags: .command, action: #selector(paste(_:))),
            UIKeyCommand(input: "x", modifierFlags: .command, action: #selector(handleCut(_:)))
        ])
        return commands
    }

    @objc private func handleCut(_ sender: Any?) {
        // Terminal output isn't editable — cut behaves like copy.
        copy(sender)
    }
}

struct SwiftTermView: UIViewRepresentable {
    let viewModel: TerminalViewModel
    @Binding var isKeyboardVisible: Bool

    func makeUIView(context: Context) -> TerminalView {
        let terminal = RelayTerminalView(frame: .zero)
        terminal.terminalDelegate = context.coordinator
        terminal.nativeBackgroundColor = .black
        terminal.nativeForegroundColor = .white

        viewModel.onTerminalOutput = { data in
            let bytes = ArraySlice([UInt8](data))
            terminal.feed(byteArray: bytes)

            // Sync UIScrollView after buffer changes that bypass the scrolled delegate.
            // \033[3J (clear scrollback) trims lines and adjusts yDisp without notifying
            // the view, leaving contentOffset/contentSize stale. The draw method uses
            // contentOffset to pick which rows to render, so a stale offset shows blank.
            let term = terminal.getTerminal()
            let rows = term.rows
            if rows > 0 {
                let cellHeight = terminal.bounds.height / CGFloat(rows)
                let yDisp = CGFloat(term.buffer.yDisp)
                let expectedOffsetY = yDisp * cellHeight
                if terminal.contentOffset.y - expectedOffsetY > cellHeight * 2 {
                    terminal.contentSize.height = max(terminal.bounds.height,
                                                      (yDisp + CGFloat(rows)) * cellHeight)
                    terminal.contentOffset.y = expectedOffsetY
                }
            }
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

// MARK: - Session Uptime

private struct SessionUptimeView: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(formatUptime(from: since, to: context.date))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func formatUptime(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if days > 0 {
            return String(format: "%dd %02d:%02d:%02d", days, hours, minutes, seconds)
        }
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}
