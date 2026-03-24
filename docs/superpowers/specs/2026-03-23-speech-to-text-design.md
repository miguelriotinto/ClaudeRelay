# Speech-to-Text Microphone Button

## Overview

Add a floating microphone button next to the existing keyboard toggle button in ActiveTerminalView. This button enables/disables iOS native speech recognition, streaming recognized text live into the terminal as the user speaks.

## Approach

Use Apple's `Speech` framework (`SFSpeechRecognizer`) with `AVAudioEngine` for real-time on-device speech recognition. A diff algorithm computes the minimal keystrokes (backspaces + new characters) needed to update the terminal as partial transcriptions are revised.

## Architecture

### New File

**`ClaudeRelayApp/ViewModels/SpeechRecognizer.swift`**

`@MainActor final class SpeechRecognizer: ObservableObject`

Responsibilities:
- Owns `SFSpeechRecognizer`, `AVAudioEngine`, and recognition task lifecycle
- Publishes `@Published var isRecording: Bool`
- Publishes `@Published var permissionError: PermissionError?` (enum: `.microphoneDenied`, `.speechDenied`, `.unavailable`)
- Accepts an `onInput: (Data) -> Void` closure to send keystrokes to the terminal
- Implements the diff algorithm for live-streaming partial results

Key methods:
- `startRecording(onInput:)` — Checks `SFSpeechRecognizer.isAvailable`. Requests both permissions in sequence: first `AVAudioApplication.requestRecordPermission()`, then `SFSpeechRecognizer.requestAuthorization()`. If either is denied, sets `permissionError` to the appropriate case and returns early. Configures `AVAudioSession` with `.record` category and `.measurement` mode. Installs tap on `audioEngine.inputNode` using `inputNode.outputFormat(forBus: 0)` and buffer size 1024. Creates `SFSpeechAudioBufferRecognitionRequest` with `shouldReportPartialResults = true`. Starts recognition task. Sets `isRecording = true`.
- `stopRecording()` — Stops audio engine, ends recognition request, cancels task. Deactivates audio session with `.notifyOthersOnDeactivation`. Resets `lastSentText` diff state. Sets `isRecording = false`.

Permission enum:
```swift
enum PermissionError: Identifiable {
    case microphoneDenied
    case speechDenied
    case unavailable

    var id: Self { self }
}
```

Recognition error handling:
- The `recognitionTask(with:resultHandler:)` completion block receives both results and errors.
- On non-nil result: run the diff algorithm on `result.bestTranscription.formattedString`.
- On error or `isFinal == true`: call `stopRecording()` to clean up state.
- Transient errors (network fallback failures, audio interruptions) silently stop recording. The mic button returns to idle state, signaling to the user that dictation ended.

### Modified Files

**`ClaudeRelayApp/Views/ActiveTerminalView.swift`**

- Add `@StateObject private var speechRecognizer = SpeechRecognizer()`
- Add `@Environment(\.scenePhase) private var scenePhase`
- Replace the single floating keyboard `Button` with an `HStack` containing mic button + keyboard button
- Mic button calls `toggleDictation()` which routes to `startRecording(onInput:)` / `stopRecording()`
- The `onInput` closure dynamically resolves the current view model on each invocation: `coordinator.viewModel(for: coordinator.activeSessionId ?? UUID())?.sendInput(data)` — this avoids capturing a stale `vm` reference
- Add `.onChange(of: coordinator.activeSessionId)` to call `speechRecognizer.stopRecording()` when the user switches sessions — `ActiveTerminalView` is NOT rebuilt on session switch (the `.id()` modifier only applies to the child `SwiftTermView`), so the `@StateObject` persists and must be explicitly cleaned up
- Add `.onChange(of: scenePhase)` to stop recording when app backgrounds
- Add `.alert(item: $speechRecognizer.permissionError)` with distinct messages per error case and an "Open Settings" action

**`project.yml`**

Add under `settings.base`:
```yaml
INFOPLIST_KEY_NSMicrophoneUsageDescription: "Claude Relay needs microphone access for voice-to-text input."
INFOPLIST_KEY_NSSpeechRecognitionUsageDescription: "Claude Relay uses speech recognition to convert voice input to terminal commands."
```

`Info.plist` is left unchanged. Since `GENERATE_INFOPLIST_FILE = YES` is already set, Xcode merges `INFOPLIST_KEY_*` build settings into the generated plist automatically. Adding keys to both places would be redundant and risk conflicts.

## Diff Algorithm

The core mechanism for live-streaming speech into the terminal. Tracks what text has already been sent and computes the minimal edit to update the terminal line.

### State

```
private var lastSentText: String = ""
```

### On Each Partial Result

Given `newText` from `bestTranscription.formattedString`:

1. Find the longest common prefix between `lastSentText` and `newText`
2. Compute `charsToErase = lastSentText.count - commonPrefixLength`
3. Compute `charsToSend = newText[commonPrefixLength...]`
4. Send `charsToErase` DEL bytes (`0x7F`) followed by `charsToSend` as UTF-8
5. Set `lastSentText = newText`

### Example: Normal Append

```
lastSentText = "hello wor"
newText      = "hello world"
commonPrefix = "hello wor" (9)
erase        = 9 - 9 = 0
send         = "ld"
```

