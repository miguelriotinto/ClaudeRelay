import SwiftUI
import ClaudeRelayClient

struct MainWindow: View {
    @StateObject private var serverList = ServerListViewModel()
    @State private var coordinator: SessionCoordinator?
    @State private var showServerList = false
    @State private var loadFailure: String?

    var body: some View {
        Group {
            if let coordinator,
               let activeId = coordinator.activeSessionId,
               let vm = coordinator.viewModel(for: activeId) {
                TerminalContainerView(viewModel: vm)
            } else if let failure = loadFailure {
                VStack(spacing: 12) {
                    Text("Cannot connect")
                        .font(.title2)
                    Text(failure)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("Choose Server") { showServerList = true }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .task {
            await attemptAutoConnect()
        }
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
        }
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
                loadFailure = "No token stored for this server. Open Servers to re-enter."
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
