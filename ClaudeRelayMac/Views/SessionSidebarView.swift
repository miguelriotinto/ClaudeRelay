import SwiftUI
import ClaudeRelayKit

struct SessionSidebarView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @State private var renameTarget: UUID?
    @State private var renameText: String = ""
    @State private var terminateTarget: UUID?
    @State private var showAttachSheet = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
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
                            agentId: coordinator.activeAgent(for: session.id),
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
                .scrollContentBackground(.hidden)
                // SwiftUI's default List(selection:) auto-scroll on selection
                // change can place the selected row partially under the window
                // titlebar on macOS. Re-anchor it to the vertical center after
                // the built-in scroll settles so the row lands fully visible.
                .onChange(of: coordinator.activeSessionId) { _, newId in
                    guard let newId else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(newId, anchor: .center)
                        }
                    }
                }
            }

            Divider()
            HStack {
                Button {
                    Task { await coordinator.createNewSession() }
                } label: {
                    Label("New", systemImage: "plus")
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    showAttachSheet = true
                } label: {
                    Label("Attach", systemImage: "rectangle.connected.to.line.below")
                }
                .buttonStyle(.plain)
            }
            .padding(12)
        }
        .background(.black)
        .sheet(isPresented: $showAttachSheet) {
            AttachRemoteSessionSheet(coordinator: coordinator)
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
        if coordinator.isRunningAgent(sessionId: id) {
            return coordinator.sessionsAwaitingInput.contains(id) ? .agentIdle : .agentActive
        }
        return coordinator.sessionsAwaitingInput.contains(id) ? .idle : .active
    }
}

private struct SessionRow: View {
    let name: String
    let shortId: String
    let activity: ActivityState
    let agentId: String?
    let createdAt: Date

    var body: some View {
        HStack(spacing: 8) {
            ActivityDot(activity: activity, agentId: agentId, size: 6)
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

struct ConnectionQualityDot: View {
    let quality: ConnectionQuality
    var size: CGFloat = 8
    @State private var blinkOpacity: Double = 1.0

    private var color: Color {
        switch quality {
        case .excellent, .good: return .green
        case .poor, .veryPoor: return .yellow
        case .disconnected: return .red
        }
    }

    private var shouldBlink: Bool {
        quality == .good || quality == .veryPoor
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .fixedSize()
            .opacity(shouldBlink ? blinkOpacity : 1.0)
            .onChange(of: quality) { _, newValue in
                let blink = newValue == .good || newValue == .veryPoor
                if blink {
                    withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                        blinkOpacity = 0.3
                    }
                } else {
                    withAnimation(.default) {
                        blinkOpacity = 1.0
                    }
                }
            }
            .onAppear {
                if shouldBlink {
                    withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                        blinkOpacity = 0.3
                    }
                }
            }
    }
}

struct ActivityDot: View {
    let activity: ActivityState
    var agentId: String?
    var size: CGFloat = 8
    @State private var blinkOpacity: Double = 1.0

    private var color: Color {
        switch activity {
        case .active, .idle: return .green
        case .agentActive, .agentIdle:
            return AgentColorPalette.color(for: agentId)
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .fixedSize()
            .opacity(activity == .agentIdle ? blinkOpacity : 1.0)
            .onChange(of: activity) { _, newValue in
                if newValue == .agentIdle {
                    withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                        blinkOpacity = 0.3
                    }
                } else {
                    withAnimation(.default) {
                        blinkOpacity = 1.0
                    }
                }
            }
            .onAppear {
                if activity == .agentIdle {
                    withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                        blinkOpacity = 0.3
                    }
                }
            }
    }
}
