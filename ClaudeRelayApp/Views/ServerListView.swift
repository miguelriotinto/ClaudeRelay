import SwiftUI
import ClaudeRelayClient

/// Primary screen showing saved servers. Tap to connect, swipe for edit/delete.
struct ServerListView: View {
    @StateObject private var viewModel = ServerListViewModel()
    @State private var showAddSheet = false
    @State private var serverToEdit: ConnectionConfig?
    @State private var showTimeoutAlert = false

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.servers.isEmpty {
                    ContentUnavailableView {
                        Label("No Servers", systemImage: "server.rack")
                    } description: {
                        Text("Add a server to get started.")
                    } actions: {
                        Button("Add Server") {
                            showAddSheet = true
                        }
                    }
                } else {
                    List {
                        ForEach(viewModel.servers) { server in
                            Button {
                                Task { await viewModel.connect(to: server) }
                            } label: {
                                ServerRowView(
                                    server: server,
                                    status: viewModel.serverStatuses[server.id],
                                    isConnecting: viewModel.connectingServerId == server.id,
                                    isConnected: viewModel.connectedServerId == server.id
                                )
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    viewModel.deleteServer(id: server.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }

                                Button {
                                    serverToEdit = server
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                        }
                    }
                    .refreshable {
                        viewModel.refreshStatuses()
                    }
                }
            }
            .navigationTitle("Servers")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AddEditServerView(mode: .add) { _ in
                    viewModel.refreshServers()
                }
            }
            .sheet(item: $serverToEdit) { server in
                AddEditServerView(mode: .edit(server), onSave: { _ in
                    viewModel.refreshServers()
                }, onDelete: {
                    viewModel.deleteServer(id: server.id)
                })
            }
            .alert("Error", isPresented: $viewModel.showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "Unknown error")
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
            .onAppear {
                viewModel.refreshServers()
                viewModel.startPolling()
            }
        }
    }
}

// MARK: - Server Row

struct ServerRowView: View {
    let server: ConnectionConfig
    let status: ServerStatus?
    var isConnecting: Bool = false
    var isConnected: Bool = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(server.name)
                    .font(.body)
                    .fontWeight(.medium)
                Text(verbatim: "\(server.host):\(server.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(status?.isLive == true ? .green : .red)
                            .frame(width: 8, height: 8)
                        Text(status?.isLive == true ? "Live" : "Offline")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 4) {
                        Text("Sessions:")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(status?.sessionCount ?? 0)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if isConnecting {
                ProgressView()
            } else if isConnected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }
}

#Preview {
    ServerListView()
}
