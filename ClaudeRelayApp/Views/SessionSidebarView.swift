import SwiftUI
import ClaudeRelayKit

/// Sidebar content for the workspace: session list with quick switching.
struct SessionSidebarView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @State private var showAttachSheet = false
    @State private var attachableSessions: [SessionInfo] = []
    @State private var isLoadingAttachable = false

    var body: some View {
        List {
            Section {
                Button {
                    Task { await coordinator.createNewSession() }
                } label: {
                    Label("New Session", systemImage: "plus.rectangle")
                }
                Button {
                    isLoadingAttachable = true
                    Task {
                        attachableSessions = await coordinator.fetchAttachableSessions()
                        isLoadingAttachable = false
                        showAttachSheet = true
                    }
                } label: {
                    Label("Attach Session", systemImage: "arrow.triangle.branch")
                }
                .disabled(isLoadingAttachable)
            }

            if coordinator.activeSessions.isEmpty && !coordinator.isLoading {
                ContentUnavailableView(
                    "No Sessions",
                    systemImage: "terminal",
                    description: Text("Create a new session to get started.")
                )
            } else {
                Section("Sessions") {
                    ForEach(coordinator.activeSessions, id: \.id) { session in
                        SessionRow(
                            session: session,
                            name: coordinator.name(for: session.id),
                            shortId: String(session.id.uuidString.prefix(8)),
                            isActive: session.id == coordinator.activeSessionId,
                            onRename: { newName in
                                coordinator.setName(newName, for: session.id)
                            }
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            Task { await coordinator.switchToSession(id: session.id) }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                Task { await coordinator.terminateSession(id: session.id) }
                            } label: {
                                Label("Kill", systemImage: "xmark.circle")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Sessions")
        .refreshable {
            await coordinator.fetchSessions()
        }
        .overlay {
            if coordinator.isLoading && coordinator.sessions.isEmpty {
                ProgressView("Loading...")
            }
        }
        .sheet(isPresented: $showAttachSheet) {
            AttachSessionSheet(
                sessions: attachableSessions,
                coordinator: coordinator,
                isPresented: $showAttachSheet
            )
        }
    }
}

// MARK: - Session Row

private struct SessionRow: View {
    let session: SessionInfo
    let name: String
    let shortId: String
    let isActive: Bool
    let onRename: (String) -> Void

    @State private var isEditing = false
    @State private var editedName = ""

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isActive ? .green : .clear)
                .frame(width: 8, height: 8)

            // Left: name + ID/time stacked
            VStack(alignment: .leading, spacing: 3) {
                if isEditing {
                    TextField("Name", text: $editedName, onCommit: {
                        let trimmed = editedName.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty { onRename(trimmed) }
                        isEditing = false
                    })
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .textFieldStyle(.plain)
                } else {
                    Text(name)
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Text(shortId)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            // Right: badge + time stacked
            VStack(alignment: .trailing, spacing: 3) {
                Text(session.state.rawValue)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(badgeColor.opacity(0.15))
                    .foregroundStyle(badgeColor)
                    .clipShape(Capsule())

                Text(session.createdAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            Button {
                editedName = name
                isEditing = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
        }
    }

    private var badgeColor: SwiftUI.Color {
        switch session.state {
        case .activeAttached, .activeDetached: return .green
        case .created, .starting, .resuming: return .yellow
        case .exited, .failed, .terminated, .expired: return .red
        }
    }
}

// MARK: - Attach Session Sheet

private struct AttachSessionSheet: View {
    let sessions: [SessionInfo]
    let coordinator: SessionCoordinator
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView(
                        "No Sessions Available",
                        systemImage: "terminal",
                        description: Text("There are no other sessions running on the server.")
                    )
                } else {
                    List(sessions, id: \.id) { session in
                        Button {
                            isPresented = false
                            Task { await coordinator.attachRemoteSession(id: session.id) }
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(coordinator.name(for: session.id))
                                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                                        .lineLimit(1)

                                    Text(String(session.id.uuidString.prefix(8)))
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }

                                Spacer()

                                Text(session.state.rawValue)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(attachBadgeColor(session.state).opacity(0.15))
                                    .foregroundStyle(attachBadgeColor(session.state))
                                    .clipShape(Capsule())
                            }
                        }
                        .tint(.primary)
                    }
                }
            }
            .navigationTitle("Attach Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func attachBadgeColor(_ state: SessionState) -> SwiftUI.Color {
        switch state {
        case .activeAttached, .activeDetached: return .green
        case .created, .starting, .resuming: return .yellow
        case .exited, .failed, .terminated, .expired: return .red
        }
    }
}
