# Source Performance and Improvement Review

Date: 2026-05-04

Scope: Swift package sources, iOS app sources, macOS app sources, C PTY shim, CLI sources, and tests under `Tests/` and `ClaudeRelayAppTests/`.

Verification performed:

- `swift test` passed: 331 tests, 0 failures, 1 skipped TLS-certificate test.
- Existing `docs/superpowers/plans/2026-05-03-performance-hygiene-pass.md` was checked first. Several items from that plan are already implemented, including the narrowed Homebrew formula build, pinned `LLM.swift` revision, faster non-agent activity path, detached poll cadence, and cached activity snapshots.

## Highest Priority Findings

### P0-1: iOS app downloads speech models automatically on launch

File: `ClaudeRelayApp/ClaudeRelayApp.swift:30`, `ClaudeRelayApp/ClaudeRelayApp.swift:47`

Finding: `WindowGroup.task` calls `preloadSpeechModels()`, and that method downloads all speech models when `store.modelsReady` is false. This contradicts the mic/settings UX, which asks the user before downloading approximately 1 GB. It also creates avoidable launch network, storage, battery, and thermal cost.

Proposed solution:

- Change iOS launch behavior to preload only when models are already present.
- Keep first-time download behind the mic alert/settings button.
- Add a unit/UI-level regression test or lightweight store abstraction test proving app launch does not call `downloadAllModels()` when models are missing.

### P0-2: Speech audio capture mutates shared buffer from the audio tap thread

File: `Sources/ClaudeRelaySpeech/AudioCaptureSession.swift:50`, `Sources/ClaudeRelaySpeech/AudioCaptureSession.swift:64`, `Sources/ClaudeRelaySpeech/AudioCaptureSession.swift:96`

Finding: `installTap` runs on Core Audio's callback thread, but it appends to `buffer` directly while `stop()` can read and clear the same array. The tap also allocates a new `AVAudioPCMBuffer` and `Array` for every callback.

Proposed solution:

- Move capture state behind a serial queue, lock, or small actor-facing buffer with explicit thread handoff.
- Reserve buffer capacity on start based on an expected maximum recording length.
- Avoid per-tap `Array` allocation by appending directly from `UnsafeBufferPointer<Float>` under the same synchronization primitive.
- Add a stress test for repeated start/stop and a small benchmark around tap conversion allocation.

### P0-3: `TextCleaner` is an unchecked mutable singleton used across tasks

File: `Sources/ClaudeRelaySpeech/TextCleaner.swift:11`, `Sources/ClaudeRelaySpeech/TextCleaner.swift:15`, `Sources/ClaudeRelaySpeech/TextCleaner.swift:51`, `Sources/ClaudeRelaySpeech/TextCleaner.swift:101`

Finding: `TextCleaner` is `@unchecked Sendable` and owns mutable `llm`, `unloadTimer`, `isLoaded`, and `modelPath`. `clean`, `loadModel`, `unload`, the idle timer, and iOS memory warning handling can interleave. The timeout path calls `model.stop()`, which can also affect another cleanup if two calls overlap.

Proposed solution:

- Convert `TextCleaner` into an `actor` or isolate it to a dedicated serial executor.
- Enforce one cleanup at a time, with explicit cancellation semantics.
- Make `unload()` wait for or cancel active cleanup deterministically.
- Add tests for concurrent `clean()` calls, unload during clean, and timeout recovery.

### P0-4: Request/response handling is single-slot and can misroute concurrent responses

File: `Sources/ClaudeRelayClient/SessionController.swift:211`, `Sources/ClaudeRelayClient/SessionController.swift:220`

Finding: `sendAndWaitForResponse` temporarily replaces `connection.onServerMessage`. Any overlapping command can overwrite the previous handler or consume a response meant for another request. Responses also are matched only by type, not by expected command/session id.

Proposed solution:

- Add a response router in `RelayConnection` or a command queue in `SessionController`.
- Serialize request/response commands at minimum; ideally match by request correlation id in the protocol.
- Keep push notifications (`sessionActivity`, `sessionStolen`, `sessionRenamed`) separate from command response routing.
- Add tests where `listSessions`, `resumeSession`, and `detach` overlap and responses arrive out of order.

### P0-5: WebSocket handler state is mutated from unstructured tasks off the NIO event loop

