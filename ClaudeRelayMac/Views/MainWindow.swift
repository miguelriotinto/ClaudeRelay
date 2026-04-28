import SwiftUI
import ClaudeRelayClient

struct MainWindow: View {
    @StateObject private var serverList = ServerListViewModel()
    @State private var coordinator: SessionCoordinator?
    @State private var showServerList = false
    @State private var loadFailure: String?

    var body: some View {
        Group {
            if let coordinator {
                WorkspaceView(coordinator: coordinator)
            } else if let failure = loadFailure {
                FailureView(message: failure) { showServerList = true }
            } else {
                ProgressView("Connecting...")
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
        .onDisappear { coordinator?.tearDown() }
    }

    private func attemptAutoConnect() async {
        guard let last = serverList.selectedConnection() else {
            showServerList = true
            return
        }
        await connect(to: last)
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
            }
        } catch {
            loadFailure = error.localizedDescription
        }
    }
}

private struct WorkspaceView: View {
    @ObservedObject var coordinator: SessionCoordinator

    var body: some View {
        NavigationSplitView {
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
