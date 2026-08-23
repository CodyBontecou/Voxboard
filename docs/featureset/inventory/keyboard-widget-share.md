# Vox.md (Voxboard) — Keyboard Extension, Widgets/Controls/Live Activity, Share Extension Feature Inventory

LID prefix: **KW** (Keyboard/Widget/Share surfaces). All file paths relative to repo root. Every claim below is verified in the listed source file; shared helpers in `VoxboardShared` / main app are cited only to confirm where a referenced type lives.

---

## Keyboard Extension

### F-KW-01 Keyboard activation & setup (always-on persistent listening architecture)
- Surface: iOS system keyboard (Voxboard keyboard), used in any host app; setup occurs implicitly when the keyboard needs the main app.
- Summary: The keyboard extension embeds a custom voice toolbar above a standard KeyboardKit layout. It does not record audio itself; the main Vox.md app runs a persistent background recorder ("Listening Mode") and the keyboard drives it entirely via IPC (shared container files + Darwin notifications). If the app is not listening, the keyboard prompts the user to open Vox.md once.
- Details:
  - Root controller `KeyboardViewController: KeyboardInputViewController` (KeyboardKit) builds `VoxboardKeyboardView` = `VoiceToolbarView` + `KeyboardView` in a VStack, with a fixed opaque background color (light `226/228/232`, dark `26/26/28`) so the canvas doesn't bleed through.
  - `VoiceKeyboardState.init` calls `TranscriptionIPC.ensureDirectory()`, refreshes model + flow caches, registers Darwin observers, checks listening state, and recovers any existing IPC session (`checkForExistingSession`).
  - Status machine: `.idle`, `.recording`, `.transcribing`, `.error(String)`, `.noModel`, `.needsFullAccess`, `.appNotListening`.
  - On `viewDidAppear`: refresh listening state, refresh model cache, insert any recovered pending text (`tryInsertPendingText`), `resumeAfterSuspension()`, re-apply haptics setting.
  - Haptics: `state.feedbackContext.settings.isHapticFeedbackEnabled = AppConstants.hapticsEnabled` — re-read on each appear so main-app toggles apply without keyboard reload.
  - `didReceiveMemoryWarning` forwarded to `VoiceKeyboardState.handleMemoryWarning` (currently log-only; "no heavy resources in extension").
- Constraints: Requires the main app to have been opened and started Listening Mode; keyboard itself performs no audio capture.
- Evidence: `Voxboard Keyboard/KeyboardViewController.swift` (whole file, esp. `viewWillSetupKeyboardView` ~43-70, `viewDidAppear` ~72-90); `Voxboard Keyboard/VoiceKeyboardState.swift` (~55-135 init).
- Status: shipped

### F-KW-02 Full Access requirement
- Surface: Keyboard toolbar status label + mic button gating.
- Summary: Voice recording from the keyboard requires iOS "Full Access" for the keyboard extension. Without it, tapping the mic sets `.needsFullAccess`.
- Details:
  - `startRecording(hasFullAccess:)` guards `hasFullAccess` and sets `.needsFullAccess`; toolbar shows "Enable Full Access" in error color.
  - `hasFullAccess` is passed from `controller.hasFullAccess` (KeyboardKit) into `VoiceToolbarView`.
  - Full-access value is also cached (`cachedHasFullAccess`) when the mic is used to auto-record after opening the app.
- Constraints: iOS Full Access toggle; no voice capture without it.
- Evidence: `Voxboard Keyboard/VoiceKeyboardState.swift` (~230-240 `startRecording` guard); `Voxboard Keyboard/VoiceToolbarView.swift` (`needsFullAccess` case in statusLabel/actionButton ~140-190).
- Status: shipped

### F-KW-03 Persistent listening mode + IPC segment control (start/stop without app switching)
- Surface: Keyboard toolbar record/stop buttons.
- Summary: Record tap writes a `startSegment` command (with modelId, language, flowId, origin `.keyboardExtension`) into the shared IPC container and posts a Darwin notification; the running app marks its buffer position and begins capturing. Stop tap writes `stopSegment`; the app extracts the audio, transcribes, and writes a response the keyboard polls for (0.1 s poll timer plus Darwin response notification).
- Details:
  - UI updates optimistically: status → `.recording`, local duration timer (0.1 s) and poll timer started immediately.
  - Start-acknowledgement: app confirms via status file `phase == .recording` (most starts acknowledged <250 ms); if no ack within `startAcknowledgementTimeout = 3 s`, the pending command is cleared and an error is shown ("Vox.md did not start recording — reopen Listening Mode and try again").
  - Stop-before-ack: `stopRequestedBeforeAcknowledgement` — never overwrite an unclaimed start command with stop; when the app acknowledges start, the pending stop is sent immediately.
  - Command-notification retry: while the durable command file remains unclaimed, the Darwin notification is re-posted every `commandNotificationRetryInterval = 0.5 s` ("the app also polls it").
  - Cancel: `cancelRecording()` sends a `stopSegment` to clean up the app side and resets to `.idle`.
  - Transcription progress: status file's `transcriptionProgress` is clamped 0–1 and only ever increases (monotonic guard); feeds toolbar progress UI.
  - Transcription timeout: `transcriptionTimeout = 90 s` since last progress activity ("Apple may need to prepare a system-managed locale asset on first use"); on timeout clears response/status/live state and shows "Transcription timed out — try again".
  - Transcript-store fallback: if status `.transcribing` > 5 s, no response artifact, and `transcripts.json` in the shared container has an entry newer than the user's Stop tap (`segmentStopTime`), that transcript is used as the response ("the app writes history before asynchronous post-processing. If the response artifact is lost, recover a transcript newer than Stop").
  - Response/requestId filtering: responses for other requestIds are ignored (logged every 30th poll).
  - App-side error (`phase == .error`) surfaces as an error status with the app's message or "Recording failed — try again".
  - Errors auto-reset after 3 s (`resetErrorAfterDelay`) back to a listening-state check.