File: `Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift:276`, `Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift:323`, `Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift:358`, `Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift:488`

Finding: `RelayMessageHandler` is a NIO handler with mutable fields such as `attachedSessionId`, `attachedPTY`, and observer ids. Some mutations happen on the event loop, but `autoDetachIfNeeded()` is awaited inside unstructured tasks and mutates handler fields directly. That breaks event-loop confinement and is risky under concurrent messages or disconnect races.

Proposed solution:

- Treat the handler as event-loop confined.
- Run async actor work in `Task`, but marshal every read/write of handler fields back through `context.eventLoop.execute`.
- Consider extracting per-connection mutable state into an event-loop-bound state object.
- Add tests for rapid create/attach/resume/detach plus channel close while async actor calls are in flight.

### P0-6: Admin rate limiting likely keys by full socket address and uses an O(n) cleanup path

File: `Sources/ClaudeRelayServer/Network/AdminHTTPServer.swift:121`, `Sources/ClaudeRelayServer/Services/RateLimiter.swift:9`, `Sources/ClaudeRelayServer/Services/RateLimiter.swift:49`

Finding: `remoteAddress?.description` likely includes the client port, so localhost requests from new ephemeral ports can bypass per-IP limits. Cleanup uses repeated `removeFirst()`, which shifts the array each time.

Proposed solution:

- Extract host/IP only from `SocketAddress`, not the full address description.
- Store timestamps in a small deque/ring with a moving start index.
- Add tests that multiple ports for the same IP share one limit bucket.

## File-By-File Review

### Package and Build Metadata

`Package.swift`

- Finding: `ClaudeRelayKit` depends on `CPTYShim`, but only `PTYSession` imports `CPTYShim`; `ClaudeRelayServer` already depends on both. This unnecessarily couples client/shared kit builds to the C shim.
- Proposed solution: Remove `"CPTYShim"` from the `ClaudeRelayKit` target dependencies and keep it only on `ClaudeRelayServer`.

`Formula/clauderelay.rb`

- Current state: The high-value Homebrew performance fix is already present: the formula builds only `claude-relay-server` and `claude-relay`.
- Finding: Formula points at tag `v0.3.0`, while `ClaudeRelayKit.version` is `0.2.2`.
- Proposed solution: Normalize release versioning before the next release. Either bump `ClaudeRelayKit.version` or update the formula tag strategy.

`project.yml`, Xcode project files, resolved package files

- Finding: No source-level performance issue found. Keep generated project files out of manual refactors except package resolution changes.
- Proposed solution: If `Package.swift` dependency cleanup is done, regenerate/resolve project metadata once and include it in the same commit.

### Shared Kit

`Sources/ClaudeRelayKit/ClaudeRelayKit.swift`

- Finding: Version constant does not match the Homebrew tag.
- Proposed solution: Make release version source-of-truth explicit, preferably generated or checked in CI.

`Sources/ClaudeRelayKit/Protocol/MessageEnvelope.swift`

- Current state: Type-origin lookup table is already efficient.
- Finding: No major performance issue.
- Proposed solution: If protocol correlation ids are added, add envelope-level optional `requestId`.

`Sources/ClaudeRelayKit/Protocol/ClientMessage.swift`

- Finding: Request messages have no correlation id, which forces fragile response matching in the client.
- Proposed solution: Add a backwards-compatible optional `requestId` to command-style messages, or add it at envelope level and bump protocol version when required.

`Sources/ClaudeRelayKit/Protocol/ServerMessage.swift`

- Finding: Command responses have no correlation id and some responses do not include enough context to validate the request they satisfy.
- Proposed solution: Add optional `requestId`; include relevant ids where missing.

`Sources/ClaudeRelayKit/Models/ActivityState.swift`

- Current state: Codable compatibility for legacy `claude_*` values is good.
- Finding: No material issue.
- Proposed solution: Keep.

`Sources/ClaudeRelayKit/Models/CodingAgent.swift`

- Current state: Small static registry and matching logic are fine.
- Finding: Registry is compile-time only.
- Proposed solution: If new agents are expected frequently, move registry to config later. Not performance-critical.

`Sources/ClaudeRelayKit/Models/ConnectionQuality.swift`

- Finding: No material issue.
- Proposed solution: Keep.

`Sources/ClaudeRelayKit/Models/RelayConfig.swift`

