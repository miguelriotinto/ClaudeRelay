import SwiftUI
import SwiftTerm
import ClaudeRelayClient
import ClaudeRelaySpeech
import GameController
import CoreImage

/// Detail pane: thin toolbar + terminal + optional key bar.
struct ActiveTerminalView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @Binding var columnVisibility: NavigationSplitViewVisibility
    var onDisconnect: () -> Void
    @State private var showKeyBar = true
    @State private var isKeyboardVisible = false
    @State private var hasHardwareKeyboard = GCKeyboard.coalesced != nil
    @State private var showQROverlay = false
    @State private var showRenameAlert = false
    @State private var renameText = ""
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
            HStack(spacing: 6) {
                // Fixed left: icon buttons
                ToolbarIconButton(icon: "chevron.left") { onDisconnect() }
                ToolbarIconButton(icon: "sidebar.left") {
                    withAnimation {
                        columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                    }
                }
                ToolbarIconButton(icon: "fn", isActive: showKeyBar) { showKeyBar.toggle() }

                // Fixed left: connectivity indicator + session time
                if let id = coordinator.activeSessionId,
                   let vm = coordinator.viewModel(for: id) {
                    Circle()
                        .fill(statusColor(vm.connectionState))
                        .frame(width: 8, height: 8)

                    if let createdAt = coordinator.createdAt(for: id) {
                        SessionUptimeView(since: createdAt)
                    }
                }

                // Scrollable middle: session tabs
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(coordinator.activeSessions.enumerated()), id: \.element.id) { index, session in
                            let isSelected = session.id == coordinator.activeSessionId
                            let isClaude = coordinator.isRunningClaude(sessionId: session.id)
                            let needsAttention = coordinator.sessionsAwaitingInput.contains(session.id)
                            Button {
                                if AppSettings.shared.hapticFeedbackEnabled {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                }
                                Task { await coordinator.switchToSession(id: session.id) }
                            } label: {
                                SessionTab(
                                    number: index + 1,
                                    isSelected: isSelected,
                                    isClaude: isClaude,
                                    needsAttention: needsAttention
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // QR code button
                if coordinator.activeSessionId != nil {
                    ToolbarIconButton(icon: "qrcode") {
                        showQROverlay = true
                    }
                }

                // Fixed right: session name pill
                if let id = coordinator.activeSessionId {
                    Text(coordinator.name(for: id))
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(maxWidth: 100)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 22)
                        .background(Color.white.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .layoutPriority(1)
                        .onLongPressGesture {
                            renameText = coordinator.name(for: id)
                            showRenameAlert = true
                        }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(.black)
        }
        .background(.black)
        .ignoresSafeArea(.container, edges: .horizontal)
        .preferredColorScheme(.dark)
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: coordinator.activeSessionId) { _, _ in
            showQROverlay = false
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
        .alert("Rename Session", isPresented: $showRenameAlert) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty, let id = coordinator.activeSessionId {
                    coordinator.setName(trimmed, for: id)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .overlay {
            if let progress = speechEngine.modelLoadProgress {
                ModelLoadingOverlay(progress: progress)
            }
        }
        .overlay {
            if showQROverlay, let id = coordinator.activeSessionId {
                QRCodeOverlay(
                    sessionId: id,
                    sessionName: coordinator.name(for: id),
                    onDismiss: { showQROverlay = false }
                )
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

// MARK: - Toolbar Icon Button

/// Compact icon button for the status bar toolbar.
private struct ToolbarIconButton: View {
    let icon: String
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button {
            if AppSettings.shared.hapticFeedbackEnabled {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isActive ? .black : SwiftUI.Color.white.opacity(0.7))
                .frame(minWidth: 26, minHeight: 22)
                .background(isActive ? Color.white : Color.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

/// Individual session tab with optional flash animation when input is needed.
/// Uses a timer-driven flash instead of repeatForever to ensure the animation
/// reliably stops when needsAttention becomes false.
private struct SessionTab: View {
    let number: Int
    let isSelected: Bool
    let isClaude: Bool
    let needsAttention: Bool

    @State private var flashOn = false

    var body: some View {
        Text("\(number)")
            .font(.system(size: 12, weight: isSelected ? .bold : .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .frame(minWidth: 26, minHeight: 22)
            .background(tabBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(selectionBorderColor, lineWidth: isSelected ? 2 : 0)
            )
            .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
                guard needsAttention else { return }
                withAnimation(.easeInOut(duration: 0.4)) {
                    flashOn.toggle()
                }
            }
            .onChange(of: needsAttention) { _, attention in
                if !attention {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        flashOn = false
                    }
                }
            }
    }

    private var selectionBorderColor: SwiftUI.Color {
        .white
    }

    private var tabBackground: SwiftUI.Color {
        if needsAttention {
            return flashOn ? SwiftUI.Color.orange : SwiftUI.Color.white.opacity(0.15)
        }
        if isClaude {
            return SwiftUI.Color.orange
        }
        return SwiftUI.Color.white.opacity(0.15)
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
        .onReceive(NotificationCenter.default.publisher(for: .toggleSpeechRecording)) { _ in
            handleTap()
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
    static let toggleSpeechRecording = Notification.Name("toggleSpeechRecording")
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

        // 3. Override canPerformAction to hide Paste when clipboard has no text.
        //    SwiftTerm declares this as `public` (not `open`), so we use the runtime.
        let canSel = #selector(UIResponder.canPerformAction(_:withSender:))
        if let origCanMethod = class_getInstanceMethod(TerminalView.self, canSel) {
            let origCanImp = method_getImplementation(origCanMethod)
            typealias CanFn = @convention(c) (AnyObject, Selector, Selector, AnyObject?) -> Bool
            let canImp = imp_implementationWithBlock({ (self_: AnyObject, action: Selector, sender: AnyObject?) -> Bool in
                if action == #selector(UIResponderStandardEditActions.paste(_:)) {
                    return UIPasteboard.general.hasStrings || UIPasteboard.general.hasImages
                }
                let fn = unsafeBitCast(origCanImp, to: CanFn.self)
                return fn(self_, canSel, action, sender)
            } as @convention(block) (AnyObject, Selector, AnyObject?) -> Bool)
            // "B32@0:8:16@24" = returns Bool, self at 0, _cmd at 8, SEL at 16, id at 24
            class_replaceMethod(RelayTerminalView.self, canSel, canImp, "B32@0:8:16@24")
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

        let enabled = UserDefaults.standard.object(forKey: "recordingShortcutEnabled") as? Bool ?? true
        if enabled {
            let key = UserDefaults.standard.string(forKey: "recordingShortcutKey") ?? ""
            if !key.isEmpty {
                let flagsRaw = UserDefaults.standard.integer(forKey: "recordingShortcutFlags")
                let flags: UIKeyModifierFlags = flagsRaw != 0
                    ? UIKeyModifierFlags(rawValue: flagsRaw)
                    : [.command, .alternate]
                let cmd = UIKeyCommand(input: key, modifierFlags: flags,
                                       action: #selector(handleRecordingShortcut))
                cmd.discoverabilityTitle = "Toggle Recording"
                commands.append(cmd)
            }
        }

        return commands
    }

    @objc private func handleRecordingShortcut() {
        NotificationCenter.default.post(name: .toggleSpeechRecording, object: nil)
    }

    var onPasteImage: ((Data) -> Void)?

    override func paste(_ sender: Any?) {
        // Check images first — many clipboard entries carry both text and an image
        // (e.g. a photo copied from Safari also has a URL string). Prioritise the
        // image so it actually reaches Claude Code via the relay's clipboard path.
        if UIPasteboard.general.hasImages,
           let image = UIPasteboard.general.image,
           let pngData = image.pngData() {
            onPasteImage?(pngData)
            return
        }
        // Plain text — let SwiftTerm handle it normally.
        super.paste(sender)
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
        terminal.changeScrollback(10_000)

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

        terminal.onPasteImage = { [weak viewModel] imageData in
            viewModel?.sendPasteImage(imageData)
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
        func setTerminalTitle(source: TerminalView, title: String) {
            Task { @MainActor in
                viewModel.terminalTitle = title
                viewModel.onTitleChanged?(title)
            }
        }
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
                .foregroundStyle(SwiftUI.Color.white.opacity(0.5))
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

// MARK: - QR Code Generation

struct QRCodeGenerator {
    private static let context = CIContext()

    static func generate(from string: String, size: CGFloat = 200) -> UIImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let ciImage = filter.outputImage else { return nil }
        let scale = size / ciImage.extent.size.width
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - QR Code Overlay

struct QRCodeOverlay: View {
    let sessionId: UUID
    let sessionName: String
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(spacing: 16) {
                if let image = QRCodeGenerator.generate(
                    from: "clauderelay://session/\(sessionId.uuidString)",
                    size: 200
                ) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 200, height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Text(sessionName)
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
    }
}