- Constraints: Shared App Group container (`group.bontecou.Voxboard`), fresh listening heartbeat required (see F-KW-04).
- Evidence: `Voxboard Keyboard/VoiceKeyboardState.swift` (`startRecording` ~225-320, `stopRecording` ~322-365, `checkForUpdates` ~500-620, `latestTranscriptSince` ~640-660, `finishWithResponse` ~665-740).
- Status: shipped

### F-KW-04 Listening-state heartbeat freshness & "Open Vox.md" prompt
- Surface: Keyboard toolbar; app-open flow.
- Summary: The app publishes a listening-state file; the keyboard requires it to be *fresh* (`TranscriptionIPC.isListeningStateFresh`) so it never sends commands to a stale file left after iOS kills the background app. When stale/absent, status is `.appNotListening`, toolbar shows "Open Vox.md", and the mic button opens the app via `voxboard://listen`.
- Details:
  - `pendingAutoRecord`: when the mic is tapped while the app isn't listening, `openApp` sets the flag and opens the URL; when a listening-state Darwin notification later reports fresh listening, recording auto-starts (with the cached full-access value).
  - Darwin observer on `listeningStateNotificationName` refreshes state live; only `.idle`/`.appNotListening` states are downgraded (active operations are never interrupted).
  - Stale session clearing: on init, a `.recording` or `.transcribing` status without a fresh heartbeat is cleared and status set to `.appNotListening`.
  - URL opening: `extensionContext.open(url)` first; on failure, walks the responder chain for `openURL:options:completionHandler:`; final fallback is legacy `openURL:` selector (works on some iOS versions).
- Constraints: One-time user prompt to open the app; keyboard cannot background-start the app.
- Evidence: `Voxboard Keyboard/VoiceKeyboardState.swift` (`openApp` ~390-400, `refreshListeningState` ~402-440); `Voxboard Keyboard/KeyboardViewController.swift` (`openAppURL`/`openAppURLViaResponderChain` ~96-155).
- Status: shipped

### F-KW-05 Streaming insertion of finalized text vs tentative toolbar text
- Surface: Keyboard toolbar status area + host app's text field.
- Summary: For Apple-Speech (live) segments, the app writes live snapshots (volatile text + cumulative text + revision) to the IPC container. The keyboard inserts only monotonic deltas of finalized text into the host app, while the volatile (revisable) tail is shown only in the toolbar and is never inserted.
- Details:
  - `volatileTranscription` — toolbar display only ("never inserted into another app because volatile recognition can be revised").
  - `LiveTranscriptionDeliveryReducer.apply(snapshot, ...)` with persisted checkpoint (`TranscriptionIPC.writeLiveDeliveryCheckpoint`); outcomes: `.ignoredStale`, `.ignoredNonMonotonic` (log warning), `.persistenceFailed` (delay insertion), `.committed` (insert delta).
  - If `textInserter` is unavailable, deltas accumulate into `pendingTranscription` and are persisted to `TranscriptionIPC/pending_text.txt` for recovery.
  - Final reconciliation: `TranscriptionInsertionPlanner.plan(deliveredText:finalText:)` → `.insert(suffix)` inserts only the remaining suffix; `.alreadyComplete` inserts nothing; `.unsafeMismatch` shows "Transcript saved, but the remaining text could not be safely inserted" (transcript still saved in app).
  - Checkpoint restore on reconnect (`restoreLiveDeliveryCheckpoint`) prevents double-pasting cumulative text after keyboard reload.
- Constraints: Applies only when the backend is Apple live speech (`response.usesLiveTranscription == true`); Whisper backends deliver text only at completion.
- Evidence: `Voxboard Keyboard/VoiceKeyboardState.swift` (`processLiveSnapshot` ~470-505, `finishWithResponse` ~665-740).
- Status: shipped

### F-KW-06 Session recovery across keyboard reload/suspension
- Surface: Keyboard extension lifecycle.
- Summary: If the keyboard extension is reloaded or suspended mid-recording/transcription, it reconnects to the in-flight IPC session instead of losing it.
- Details:
  - `checkForExistingSession()` (init): reads pending text file first; then recovers an orphaned response only when it matches the current status requestId (otherwise "ignoring stale response"); then reconnects by status `phase`:
    - `.recording` — reconnect (restore ack, checkpoint, live snapshot, timers) if heartbeat fresh, else clear as stale.
    - `.transcribing` — stale cutoff: >90 s with exact progress, >120 s without; else reconnect and keep polling.
    - `.done`/`.error` — clear status.
    - `.listening` — idle or appNotListening.
  - `resumeAfterSuspension()` (viewDidAppear): restarts the poll timer if iOS killed it and checks the shared container immediately, "because Darwin notifications may not be delivered" while suspended.
  - Pending-text persistence: `TranscriptionIPC/pending_text.txt` written when the document proxy is unavailable; inserted on next appearance then deleted.
  - Timer/Darwin callbacks use `DispatchQueue.main.async` + `MainActor.assumeIsolated` — comment notes `Task { @MainActor }` can be silently dropped in keyboard extensions under memory pressure.
