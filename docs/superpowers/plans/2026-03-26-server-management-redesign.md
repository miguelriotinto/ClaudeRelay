# Server Management UX Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the dual-purpose ConnectionView with a clean server management architecture: ServerListView (browse), ServerDetailView (inspect + connect), AddEditServerView (configure), QuickConnectView (ephemeral).

**Architecture:** Four new views with dedicated view models replace ConnectionView + ConnectionViewModel. Existing data layer (SavedConnectionStore, ServerStatusChecker, AuthManager, RelayConnection) is reused unchanged. WorkspaceView remains the terminal destination.

**Tech Stack:** SwiftUI, ClaudeRelayClient, ClaudeRelayKit

**Spec:** `docs/superpowers/specs/2026-03-26-server-management-redesign-design.md`

---

### Task 1: Create AddEditServerViewModel

**Files:**
- Create: `ClaudeRelayApp/ViewModels/AddEditServerViewModel.swift`

- [ ] **Step 1: Create the view model file**

```swift
import Foundation
import SwiftUI
import ClaudeRelayClient

/// Drives the Add/Edit Server form. Configuration only — no connection logic.
@MainActor
final class AddEditServerViewModel: ObservableObject {

    enum Mode {
        case add
        case edit(ConnectionConfig)
    }

    // MARK: - Form Fields

    @Published var name: String = ""
    @Published var host: String = ""
    @Published var port: String = "9200"
    @Published var token: String = ""
    @Published var useTLS: Bool = false

    let mode: Mode

    var isValid: Bool { !host.isEmpty }

    var navigationTitle: String {
        switch mode {
        case .add: return "Add Server"
        case .edit: return "Edit Server"
        }
    }

    var saveButtonTitle: String {
        switch mode {
        case .add: return "Save Server"
        case .edit: return "Save Changes"
        }
    }

    // MARK: - Private

    private let existingId: UUID?

    // MARK: - Init

    init(mode: Mode) {
        self.mode = mode
        if case .edit(let config) = mode {
            existingId = config.id
            name = config.name
            host = config.host
            port = String(config.port)
            useTLS = config.useTLS
            token = (try? AuthManager.shared.loadToken(for: config.id)) ?? ""
        } else {
            existingId = nil
        }
    }

    // MARK: - Actions

    /// Validates, persists to SavedConnectionStore + Keychain, returns the saved config.
    func save() -> ConnectionConfig? {
        guard isValid else { return nil }
        guard let portNumber = UInt16(port), portNumber > 0 else { return nil }

        let config = ConnectionConfig(
            id: existingId ?? UUID(),
            name: name.isEmpty ? host : name,
            host: host,
            port: portNumber,
            useTLS: useTLS
        )

        SavedConnectionStore.add(config)

        if !token.isEmpty {
            try? AuthManager.shared.saveToken(token, for: config.id)
        }

        return config
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add ClaudeRelayApp/ViewModels/AddEditServerViewModel.swift
git commit -m "feat: add AddEditServerViewModel for config-only server form"
```

---

### Task 2: Create AddEditServerView

**Files:**
- Create: `ClaudeRelayApp/Views/AddEditServerView.swift`

- [ ] **Step 1: Create the view file**

```swift
import SwiftUI
import ClaudeRelayClient

/// Modal form for adding or editing a server configuration.
/// This screen is configuration only — no connection happens here.
struct AddEditServerView: View {
    @StateObject private var viewModel: AddEditServerViewModel
    @Environment(\.dismiss) private var dismiss

    let onSave: ((ConnectionConfig) -> Void)?

    init(mode: AddEditServerViewModel.Mode, onSave: ((ConnectionConfig) -> Void)? = nil) {
        _viewModel = StateObject(wrappedValue: AddEditServerViewModel(mode: mode))
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Server Name", text: $viewModel.name)
                        .textContentType(.name)
                        .autocorrectionDisabled()

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
                        if let config = viewModel.save() {
                            onSave?(config)
                            dismiss()
                        }
                    } label: {
                        HStack {
                            Spacer()
                            Text(viewModel.saveButtonTitle)
                                .fontWeight(.semibold)
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(viewModel.isValid ? Color.red : Color(.systemGray5))
                    .foregroundStyle(viewModel.isValid ? .white : .black)
                    .disabled(!viewModel.isValid)
                }
            }
            .navigationTitle(viewModel.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

#Preview("Add") {
    AddEditServerView(mode: .add)
}
```