- Finding: Config paths use force unwrap for iOS document directory lookup.
- Proposed solution: Prefer application support directory and non-crashing fallback where practical. Low priority.

`Sources/ClaudeRelayKit/Models/SessionInfo.swift`

- Finding: No material issue.
- Proposed solution: Keep.

`Sources/ClaudeRelayKit/Models/SessionState.swift`

- Current state: Static transition sets avoid per-call allocation.
- Finding: No material issue.
- Proposed solution: Keep.

`Sources/ClaudeRelayKit/Models/TokenInfo.swift`

- Finding: Expiry checks call `Date()` each time, which is fine at current scale.
- Proposed solution: Keep.

`Sources/ClaudeRelayKit/Security/TokenGenerator.swift`

- Finding: Token comparison uses regular string equality after SHA-256 hashing.
- Proposed solution: Because tokens are high entropy, this is not urgent. For hardening, compare digest bytes with constant-time equality and avoid repeated hex string formatting in hot auth paths.

`Sources/ClaudeRelayKit/Services/ConfigManager.swift`

- Current state: Shared encoder/decoder are already used.
- Finding: Synchronous disk I/O is acceptable for CLI/admin writes, but should not be used from UI hot paths.
- Proposed solution: Keep for server/CLI. If UI starts editing config directly, wrap in background task.

### Server

`Sources/ClaudeRelayServer/main.swift`

- Finding: `SIGCHLD` ignore is installed after the servers start, and `PTYSession.terminate()` relies on ignored children being auto-reaped.
- Proposed solution: Install child handling before any PTY can be created. Longer term, use explicit child lifecycle tracking rather than PID-only kill checks.

`Sources/ClaudeRelayServer/Actors/PTYSession.swift`

- Finding: Read path still copies each PTY chunk into `Data` before actor handoff.
- Proposed solution: Acceptable now, but if throughput becomes an issue, route reads through a dedicated serial queue/actor and batch adjacent chunks.
- Finding: `terminate()` sends SIGTERM and later SIGKILL by PID. If the child has exited and the PID is reused, the delayed kill check can target the wrong process.
- Proposed solution: Track process group/session ownership, use `waitpid` where possible, or cancel the delayed kill once EOF is observed. Avoid PID-only delayed SIGKILL after auto-reap.

`Sources/ClaudeRelayServer/Actors/SessionActivityMonitor.swift`

- Current state: The important non-agent fast path is implemented.
- Finding: `detectTitleChange(in:)` copies `Data` to `[UInt8]` every chunk.
- Proposed solution: Iterate `Data` bytes directly or scan only chunks containing ESC `]`. Low priority because the regex hot path was already removed for non-agent output.

`Sources/ClaudeRelayServer/Actors/SessionManager.swift`

- Current state: Cached activity snapshots avoid PTY actor hops in list calls.
- Finding: Observer dictionaries are scanned linearly for every activity/rename/steal event.
- Proposed solution: Store observers grouped by token id, e.g. `[String: [UUID: Callback]]`, if many clients per server are expected.
- Finding: Many manual `SessionInfo` rebuilds increase maintenance risk.
- Proposed solution: Add `SessionInfo.with(state:name:activity:agent:)` helpers or make mutable server-internal session record distinct from wire DTO.

`Sources/ClaudeRelayServer/Actors/TokenStore.swift`

- Current state: `lastUsedAt` writes are deferred, which is good.
- Finding: `validate(token:)` scans all tokens by hash.
- Proposed solution: Maintain an in-memory `[hash: index]` dictionary after load if token count can grow beyond small personal-use numbers.
- Finding: Expired tokens are rejected but not pruned.
- Proposed solution: Add periodic or write-time pruning for expired tokens.

`Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift`

- Finding: Event-loop confinement issue, described in P0-5.
- Finding: `handlePasteImage` decodes base64 and touches `NSPasteboard` from the NIO handler path.
- Proposed solution: Enforce decoded image size limits and move pasteboard operations onto the main thread/AppKit-safe context before writing bracketed paste.
- Finding: `sendChunkedBinaryData` creates a promise and immediately succeeds it after `flush`, so it does not observe actual write failure.
- Proposed solution: Attach the failure promise to the final write, or use `writeAndFlush` on the final frame with a promise.
- Finding: `filterEscapeResponses` copies `Data` to `[UInt8]`, builds another array, then returns `Data`.
- Proposed solution: Implement filtering into `ByteBuffer` or return original data when no response sequence is detected via a cheap pre-scan.