- Constraints: Recovery depends on shared-container artifacts surviving extension death.
- Evidence: `Voxboard Keyboard/VoiceKeyboardState.swift` (`checkForExistingSession` ~447-495, `resumeAfterSuspension` ~507-525, pending text helpers ~880-900).
- Status: shipped

### F-KW-07 Model selection from keyboard (‹ MODEL › navigator)
- Surface: Keyboard toolbar model navigator (‹ / › chevrons around a status glyph).
- Summary: The user can cycle transcription backends directly from the keyboard. "Automatic" (Apple Speech) is always first; locally downloaded Whisper models (downloaded in the main app) follow. Selection persists to shared UserDefaults and stays in sync with the main app.
- Details:
  - `refreshModelCache()`: `WhisperModelInfo.availableModels.filter { $0.isDownloaded }`; persisted ID from `AppConstants.selectedModelKey`; falling back to index 0.
  - `previousModel()`/`nextModel()` wrap circularly; selection haptic (`UISelectionFeedbackGenerator`) fires via `modelChangeCount` change.
  - Persisting a local model also writes `AppConstants.selectedFallbackModelKey`.
  - Guard: "Automatic" requires `automaticBackendReadyKey == true`; if not ready and no downloaded models → `.noModel` ("Open Vox.md" prompt).
  - Model cache refreshed on every `viewDidAppear` (models may have been downloaded while keyboard hidden) and lazily inside `startRecording`.
  - If the model disappears mid-cycle, `startRecording` refreshes and retries once.
- Constraints: Models must be downloaded in the main app first; keyboard never downloads.
- Evidence: `Voxboard Keyboard/VoiceKeyboardState.swift` (~96-190 model section); `Voxboard Keyboard/VoiceToolbarView.swift` (`modelNavigator` ~48-95).
- Status: shipped

### F-KW-08 Capture flow (preset) selection from keyboard
- Surface: Keyboard (flow state consumed by app at segment transcription).
- Summary: The keyboard remembers the currently selected capture flow/preset (`CapturePresetStore`) and sends its id with each `startSegment` command, so transcribed text is routed by the chosen preset. `nextFlow()` cycles to the next enabled flow.
- Details:
  - `selectedFlowId` refreshed from `CapturePresetStore.selectedFlowId()`; `currentFlow` filters to enabled flows and falls back to the store's selected flow.
  - `refreshFlowCache()` on init and on every `startRecording` tap.
  - The toolbar itself does not expose a flow button in this build; flow switching API exists on state (`nextFlow`) and is logged.
- Constraints: Enabled flows only; flows configured in main app.
- Evidence: `Voxboard Keyboard/VoiceKeyboardState.swift` (~170-200 flow section).
- Status: shipped (API present; no toolbar UI binding found — see Uncertainties)

### F-KW-09 Free-tier usage limit enforcement in keyboard
- Surface: Keyboard record button.
- Summary: Before starting, the keyboard checks `UsageTracker.staticIsAtLimit`; if the free tier is exhausted it blocks recording with "Limit reached — open Vox.md to unlock" and auto-clears after 3 s.
- Details: Only gates `startRecording`; error path identical to other errors (auto-reset via `resetErrorAfterDelay`).
- Constraints: Entitlement/purchase gating from the shared `UsageTracker`.
- Evidence: `Voxboard Keyboard/VoiceKeyboardState.swift` (~250-257).
- Status: gated

### F-KW-10 Sound wave visualization
- Surface: Keyboard toolbar, recording state.
- Summary: A 7-bar Geist-style waveform (white rectangles, square corners, 0.08 s ease-in-out animation) animates from rolling audio levels published by the app via the IPC container.
- Details:
  - `audioLevels` is a 7-element rolling array updated by the poll timer each tick via `TranscriptionIPC.readAudioLevel()`; levels 0.0–1.0; bar min fraction 0.15, max height 20 pt, bar width 3 pt, spacing 2 pt; white at 0.8 opacity.
  - Waveform fades in with `.transition(.opacity)` when status becomes `.recording`; bars reset to zeros in `cleanupPending`.
  - A frozen (zero-level) waveform is the visible symptom the 3 s start-acknowledgement timeout protects against ("avoiding a fake recording with no waveform").
- Constraints: Requires app-side level publication (shared container).
- Evidence: `Voxboard Keyboard/SoundWaveView.swift` (whole file); `Voxboard Keyboard/VoiceKeyboardState.swift` (`audioLevels` ~66-68, poll update ~530-535); `Voxboard Keyboard/VoiceToolbarView.swift` (~30-36).
- Status: shipped

### F-KW-11 Voice-pause auto-stop behavior from the keyboard's perspective
- Surface: Keyboard recording; implemented app-side.
- Summary: The keyboard extension itself contains no silence-detection/auto-stop code; all audio decisions live in the main app's persistent recorder (validated by `VoxboardTests/VoiceAutoStopCoordinatorTests.swift` in the main-app target). The keyboard's stop path is purely manual (Stop button) plus the app-driven status transitions it polls.
- Details: Auto-stop, if active, would surface to the keyboard as an unsolicited `phase == .transcribing` transition in `checkForUpdates` (handled: keyboard flips to transcribing UI, records `segmentStopTime`). No keyboard-side timer cap on recording duration exists.
- Constraints: N/A (app-side feature).
- Evidence: `Voxboard Keyboard/VoiceKeyboardState.swift` (`checkForUpdates` transcribing branch ~560-580); `VoxboardTests/VoiceAutoStopCoordinatorTests.swift` (existence confirms app-side coordinator).
- Status: shipped (app-side; keyboard merely reflects state)