- [ ] **Step 2: Commit**

```bash
git add ClaudeRelayApp/Views/AddEditServerView.swift
git commit -m "feat: add AddEditServerView for server configuration"
```

---

### Task 3: Create ServerListViewModel

**Files:**
- Create: `ClaudeRelayApp/ViewModels/ServerListViewModel.swift`

- [ ] **Step 1: Create the view model file**

```swift
import Foundation
import SwiftUI
import Combine
import ClaudeRelayClient

/// Manages the server list and status polling.
@MainActor
final class ServerListViewModel: ObservableObject {

    @Published var servers: [ConnectionConfig] = []
    @Published var serverStatuses: [UUID: ServerStatus] = [:]

    private let statusChecker = ServerStatusChecker()

    // MARK: - Init

    init() {
        servers = SavedConnectionStore.loadAll()
        statusChecker.$statuses.assign(to: &$serverStatuses)
    }

    // MARK: - Polling

    func startPolling() {
        statusChecker.startPolling(connections: servers)
    }

    func stopPolling() {
        statusChecker.stopPolling()
    }

    // MARK: - Actions

    func refreshServers() {
        servers = SavedConnectionStore.loadAll()
        statusChecker.refresh(connections: servers)
    }

    func refreshStatuses() {
        statusChecker.refresh(connections: servers)
    }

    func deleteServer(at offsets: IndexSet) {
        for index in offsets {
            let config = servers[index]
            try? AuthManager.shared.deleteToken(for: config.id)
            servers = SavedConnectionStore.delete(id: config.id)
        }
        statusChecker.refresh(connections: servers)
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add ClaudeRelayApp/ViewModels/ServerListViewModel.swift
git commit -m "feat: add ServerListViewModel for server list + status polling"
```

---

### Task 4: Create ServerDetailViewModel

**Files:**
- Create: `ClaudeRelayApp/ViewModels/ServerDetailViewModel.swift`

- [ ] **Step 1: Create the view model file**

```swift
import Foundation
import SwiftUI
import ClaudeRelayClient

/// Manages the server detail screen: connection, duplication, deletion.
@MainActor
final class ServerDetailViewModel: ObservableObject {

    @Published var server: ConnectionConfig
    @Published var status: ServerStatus?
    @Published var isConnecting: Bool = false
    @Published var activeConnection: RelayConnection?
    @Published var activeToken: String?
    @Published var isNavigatingToWorkspace: Bool = false
    @Published var errorMessage: String?
    @Published var showError: Bool = false
    @Published var showDeleteConfirmation: Bool = false

    var hasToken: Bool {
        (try? AuthManager.shared.loadToken(for: server.id)) != nil
    }

    init(server: ConnectionConfig) {
        self.server = server
    }

    // MARK: - Actions

    func refreshStatus() async {
        status = await ServerStatusChecker.probe(config: server)
    }

    func connect() async {
        isConnecting = true
        defer { isConnecting = false }

        guard let token = try? AuthManager.shared.loadToken(for: server.id),
              !token.isEmpty else {
            presentError("No auth token saved for this server. Edit the server to add one.")
            return
        }

        let connection = RelayConnection()

        do {
            try await connection.connect(config: server, token: token)
            activeConnection = connection
            activeToken = token
            isNavigatingToWorkspace = true
        } catch {
            presentError(error.localizedDescription)
        }
    }

    func duplicate() -> ConnectionConfig {
        let copy = ConnectionConfig(
            id: UUID(),
            name: "Copy of \(server.name)",
            host: server.host,
            port: server.port,
            useTLS: server.useTLS
        )
        SavedConnectionStore.add(copy)

        // Copy token if one exists for the original server.
        if let token = try? AuthManager.shared.loadToken(for: server.id) {
            try? AuthManager.shared.saveToken(token, for: copy.id)
        }

        return copy
    }

    func delete() {
        try? AuthManager.shared.deleteToken(for: server.id)
        SavedConnectionStore.delete(id: server.id)
    }

    func resetNavigationState() {
        isNavigatingToWorkspace = false
        activeConnection = nil
        activeToken = nil
    }

    // MARK: - Private

    private func presentError(_ message: String) {
        errorMessage = message
        showError = true
    }
}
```

