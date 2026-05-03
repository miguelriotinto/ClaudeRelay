# ClaudeRelayApp - Xcode Setup Guide

The iOS app is managed via XcodeGen (`project.yml`). It cannot be built purely
via Swift Package Manager because it requires an Xcode project for signing,
entitlements, and asset catalogs.

## Prerequisites

- Xcode 15 or later
- iOS 17+ Simulator or device
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- The root `ClaudeRelay` Swift package must build successfully (`swift build` from
  the repository root)

## Setup Steps

1. **Generate the Xcode project**

   ```bash
   xcodegen generate
   ```

   This reads `project.yml` and creates `ClaudeRelay.xcodeproj`.

2. **Build and run**

   Open `ClaudeRelay.xcodeproj` in Xcode, select the `ClaudeRelayApp` scheme,
   choose an iOS 17+ Simulator or device, and press Cmd+R.

After modifying `ClaudeRelayClient` or `ClaudeRelayKit` sources, rebuild the
iOS app in Xcode to pick up changes.

## File Overview

```
ClaudeRelayApp/
  ClaudeRelayApp.swift              -- @main App entry point
  Models/
    AppSettings.swift               -- User preferences (@AppStorage)
  ViewModels/
    ServerListViewModel.swift       -- Server list, status polling, connection
    AddEditServerViewModel.swift    -- Add/edit server form state
    SessionCoordinator.swift        -- Auth, session lifecycle, I/O routing
  Views/
    ServerListView.swift            -- Server list (tap to connect, swipe for edit/delete)
    AddEditServerView.swift         -- Server configuration form (add/edit/delete)
    SplashScreenView.swift          -- App launch splash
    WorkspaceView.swift             -- NavigationSplitView: sidebar + terminal
    SessionSidebarView.swift        -- Session list sidebar
    ActiveTerminalView.swift        -- Terminal with keyboard accessory + mic
    SettingsView.swift              -- App settings screen
    QRCodeSheet.swift               -- QR code overlay for session sharing
    QRScannerView.swift             -- QR code scanner via AVFoundation camera
    Components/
      KeyboardAccessory.swift       -- Extra key row above keyboard
      KeyCaptureView.swift          -- Live key combination capture
      ActivityDot.swift             -- Coding agent activity indicator
      AgentColorPalette.swift      -- Per-agent tab/dot coloring
      ConnectionQualityDot.swift    -- Connection quality indicator
```

Shared types that previously lived here (`TerminalViewModel`, `ServerStatusChecker`,
`SavedConnectionStore`, `NetworkMonitor`, speech pipeline) now live in
`Sources/ClaudeRelayClient/` and `Sources/ClaudeRelaySpeech/`.
