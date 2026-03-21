import SwiftUI
import CodeRelayClient

/// Displays active sessions and allows creating or resuming them.
struct SessionListView: View {
    @StateObject private var viewModel: SessionListViewModel

    init(connection: RelayConnection, token: String) {
        _viewModel = StateObject(wrappedValue: SessionListViewModel(
            connection: connection,
            token: token
        ))
    }

    var body: some View {
        List {
            Section {
                Button {
                    Task { await viewModel.createNewSession() }
                } label: {
                    Label("New Session", systemImage: "plus.rectangle")
                }
            }

            if viewModel.sessions.isEmpty && !viewModel.isLoading {
                Section {
                    ContentUnavailableView(
                        "No Sessions",
                        systemImage: "terminal",
                        description: Text("Tap \"New Session\" to start one.")
                    )
                }
            } else {
                Section("Sessions") {
                    ForEach(viewModel.sessions, id: \.id) { session in
                        Button {
                            Task { await viewModel.resumeSession(id: session.id) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(session.id.uuidString.prefix(8))
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(.primary)
                                    Text(session.createdAt, style: .relative)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Text(session.state.rawValue)
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(badgeColor(for: session.state).opacity(0.2))
                                    .foregroundStyle(badgeColor(for: session.state))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Sessions")
        .navigationDestination(isPresented: $viewModel.isNavigatingToTerminal) {
            if let sessionId = viewModel.activeSessionId {
                TerminalContainerView(
                    connection: viewModel.connection,
                    sessionId: sessionId
                )
            }
        }
        .refreshable {
            await viewModel.fetchSessions()
        }
        .task {
            await viewModel.fetchSessions()
        }
        .overlay {
            if viewModel.isLoading && viewModel.sessions.isEmpty {
                ProgressView("Loading sessions...")
            }
        }
        .alert("Error", isPresented: $viewModel.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        }
    }

    // MARK: - Helpers

    private func badgeColor(for state: SessionState) -> Color {
        switch state {
        case .activeAttached, .activeDetached:
            return .green
        case .created, .starting, .resuming:
            return .yellow
        case .exited, .failed, .terminated, .expired:
            return .red
        }
    }
}
