import SwiftUI
import ClaudeRelayClient

/// Host/token configuration screen. Entry point of the app.
struct ConnectionView: View {
    @StateObject private var viewModel = ConnectionViewModel()
    @State private var showTimeoutAlert = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Name (optional)", text: $viewModel.name)
                        .textContentType(.name)
                        .autocorrectionDisabled()

                    TextField("Host", text: $viewModel.host)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    TextField("Port", text: $viewModel.port)
                        .keyboardType(.numberPad)

                    SecureField("Token", text: $viewModel.token)

                    Toggle("Use TLS", isOn: $viewModel.useTLS)
                }

                Section {
                    Button {
                        Task { await viewModel.connect() }
                    } label: {
                        if viewModel.isConnecting {
                            HStack {
                                ProgressView()
                                Text("Connecting...")
                            }
                        } else {
                            Text("Connect")
                        }
                    }
                    .disabled(viewModel.host.isEmpty || viewModel.isConnecting)
                }

                if !viewModel.savedConnections.isEmpty {
                    Section("Saved Connections") {
                        ForEach(viewModel.savedConnections) { config in
                            let status = viewModel.serverStatuses[config.id]
                            Button {
                                viewModel.fillFromSaved(config)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(config.name)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                    Text(verbatim: "\(config.host):\(config.port)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    HStack(spacing: 12) {
                                        HStack(spacing: 4) {
                                            Circle()
                                                .fill(status?.isLive == true ? .green : .red)
                                                .frame(width: 8, height: 8)
                                            Text("Live")
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
                        .onDelete(perform: viewModel.deleteConnection)
                    }
                }
            }
            .onAppear { viewModel.refreshStatuses() }
            .navigationTitle("ClaudeRelay")
            .navigationDestination(isPresented: $viewModel.isNavigatingToSessions) {
                if let connection = viewModel.activeConnection,
                   let token = viewModel.activeToken {
                    WorkspaceView(
                        connection: connection,
                        token: token,
                        showTimeoutAlert: $showTimeoutAlert
                    )
                }
            }
            .alert("Error", isPresented: $viewModel.showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "Unknown error")
            }
            .alert("Connection Timed Out", isPresented: $showTimeoutAlert) {
                Button("Reconnect", role: .cancel) {}
            } message: {
                Text("Connection timed out. Please reconnect.")
            }
        }
    }
}

#Preview {
    ConnectionView()
}
