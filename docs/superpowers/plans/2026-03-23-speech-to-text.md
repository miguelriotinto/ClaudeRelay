# Speech-to-Text Microphone Button Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a floating microphone button to ActiveTerminalView that streams live speech recognition into the terminal via SFSpeechRecognizer + AVAudioEngine.

**Architecture:** New `SpeechRecognizer` ObservableObject handles the full speech pipeline (permissions, audio capture, recognition, diff-based text streaming). ActiveTerminalView gains a second floating button and wires the recognizer's output to the existing `TerminalViewModel.sendInput()` path. A diff algorithm computes minimal keystrokes (DEL + new chars) as partial transcriptions are revised.

**Tech Stack:** Speech framework (SFSpeechRecognizer), AVFoundation (AVAudioEngine, AVAudioSession), SwiftUI, XcodeGen

**Spec:** `docs/superpowers/specs/2026-03-23-speech-to-text-design.md`

**Testing note:** The iOS app target has no SPM test target. The SpeechRecognizer depends on system audio/speech APIs that require device hardware. All verification is manual on-device via Xcode (Cmd+R). Each task includes specific verification steps.

---

## File Structure

| Action | File | Responsibility |
|--------|------|----------------|
| Create | `ClaudeRelayApp/ViewModels/SpeechRecognizer.swift` | Speech recognition lifecycle, permissions, diff algorithm, audio session |
| Modify | `ClaudeRelayApp/Views/ActiveTerminalView.swift` | Add mic button, wire recognizer, session-switch/background cleanup, permission alert |
| Modify | `project.yml` | Add `INFOPLIST_KEY_` entries for microphone and speech recognition permissions |

After modifying `project.yml`, regenerate the Xcode project with `xcodegen`.

---

### Task 1: Add permission keys to project.yml

**Files:**
- Modify: `project.yml:29-42` (settings.base section)

- [ ] **Step 1: Add INFOPLIST_KEY entries**

Add two lines under `settings.base` in `project.yml`, after the existing `INFOPLIST_KEY_` entries:

```yaml
        INFOPLIST_KEY_NSMicrophoneUsageDescription: "Claude Relay needs microphone access for voice-to-text input."
        INFOPLIST_KEY_NSSpeechRecognitionUsageDescription: "Claude Relay uses speech recognition to convert voice input to terminal commands."
```

- [ ] **Step 2: Regenerate Xcode project**

Run: `cd /Users/miguelriotinto/Desktop/Projects/ClaudeRelay && xcodegen`
Expected: "Generated project ClaudeRelay.xcodeproj"

- [ ] **Step 3: Verify in Xcode**

Open `ClaudeRelay.xcodeproj` → Build Settings → search "microphone". Both keys should appear under "Info.plist Values".

- [ ] **Step 4: Commit**

```bash
git add project.yml ClaudeRelay.xcodeproj
git commit -m "feat: add microphone and speech recognition permission keys"
```

---

### Task 2: Create SpeechRecognizer with diff algorithm

**Files:**
- Create: `ClaudeRelayApp/ViewModels/SpeechRecognizer.swift`

- [ ] **Step 1: Create SpeechRecognizer.swift with full implementation**

