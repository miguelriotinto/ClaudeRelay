import SwiftUI
import ClaudeRelayClient

/// Primary screen showing saved servers. No editable fields — just browse, tap, connect.
struct ServerListView: View {
    @StateObject private var viewModel = ServerListViewModel()
    @State private var showAddSheet = false

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
                            NavigationLink {
                                ServerDetailView(server: server) {
                                    viewModel.refreshServers()
                                }
                            } label: {
                                ServerRowView(
                                    server: server,
                                    status: viewModel.serverStatuses[server.id]
                                )
                            }
                        }
                        .onDelete(perform: viewModel.deleteServer(at:))
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

    var body: some View {
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
    }
}

#Preview {
    ServerListView()
}