### Example: Revision

```
lastSentText = "there go"
newText      = "their going"
commonPrefix = "the" (3)
erase        = 8 - 3 = 5 DEL bytes
send         = "ir going"
```

### Why 0x7F (DEL)

The PTY spawns an interactive zsh login shell on macOS. The default `stty erase` character is `^?` (0x7F). Sending DEL bytes erases characters in the shell's line editor, which is exactly what we need for revising partial results.

### Limitation: Multi-byte Characters

The diff algorithm counts Swift `String.count` (grapheme clusters) for erasure. This works correctly for single-width character scripts (Latin, Cyrillic, etc.) but may produce incorrect erasure counts for CJK characters (which occupy 2 terminal columns) or complex emoji. Since the primary use case is dictating terminal commands in the device's language, this is acceptable. CJK/emoji support can be addressed in a future iteration by switching to a column-width-aware count.

## Audio Session Configuration

```swift
// In startRecording():
try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement)
try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)

// Audio tap:
let inputNode = audioEngine.inputNode
let format = inputNode.outputFormat(forBus: 0)
inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
    recognitionRequest.append(buffer)
}

// In stopRecording():
try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
```

The `.measurement` mode minimizes system audio processing, which Apple recommends for speech recognition. Buffer size 1024 is Apple's recommended size. The format must come from `inputNode.outputFormat(forBus: 0)` to match the device's hardware sample rate — hardcoded formats cause silent failures on some devices.

## Button Layout & Visual Design

### Placement

The floating button area at `.bottomTrailing` becomes an `HStack(spacing: 10)`:

```
[mic] [keyboard]
```

Mic button is on the left, keyboard button on the right (unchanged).

### Mic Button States

**Idle:** `Image(systemName: "mic")`, white foreground, `Color.gray.opacity(0.5)` circle background. Same 44x44pt hit target as the keyboard button.

**Recording:** `Image(systemName: "mic.fill")`, white foreground, `Color.red.opacity(0.8)` circle background. Subtle pulsing animation: `scaleEffect` oscillating between 1.0 and 1.15 with `.easeInOut` repeat.

### Permission Error Alerts

`.alert(item: $speechRecognizer.permissionError)` with case-specific messages:

- `.microphoneDenied` — Title: "Microphone Access Required", Message: "Voice input needs microphone access. Enable it in Settings."
- `.speechDenied` — Title: "Speech Recognition Required", Message: "Voice input needs speech recognition access. Enable it in Settings."
- `.unavailable` — Title: "Speech Recognition Unavailable", Message: "Speech recognition is not available on this device or for your language."

All error alerts include "Open Settings" (opens `UIApplication.openSettingsURLString`) and "Cancel" actions, except `.unavailable` which only has "OK".

## Edge Cases

### App Backgrounding
`ActiveTerminalView` adds `@Environment(\.scenePhase) private var scenePhase`. When `scenePhase` changes to `.inactive` or `.background` while recording, auto-stop dictation via `.onChange(of: scenePhase)`. iOS suspends audio capture in background anyway; this keeps state consistent.

### Recognition Timeout
`SFSpeechRecognizer` on-device recognition runs for about 1 minute. When the result handler fires with `isFinal == true`, we call `stopRecording()` and reset state. No auto-restart; the user taps the mic again if needed.

### Recognition Errors
When the result handler receives a non-nil error (network fallback failure, audio interruption, etc.), we call `stopRecording()`. The mic button returns to idle state. No error alert is shown for transient recognition errors — the visual state change is sufficient feedback.

### Availability Changes
`SFSpeechRecognizer.isAvailable` is checked at the start of `startRecording()`. If unavailable, `permissionError` is set to `.unavailable`. Mid-session availability loss (rare — MDM restriction, low disk) is handled by the recognition task's error callback, which triggers `stopRecording()`.

### No Speech Detected
If the user starts recording but says nothing, no results arrive. On stop, nothing is sent. Clean no-op.

### Session Switching
`ActiveTerminalView` is NOT rebuilt when `coordinator.activeSessionId` changes — the `.id()` modifier applies only to the child `SwiftTermView`. The `@StateObject` `SpeechRecognizer` persists across session switches. An explicit `.onChange(of: coordinator.activeSessionId)` calls `speechRecognizer.stopRecording()` to prevent dictation from bleeding into a different session.

### Stale Closure Prevention
The `onInput` closure passed to `startRecording()` does NOT capture `vm` directly. Instead, it dynamically resolves the current view model each invocation: `coordinator.viewModel(for: coordinator.activeSessionId ?? UUID())?.sendInput(data)`. Combined with the session-switch stop above, this is defense-in-depth against sending input to the wrong session.

### Keyboard + Voice Simultaneously
Both paths feed the same PTY via `vm.sendInput()`. Mixing is technically possible but the diff algorithm's backspaces could collide with user-typed characters. This is an unlikely edge case with no special handling needed.

### On Stop Behavior
When the user taps the mic button to stop, dictation ends and recognized text stays on the command line as-is. No automatic newline is sent. The user reviews, edits if needed, then presses Enter manually.

## Locale
`SFSpeechRecognizer()` with no arguments uses the device locale. No configuration needed.
