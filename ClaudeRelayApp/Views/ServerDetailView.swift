import SwiftUI
import ClaudeRelayClient

/// Read-only server detail with connect, edit, duplicate, and delete actions.
struct ServerDetailView: View {
    @StateObject private var viewModel: ServerDetailViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showEditSheet = false
    @State private var showTimeoutAlert = false

    /// Called when the server list needs to refresh (after edit, duplicate, or delete).
    let onServerChanged: () -> Void

    init(server: ConnectionConfig, onServerChanged: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: ServerDetailViewModel(server: server))
        self.onServerChanged = onServerChanged
    }

    var body: some View {
        List {
            Section("Connection") {
                LabeledContent("Host", value: viewModel.server.host)
                LabeledContent("Port", value: String(viewModel.server.port))
                LabeledContent("TLS", value: viewModel.server.useTLS ? "On" : "Off")
                LabeledContent("Auth", value: viewModel.hasToken ? "Token saved" : "No token")
            }

            Section("Status") {
                HStack {
                    Circle()
                        .fill(viewModel.status?.isLive == true ? .green : .red)
                        .frame(width: 10, height: 10)
                    Text(viewModel.status?.isLive == true ? "Live" : "Offline")
                }
                if let status = viewModel.status {
                    LabeledContent("Sessions", value: "\(status.sessionCount)")
                }
            }

            Section {
                Button {
                    Task { await viewModel.connect() }
                } label: {
                    HStack {
                        Spacer()
                        if viewModel.isConnecting {
                            ProgressView()
                            Text("Connecting...")
                        } else {
                            Text("Connect")
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(viewModel.hasToken ? Color.red : Color(.systemGray5))
                .foregroundStyle(viewModel.hasToken ? .white : .black)
                .disabled(!viewModel.hasToken || viewModel.isConnecting)
            }

            Section("Management") {
                Button("Edit") {
                    showEditSheet = true
                }

                Button("Duplicate") {
                    _ = viewModel.duplicate()
                    onServerChanged()
                    dismiss()
                }

                Button("Delete", role: .destructive) {
                    viewModel.showDeleteConfirmation = true
                }
            }
        }
        .navigationTitle(viewModel.server.name)
        .task {
            await viewModel.refreshStatus()
        }
        .alert("Error", isPresented: $viewModel.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        }
        .alert("Delete Server", isPresented: $viewModel.showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                viewModel.delete()
                onServerChanged()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete \"\(viewModel.server.name)\"? This cannot be undone.")
        }
        .sheet(isPresented: $showEditSheet) {
            AddEditServerView(mode: .edit(viewModel.server)) { updatedConfig in
                viewModel.server = updatedConfig
                onServerChanged()
            }
        }
        .fullScreenCover(isPresented: $viewModel.isNavigatingToWorkspace) {
            viewModel.resetNavigationState()
        } content: {
            if let connection = viewModel.activeConnection,
               let token = viewModel.activeToken {
                WorkspaceView(
                    connection: connection,
                    token: token,
                    showTimeoutAlert: $showTimeoutAlert
                )
            }
        }
        .alert("Connection Timed Out", isPresented: $showTimeoutAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Connection timed out. Please reconnect.")
        }
    }
}