`Sources/ClaudeRelayServer/Network/AdminHTTPServer.swift`

- Finding: Rate-limit key likely includes ephemeral port, described in P0-6.
- Finding: Every response closes the HTTP connection.
- Proposed solution: Fine for CLI/admin use. If admin polling grows, support keep-alive.

`Sources/ClaudeRelayServer/Network/AdminRoutes.swift`

- Finding: JSON bodies are parsed through `[String: Any]` and repeated `Data` copies from `ByteBuffer`.
- Proposed solution: Use small `Decodable` request structs for token/config mutations.
- Finding: `ISO8601DateFormatter()` is allocated per token create response.
- Proposed solution: Use a static formatter or return `Encodable` DTOs and shared encoder.

`Sources/ClaudeRelayServer/Network/WebSocketServer.swift`

- Current state: TLS setup is clear and lazy when configured.
- Finding: WebSocket `shouldUpgrade` accepts any path/origin.
- Proposed solution: Validate path and optionally Origin for hardening. Not primarily performance-related.

`Sources/ClaudeRelayServer/Network/UnsafeTransfer.swift`

- Finding: The wrapper is reasonable only if access returns to the originating event loop. P0-5 shows some places where surrounding code breaks that assumption.
- Proposed solution: Keep the wrapper, but audit every use to ensure value access occurs only on the event loop.

`Sources/ClaudeRelayServer/Services/RateLimiter.swift`

- Finding: O(n) `removeFirst()` cleanup and likely ineffective IP key, described in P0-6.
- Proposed solution: Host-only key plus deque/moving start index.

`Sources/ClaudeRelayServer/Services/RingBuffer.swift`

- Finding: Large writes replace the whole storage array. Reads allocate an intermediate `[UInt8]`.
- Proposed solution: Keep one fixed buffer and copy only the last `capacity` bytes into it. Return `Data` directly using `Data(capacity:)` or expose chunk iteration to replay without a large contiguous copy.

`Sources/ClaudeRelayServer/Services/LogStore.swift`

- Finding: The store allows up to `maxEntries + 999` physical entries before compaction and slices on read.
- Proposed solution: Replace with a real ring buffer of strings.

`Sources/ClaudeRelayServer/Services/RelayLogger.swift`

- Finding: A new `Logger` is created for each log call.
- Proposed solution: Cache loggers per category or define static category loggers.

`Sources/CPTYShim/pty_shim.c` and `Sources/CPTYShim/include/pty_shim.h`

- Finding: `relay_get_process_name` and `relay_get_process_script_name` each call `sysctl(KERN_PROCARGS2)` separately for the same PID.
- Proposed solution: Add one C helper that returns executable basename, argv[1] basename, and parent pid where possible; this cuts polling syscalls.

### Client Library

`Sources/ClaudeRelayClient/RelayConnection.swift`

- Current state: Ping deduplication and generation checks are good.
- Finding: All receive handling is `@MainActor`, including JSON decode and binary output dispatch.
- Proposed solution: Keep UI callbacks on main, but consider decoding/parsing off-main if protocol traffic grows. Terminal output still must feed SwiftTerm on main.

`Sources/ClaudeRelayClient/SessionController.swift`

- Finding: Single-slot response handler, described in P0-4.
- Proposed solution: Response router or command serialization with correlation ids.

`Sources/ClaudeRelayClient/ViewModels/ServerStatusChecker.swift`

- Finding: Polling every saved server creates a full WebSocket connection and authenticates every 15 seconds on iOS and every 5 seconds on macOS.
- Proposed solution: Use unauthenticated WebSocket ping for "live" status, or add a lightweight unauthenticated `server_info` message. Validate token only when connecting.

`Sources/ClaudeRelayClient/ViewModels/SharedSessionCoordinator.swift`

- Finding: Very large class combines persistence, recovery, session lifecycle, terminal cache, activity, naming, and error presentation.
- Proposed solution: Split into `SessionRecoveryCoordinator`, `SessionPersistenceStore`, `TerminalCache`, and a thin observable facade.
- Finding: `activeSessions` filters and sorts every access.
- Proposed solution: Cache sorted active sessions after fetch/activity changes if session counts grow. Low priority.
- Finding: `agentSessions` and `sessionNames` save to `UserDefaults` synchronously on update paths.
- Proposed solution: Debounce persistence and save only when values actually change.