Note: `ServerStatusChecker.probe` is a `private static` method. It needs to be made accessible. See Task 4 Step 2.

- [ ] **Step 2: Make ServerStatusChecker.probe accessible**

In `ClaudeRelayApp/ViewModels/ServerStatusChecker.swift`, change `private static func probe` to `static func probe`:

```
Old: private static func probe(config: ConnectionConfig) async -> ServerStatus {
New: static func probe(config: ConnectionConfig) async -> ServerStatus {
```

- [ ] **Step 3: Commit**

```bash
git add ClaudeRelayApp/ViewModels/ServerDetailViewModel.swift ClaudeRelayApp/ViewModels/ServerStatusChecker.swift
git commit -m "feat: add ServerDetailViewModel for connect/duplicate/delete"
```

---

### Task 5: Create ServerDetailView

**Files:**
- Create: `ClaudeRelayApp/Views/ServerDetailView.swift`

- [ ] **Step 1: Create the view file**

```swift
import SwiftUI
import ClaudeRelayClient

/// Read-only server detail with connect, edit, duplicate, and delete actions.
struct ServerDetailView: View {
    @StateObject private var viewModel: ServerDetailViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showEditSheet = false
    @State private var showTimeoutAlert = false

    /// Called when the server list needs to refresh (after edit, duplicate, or delete).
    let onServerChanged: () -> Void

    init(server: ConnectionConfig, onServerChanged: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: ServerDetailViewModel(server: server))
        self.onServerChanged = onServerChanged
    }

    var body: some View {
        List {
            Section("Connection") {
                LabeledContent("Host", value: viewModel.server.host)
                LabeledContent("Port", value: String(viewModel.server.port))
                LabeledContent("TLS", value: viewModel.server.useTLS ? "On" : "Off")
                LabeledContent("Auth", value: viewModel.hasToken ? "Token saved" : "No token")
            }

            Section("Status") {
                HStack {
                    Circle()
                        .fill(viewModel.status?.isLive == true ? .green : .red)
                        .frame(width: 10, height: 10)
                    Text(viewModel.status?.isLive == true ? "Live" : "Offline")
                }
                if let status = viewModel.status {
                    LabeledContent("Sessions", value: "\(status.sessionCount)")
                }
            }

            Section {
                Button {
                    Task { await viewModel.connect() }
                } label: {
                    HStack {
                        Spacer()
                        if viewModel.isConnecting {
                            ProgressView()
                            Text("Connecting...")
                        } else {
                            Text("Connect")
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(viewModel.hasToken ? Color.red : Color(.systemGray5))
                .foregroundStyle(viewModel.hasToken ? .white : .black)
                .disabled(!viewModel.hasToken || viewModel.isConnecting)
            }

            Section("Management") {
                Button("Edit") {
                    showEditSheet = true
                }

                Button("Duplicate") {
                    _ = viewModel.duplicate()
                    onServerChanged()
                    dismiss()
                }

                Button("Delete", role: .destructive) {
                    viewModel.showDeleteConfirmation = true
                }
            }
        }
        .navigationTitle(viewModel.server.name)
        .task {
            await viewModel.refreshStatus()
        }
        .alert("Error", isPresented: $viewModel.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        }
        .alert("Delete Server", isPresented: $viewModel.showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                viewModel.delete()
                onServerChanged()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete \"\(viewModel.server.name)\"? This cannot be undone.")
        }
        .sheet(isPresented: $showEditSheet) {
            AddEditServerView(mode: .edit(viewModel.server)) { updatedConfig in
                viewModel.server = updatedConfig
                onServerChanged()
            }
        }
        .fullScreenCover(isPresented: $viewModel.isNavigatingToWorkspace) {
            viewModel.resetNavigationState()
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
```

