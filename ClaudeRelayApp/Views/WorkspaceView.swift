import SwiftUI
import ClaudeRelayClient

/// Main workspace: NavigationSplitView with a session sidebar and terminal detail.
struct WorkspaceView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @StateObject private var coordinator: SessionCoordinator
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    @State private var showSidebarSheet = false
    @Environment(\.dismiss) private var dismiss

    init(connection: RelayConnection, token: String) {
        _coordinator = StateObject(wrappedValue: SessionCoordinator(
            connection: connection,
            token: token
        ))
    }

    /// Maps the sidebar button's columnVisibility toggle directly to showSidebarSheet on iPhone.
    private var sidebarSheetBinding: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { showSidebarSheet ? .all : .detailOnly },
            set: { newValue in showSidebarSheet = (newValue == .all) }
        )
    }

    var body: some View {
        Group {
            if sizeClass == .compact {
                // iPhone: detail-only with sidebar as a sheet
                ActiveTerminalView(
                    coordinator: coordinator,
                    columnVisibility: sidebarSheetBinding,
                    onDisconnect: { dismiss() }
                )
                .sheet(isPresented: $showSidebarSheet) {
                    NavigationStack {
                        SessionSidebarView(coordinator: coordinator)
                            .toolbar {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button("Done") { showSidebarSheet = false }
                                }
                            }
                    }
                    .presentationDetents([.medium, .large])
                }
            } else {
                // iPad: full split view
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
            }
        }
        .task {
            await coordinator.fetchSessions()
            if coordinator.activeSessionId == nil {
                if sizeClass == .compact {
                    showSidebarSheet = true
                } else {
                    columnVisibility = .all
                }
            }
        }
        .onChange(of: coordinator.activeSessionId) { _, newValue in
            if newValue != nil {
                withAnimation {
                    columnVisibility = .detailOnly
                    showSidebarSheet = false
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