`Sources/ClaudeRelayClient/ViewModels/TerminalViewModel.swift`

- Finding: Pending output eviction uses `removeFirst()` and `terminalReady()` feeds all queued chunks one by one.
- Proposed solution: Use a byte ring/deque or coalesce pending chunks into larger batches before feeding the terminal.
- Finding: Each output chunk cancels and recreates a task for local awaiting-input detection, while the server already pushes activity state.
- Proposed solution: Prefer server activity for tab attention. If local detection remains, gate it to active session and use a cheaper resettable timer abstraction.

`Sources/ClaudeRelayClient/ViewModels/ServerStatusChecker.swift`

- See status polling finding above.

`Sources/ClaudeRelayClient/AuthManager.swift`

- Finding: `saveToken` deletes before adding. If `SecItemAdd` fails, the previous token is lost.
- Proposed solution: Try `SecItemUpdate` first; if item not found, add. Add accessibility attributes explicitly.

`Sources/ClaudeRelayClient/ConnectionConfig.swift`

- Finding: `wsURL` force-unwraps a string-built URL and does not handle IPv6 hosts or escaping.
- Proposed solution: Build with `URLComponents`; store validation errors at save time.

`Sources/ClaudeRelayClient/Helpers/SavedConnectionStore.swift`

- Finding: Small repeated JSON encoder/decoder allocations.
- Proposed solution: Low priority. Consider static encoder/decoder if called often.

`Sources/ClaudeRelayClient/Helpers/DeviceIdentifier.swift`

- Finding: No material issue; lookup is cached.
- Proposed solution: Keep.

`Sources/ClaudeRelayClient/Helpers/NetworkMonitor.swift`

- Finding: Multiple monitors can exist: app delegate, each coordinator, and status/recovery flows.
- Proposed solution: Provide a singleton or injected monitor so network restoration emits once.

`Sources/ClaudeRelayClient/Helpers/SessionNaming.swift`

- Finding: `pickDefaultName` filters the full theme list each call. Theme lists are small.
- Proposed solution: Keep.

`Sources/ClaudeRelayClient/Protocols/SessionCoordinating.swift`

- Finding: No material issue.
- Proposed solution: Keep and expand as coordinator extraction progresses.

`Sources/ClaudeRelayClient/ClaudeRelayClient.swift`

- Finding: No material issue.
- Proposed solution: Keep.

### Speech

`Sources/ClaudeRelaySpeech/OnDeviceSpeechEngine.swift`

- Finding: `preloadInBackground` uses `Task` from a `@MainActor` method and then calls synchronous LLM loading. `startRecording` also loads the LLM synchronously before recording.
- Proposed solution: Move Whisper and LLM load/transcribe/cleanup to dedicated actors or background executors; publish only progress/state on main.
- Finding: `prepareModels` downloads and loads models in one path.
- Proposed solution: Separate download, integrity check, load, and warm-up states for better cancellation and user feedback.

`Sources/ClaudeRelaySpeech/SpeechModelStore.swift`

- Finding: No free-space check despite `insufficientDiskSpace` error existing.
- Proposed solution: Check available capacity before downloading the approximately 1 GB model set.
- Finding: `whisperReady` trusts `UserDefaults` rather than verifying the model folder.
- Proposed solution: Verify actual files/folder at startup and clear stale ready flags.
- Finding: `downloadAllModels` always calls `WhisperKit.download` even if `whisperReady` is true.
- Proposed solution: Skip Whisper download/load validation when already verified ready.

`Sources/ClaudeRelaySpeech/WhisperTranscriber.swift`

- Finding: The transcriber is `@MainActor`, so transcription state and completion handling share main-actor isolation.
- Proposed solution: Convert to a `SpeechTranscriberActor` or dedicated serial model service. Keep SwiftUI state updates in `OnDeviceSpeechEngine`.

`Sources/ClaudeRelaySpeech/TextCleaner.swift`

- See P0-3.

`Sources/ClaudeRelaySpeech/AudioCaptureSession.swift`

- See P0-2.

