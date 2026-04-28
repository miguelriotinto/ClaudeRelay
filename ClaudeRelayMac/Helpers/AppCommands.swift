import SwiftUI

/// FocusedValue key so menu bar commands can access the active SessionCoordinator.
struct SessionCoordinatorKey: FocusedValueKey {
    typealias Value = SessionCoordinator
}

extension FocusedValues {
    var sessionCoordinator: SessionCoordinator? {
        get { self[SessionCoordinatorKey.self] }
        set { self[SessionCoordinatorKey.self] = newValue }
    }
}

struct AppCommands: Commands {
    @FocusedValue(\.sessionCoordinator) var coordinator: SessionCoordinator?

    var body: some Commands {
        // Replace the default New item in the File menu.
        CommandGroup(replacing: .newItem) {
            Button("New Session") {
                guard let coordinator else { return }
                Task { await coordinator.createNewSession() }
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(coordinator == nil)
        }

        // Add a Session menu between View and Window.
        CommandMenu("Session") {
            Button("Detach Current") {
                guard let coordinator, let id = coordinator.activeSessionId else { return }
                Task { await coordinator.detachSession(id: id) }
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(coordinator?.activeSessionId == nil)

            Button("Terminate Current") {
                guard let coordinator, let id = coordinator.activeSessionId else { return }
                Task { await coordinator.terminateSession(id: id) }
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            .disabled(coordinator?.activeSessionId == nil)

            Divider()

            Button("Next Session") {
                coordinator?.switchToNextSession()
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])

            Button("Previous Session") {
                coordinator?.switchToPreviousSession()
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
        }
    }
}
