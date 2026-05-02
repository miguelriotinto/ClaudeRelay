import SwiftUI
import ClaudeRelayClient
import ClaudeRelaySpeech

struct MainWindow: View {
    @StateObject private var serverList = ServerListViewModel()
    @StateObject private var speechEngine = OnDeviceSpeechEngine()
    @State private var coordinator: SessionCoordinator?
    @State private var showServerList = false
    @State private var showSettings = false
    @State private var loadFailure: String?

    var body: some View {
        Group {
            if let coordinator {
                WorkspaceView(coordinator: coordinator, speechEngine: speechEngine)
            } else if let failure = loadFailure {
                FailureView(message: failure) { showServerList = true }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("Select a server to connect")
                        .foregroundStyle(.secondary)
                    Button("Choose Server") { showServerList = true }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.black)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    showServerList = true
                } label: {
                    Label("Servers", systemImage: "server.rack")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gear")
                }
            }
        }
        .task { await attemptAutoConnect() }
        .task { await preloadSpeechModels() }
        .sheet(isPresented: $showServerList) {
            NavigationStack {
                ServerListWindow { config in
                    Task { await connect(to: config) }
                    showServerList = false
                }
            }
            .background(.black)
            .presentationBackground(.black)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .presentationBackground(.black)
        }
        .onDisappear {
            coordinator?.tearDown()
            ActiveCoordinatorRegistry.shared.clear()
        }
        .preferredColorScheme(.dark)
        .focusedValue(\.sessionCoordinator, coordinator)
    }

    private func attemptAutoConnect() async {
        showServerList = true
    }

    private func preloadSpeechModels() async {
        let store = SpeechModelStore.shared

        if !store.modelsReady {
            try? await store.downloadAllModels()
        }

        guard store.modelsReady else { return }

        let transcriber = WhisperTranscriber.shared
        if !transcriber.isLoaded {
            try? await transcriber.loadModel()
        }

        let cleaner = TextCleaner.shared
        if !cleaner.isLoaded {
            cleaner.modelPath = store.llmModelPath
            try? cleaner.loadModel(from: store.llmModelPath)
        }
    }

    private func connect(to config: ConnectionConfig) async {
        loadFailure = nil
        do {
            guard let token = try AuthManager.shared.loadToken(for: config.id) else {
                loadFailure = "No token stored for this server."
                return
            }
            let c = SessionCoordinator(config: config, token: token)
            coordinator = c
            await c.start()
            if let err = c.errorMessage {
                loadFailure = err
                coordinator = nil
            } else {
                ActiveCoordinatorRegistry.shared.register(coordinator: c, serverName: config.name)
            }
        } catch {
            loadFailure = error.localizedDescription
        }
    }

}

private struct WorkspaceView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @ObservedObject var speechEngine: OnDeviceSpeechEngine
    @StateObject private var settings = AppSettings.shared
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showQRPopover = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SessionSidebarView(coordinator: coordinator)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            VStack(spacing: 0) {
                if let activeId = coordinator.activeSessionId,
                   let vm = coordinator.viewModel(for: activeId) {
                    TerminalContainerView(viewModel: vm, fontSize: CGFloat(settings.terminalFontSize))
                        .padding(.leading, 6)
                        .id(activeId)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "terminal")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("No session selected")
                            .foregroundStyle(.secondary)
                        Button("New Session") {
                            Task { await coordinator.createNewSession() }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider()
                StatusBarView(coordinator: coordinator)
            }
            .background(.black)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showQRPopover = true
                } label: {
                    Label("Share via QR Code", systemImage: "qrcode")
                }
                .disabled(coordinator.activeSessionId == nil)
                .popover(isPresented: $showQRPopover, arrowEdge: .bottom) {
                    if let id = coordinator.activeSessionId {
                        QRCodePopover(sessionId: id, sessionName: coordinator.name(for: id))
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                MacMicButton(engine: speechEngine, coordinator: coordinator, hasActiveSession: coordinator.activeSessionId != nil)
            }
        }
        .toolbarBackground(.black, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .focusedValue(\.sidebarVisibility, $columnVisibility)
        .sheet(isPresented: $coordinator.showQRScanner) {
            QRScannerSheet(coordinator: coordinator)
        }
        .sheet(isPresented: $coordinator.isRecovering) {
            RecoverySheet(
                phase: coordinator.recoveryPhase,
                onCancel: {
                    coordinator.recoveryTask?.cancel()
                    coordinator.recoveryTask = nil
                }
            )
            .interactiveDismissDisabled()
        }
    }
}