`Sources/ClaudeRelaySpeech/CloudPromptEnhancer.swift`

- Finding: Uses `JSONSerialization` for a fixed Bedrock request/response shape.
- Proposed solution: Use `Encodable`/`Decodable` structs so shape drift is caught by tests.
- Finding: Model id is hardcoded.
- Proposed solution: Move model id to settings/config with a safe default.

`Sources/ClaudeRelaySpeech/SpeechEngineState.swift`

- Finding: No material issue.
- Proposed solution: Keep.

### iOS App

`ClaudeRelayApp/ClaudeRelayApp.swift`

- See P0-1.

`ClaudeRelayApp/Models/AppSettings.swift`

- Finding: Settings store the Bedrock bearer token in `@AppStorage`.
- Proposed solution: Move secret storage to Keychain, mirroring server auth tokens.

`ClaudeRelayApp/ViewModels/ServerListViewModel.swift`

- Finding: `cancelConnect()` cancels the task but the in-flight connection path should add explicit cancellation checks after awaits before publishing active connection state.
- Proposed solution: Check `Task.isCancelled` after `connect`.

`ClaudeRelayApp/ViewModels/AddEditServerViewModel.swift`

- Finding: iOS validation only requires host; token is optional at save but required at connect.
- Proposed solution: Match macOS validation or clearly support tokenless draft entries.

`ClaudeRelayApp/ViewModels/SessionCoordinator.swift`

- Finding: No material issue; thin subclass is good.
- Proposed solution: Keep.

`ClaudeRelayApp/Views/ActiveTerminalView.swift`

- Finding: Large 886-line file mixes toolbar, speech UI, terminal subclass, runtime overrides, QR generation, and terminal host.
- Proposed solution: Split by responsibility.
- Finding: Terminal output feed copies every `Data` chunk to `[UInt8]`.
- Proposed solution: Add a small adapter/cache to reduce per-chunk allocations or batch terminal output.
- Finding: QR image generation happens from the overlay body.
- Proposed solution: Generate once per `sessionId` in state.

`ClaudeRelayApp/Views/WorkspaceView.swift`

- Finding: `.task` can run more than once across view lifecycle and repeats `fetchSessions`.
- Proposed solution: Add an idempotent startup flag in the coordinator/view.

`ClaudeRelayApp/Views/ServerListView.swift`

- Finding: `onAppear` restarts status polling; no matching `onDisappear` stop in this view.
- Proposed solution: Stop polling when the list is covered by workspace or disappears.

`ClaudeRelayApp/Views/SessionSidebarView.swift`

- Finding: `coordinator.activeSessions` is recomputed multiple times in the body.
- Proposed solution: Store `let active = coordinator.activeSessions` at body branch level or cache in coordinator.

`ClaudeRelayApp/Views/SettingsView.swift`

- Finding: Bedrock bearer token is stored in app storage.
- Proposed solution: Move to Keychain.

`ClaudeRelayApp/Views/QRScannerView.swift`

- Finding: Camera permission failure is silent and session setup/start are split across global queues.
- Proposed solution: Handle authorization explicitly and use a dedicated session queue property.

`ClaudeRelayApp/Views/QRCodeSheet.swift`, `QRCodeSheet` related overlay/generator

- Finding: QR generation should be cached per session id.
- Proposed solution: Store generated image in `@State` or a small shared cache.

`ClaudeRelayApp/Views/Components/KeyboardAccessory.swift`

- Finding: Each button creates small `Data` values on tap. This is fine.
- Proposed solution: Keep. Optional static constants for repeated control sequences.

`ClaudeRelayApp/Views/Components/KeyCaptureView.swift`

- Finding: No material issue.
- Proposed solution: Keep.

`ClaudeRelayApp/Views/Components/ActivityDot.swift`, `ConnectionQualityDot.swift`, `AgentColorPalette.swift`

- Finding: Blink animations are duplicated between platforms.
- Proposed solution: Move shared dot components into a common module if app target structure allows it.

`ClaudeRelayApp/Views/SplashScreenView.swift`, `AddEditServerView.swift`

- Finding: No major performance issue.
- Proposed solution: Keep.

### macOS App

`ClaudeRelayMac/ClaudeRelayMacApp.swift`

- Finding: Deep link handling only works if a coordinator is already active.
- Proposed solution: Queue pending deep links and connect/attach after server selection or auto-connect.

