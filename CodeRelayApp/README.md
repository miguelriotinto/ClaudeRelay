# CodeRelayApp - Xcode Setup Guide

The iOS app cannot be built purely via Swift Package Manager because it requires
an Xcode project for signing, entitlements, and asset catalogs. Follow the steps
below to get a working build.

## Prerequisites

- Xcode 15 or later
- iOS 17+ Simulator or device
- The root `CodeRelay` Swift package must build successfully (`swift build` from
  the repository root)

## Setup Steps

1. **Create the Xcode project**
   Open Xcode -> File -> New -> Project -> iOS App (SwiftUI).
   Name it `CodeRelayApp` and save it **alongside** (not inside) the existing
   `CodeRelayApp/` directory. Xcode will create a `.xcodeproj` and a matching
   folder; you can merge or redirect source references in the next step.

2. **Remove auto-generated sources**
   Delete the auto-generated `ContentView.swift` and `CodeRelayAppApp.swift`
   that Xcode created (if any conflict with the existing files).

3. **Add existing source files**
   Drag all `.swift` files from the `CodeRelayApp/` directory into the Xcode
   project navigator. Make sure "Copy items if needed" is **unchecked** (the
   files already live in the repo) and the target checkbox is selected.

4. **Add package dependencies**
   Go to File -> Add Package Dependencies and add the following:

   - **CodeRelayClient (local):** Click "Add Local..." and select the root
     `CodeRelay` directory (the folder containing `Package.swift`). In the
     product picker choose `CodeRelayClient`.
   - **SwiftTerm (remote):** Enter the URL
     `https://github.com/migueldeicaza/SwiftTerm.git`, set the version rule to
     "Up to Next Major Version" starting from `1.2.0`, and add the `SwiftTerm`
     library product.

5. **Link frameworks**
   In the target's General -> Frameworks, Libraries, and Embedded Content,
   confirm that both `CodeRelayClient` and `SwiftTerm` appear. Add them
   manually if they are missing.

6. **Build and run**
   Select an iOS 17+ Simulator (or a physical device with a valid signing
   team) and press Cmd+R.

## File Overview

```
CodeRelayApp/
  CodeRelayAppApp.swift          -- @main App entry point
  Models/
    SavedConnection.swift        -- Persisted server bookmarks
  ViewModels/
    ConnectionViewModel.swift    -- Login / connection logic
    SessionListViewModel.swift   -- Session enumeration
    TerminalViewModel.swift      -- Terminal I/O bridge
  Views/
    ConnectionView.swift         -- Server address entry
    SessionListView.swift        -- Session picker
    TerminalContainerView.swift  -- Full-screen terminal (SwiftTerm)
    Components/
      StatusIndicator.swift      -- Connection-state badge
      KeyboardAccessory.swift    -- Extra key row above keyboard
```