- [ ] **Step 2: Commit**

```bash
git add ClaudeRelayApp/Views/ServerDetailView.swift
git commit -m "feat: add ServerDetailView with connect, edit, duplicate, delete"
```

---

### Task 6: Create QuickConnectViewModel

**Files:**
- Create: `ClaudeRelayApp/ViewModels/QuickConnectViewModel.swift`

- [ ] **Step 1: Create the view model file**

```swift
import Foundation
import SwiftUI
import ClaudeRelayClient

/// Drives the Quick Connect sheet for ephemeral or save-and-connect flows.
@MainActor
final class QuickConnectViewModel: ObservableObject {

    @Published var host: String = ""
    @Published var port: String = "9200"
    @Published var token: String = ""
    @Published var useTLS: Bool = false
    @Published var isConnecting: Bool = false
    @Published var activeConnection: RelayConnection?
    @Published var activeToken: String?
    @Published var isNavigatingToWorkspace: Bool = false
    @Published var errorMessage: String?
    @Published var showError: Bool = false

    /// Tracks whether a server was saved (for the onServerSaved callback).
    private(set) var didSaveServer: Bool = false

    var isValid: Bool { !host.isEmpty }

    // MARK: - Actions

    func connectTemporary() async {
        await performConnect(save: false)
    }

    func saveAndConnect() async {
        await performConnect(save: true)
    }

    func resetNavigationState() {
        isNavigatingToWorkspace = false
        activeConnection = nil
        activeToken = nil
    }

    // MARK: - Private

    private func performConnect(save: Bool) async {
        guard isValid else { return }
        guard let portNumber = UInt16(port), portNumber > 0 else {
            presentError("Port must be a number between 1 and 65535.")
            return
        }

        isConnecting = true
        defer { isConnecting = false }

        let config = ConnectionConfig(
            id: UUID(),
            name: host,
            host: host,
            port: portNumber,
            useTLS: useTLS
        )

        if save {
            SavedConnectionStore.add(config)
            if !token.isEmpty {
                try? AuthManager.shared.saveToken(token, for: config.id)
            }
            didSaveServer = true
        }

        let connection = RelayConnection()

        do {
            try await connection.connect(config: config, token: token)
            activeConnection = connection
            activeToken = token
            isNavigatingToWorkspace = true
        } catch {
            presentError(error.localizedDescription)
        }
    }

    private func presentError(_ message: String) {
        errorMessage = message
        showError = true
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add ClaudeRelayApp/ViewModels/QuickConnectViewModel.swift
git commit -m "feat: add QuickConnectViewModel for ephemeral and save-and-connect"
```

---

### Task 7: Create QuickConnectView

**Files:**
- Create: `ClaudeRelayApp/Views/QuickConnectView.swift`

- [ ] **Step 1: Create the view file**

```swift
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
```

- [ ] **Step 2: Commit**

```bash
git add ClaudeRelayApp/Views/QuickConnectView.swift
git commit -m "feat: add QuickConnectView with temporary and save-and-connect options"
```

---

### Task 8: Create ServerListView

**Files:**
- Create: `ClaudeRelayApp/Views/ServerListView.swift`

- [ ] **Step 1: Create the view file**

