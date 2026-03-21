import SwiftUI
import ClaudeRelayClient

/// Main workspace: NavigationSplitView with a session sidebar and terminal detail.
struct WorkspaceView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var coordinator: SessionCoordinator
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    @Environment(\.dismiss) private var dismiss

    init(connection: RelayConnection, token: String) {
        _coordinator = StateObject(wrappedValue: SessionCoordinator(
            connection: connection,
            token: token
        ))
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SessionSidebarView(coordinator: coordinator)
        } detail: {
            ActiveTerminalView(
                coordinator: coordinator,
                columnVisibility: $columnVisibility,
                onDisconnect: { dismiss() }
            )
        }
        .navigationSplitViewStyle(.prominentDetail)
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await coordinator.fetchSessions()
            if coordinator.activeSessionId == nil {
                columnVisibility = .all
            }
        }
        .onChange(of: coordinator.activeSessionId) { _, newValue in
            if newValue != nil {
                withAnimation {
                    columnVisibility = .detailOnly
                }
            }
        }
        .onDisappear {
            coordinator.detachActive()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task {
                    await coordinator.handleForegroundTransition()
                }
            }
        }
        .alert("Error", isPresented: $coordinator.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(coordinator.errorMessage ?? "Unknown error")
        }
    }
}