`ClaudeRelayMac/AppDelegate.swift`

- Finding: Owns a `NetworkMonitor` while coordinators also create monitors.
- Proposed solution: Share one monitor.

`ClaudeRelayMac/Models/AppSettings.swift`

- Finding: Bedrock bearer token is stored in `@AppStorage`.
- Proposed solution: Move to Keychain.

`ClaudeRelayMac/ViewModels/SessionCoordinator.swift`

- Finding: `isAuthenticated` is set true on authenticate but not reset on connection reset paths.
- Proposed solution: Mirror `SessionController.resetAuth()` into published mac state.

`ClaudeRelayMac/ViewModels/MenuBarViewModel.swift`

- Finding: Three async observation tasks recompute derived state separately and do not observe `sessionsAwaitingInput`.
- Proposed solution: Use one combined publisher/task or explicitly observe all inputs that affect derived activity state.

`ClaudeRelayMac/ViewModels/ServerListViewModel.swift`

- Finding: Status checker interval is 5 seconds and each check authenticates over WebSocket.
- Proposed solution: Same lightweight probe as client status checker.

`ClaudeRelayMac/Views/TerminalContainerView.swift`

- Finding: Terminal output feed copies every `Data` chunk to `Array`.
- Proposed solution: Same terminal output batching/adapter as iOS.

`ClaudeRelayMac/Views/MainWindow.swift`

- Finding: `attemptAutoConnect()` currently always opens the server list, ignoring auto-connect settings.
- Proposed solution: Implement actual auto-connect or remove unused setting.

`ClaudeRelayMac/Views/SettingsView.swift`

- Finding: Debug `NSLog` calls in key capture paths add noise.
- Proposed solution: Gate behind debug flag or remove.

`ClaudeRelayMac/Views/SessionSidebarView.swift`

- Finding: Duplicates activity and quality dot implementations from iOS.
- Proposed solution: Share common components.

`ClaudeRelayMac/Views/MenuBarDropdown.swift`

- Finding: Uses active registry directly in actions while also maintaining a view model.
- Proposed solution: Route actions through the view model for consistency/testability.

`ClaudeRelayMac/Helpers/ImagePasteHandler.swift`

- Finding: Dragged files are loaded synchronously and converted to PNG on the main path.
- Proposed solution: Enforce size/type limits and convert off-main.

`ClaudeRelayMac/Helpers/RecordingShortcutMonitor.swift`, `RelayApplication.swift`

- Finding: Debug logging should not be unconditional in release builds.
- Proposed solution: Wrap in `#if DEBUG` or use `Logger` with configurable level.

`ClaudeRelayMac/Helpers/LaunchAtLogin.swift`, `SleepWakeObserver.swift`, `AppCommands.swift`, `AgentColorPalette.swift`

- Finding: No major issue.
- Proposed solution: Keep.

### CLI

`Sources/ClaudeRelayCLI/AdminClient.swift`

- Finding: `buildURL` concatenates strings and can mishandle paths that need escaping.
- Proposed solution: Use `URLComponents` or `URL.appending(path:)` plus query items.

`Sources/ClaudeRelayCLI/Commands/ServiceCommands.swift`

- Finding: LaunchAgent plist is generated by string interpolation without XML escaping for paths/env values.
- Proposed solution: Generate plist with `PropertyListSerialization`.

`Sources/ClaudeRelayCLI/Commands/ConfigCommands.swift`

- Finding: CLI validation allows ports 1-65535, server validation allows only 1024-65535.
- Proposed solution: Move validation into shared Kit and use it from both server admin routes and CLI.

`Sources/ClaudeRelayCLI/Commands/SessionCommands.swift`

- Finding: `createdAtFormatted` allocates an `ISO8601DateFormatter` per row.
- Proposed solution: Use a static formatter.

`Sources/ClaudeRelayCLI/Commands/TokenCommands.swift`

- Finding: CLI token DTO includes `prefix`, but server token responses do not provide it.
- Proposed solution: Either add a non-secret token prefix field server-side or remove the CLI column.

`Sources/ClaudeRelayCLI/Commands/LogCommands.swift`

- Finding: Tail polls the admin endpoint every 2 seconds.
- Proposed solution: Acceptable now. If logs become important, add streaming/SSE or cursor-based polling.