```swift
import Foundation
import Speech
import AVFoundation

@MainActor
final class SpeechRecognizer: ObservableObject {

    // MARK: - Published State

    @Published var isRecording = false
    @Published var permissionError: PermissionError?

    enum PermissionError: Identifiable {
        case microphoneDenied
        case speechDenied
        case unavailable

        var id: Self { self }
    }

    // MARK: - Private State

    private let speechRecognizer = SFSpeechRecognizer()
    private let audioEngine = AVAudioEngine()
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var lastSentText = ""
    private var onInput: ((Data) -> Void)?

    // MARK: - Start / Stop

    func startRecording(onInput: @escaping (Data) -> Void) {
        guard !isRecording else { return }
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            permissionError = .unavailable
            return
        }

        self.onInput = onInput

        Task {
            // Request microphone permission
            let micAllowed = await AVAudioApplication.requestRecordPermission()
            guard micAllowed else {
                permissionError = .microphoneDenied
                return
            }

            // Request speech recognition permission
            let speechStatus = await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { status in
                    cont.resume(returning: status)
                }
            }
            guard speechStatus == .authorized else {
                permissionError = .speechDenied
                return
            }

            do {
                try beginRecognition()
            } catch {
                cleanUp()
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        cleanUp()
    }

    // MARK: - Recognition Pipeline

    private func beginRecognition() throws {
        // Configure audio session
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        // Create recognition request
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.recognitionRequest = request

        // Install audio tap
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        // Start audio engine
        audioEngine.prepare()
        try audioEngine.start()

        // Start recognition task
        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }

                if let result {
                    let newText = result.bestTranscription.formattedString
                    self.applyDiff(newText: newText)
                }

                if error != nil || result?.isFinal == true {
                    self.cleanUp()
                }
            }
        }

        lastSentText = ""
        isRecording = true
    }

    // MARK: - Diff Algorithm

    private func applyDiff(newText: String) {
        let commonLen = zip(lastSentText, newText).prefix(while: { $0 == $1 }).count
        let charsToErase = lastSentText.count - commonLen
        let newSuffix = String(newText.dropFirst(commonLen))

        var bytes = Data(repeating: 0x7F, count: charsToErase)
        bytes.append(Data(newSuffix.utf8))

        if !bytes.isEmpty {
            onInput?(bytes)
        }

        lastSentText = newText
    }

    // MARK: - Cleanup

    private func cleanUp() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        lastSentText = ""
        onInput = nil
        isRecording = false

        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: Open Xcode → Cmd+B (Build)
Expected: Build succeeds with no errors. (Warnings about unused class are fine at this stage.)

- [ ] **Step 3: Commit**

```bash
git add ClaudeRelayApp/ViewModels/SpeechRecognizer.swift
git commit -m "feat: add SpeechRecognizer with live diff-based text streaming"
```

---

### Task 3: Add mic button and wire up recognizer in ActiveTerminalView

**Files:**
- Modify: `ClaudeRelayApp/Views/ActiveTerminalView.swift`

This task modifies `ActiveTerminalView` to:
1. Add `@StateObject` for the recognizer and `@Environment` for scenePhase
2. Replace the single floating button with an HStack (mic + keyboard)
3. Add `.onChange` handlers for session switch and app backgrounding
4. Add permission error alert

- [ ] **Step 1: Add state properties**

At the top of `ActiveTerminalView`, after the existing `@State` properties (line 11), add:

```swift
@StateObject private var speechRecognizer = SpeechRecognizer()
@Environment(\.scenePhase) private var scenePhase
@State private var pulseAnimation = false
```

No new imports needed — `SpeechRecognizer` is our own type, not from the Speech framework.

- [ ] **Step 2: Replace floating button with HStack**

Replace the floating keyboard toggle button block (lines 37–59, the `Button { ... }` and its padding) with:

```swift
// Floating buttons: mic + keyboard toggle
HStack(spacing: 10) {
    // Mic button
    Button {
        toggleDictation()
    } label: {
        Image(systemName: speechRecognizer.isRecording ? "mic.fill" : "mic")
            .font(.system(size: 16))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(speechRecognizer.isRecording
                        ? Color.red.opacity(0.8)
                        : Color.gray.opacity(0.5))
            .clipShape(Circle())
            .scaleEffect(pulseAnimation && speechRecognizer.isRecording ? 1.15 : 1.0)
            .animation(
                speechRecognizer.isRecording
                    ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                    : .default,
                value: pulseAnimation
            )
    }

    // Keyboard toggle button (unchanged)
    Button {
        if isKeyboardVisible {
            NotificationCenter.default.post(
                name: .terminalResignFocus, object: nil
            )
        } else {
            NotificationCenter.default.post(
                name: .terminalRequestFocus, object: nil
            )
        }
    } label: {
        Image(systemName: isKeyboardVisible
              ? "keyboard.chevron.compact.down"
              : "keyboard")
            .font(.system(size: 16))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(Color.gray.opacity(0.5))
            .clipShape(Circle())
    }
}
.padding(.trailing, 16)
.padding(.bottom, 12)
```

- [ ] **Step 3: Add toggleDictation() method and onChange handlers**

Add a private method to `ActiveTerminalView`, after the `statusColor` method:

```swift
private func toggleDictation() {
    if speechRecognizer.isRecording {
        speechRecognizer.stopRecording()
        pulseAnimation = false
    } else {
        speechRecognizer.startRecording { [coordinator] data in
            guard let id = coordinator.activeSessionId,
                  let vm = coordinator.viewModel(for: id) else { return }
            vm.sendInput(data)
        }
        pulseAnimation = true
    }
}
```

Add `.onChange` modifiers to the outermost view (after `.toolbar(.hidden, for: .navigationBar)`):

```swift
.onChange(of: coordinator.activeSessionId) { _, _ in
    speechRecognizer.stopRecording()
    pulseAnimation = false
}
.onChange(of: scenePhase) { _, newPhase in
    if newPhase != .active {
        speechRecognizer.stopRecording()
        pulseAnimation = false
    }
}
```

- [ ] **Step 4: Add permission error alert**

Add after the `.onChange` modifiers. Uses the modern `.alert(_:isPresented:presenting:actions:message:)` API consistent with existing alerts in `WorkspaceView.swift` and `ConnectionView.swift`:

```swift
.alert(
    permissionAlertTitle,
    isPresented: Binding(
        get: { speechRecognizer.permissionError != nil },
        set: { if !$0 { speechRecognizer.permissionError = nil } }
    ),
    presenting: speechRecognizer.permissionError,
    actions: { error in
        if error != .unavailable {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        }
        Button("Cancel", role: .cancel) {}
    },
    message: { error in
        switch error {
        case .microphoneDenied:
            Text("Voice input needs microphone access. Enable it in Settings.")
        case .speechDenied:
            Text("Voice input needs speech recognition access. Enable it in Settings.")
        case .unavailable:
            Text("Speech recognition is not available on this device or for your language.")
        }
    }
)
```

Also add a computed property to `ActiveTerminalView`:

```swift
private var permissionAlertTitle: String {
    switch speechRecognizer.permissionError {
    case .microphoneDenied: return "Microphone Access Required"
    case .speechDenied: return "Speech Recognition Required"
    case .unavailable: return "Speech Recognition Unavailable"
    case nil: return ""
    }
}
```

- [ ] **Step 5: Build and verify**

Run: Xcode → Cmd+B
Expected: Build succeeds.

- [ ] **Step 6: Commit**

```bash
git add ClaudeRelayApp/Views/ActiveTerminalView.swift
git commit -m "feat: add mic button with speech-to-text wiring in ActiveTerminalView"
```

---

### Task 4: On-device manual verification

**Prerequisites:** Physical iPhone or iPad (speech recognition does not work in Simulator).

- [ ] **Step 1: Build and run on device**

Run: Xcode → select physical device → Cmd+R
Expected: App launches, connects to server.

- [ ] **Step 2: Verify button layout**

Navigate to a terminal session. Two floating buttons should appear at bottom-right: mic (left) and keyboard (right). Both should be circular with gray backgrounds.

- [ ] **Step 3: Verify permission prompts**

Tap the mic button. Two system permission dialogs should appear in sequence:
1. "Claude Relay needs microphone access for voice-to-text input." → Allow
2. "Claude Relay uses speech recognition to convert voice input to terminal commands." → Allow

- [ ] **Step 4: Verify live speech streaming**

After granting permissions, the mic button should turn red and pulse. Speak a short phrase (e.g., "echo hello world"). The words should appear on the terminal command line in real-time as you speak. Partial revisions should correctly backspace and retype.

- [ ] **Step 5: Verify stop behavior**

Tap the mic button again. The button should return to gray/idle. The dictated text should remain on the command line. Press Enter on the keyboard to execute it. Verify the command runs correctly.

- [ ] **Step 6: Verify session switch stops dictation**

Start dictation, then switch to a different session in the sidebar. Dictation should stop (mic button returns to idle). No text should be sent to the new session.

- [ ] **Step 7: Verify app backgrounding stops dictation**

Start dictation, then swipe up to go home. Return to the app. Mic button should be in idle state.

- [ ] **Step 8: Commit verification notes**

No code changes — this is a verification-only task.

---

### Task 5: Final cleanup and commit

- [ ] **Step 1: Run swift build to verify SPM targets unaffected**

Run: `swift build`
Expected: Build succeeds. (The app target is Xcode-only, but SPM targets should still compile cleanly.)

- [ ] **Step 2: Run swift test to verify no regressions**

Run: `swift test`
Expected: All 110 tests pass.

- [ ] **Step 3: Final commit if any cleanup needed**

Only if previous tasks left any loose ends. Otherwise, skip.
