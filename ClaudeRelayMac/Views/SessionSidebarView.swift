import SwiftUI
import ClaudeRelayKit

struct SessionSidebarView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @State private var renameTarget: UUID?
    @State private var renameText: String = ""
    @State private var terminateTarget: UUID?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { coordinator.activeSessionId },
                set: { newId in
                    if let id = newId {
                        Task { await coordinator.switchToSession(id: id) }
                    }
                }
            )) {
                ForEach(coordinator.activeSessions, id: \.id) { session in
                    SessionRow(
                        name: coordinator.name(for: session.id),
                        shortId: String(session.id.uuidString.prefix(8)),
                        activity: activityFor(session.id),
                        createdAt: session.createdAt
                    )
                    .contextMenu {
                        Button("Rename") {
                            renameText = coordinator.name(for: session.id)
                            renameTarget = session.id
                        }
                        Divider()
                        Button("Terminate", role: .destructive) {
                            terminateTarget = session.id
                        }
                    }
                    .tag(session.id)
                }
            }
            .listStyle(.sidebar)

            Divider()
            Button {
                Task { await coordinator.createNewSession() }
            } label: {
                Label("New Session", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(12)
        }
        .alert("Rename Session", isPresented: .init(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let id = renameTarget {
                    coordinator.setName(renameText, for: id)
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .alert("Terminate Session?",
               isPresented: .init(
                get: { terminateTarget != nil },
                set: { if !$0 { terminateTarget = nil } }
               )) {
            Button("Terminate", role: .destructive) {
                if let id = terminateTarget {
                    Task { await coordinator.terminateSession(id: id) }
                }
                terminateTarget = nil
            }
            Button("Cancel", role: .cancel) { terminateTarget = nil }
        }
    }

    private func activityFor(_ id: UUID) -> ActivityState {
        if coordinator.isRunningClaude(sessionId: id) {
            return coordinator.sessionsAwaitingInput.contains(id) ? .claudeIdle : .claudeActive
        }
        return coordinator.sessionsAwaitingInput.contains(id) ? .idle : .active
    }
}

private struct SessionRow: View {
    let name: String
    let shortId: String
    let activity: ActivityState
    let createdAt: Date

    private var icon: String {
        switch activity {
        case .claudeActive: return "circle.fill"
        case .claudeIdle:   return "circle.lefthalf.filled"
        case .idle:         return "circle"
        case .active:       return "circle"
        }
    }
    private var iconColor: Color {
        switch activity {
        case .claudeActive: return .green
        case .claudeIdle:   return .orange
        case .idle, .active: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .font(.system(size: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body)
                Text(shortId)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospaced()
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}