`Sources/ClaudeRelayCLI/Formatters/OutputFormatter.swift`

- Finding: Table width uses `String.count`, not terminal display width.
- Proposed solution: Use a display-width helper for non-ASCII output if needed.

`Sources/ClaudeRelayCLI/CLIRoot.swift`, `GlobalOptions.swift`

- Finding: No major issue.
- Proposed solution: Keep.

### Tests

`Tests/ClaudeRelayServerTests/*`

- Current state: Server actor/config/protocol coverage is broad.
- Gap: No stress tests for NIO handler event-loop confinement, paste image size/main-thread behavior, or PID termination race.

`Tests/ClaudeRelayClientTests/*`

- Current state: Relay connection, coordinator, cache, and terminal view model coverage is useful.
- Gap: No test for concurrent `SessionController` commands and out-of-order responses.
- Gap: No test proving `ServerStatusChecker` avoids repeated authentication, because it currently does not.

`Tests/ClaudeRelayKitTests/*`

- Current state: Protocol and model tests are comprehensive.
- Gap: Add tests when request correlation ids are introduced.

`Tests/ClaudeRelayCLITests/OutputFormatterTests.swift`

- Current state: Formatter tests pass.
- Gap: Add config validation parity tests after moving validation to Kit.

`ClaudeRelayAppTests/*`

- Current state: Speech tests are shallow and appear Xcode-target-only, not part of `swift test`.
- Gap: Add tests for no auto-download on launch, audio capture threading, `TextCleaner` concurrency, and model-store disk verification.

## Prioritized Implementation Plan

### Phase 0: Guardrails

1. Keep `swift test` green as the baseline.
2. Add failing regression tests for:
   - no speech model download on iOS launch,
   - concurrent `SessionController` request handling,
   - rate limiter same-IP/different-port behavior,
   - `TextCleaner` concurrent clean/unload behavior.

### Phase 1: P0 correctness and user-impact fixes

1. Remove iOS launch auto-download and preload only already-downloaded models.
2. Replace `SessionController` single-slot response handler with serialized command routing or request ids.
3. Confine `RelayMessageHandler` mutable state to the NIO event loop.
4. Make `TextCleaner` serialized and cancellation-safe.
5. Make `AudioCaptureSession` thread-safe and reduce tap-time allocations.
6. Fix admin rate-limit keying and timestamp storage.
7. Move server pasteboard writes to an AppKit-safe context and add decoded image size limits.

### Phase 2: Hot-path performance

1. Replace authenticated status polling with a lightweight live probe.
2. Reduce terminal output copies in iOS/macOS terminal hosts.
3. Rework `TerminalViewModel` pending output into a deque/ring or coalesced buffer.
4. Optimize `RingBuffer` read/write and replay filtering to avoid avoidable intermediate arrays.
5. Combine C shim process polling helpers to reduce syscalls per foreground poll.
6. Cache `RelayLogger` category loggers and convert `LogStore` to a true ring buffer.

### Phase 3: Build, security, and consistency

1. Remove unused `CPTYShim` dependency from `ClaudeRelayKit`.
2. Align `ClaudeRelayKit.version`, tags, changelog, and formula version.
3. Move Bedrock bearer tokens from `@AppStorage` to Keychain on iOS and macOS.
4. Change `AuthManager.saveToken` to update-before-add.
5. Build WebSocket/admin URLs with `URLComponents`.
6. Generate LaunchAgent plists with `PropertyListSerialization`.
7. Move config validation into shared Kit and reuse it from CLI and server.

### Phase 4: Maintainability refactors

1. Split `SharedSessionCoordinator` into recovery, persistence, terminal-cache, and observable facade components.
2. Split `ActiveTerminalView.swift` into terminal host, toolbar, mic button, QR overlay, and runtime override files.
3. Share duplicated activity/quality dot and agent color components across iOS/macOS.
4. Move Bedrock request/response parsing to typed Codable DTOs.

### Suggested Sequencing

Start with Phase 1 items 1, 2, 3, and 6 because they are correctness fixes with clear tests and minimal UI churn. Then do the speech concurrency work as a focused branch because it touches model loading, audio capture, and cancellation semantics. After those land, take the hot-path terminal/replay work in one branch with before/after allocation measurements. Finish with build/security consistency and larger file-splitting refactors once behavior is stable.

