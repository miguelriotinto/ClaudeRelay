import SwiftUI
import SwiftTerm
import ClaudeRelayClient
import ClaudeRelayKit
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
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                if let id = coordinator.activeSessionId,
                   let vm = coordinator.viewModel(for: id) {
                    // Single host reused across session switches so each
                    // terminal's SwiftTerm scrollback survives the swap.
                    TerminalHostView(
                        coordinator: coordinator,
                        fontSize: CGFloat(settings.terminalFontSize),
                        isKeyboardVisible: $isKeyboardVisible
                    )

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
            .onAppear {
                speechEngine.preloadInBackground()
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
                ToolbarIconButton(icon: "sidebar.left") {
                    withAnimation {
                        columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                    }
                }
                ToolbarIconButton(icon: "server.rack") { onDisconnect() }
                ToolbarIconButton(icon: "fn", isActive: showKeyBar) { showKeyBar.toggle() }

                ConnectionQualityDot(quality: coordinator.connection.connectionQuality, size: 8)

                if let id = coordinator.activeSessionId {
                    if let createdAt = coordinator.createdAt(for: id) {
                        SessionUptimeView(since: createdAt)
                    }
                }

                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let flashOn = Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(coordinator.activeSessions.enumerated()), id: \.element.id) { index, session in
                                let isSelected = session.id == coordinator.activeSessionId
                                let agentId = coordinator.activeAgent(for: session.id)
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
                                        agentId: agentId,
                                        needsAttention: needsAttention,
                                        flashOn: flashOn
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                if coordinator.activeSessionId != nil {
                    ToolbarIconButton(icon: "qrcode") {
                        showQROverlay = true
                    }
                }

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
            if showQROverlay, let id = coordinator.activeSessionId {
                QRCodeOverlay(
                    sessionId: id,
                    sessionName: coordinator.name(for: id),
                    onDismiss: { showQROverlay = false }
                )
            }
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

/// Individual session tab. Flash phase is driven by a shared TimelineView clock
/// in the parent, so we don't spin up one Timer.publish per tab.
private struct SessionTab: View {
    let number: Int
    let isSelected: Bool
    let agentId: String?
    let needsAttention: Bool
    /// Shared flash phase passed down from the parent's TimelineView.
    /// Ignored by tabs that don't need attention.
    let flashOn: Bool

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
            .animation(.easeInOut(duration: 0.15), value: flashOn)
    }

    private var selectionBorderColor: SwiftUI.Color { .white }

    private var agentColor: SwiftUI.Color {
        AgentColorPalette.color(for: agentId)
    }

    private var tabBackground: SwiftUI.Color {
        if needsAttention {
            return flashOn ? agentColor : SwiftUI.Color.white.opacity(0.15)
        }
        if agentId != nil { return agentColor }
        return SwiftUI.Color.white.opacity(0.15)
    }
}

// MARK: - Mic Button (on-device speech engine)

private struct MicButton: View {
    @ObservedObject var engine: OnDeviceSpeechEngine
    @ObservedObject var settings: AppSettings
    let coordinator: SessionCoordinator
    @State private var showDownloadAlert = false

    private var activeProgress: Double? {
        engine.modelStore.downloadProgress ?? engine.modelLoadProgress
    }

    var body: some View {
        Button {
            handleTap()
        } label: {
            Group {
                if let progress = activeProgress {
                    ZStack {
                        Circle()
                            .stroke(Color.gray.opacity(0.4), lineWidth: 3)
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
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
            return activeProgress != nil
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
        case .idle, .loadingModel: return SwiftUI.Color.gray.opacity(0.5)
        case .recording: return SwiftUI.Color.red.opacity(0.8)
        case .transcribing, .cleaning: return SwiftUI.Color.yellow.opacity(0.8)
        case .error: return SwiftUI.Color.red.opacity(0.8)
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
class RelayTerminalView: TerminalView {
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

/// Holds a RelayTerminalView together with the SwiftTerm delegate so its
/// lifetime exceeds any single SwiftUI render cycle. Cached on the coordinator
/// so switching sessions reuses the same UIView (preserving SwiftTerm's
/// internal scrollback) instead of tearing it down.
final class CachedIOSTerminal {
    let view: RelayTerminalView
    let delegate: IOSTerminalCoordinator

    init(view: RelayTerminalView, delegate: IOSTerminalCoordinator) {
        self.view = view
        self.delegate = delegate
    }
}

/// SwiftUI host that shows the coordinator's cached terminal for the active
/// session. Creates a new cached terminal on first use and registers it with
/// the coordinator so subsequent resumes can ask the server to skip the
/// ring-buffer replay.
struct TerminalHostView: UIViewRepresentable {
    @ObservedObject var coordinator: SessionCoordinator
    var fontSize: CGFloat
    @Binding var isKeyboardVisible: Bool

    func makeCoordinator() -> HostCoordinator {
        HostCoordinator(isKeyboardVisible: $isKeyboardVisible)
    }

    func makeUIView(context: Context) -> UIView {
        let host = UIView(frame: .zero)
        host.backgroundColor = .black
        context.coordinator.installKeyboardObservers()
        context.coordinator.installFocusObservers { [weak host] in
            (host?.subviews.first { !$0.isHidden }) as? RelayTerminalView
        }
        return host
    }

    func updateUIView(_ host: UIView, context: Context) {
        guard let activeId = coordinator.activeSessionId,
              let viewModel = coordinator.viewModel(for: activeId) else {
            for subview in host.subviews { subview.isHidden = true }
            return
        }

        let isFirstTimeForSession = coordinator.cachedTerminalView(for: activeId) == nil
        let sessionChanged = context.coordinator.lastFocusedSessionId != activeId
        let cached = cachedOrMake(for: activeId, viewModel: viewModel, host: host)

        if cached.view.superview !== host {
            host.addSubview(cached.view)
            cached.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                cached.view.topAnchor.constraint(equalTo: host.topAnchor),
                cached.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                cached.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                cached.view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
            ])
        }

        for subview in host.subviews {
            subview.isHidden = (subview !== cached.view)
        }

        let newFont = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if cached.view.font != newFont {
            cached.view.font = newFont
        }

        cached.delegate.viewModel = viewModel
        viewModel.onTerminalOutput = { [weak view = cached.view] data in
            guard let view else { return }
            let bytes = ArraySlice([UInt8](data))
            view.feed(byteArray: bytes)

            // Sync UIScrollView after buffer changes that bypass the scrolled delegate.
            // \033[3J (clear scrollback) trims lines and adjusts yDisp without
            // notifying the view, leaving contentOffset/contentSize stale.
            let term = view.getTerminal()
            let rows = term.rows
            if rows > 0 {
                let cellHeight = view.bounds.height / CGFloat(rows)
                let yDisp = CGFloat(term.buffer.yDisp)
                let expectedOffsetY = yDisp * cellHeight
                if view.contentOffset.y - expectedOffsetY > cellHeight * 2 {
                    view.contentSize.height = max(view.bounds.height,
                                                  (yDisp + CGFloat(rows)) * cellHeight)
                    view.contentOffset.y = expectedOffsetY
                }
            }
        }
        viewModel.terminalReady()

        // Hide the built-in input accessory once per terminal (idempotent, but
        // not needed on every updateUIView).
        if isFirstTimeForSession {
            cached.view.inputAccessoryView?.isHidden = true
            cached.view.inputAccessoryView?.frame.size.height = 0
            cached.view.reloadInputViews()
        }

        // Only focus the terminal when the active session actually changes.
        // updateUIView fires on every @ObservedObject publish (activity updates,
        // connection quality, etc.), and forcing first-responder on each call
        // would override user dismisses — the keyboard would pop back up every
        // time a coordinator property changes.
        if sessionChanged {
            context.coordinator.lastFocusedSessionId = activeId
            _ = cached.view.becomeFirstResponder()
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: HostCoordinator) {
        coordinator.removeKeyboardObservers()
        coordinator.removeFocusObservers()
    }

    // MARK: - Cache Lookup

    private func cachedOrMake(
        for sessionId: UUID,
        viewModel: TerminalViewModel,
        host: UIView
    ) -> CachedIOSTerminal {
        if let existing = coordinator.cachedTerminalView(for: sessionId) as? CachedIOSTerminal {
            return existing
        }
        let delegate = IOSTerminalCoordinator(viewModel: viewModel)
        let terminal = RelayTerminalView(frame: host.bounds)
        terminal.terminalDelegate = delegate
        terminal.nativeBackgroundColor = .black
        terminal.nativeForegroundColor = .white
        terminal.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        terminal.changeScrollback(10_000)
        terminal.onPasteImage = { [weak viewModel] imageData in
            viewModel?.sendPasteImage(imageData)
        }

        let cached = CachedIOSTerminal(view: terminal, delegate: delegate)
        coordinator.registerLiveTerminal(for: sessionId, view: cached)
        return cached
    }
}

// MARK: - Host Coordinator (keyboard + focus observers)

/// Owns the keyboard-visibility and focus/resign notification observers for
/// the terminal host. These are installed once per host (not per terminal)
/// so switching sessions doesn't register duplicate observers.
final class HostCoordinator: NSObject {
    private var isKeyboardVisible: Binding<Bool>
    private var focusObserver: Any?
    private var resignObserver: Any?
    private var keyboardShowObserver: Any?
    private var keyboardHideObserver: Any?
    /// Tracks which session was most recently focused so we only force-focus
    /// the terminal on actual session switches, not on every coordinator
    /// property publish.
    var lastFocusedSessionId: UUID?

    init(isKeyboardVisible: Binding<Bool>) {
        self.isKeyboardVisible = isKeyboardVisible
        super.init()
    }

    func installKeyboardObservers() {
        removeKeyboardObservers()
        keyboardShowObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardDidShowNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.isKeyboardVisible.wrappedValue = true
        }
        keyboardHideObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardDidHideNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.isKeyboardVisible.wrappedValue = false
        }
    }

    func removeKeyboardObservers() {
        if let obs = keyboardShowObserver {
            NotificationCenter.default.removeObserver(obs)
            keyboardShowObserver = nil
        }
        if let obs = keyboardHideObserver {
            NotificationCenter.default.removeObserver(obs)
            keyboardHideObserver = nil
        }
    }

    /// Installs focus/resign observers that act on the currently-visible
    /// terminal, resolved lazily via `activeTerminal()` — this avoids dangling
    /// references when session swaps change which terminal is front.
    func installFocusObservers(activeTerminal: @escaping () -> RelayTerminalView?) {
        removeFocusObservers()
        focusObserver = NotificationCenter.default.addObserver(
            forName: .terminalRequestFocus, object: nil, queue: .main
        ) { _ in
            _ = activeTerminal()?.becomeFirstResponder()
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: .terminalResignFocus, object: nil, queue: .main
        ) { _ in
            _ = activeTerminal()?.resignFirstResponder()
        }
    }

    func removeFocusObservers() {
        if let obs = focusObserver {
            NotificationCenter.default.removeObserver(obs)
            focusObserver = nil
        }
        if let obs = resignObserver {
            NotificationCenter.default.removeObserver(obs)
            resignObserver = nil
        }
    }
}

// MARK: - SwiftTerm Delegate

/// One instance per cached terminal. Holds a weak reference to the current
/// view model (which is re-assigned by `updateUIView` as sessions swap in).
final class IOSTerminalCoordinator: NSObject, TerminalViewDelegate {
    weak var viewModel: TerminalViewModel?

    init(viewModel: TerminalViewModel) {
        self.viewModel = viewModel
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        Task { @MainActor [weak self] in
            self?.viewModel?.sendInput(Data(data))
        }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard newCols > 0, newRows > 0 else { return }
        Task { @MainActor [weak self] in
            self?.viewModel?.sendResize(cols: UInt16(newCols), rows: UInt16(newRows))
            self?.viewModel?.terminalReady()
        }
    }

    func scrolled(source: TerminalView, position: Double) {}
    func setTerminalTitle(source: TerminalView, title: String) {
        Task { @MainActor [weak self] in
            self?.viewModel?.terminalTitle = title
            self?.viewModel?.onTitleChanged?(title)
        }
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
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
