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
                            Button {
                                viewModel.fillFromSaved(config)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(config.name)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                    Text(verbatim: "\(config.host):\(config.port)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete(perform: viewModel.deleteConnection)
                    }
                }
            }
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