### F-KW-12 Callout actions (long-press accent-key alternates, localized)
- Surface: Standard keyboard keys, long-press.
- Summary: Replaces KeyboardKit's default accent-character callouts with custom per-language alternate maps for 10 languages (en, de, es, fr, it, pt, nl, sv, da, no); falls back to KeyboardKit's `params.standardActions()` for unmapped languages/actions.
- Details:
  - Only `.character` actions get custom actions; key lowercased for lookup.
  - Uppercase handling: alternates are uppercased only if the result is a single character (e.g. "ß" uppercase "SS" is filtered out); if all alternates fail casing, falls back to `standardActions`.
  - Spanish includes `!`→`¡` and `?`→`¿` maps.
  - Language comes from `AppConstants.selectedLanguageKey` ("auto" → no custom map → standard actions).
- Constraints: Limited to the 10 hardcoded language maps; language selection from main app settings.
- Evidence: `Voxboard Keyboard/CalloutActionsProvider.swift` (whole file); wired in `Voxboard Keyboard/KeyboardViewController.swift` (`.keyboardCalloutActions` ~195-205).
- Status: shipped

### F-KW-13 Keyboard haptics setting
- Surface: All keyboard key feedback.
- Summary: Haptic feedback for KeyboardKit keys follows `AppConstants.hapticsEnabled` from the shared defaults; re-applied on every keyboard setup and appear. Toolbar adds its own UIKit haptics: medium impact on record/transcribe start, success notification when transcription completes, error notification on error, selection tick on model change.
- Details:
  - `applyHapticsSetting()` (KeyboardViewController.swift:73-74) sets `state.feedbackContext.settings.isHapticFeedbackEnabled = AppConstants.hapticsEnabled`, reading the value fresh from shared defaults on `viewWillSetupKeyboardView` and again on every `viewDidAppear` so main-app toggles apply without reloading the keyboard.
  - Toolbar UIKit haptics (VoiceToolbarView.swift:41-51): `.onChange(of: voiceState.status)` fires `UIImpactFeedbackGenerator(style: .medium).impactOccurred()` on entering `.recording`/`.transcribing`, `UINotificationFeedbackGenerator().notificationOccurred(.success)` when transcription completes, and `.error` on error; `.onChange(of: modelChangeCount)` fires `UISelectionFeedbackGenerator().selectionChanged()` on model switches.
- Constraints: KeyboardKit key haptics gated by the main app's haptics setting (`AppConstants.hapticsEnabled` in shared defaults); toolbar haptics always fire.
- Evidence: `Voxboard Keyboard/KeyboardViewController.swift` (`applyHapticsSetting` ~92-94); `Voxboard Keyboard/VoiceToolbarView.swift` (`.onChange(of: voiceState.status)` ~38-48).
- Status: shipped

### F-KW-14 Keyboard debug logging
- Surface: Hidden/diagnostic.
- Summary: The extension logs extensively to `KeyboardDebugLog.shared` (every state transition, IPC command, poll throttled to every 30th tick / every 10th for fallback checks). No user-visible UI; purely diagnostic.
- Details:
  - `KeyboardDebugLog.shared` is the shared logger instance (e.g. `KeyboardViewController.swift:6`, used throughout `VoiceKeyboardState.swift`); entries include lifecycle events (`viewDidLoad — keyboard extension loaded`, `viewWillSetupKeyboardView — hasFullAccess=...`), state transitions (`VoiceKeyboardState init — always-on mode`, `❌ No full access`, `Model switched to: ...`), and IPC outcomes (`openAppURL — extensionContext completion: success=...`).
  - Poll-loop logging is throttled (every 30th tick; every 10th for fallback checks) to avoid spam.
