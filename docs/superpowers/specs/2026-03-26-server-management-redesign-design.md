# Server Management UX Redesign

**Date:** 2026-03-26
**Status:** Approved

## Problem

The current `ConnectionView` conflates server configuration (defining a server) with execution (connecting to a server). This creates hidden state, implicit behaviors, and non-obvious affordances:

- Connecting implicitly creates/updates a saved server
- Tapping a saved connection auto-fills the form (implicit state copy)
- The form serves dual purpose: both config entry and connection trigger

## Design Principle

Strict separation of concerns:

- **Server Definition** = persistent configuration (Add/Edit)
- **Connection** = explicit action on a defined server (Connect button)

No implicit creation. No silent state copying. No dual-purpose screens.

## View Hierarchy & Navigation

```
ServerListView (app entry point, replaces ConnectionView)
  +-- [+] --> AddEditServerView (sheet, add mode)
  +-- [Quick Connect] --> QuickConnectView (sheet)
  +-- Tap server --> ServerDetailView (push)
        +-- [Connect] --> WorkspaceView (fullScreenCover)
        +-- [Edit] --> AddEditServerView (sheet, edit mode)
        +-- [Duplicate] --> creates copy, returns to list
        +-- [Delete] --> confirms, pops to list
```

### ServerListView (Primary Screen)

Replaces `ConnectionView` as the app entry point. Displays saved servers as a list with status indicators. No editable fields on this screen.

**Content per server row:**
- Server name
- Host:port subtitle
- Live/Offline indicator (green/red dot)
- Session count

**Toolbar:**
- "+" button (top right) -- presents AddEditServerView as sheet in add mode
- "Quick Connect" button -- presents QuickConnectView as sheet

**Behavior:**
- Tap server row pushes to ServerDetailView
- Swipe to delete with confirmation
- Pull to refresh statuses
- Status polling starts on appear, stops on disappear

### ServerDetailView (Operational Hub)

Pushed via NavigationStack from the server list. Read-only display of server configuration with action buttons.

**Sections:**

1. **Connection Info** (read-only)
   - Host
   - Port
   - TLS status
   - Auth: "Token saved" or "No token" (never shows actual token)

2. **Status**
   - Live/Offline indicator
   - Session count

3. **Actions**
   - Connect button (primary, red background when ready, navigates to WorkspaceView via fullScreenCover)

4. **Management**
   - Edit (presents AddEditServerView sheet in edit mode)
   - Duplicate (creates copy named "Copy of {name}", saves, pops to list)
   - Delete (confirmation alert, removes from store + Keychain, pops to list)

### AddEditServerView (Configuration Only)

Presented as a modal sheet. Used for both adding new servers and editing existing ones. This screen is ONLY for configuration -- no connection happens here.

**Fields:**
- Server Name (required)
- Host (required)
- Port (defaults to 9200)
- Auth Token (secure field)
- Use TLS toggle

**Modes:**
- `.add` -- blank form, "Save Server" button
- `.edit(ConnectionConfig)` -- pre-filled form, "Save Changes" button

**Behavior:**
- Save validates (host required), persists to SavedConnectionStore, saves token to Keychain
- Save dismisses sheet
- Accepts `onSave: (ConnectionConfig) -> Void` closure for parent to react

### QuickConnectView (Ephemeral Flow)

Presented as a modal sheet from the server list. For one-off connections without persisting a server config.

**Fields:**
- Host (required)
- Port (defaults to 9200)
- Auth Token (secure field)
- Use TLS toggle

**Buttons:**
- "Connect (Temporary)" -- connects without saving, presents WorkspaceView
- "Save & Connect" -- saves as new server, then connects, presents WorkspaceView

**Behavior:**
- Manages its own fullScreenCover for WorkspaceView internally
- On WorkspaceView dismiss, auto-dismisses the sheet via `@Environment(\.dismiss)`
- For "Save & Connect", accepts `onServerSaved: () -> Void` so the list can refresh after the sheet dismisses

### WorkspaceView (Unchanged)

Presented as fullScreenCover from ServerDetailView or QuickConnectView. Receives `RelayConnection` and token as before. Session management (create, switch, terminate) remains inside WorkspaceView via SessionCoordinator.

## View Models

### ServerListViewModel

```
@Published var servers: [ConnectionConfig]
@Published var serverStatuses: [UUID: ServerStatus]

init()                    -- loads from SavedConnectionStore, starts polling
refreshServers()          -- reloads from SavedConnectionStore
refreshStatuses()         -- triggers ServerStatusChecker
deleteServer(id:)         -- removes from store + Keychain
```

Owns a `ServerStatusChecker` instance. Starts polling on init, provides `refresh` methods for pull-to-refresh and post-mutation updates.

### ServerDetailViewModel

