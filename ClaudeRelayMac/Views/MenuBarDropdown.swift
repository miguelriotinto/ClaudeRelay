import SwiftUI
import AppKit
import ClaudeRelayKit

struct MenuBarDropdown: View {
    @StateObject private var viewModel = MenuBarViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header: connection
            HStack(spacing: 6) {
                Circle()
                    .fill(viewModel.connectionColor)
                    .frame(width: 8, height: 8)
                Text(viewModel.connectionLabel)
                    .font(.headline)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            // Session list
            if viewModel.sessions.isEmpty {
                Text("No active sessions")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(viewModel.sessions, id: \.id) { session in
                        SessionMenuRow(
                            session: session,
                            activity: viewModel.activityStates[session.id] ?? .active,
                            isActive: session.id == viewModel.activeSessionId,
                            onSelect: { activate(sessionId: session.id) }
                        )
                    }
                }
            }

            Divider()

            // Actions
            VStack(alignment: .leading, spacing: 2) {
                MenuButton(label: "Open Window") {
                    NSApp.activate(ignoringOtherApps: true)
                    for window in NSApp.windows where window.canBecomeMain {
                        window.makeKeyAndOrderFront(nil)
                        return
                    }
                }
                MenuButton(label: "Preferences...") {
                    NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                }
                MenuButton(label: "Quit Claude Relay") {
                    NSApp.terminate(nil)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(width: 280)
    }

    private func activate(sessionId: UUID) {
        if let coordinator = ActiveCoordinatorRegistry.shared.coordinator {
            Task { await coordinator.switchToSession(id: sessionId) }
        }
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }
}

private struct SessionMenuRow: View {
    let session: SessionInfo
    let activity: ActivityState
    let isActive: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                    .font(.system(size: 10))
                Text(session.name ?? String(session.id.uuidString.prefix(8)))
                    .foregroundStyle(.primary)
                Spacer()
                if isActive {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.blue)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var icon: String {
        switch activity {
        case .claudeActive: return "circle.fill"
        case .claudeIdle:   return "circle.lefthalf.filled"
        case .idle, .active: return "circle"
        }
    }
    private var iconColor: Color {
        switch activity {
        case .claudeActive: return .green
        case .claudeIdle:   return .orange
        case .idle, .active: return .secondary
        }
    }
}

private struct MenuButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