- Constraints: none beyond platform minimums (diagnostic-only; no user-facing UI or data written outside the extension's log).
- Evidence: throughout `Voxboard Keyboard/*.swift`.
- Status: hidden

### F-KW-15 Recording artifact retention (WAV + journal delivery receipts)
- Surface: Main app post-keyboard-segment handling (evidenced via tests).
- Summary: After a keyboard-originated segment is delivered, the app removes the WAV and journal WAV via `KeyboardRecordingArtifactRetention.perform`. On any failure the pair is preserved, and cleanup-failed artifacts are protected with `RecordingArtifactDeliveryReceipt`s so a later sweep does not delete undelivered audio.
- Details (from tests):
  - Delivery failure → both files retained, no receipts.
  - Success → both removed, `didRemoveAllArtifacts == true`, retained/unprotected counts 0.
  - Journal cleanup failure → both retained, 2 receipts written, `retainedArtifactCount == 2`, unprotected 0.
  - WAV cleanup failure (journal removed) → 1 retained, 1 receipt for WAV only.
  - Receipt-write failure → both retained and reported as *unprotected* (`unprotectedRetainedArtifactCount == 2`).
- Constraints: Privacy/data-retention behavior: failed deliveries never silently delete user audio.
- Evidence: `VoxboardTests/KeyboardRecordingArtifactRetentionTests.swift` (whole file); types `KeyboardRecordingArtifactRetention`, `RecordingArtifactDeliveryReceipt` in VoxboardShared/main target.
- Status: shipped

### F-KW-16 Pending-text data retention
- Surface: Privacy/data-retention.
- Summary: Recovered-but-uninserted transcripts are written plaintext to `TranscriptionIPC/pending_text.txt` in the shared container; they are deleted immediately after successful insertion. Transcription IPC response/status/live state are all explicitly cleared after a terminal outcome.
- Details:
  - `writePendingText` (~971-976) writes plaintext UTF-8 to `<AppGroup>/TranscriptionIPC/pending_text.txt` atomically when `textInserter` is unavailable ("No textInserter — persisting transcription for recovery", ~842); `readPendingText` recovers it at session init (~408).
  - `clearPendingText` (~983+) runs immediately after successful insertion (~503, ~830/839) or when nothing remains to insert.
  - Terminal outcomes clear all IPC artifacts: `TranscriptionIPC.clearResponse()` + `clearStatus()` in `finishWithResponse` (~715-716), `clearLiveTranscriptionState()` (~700), and `clearStatus()` on stale-session/timeout paths (~436-492).
- Constraints: Requires the shared App Group container (`group.bontecou.Voxboard`); pending text is stored plaintext until insertion.
- Evidence: `Voxboard Keyboard/VoiceKeyboardState.swift` (`writePendingText`/`readPendingText`/`clearPendingText` ~880-900; clears in `finishWithResponse` and timeout paths).
- Status: shipped

---

## Widgets, Controls, Live Activity

### F-KW-17 Widget bundle composition
- Surface: WidgetKit extension.
- Summary: `VoxboardWidgetBundle` exposes `VoxboardRecordWidget` and `VoxboardCaptureWidget` unconditionally; `VoxboardLiveActivity` (iOS 17+) and the two Control Center controls `VoxboardRecordControl` + `VoxboardQuickCaptureControl` (iOS 18+) are availability-gated.
- Details:
  - `VoxboardWidgetBundle` (@main) contains `VoxboardRecordWidget()` and `VoxboardCaptureWidget()` unconditionally.
  - `if #available(iOSApplicationExtension 17.0, *)` gates `VoxboardLiveActivity()`.
  - `if #available(iOSApplicationExtension 18.0, *)` gates both Control Center controls, `VoxboardRecordControl()` and `VoxboardQuickCaptureControl()`.
- Constraints: Live Activity requires iOS 17.0+; Control Center controls require iOS 18.0+; widgets themselves run on the WidgetKit extension's deployment target.
- Evidence: `Voxboard Widget/VoxboardWidgetBundle.swift` (whole file).
- Status: shipped (with OS gates)

### F-KW-18 Quick Record widget (lock screen + home screen)
- Surface: Home screen small widget; lock screen circular + rectangular accessory widgets.
- Summary: A static widget showing mic/listening state from the App Group; tapping opens `voxboard://widget-record` (when enabled) which starts recording in the main app with the durable selected flow.
- Details:
  - Families: `.systemSmall`, `.accessoryCircular`, `.accessoryRectangular`.
  - Timeline: single entry refreshed every 900 s; state read directly from `group.bontecou.Voxboard/TranscriptionIPC/listening_state.json` (deliberately avoids importing VoxboardShared) and `lockScreenQuickRecordEnabled` (defaults to true when unset).
  - Circular: mic icon (`mic.fill`/`mic`/`mic.slash` when disabled), `AccessoryWidgetBackground`.
  - Rectangular: "Vox.md" title + "Listening"/"Tap to record"/"Disabled" status.
  - Small: status dot (accent when listening), big mic, "Tap to Record" or "Enable in Settings".
  - `widgetURL` is nil when Quick Record is disabled → tap does nothing.
- Constraints: Quick Record enable toggle in main app Settings gates interactivity.
- Evidence: `Voxboard Widget/VoxboardRecordWidget.swift` (whole file); `Voxboard Widget/WidgetViews.swift` (family views + previews).
- Status: shipped

### F-KW-19 Widget recording flow selection (explicit vs durable fallback)
- Surface: Record widget & record control deep links; app-side resolution.
- Summary: `WidgetRecordingFlowSelection` resolves which capture flow a widget-triggered recording uses: an explicit `flowId` query parameter wins (persisted to `pendingWidgetRecordFlowIdKey`), a plain `voxboard://widget-record` URL clears any stale explicit flow, and resolution falls back to the durable selected flow when the requested flow is missing or disabled.
- Details (from tests):
  - Static widget URL clears stale `pendingWidgetRecordFlowIdKey`.
  - `?flowId=configured` persists "configured".
  - Legacy widget (no flowId) → durable selected flow, `explicitlyRequestedFlow == nil`.
  - Configured Control Center flow (enabled) keeps its explicit flow even when another flow is selected in-app.
  - Disabled requested flow → falls back to durable selected flow.
- Constraints: Explicit `flowId` is honored only when the flow exists and is enabled; otherwise resolution falls back to the durable selected flow persisted in shared defaults (`CapturePresetStore`).
- Evidence: `VoxboardTests/WidgetRecordingFlowSelectionTests.swift` (whole file); types `WidgetRecordingFlowSelection`, `AppConstants.pendingWidgetRecordFlowIdKey` in shared code.
- Status: shipped

### F-KW-20 Quick Capture widget (home screen + lock screen, multi-action)
- Surface: Home screen small/medium/large; lock screen circular/rectangular.
- Summary: Static widget that deep-links into the main app's durable Markdown capture draft. Larger sizes expose a grid of capture-type shortcuts (Note, Photo, Screenshot, Camera, File, Link, Scan, Sketch, Voice), each a distinct `Link` with its own `voxboard://capture?...` URL.
- Details:
  - Families: `.accessoryCircular`, `.accessoryRectangular`, `.systemSmall` (default case), `.systemMedium` (5 actions: Note/Photo/Scan/Sketch/Voice), `.systemLarge` (9-action adaptive grid).
  - URL format: `voxboard://capture?source=widget[&action=<action>][&preset=<selectedProfileID>]` — currently selected Capture Preset Profile is appended automatically.
  - Timeline policy `.never` (fully static).
  - Each action button: 9 pt bold labels, 54 pt min height, accessibility label equal to title; icons are `widgetAccentable()`.
- Constraints: None beyond widget installation; requires main app to handle the deep links.
- Evidence: `Voxboard Widget/VoxboardCaptureWidget.swift` (whole file).
- Status: shipped

### F-KW-21 Live Activity + Dynamic Island
- Surface: Lock screen Live Activity banner; Dynamic Island (expanded/compact/minimal).
- Summary: An ActivityKit Live Activity (`VoxboardActivityAttributes`/`VoxboardLiveActivityState`, published by the main app) mirrors the persistent-recorder state with three visual states — ready, segment recording, transcribing — and embeds App-Intent buttons to start and stop recording directly from the Live Activity.
- Details:
  - Lock screen banner: black tint, white foreground; 44 pt circular icon (red-tinted when recording); states: "Recording" + running timer (`Text(timerInterval:)`), "Processing audio · X%" + linear progress bar, or "Tap to record".
  - Dynamic Island expanded: leading icon+title ("Recording"/"Processing"/"Vox.md"), trailing running timer / percent / "Working" / "Ready", bottom linear transcription progress (accessibility "Transcription progress" / "X% complete") + Record/Stop button.
  - Compact leading: state icon (waveform/hourglass/mic, tinted red when recording); compact trailing: timer (max 44 pt), percent, "…", or "Ready"; minimal: icon only.
  - Buttons: `StartRecordingLiveActivityIntent()` (a `LiveActivityIntent` defined in the main app at `Voxboard/LiveActivityRecordingIntents.swift`) when idle; `StopRecordingLiveActivityIntent(requestId:)` when a segment is active — note there is **no pause** interaction, only start/stop.
  - Transcribing state shows a non-interactive hourglass capsule with percent.
- Constraints: iOS 17.0+ (`@available(iOS 17.0, *)`); requires main app to run/publish the activity.
- Evidence: `Voxboard Widget/VoxboardLiveActivity.swift` (whole file, esp. `RecordButton` ~148-185, state extension ~186-215); intent implementations in `Voxboard/LiveActivityRecordingIntents.swift`.
- Status: shipped

### F-KW-22 Record control (Control Center / lock screen bottom slot)
- Surface: iOS 18 Control Center & lock screen control slots.
- Summary: `VoxboardRecordControl` is an `AppIntentControlConfiguration` control whose button runs `OpenVoxboardRecordIntent` with a user-configured capture preset (`VoxEntity`), opening the app to record with that preset.
- Details:
  - User-configurable (`promptsForUserConfiguration()`) via `SelectVoxboardRecordVoxIntent` (parameter `vox`).
  - State: enabled flag from `AppConstants.lockScreenQuickRecordEnabled` (main app Settings); disabled shows "Off" + `mic.slash`, action hint "Disabled in Vox.md Settings", and `.disabled(!isEnabled)`.
  - Enabled label: preset name + symbol; action hint "Record with <preset>".
  - Provider: `AppIntentControlValueProvider` with `previewValue` and async `currentValue`.
- Constraints: iOS 18.0+; Quick Record toggle gates the control.
- Evidence: `Voxboard Widget/VoxboardRecordControl.swift` (whole file); intent in `Voxboard/OpenVoxboardRecordIntent.swift`.
- Status: shipped

### F-KW-23 Quick Capture control (Control Center)
- Surface: iOS 18 Control Center.
- Summary: Static `ControlWidget` running `OpenVoxboardQuickCaptureIntent` — labeled "Quick Capture" with `square.and.pencil` icon, action hint "Open Quick Capture". No configuration or state.
- Details:
  - `StaticControlConfiguration(kind: "VoxboardQuickCaptureControl")` with a single `ControlWidgetButton(action: OpenVoxboardQuickCaptureIntent())`; label "Quick Capture" + `square.and.pencil`, `controlWidgetActionHint("Open Quick Capture")`, `displayName("Quick Capture")`, `description("Open a durable Markdown capture draft in Vox.md.")`.
  - No user configuration prompt, no value provider, no dynamic state — always-on static action.
- Constraints (existing): iOS 18.0+.
- Constraints: iOS 18.0+.
- Evidence: `Voxboard Widget/VoxboardQuickCaptureControl.swift` (whole file); intent in `Voxboard/OpenVoxboardQuickCaptureIntent.swift`.
- Status: shipped

---

## Share Extension

### F-KW-24 Share extension UI & load flow
- Surface: iOS share sheet ("Capture to Vox.md").
- Summary: `ShareViewController` hosts a SwiftUI `NavigationStack` form (`ShareCaptureView`) that loads the shared items into a staging directory in the App Group, reads the Capture library (destinations) and enabled preset profiles from shared defaults, and lets the user pick a preset, add a note, then send.
- Details:
  - Loading spinner state; error section rendered inline; error messages announced via `UIAccessibility.post(.announcement)` for VoiceOver.
  - Toolbar: Cancel/Done (cancellation side) and Send/"Open Vox.md"/"Sending…" (confirmation side; disabled while loading/submitting or when no destination resolves).
  - After queueing, the cancel button becomes "Done" and the confirmation button becomes "Open Vox.md".
  - Loading failure paths: missing App Group container → "Shared capture storage is unavailable."; no resolvable destination → "Configure a destination for a Capture Preset in Vox.md first." (`ShareCaptureError.destinationRequired`).
  - Cancellation is request-aware: if enqueue is mid-flight, deletion of staging is deferred until submit reaches a terminal state (queued or failed); queued shares cancel via `completeRequest`, pre-submit cancels remove staging and call `cancelRequest` with `NSUserCancelledError`.
- Constraints: App Group `group.bontecou.Voxboard` required.
- Evidence: `Voxboard Share Extension/ShareViewController.swift` (`ShareViewController` ~12-40, `ShareCaptureModel.load` ~58-125, `cancel` ~290-310, `ShareCaptureView` ~440-510).
- Status: shipped

### F-KW-25 Accepted input types
- Surface: Share extension item loading (`ShareItemLoader`).
- Summary: Accepts http/https URLs (with title from `suggestedName`), plain text, and files — classified into image, audio, or generic file payloads; each provider is processed in priority order URL → text → file.
- Details:
  - URL: only `http`/`https` schemes (lowercased scheme check) → `.url(url, title:)`.
  - Text: `UTType.plainText` → `.text`, counted against the text budget.
  - File: first registered type identifier conforming to image/audio/movie/pdf/data; copied into `Capture/inbox-staging/<requestID>/`; payload kind by conformance: `.image(asset, altText: suggestedName)`, `.audio(asset, transcript: nil)`, else `.file(asset)`.
  - Screenshot sharing is handled as an image (no special-cased branch beyond the image conformance).
  - Directory shares are rejected (`CaptureAssetStagerError.sourceIsDirectory`).
  - Providers with no usable type are silently skipped; providers yielding no payload text fall to file copy only if a conforming type exists.
  - Duplicate filename collision → `-2`, `-3`, … suffixing (`uniqueURL`).
  - Budgets: `CaptureInputBudget.reserveSharedItems(count)`, `reserveText(characters:)` (shared texts + user note), `reserveAsset(bytes:)` per copied file; oversized assets rejected against `CaptureAssetStager.defaultMaximumByteCount` (checked both on source and on the copied file, with rollback delete of the partial copy).
  - Missing file (provider fails to materialize) → "The shared file disappeared before Vox.md could copy it."
  - Empty share (no payloads and empty note) → "There is no supported content to capture."
- Constraints: Supported types limited by `preferredFileType` conformance list.
- Evidence: `Voxboard Share Extension/ShareViewController.swift` (`ShareItemLoader` ~317-440).
- Status: shipped

### F-KW-26 Preset routing & destination resolution
- Surface: Share extension preset picker.
- Summary: The user's enabled Capture Preset Profiles populate a picker (defaulting to the shared selected profile); each selection resolves the destination via `CapturePresetRouteResolver.destinationID` in `.inherited` mode with the library default and legacy flow bindings as fallbacks.
- Details:
  - Profiles with `captureDestinationID == nil` fall back to `library.legacyFlowBindings[profileID]`.
  - Legacy flow fallback is allowed only when the user has not completed owned-route migration (`hasOwnedRouteMigration`).
  - Changing the picker persists the selection app-wide (`selectCaptureProfile` in shared defaults) — sharing also updates the main app's active preset.
  - Resolved destination shown via `LabeledContent("Destination", value: destination.rootName)`.
  - Picker disabled once queued (`isQueuedForLater`).
  - The preset's `staticFrontmatter` and processing mode flow into the `CaptureRequest` (`voxProcessingState`: `.pending` if processing enabled and mode ≠ none, `.notRequested` if no profile, else `.applied`).
- Constraints: At least one destination must exist or the sheet fails with a configuration error.
- Evidence: `Voxboard Share Extension/ShareViewController.swift` (~40-105, `submit` ~145-165).
- Status: shipped

### F-KW-27 Inbox claim flow (queue → open app)
- Surface: Share extension submit path.
- Summary: On Send, the extension enqueues a durable `CaptureRequest` into `CaptureInbox` (App Group) and then opens `voxboard://capture-request?id=<uuid>` so the main app claims and delivers it. If the app can't be opened, the share stays safely queued with a message telling the user to open Vox.md manually.
- Details:
  - `requestID` is a fresh UUID shared between the staged payload dir, the request, and the callback URL.
  - Success path: `extensionContext.open(callback)` → `completeRequest`.
  - Failure path: "Capture is safely queued in Vox.md. Open Vox.md to finish delivery, then tap Done here." — user retains Done button.
  - If cancellation races the enqueue, the request still completes cleanly.
  - Staging directory (`Capture/inbox-staging/<uuid>/`) removed on cancel/failure paths only.
- Constraints: App must be installed (it is, by definition of the extension); opening may still fail depending on host app.
- Evidence: `Voxboard Share Extension/ShareViewController.swift` (`submit` ~145-230, `openQueuedCapture` ~270-285).
- Status: shipped

### F-KW-28 Location policy handling in the share sheet
- Surface: Share extension confirmation dialog.
- Summary: If the selected preset has an enabled location policy, the extension resolves location via `CaptureLocationService` and applies the policy's `unavailableBehavior`: `.ask` shows a dialog, `.cancel` aborts the share, `.sendWithoutLocation` proceeds.
- Details:
  - Dialog options: "Retry", "Send Without Location", "Always Send Without Location for This Preset" (persists `.sendWithoutLocation` as the preset's behavior in shared defaults and updates local state), "Cancel".
  - Message reassures retention: "The shared items are preserved while you decide."
  - Explicit send-without sets a `locationDecisionOverride = .sendWithoutLocation` on the request so the main app doesn't re-ask.
  - Dismissing the dialog counts as cancel.
- Constraints: Only when preset has `locationPolicy.isEnabled`.
- Evidence: `Voxboard Share Extension/ShareViewController.swift` (~165-200, ~255-290, dialog ~476-495).
- Status: shipped

### F-KW-29 Optional capture note
- Surface: Share sheet "Add a note" TextEditor (min 130 pt).
- Summary: Free-text note prepended as a `.text` payload before the shared items; trimmed; counted against the same text budget as shared text; disabled once queued; accessibility label "Optional capture note" with hint "Adds text before the shared content".
- Details:
  - Note is whitespace-trimmed on submit (`note.trimmingCharacters(in: .whitespacesAndNewlines)`, ShareViewController.swift:144) and its character count is reserved against the same `CaptureInputBudget.reserveText` budget as shared text items (~148-152); if non-empty it is appended as a `.text` payload *before* the loaded shared items (~155).
  - Editor: `TextEditor` in an "Add a note" section (~523-529), `frame(minHeight: 130)`, `.disabled(model.isQueuedForLater)`, VoiceOver label "Optional capture note" with hint "Adds text before the shared content".
- Constraints: none beyond platform minimums; shares the capture text budget with shared text items.
- Evidence: `Voxboard Share Extension/ShareViewController.swift` (~145-165, ~465-472).
- Status: shipped

---

## File-by-file coverage checklist

| File | Read completely | Notes |
|---|---|---|
| Voxboard Keyboard/VoiceKeyboardState.swift (989 ln) | ✅ | Core IPC/state machine |
| Voxboard Keyboard/VoiceToolbarView.swift (212 ln) | ✅ | Toolbar UI |
| Voxboard Keyboard/KeyboardViewController.swift (209 ln) | ✅ | Root controller + URL opening |
| Voxboard Keyboard/CalloutActionsProvider.swift (135 ln) | ✅ | Accent callouts |
| Voxboard Keyboard/SoundWaveView.swift (26 ln) | ✅ | Waveform |
| Voxboard Widget/VoxboardLiveActivity.swift (215 ln) | ✅ | Live Activity / DI |
| Voxboard Widget/VoxboardCaptureWidget.swift (141 ln) | ✅ | Capture widget |
| Voxboard Widget/WidgetViews.swift (124 ln) | ✅ | Record widget views |
| Voxboard Widget/VoxboardRecordWidget.swift (83 ln) | ✅ | Record widget |
| Voxboard Widget/VoxboardRecordControl.swift (49 ln) | ✅ | iOS 18 control |
| Voxboard Widget/VoxboardQuickCaptureControl.swift (21 ln) | ✅ | iOS 18 control |
| Voxboard Widget/VoxboardWidgetBundle.swift (17 ln) | ✅ | Bundle |
| Voxboard Share Extension/ShareViewController.swift (592 ln) | ✅ | Share sheet |
| VoxboardTests/KeyboardRecordingArtifactRetentionTests.swift | ✅ | Supplementary |
| VoxboardTests/WidgetRecordingFlowSelectionTests.swift | ✅ | Supplementary |

(Info.plist / entitlements files were listed but are outside the declared Swift scope; App Group `group.bontecou.Voxboard` is confirmed from code.)

## Uncertainties
- **Flow switching UI in keyboard (F-KW-08):** `nextFlow()` exists on `VoiceKeyboardState` but no toolbar control in `VoiceToolbarView.swift` invokes it. The keyboard sends the currently selected flow with every segment; users may switch flows only from the main app (or a surface not in this scope). Possibly vestigial or pending UI.
- **Live Activity "pause" interaction:** The task brief mentions start/pause/stop; only start (`StartRecordingLiveActivityIntent`) and stop (`StopRecordingLiveActivityIntent`) buttons exist in `VoxboardLiveActivity.swift`. No pause control found; pause may be implemented app-side or not exist.
- **Shared-code internals** (`TranscriptionIPC`, `LiveTranscriptionDeliveryReducer`, `TranscriptionInsertionPlanner`, `CaptureInbox`, `CaptureAssetStager` limits, `UsageTracker` limits, `VoxboardActivityAttributes`) live in VoxboardShared/main app and were inferred from call sites and tests, not read line-by-line (out of declared scope). Exact byte/character budget numbers are not stated in the in-scope files.
- **Info.plist activation rules** (e.g., `NSExtensionActivationRule` accepted type UTIs for the share sheet, keyboard `RequestsOpenAccess`) not read; share-sheet acceptance described above is what the loader code accepts, which may be broader/narrower than the plist activation rule.
- **`CapturePreset` vs `CapturePresetProfile`**: the keyboard uses legacy `CapturePresetStore` flows; the share extension and capture widget use `CapturePresetProfileStore` profiles. Whether these are one unified system post-migration is not determinable from in-scope files alone.
