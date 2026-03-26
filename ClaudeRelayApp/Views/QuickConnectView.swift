import SwiftUI
import ClaudeRelayClient

/// Modal sheet for one-off connections without persisting a server config.
/// Offers "Connect (Temporary)" and "Save & Connect" options.
struct QuickConnectView: View {
    @StateObject private var viewModel = QuickConnectViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var showTimeoutAlert = false

    /// Called when a server was saved via "Save & Connect", so the list can refresh.
    let onServerSaved: (() -> Void)?

    init(onServerSaved: (() -> Void)? = nil) {
        self.onServerSaved = onServerSaved
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Host", text: $viewModel.host)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    TextField("Port", text: $viewModel.port)
                        .keyboardType(.numberPad)

                    SecureField("Auth Token", text: $viewModel.token)

                    Toggle("Use TLS", isOn: $viewModel.useTLS)
                }

                Section {
                    Button {
                        Task { await viewModel.connectTemporary() }
                    } label: {
                        HStack {
                            Spacer()
                            if viewModel.isConnecting {
                                ProgressView()
                                Text("Connecting...")
                            } else {
                                Text("Connect (Temporary)")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(viewModel.isValid ? Color.red : Color(.systemGray5))
                    .foregroundStyle(viewModel.isValid ? .white : .black)
                    .disabled(!viewModel.isValid || viewModel.isConnecting)

                    Button {
                        Task { await viewModel.saveAndConnect() }
                    } label: {
                        HStack {
                            Spacer()
                            Text("Save & Connect")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .disabled(!viewModel.isValid || viewModel.isConnecting)
                }
            }
            .navigationTitle("Quick Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Error", isPresented: $viewModel.showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "Unknown error")
            }
            .fullScreenCover(isPresented: $viewModel.isNavigatingToWorkspace) {
                viewModel.resetNavigationState()
                if viewModel.didSaveServer {
                    onServerSaved?()
                }
                dismiss()
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
}

#Preview {
    QuickConnectView()
}
