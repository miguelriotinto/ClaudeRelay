import SwiftUI
import ClaudeRelayKit

/// Sidebar content for the workspace: session list with quick switching.
struct SessionSidebarView: View {
    @ObservedObject var coordinator: SessionCoordinator

    var body: some View {
        List {
            Section {
                Button {
                    Task { await coordinator.createNewSession() }
                } label: {
                    Label("New Session", systemImage: "plus.rectangle")
                }
            }

            if coordinator.sessions.filter({ !$0.state.isTerminal }).isEmpty && !coordinator.isLoading {
                ContentUnavailableView(
                    "No Sessions",
                    systemImage: "terminal",
                    description: Text("Create a new session to get started.")
                )
            } else {
                Section("Sessions") {
                    ForEach(coordinator.sessions.filter { !$0.state.isTerminal }, id: \.id) { session in
                        SessionRow(
                            session: session,
                            name: coordinator.name(for: session.id),
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
    }
}

// MARK: - Session Row

private struct SessionRow: View {
    let session: SessionInfo
    let name: String
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

                Text(session.id.uuidString.prefix(8))
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