private struct RecoverySheet: View {
    let phase: SharedSessionCoordinator.RecoveryPhase
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .scaleEffect(1.2)
            Text("Reconnecting")
                .font(.headline)
            Text(phase.label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .contentTransition(.interpolate)
                .animation(.easeInOut(duration: 0.25), value: phase.label)
            Spacer()
            Button("Cancel", role: .cancel) { onCancel() }
                .controlSize(.large)
                .padding(.bottom, 16)
        }
        .frame(width: 280, height: 200)
    }
}

private struct FailureView: View {
    let message: String
    let onChooseServer: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("Cannot connect")
                .font(.title2)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Choose Server") { onChooseServer() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Mic Button (matches iOS styling)

private struct MacMicButton: View {
    @ObservedObject var engine: OnDeviceSpeechEngine
    let coordinator: SessionCoordinator?
    let hasActiveSession: Bool
    @State private var showDownloadAlert = false

    var body: some View {
        Button {
            handleTap()
        } label: {
            Group {
                if let progress = engine.modelStore.downloadProgress {
                    progressRing(progress)
                } else if engine.state == .loadingModel, let progress = engine.modelLoadProgress {
                    progressRing(progress)
                } else {
                    Image(systemName: buttonIcon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 26, height: 26)
            .background(buttonColor)
            .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(engine.state.description)
        .alert("Download Speech Models?", isPresented: $showDownloadAlert) {
            Button("Download") {
                Task { await engine.prepareModels() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("On-device voice recognition requires a one-time download (~1 GB). This enables offline, private speech-to-text.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSpeechRecording)) { _ in
            guard !isDisabled else { return }
            handleTap()
        }
    }

    private func progressRing(_ progress: Double) -> some View {
        ZStack {
            Circle()
                .stroke(Color.gray.opacity(0.4), lineWidth: 2)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.3), value: progress)
        }
        .frame(width: 16, height: 16)
    }

    private func handleTap() {
        switch engine.state {
        case .idle:
            guard engine.modelsReady else {
                showDownloadAlert = true
                return
            }
            Task { await engine.startRecording() }
        case .recording:
            Task {
                let settings = AppSettings.shared
                let text = await engine.stopAndProcess(
                    smartCleanup: settings.smartCleanupEnabled,
                    promptEnhancement: settings.promptEnhancementEnabled,
                    bearerToken: settings.bedrockBearerToken,
                    region: settings.bedrockRegion
                )
                if let text, !text.isEmpty,
                   let coordinator,
                   let id = coordinator.activeSessionId,
                   let vm = coordinator.viewModel(for: id) {
                    vm.sendInput(text)
                }
            }
        case .error:
            engine.cancel()
        default:
            break
        }
    }

    private var isDisabled: Bool {
        switch engine.state {
        case .loadingModel, .transcribing, .cleaning:
            return true
        default:
            return !hasActiveSession || engine.modelStore.downloadProgress != nil
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

    private var buttonColor: Color {
        switch engine.state {
        case .idle, .loadingModel: return Color.gray.opacity(0.5)
        case .recording: return Color.red.opacity(0.8)
        case .transcribing, .cleaning: return Color.yellow.opacity(0.8)
        case .error: return Color.red.opacity(0.8)
        }
    }
}
