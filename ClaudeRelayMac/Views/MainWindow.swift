import SwiftUI
import ClaudeRelayClient
import ClaudeRelaySpeech

struct MainWindow: View {
    @StateObject private var serverList = ServerListViewModel()
    @StateObject private var speechEngine = OnDeviceSpeechEngine()
    @State private var coordinator: SessionCoordinator?
    @State private var showServerList = false
    @State private var loadFailure: String?
    @State private var showQRPopover = false

    var body: some View {
        Group {
            if let coordinator {
                WorkspaceView(coordinator: coordinator)
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
                    showQRPopover = true
                } label: {
                    Label("Share via QR Code", systemImage: "qrcode")
                }
                .disabled(coordinator?.activeSessionId == nil)
                .popover(isPresented: $showQRPopover, arrowEdge: .bottom) {
                    if let coordinator, let id = coordinator.activeSessionId {
                        QRCodePopover(sessionId: id, sessionName: coordinator.name(for: id))
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await toggleRecording() }
                } label: {
                    Label(
                        speechEngine.state.isActive ? "Stop Recording" : "Record",
                        systemImage: speechEngine.state.isActive ? "stop.circle.fill" : "mic"
                    )
                }
                .disabled(coordinator?.activeSessionId == nil)
            }
        }
        .task { await attemptAutoConnect() }
        .sheet(isPresented: $showServerList) {
            NavigationStack {
                ServerListWindow { config in
                    Task { await connect(to: config) }
                    showServerList = false
                }
            }
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

    private func toggleRecording() async {
        if speechEngine.state.isActive {
            let settings = AppSettings.shared
            let text = await speechEngine.stopAndProcess(
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
        } else {
            await speechEngine.startRecording()
        }
    }
}

private struct WorkspaceView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SessionSidebarView(coordinator: coordinator)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            VStack(spacing: 0) {
                if let activeId = coordinator.activeSessionId,
                   let vm = coordinator.viewModel(for: activeId) {
                    TerminalContainerView(viewModel: vm)
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
        }
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