```
init(server: ConnectionConfig)

@Published var status: ServerStatus?
@Published var isConnecting: Bool
@Published var activeConnection: RelayConnection?
@Published var activeToken: String?
@Published var isNavigatingToWorkspace: Bool
@Published var errorMessage: String?
@Published var showError: Bool

connect()                 -- loads token from Keychain, creates RelayConnection, authenticates
duplicate() -> ConnectionConfig  -- saves "Copy of {name}" to store
delete()                  -- removes from store + Keychain
resetNavigationState()    -- clears connection state after workspace dismissal
```

### AddEditServerViewModel

```
enum Mode { case add, edit(ConnectionConfig) }

init(mode: Mode)

@Published var name: String
@Published var host: String
@Published var port: String
@Published var token: String
@Published var useTLS: Bool

var isValid: Bool         -- computed: !host.isEmpty
save() -> ConnectionConfig?  -- validates, saves to store + Keychain, returns config
```

Pre-fills fields from config in edit mode. In edit mode, preserves the original config's UUID to avoid orphaning Keychain tokens.

### QuickConnectViewModel

```
@Published var host: String
@Published var port: String = "9200"
@Published var token: String
@Published var useTLS: Bool = false
@Published var isConnecting: Bool
@Published var activeConnection: RelayConnection?
@Published var activeToken: String?
@Published var isNavigatingToWorkspace: Bool
@Published var errorMessage: String?
@Published var showError: Bool

var isValid: Bool         -- computed: !host.isEmpty
connectTemporary()        -- creates RelayConnection, authenticates, does NOT save
saveAndConnect()          -- saves to store first, then connects
resetNavigationState()    -- clears connection state after workspace dismissal
```

## File Changes

### New Files (8)

- `ClaudeRelayApp/Views/ServerListView.swift`
- `ClaudeRelayApp/Views/ServerDetailView.swift`
- `ClaudeRelayApp/Views/AddEditServerView.swift`
- `ClaudeRelayApp/Views/QuickConnectView.swift`
- `ClaudeRelayApp/ViewModels/ServerListViewModel.swift`
- `ClaudeRelayApp/ViewModels/ServerDetailViewModel.swift`
- `ClaudeRelayApp/ViewModels/AddEditServerViewModel.swift`
- `ClaudeRelayApp/ViewModels/QuickConnectViewModel.swift`

### Modified Files (1)

- `ClaudeRelayApp/ClaudeRelayApp.swift` -- replace `ConnectionView()` with `ServerListView()`

### Deleted Files (2)

- `ClaudeRelayApp/Views/ConnectionView.swift`
- `ClaudeRelayApp/ViewModels/ConnectionViewModel.swift`

### Unchanged

- `SavedConnectionStore`, `ServerStatusChecker`, `AuthManager` -- reused as-is
- `RelayConnection`, `SessionController` -- reused as-is
- `WorkspaceView`, `SessionSidebarView`, `ActiveTerminalView` -- untouched
- `SplashScreenView` -- untouched
- `project.yml` -- globs pick up new files automatically

## State & Behavior Rules

### Explicit Connection States

Displayed on list rows and detail view:

| State | Source | Visual |
|-------|--------|--------|
| Disconnected | Default | Grey dot |
| Live | ServerStatusChecker probe | Green dot |
| Offline | ServerStatusChecker probe fails | Red dot |
| Connecting | Local VM state during connect() | ProgressView spinner |
| Error | Local VM state after failed connect() | Alert |

### Eliminated Hidden Behaviors

- No auto-creation of server on connect (must explicitly Save, or use Quick Connect)
- No form auto-fill on tap (tapping pushes to detail view)
- No dual-purpose screen (list is read-only, config is a separate sheet)

### Data Flow for Key Actions

| Action | Flow |
|--------|------|
| Add Server | List -> [+] -> AddEditSheet(add) -> Save -> dismiss -> list reloads |
| Edit Server | Detail -> Edit -> AddEditSheet(edit) -> Save -> dismiss -> detail refreshes |
| Connect | Detail -> Connect -> fullScreenCover(WorkspaceView) |
| Quick Connect (temp) | List -> QC sheet -> Connect -> fullScreenCover(WorkspaceView) |
| Quick Connect (save) | List -> QC sheet -> Save & Connect -> save -> fullScreenCover(WorkspaceView) |
| Duplicate | Detail -> Duplicate -> save copy -> pop to list |
| Delete | Detail -> Delete -> confirm alert -> delete -> pop to list |

### Dismiss Callback Pattern

`AddEditServerView` accepts `onSave: (ConnectionConfig) -> Void` so the presenting view can refresh.

`QuickConnectView` manages its own fullScreenCover for WorkspaceView internally, since it needs to present the workspace from within the sheet.

`ServerDetailView` manages its own fullScreenCover for WorkspaceView, triggered by `isNavigatingToWorkspace`.

## Testing Considerations

Each view model is independently testable:

- `ServerListViewModel`: test load, delete, status refresh with mock store
- `ServerDetailViewModel`: test connect flow, duplicate naming, delete cleanup
- `AddEditServerViewModel`: test validation, save in add vs edit mode, UUID preservation
- `QuickConnectViewModel`: test temporary vs save-and-connect paths