```swift
import SwiftUI
import ClaudeRelayClient

/// Primary screen showing saved servers. No editable fields — just browse, tap, connect.
struct ServerListView: View {
    @StateObject private var viewModel = ServerListViewModel()
    @State private var showAddSheet = false
    @State private var showQuickConnect = false

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.servers.isEmpty {
                    ContentUnavailableView {
                        Label("No Servers", systemImage: "server.rack")
                    } description: {
                        Text("Add a server to get started, or use Quick Connect for a temporary connection.")
                    } actions: {
                        Button("Add Server") {
                            showAddSheet = true
                        }
                    }
                } else {
                    List {
                        ForEach(viewModel.servers) { server in
                            NavigationLink {
                                ServerDetailView(server: server) {
                                    viewModel.refreshServers()
                                }
                            } label: {
                                ServerRowView(
                                    server: server,
                                    status: viewModel.serverStatuses[server.id]
                                )
                            }
                        }
                        .onDelete(perform: viewModel.deleteServer(at:))
                    }
                    .refreshable {
                        viewModel.refreshStatuses()
                    }
                }
            }
            .navigationTitle("Servers")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        showQuickConnect = true
                    } label: {
                        Label("Quick Connect", systemImage: "bolt.horizontal")
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AddEditServerView(mode: .add) { _ in
                    viewModel.refreshServers()
                }
            }
            .sheet(isPresented: $showQuickConnect) {
                QuickConnectView {
                    viewModel.refreshServers()
                }
            }
            .onAppear {
                viewModel.refreshServers()
                viewModel.startPolling()
            }
        }
    }
}

// MARK: - Server Row

struct ServerRowView: View {
    let server: ConnectionConfig
    let status: ServerStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(server.name)
                .font(.body)
                .fontWeight(.medium)
            Text(verbatim: "\(server.host):\(server.port)")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(status?.isLive == true ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(status?.isLive == true ? "Live" : "Offline")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Text("Sessions:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(status?.sessionCount ?? 0)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

#Preview {
    ServerListView()
}
```

- [ ] **Step 2: Commit**

```bash
git add ClaudeRelayApp/Views/ServerListView.swift
git commit -m "feat: add ServerListView as primary server browsing screen"
```

---

### Task 9: Update App Entry Point and Delete Old Files

**Files:**
- Modify: `ClaudeRelayApp/ClaudeRelayApp.swift:10` — replace `ConnectionView()` with `ServerListView()`
- Delete: `ClaudeRelayApp/Views/ConnectionView.swift`
- Delete: `ClaudeRelayApp/ViewModels/ConnectionViewModel.swift`

- [ ] **Step 1: Update ClaudeRelayApp.swift**

Change line 10 from:
```swift
                ConnectionView()
```
To:
```swift
                ServerListView()
```

- [ ] **Step 2: Delete old files**

```bash
rm ClaudeRelayApp/Views/ConnectionView.swift
rm ClaudeRelayApp/ViewModels/ConnectionViewModel.swift
```

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "refactor: replace ConnectionView with ServerListView entry point

Remove ConnectionView and ConnectionViewModel. The server management
UX is now split across ServerListView, ServerDetailView,
AddEditServerView, and QuickConnectView."
```

---

### Task 10: Regenerate Xcode Project and Build Verification

**Files:**
- Verify: `project.yml` (glob patterns should pick up new files)

- [ ] **Step 1: Regenerate Xcode project**

```bash
cd /Users/miguelriotinto/Desktop/Projects/ClaudeRelay && xcodegen generate
```

Expected: "Generated project" message. The glob patterns in `project.yml` should include the new files and exclude the deleted ones.

- [ ] **Step 2: Build the iOS app**

```bash
cd /Users/miguelriotinto/Desktop/Projects/ClaudeRelay && xcodebuild build -project ClaudeRelay.xcodeproj -scheme ClaudeRelay -destination 'platform=iOS Simulator,name=iPhone 16' -quiet 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`

If there are build errors, fix them. Common issues to check:
- Missing imports (ensure `import ClaudeRelayClient` is in all new files)
- `ServerStatusChecker.probe` visibility (must not be `private`)
- `WorkspaceView` initializer signature (must match: `connection:`, `token:`, `showTimeoutAlert:`)

- [ ] **Step 3: Commit any build fixes if needed**

```bash
git add -A
git commit -m "fix: resolve build errors from server management refactor"
```

- [ ] **Step 4: Verify SPM targets still build**

```bash
swift build 2>&1 | tail -3
```

Expected: `Build complete!` — SPM targets (ClaudeRelayKit, ClaudeRelayServer, ClaudeRelayCLI, ClaudeRelayClient) are unchanged and should still compile.
