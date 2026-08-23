# Apple Watch Surface Feature Inventory (LID = WT)

Scope: `Voxboard Watch/`, `Voxboard Watch Shared/`, `Voxboard Watch Widget/`, with phone-side counterparts (`Voxboard/WatchRecordingPipeline.swift`, `Voxboard/WatchRecordingController.swift`, `Voxboard/WatchRecordingBackgroundLease.swift`) and `VoxboardTests/Watch*` used as supplementary evidence only.

---

### F-WT-01 Watch local recording (start / stop)
- Surface: Watch app main screen (`WatchRecorderView`), Record button; widget/complication deep link (`voxboardwatch://toggle-recording`); App Intents (`ToggleVoxboardWatchRecordingIntent`).
- Summary: Records audio locally on the watch with `AVAudioRecorder` into `Documents/WatchRecordings/watch-<uuid>.m4a`. Recording starts only after microphone permission is granted and (when the iPhone has sent a preset-availability payload) a Capture Preset with a full snapshot is selected. Stopping journals the recording durably, optionally resolves location once, adds it to the local queue, and immediately begins sync.
- Details:
  - `start(using:)` guards: already-recording; `hasPresetSelectionAvailabilityPayload && !presetSelectionIsAvailable` → error "Enable a Capture Preset in Vox.md on iPhone before recording."; microphone permission denied → error "Microphone permission required on Apple Watch."
  - Audio session: category `.record`, mode `.default`, activated before recording, deactivated on stop/cancel/error.
  - Format: AAC (`kAudioFormatMPEG4AAC`), 16 kHz sample rate, mono, high encoder quality (`recordingSettings`).
  - Filename `watch-<UUID>.m4a`; metering disabled.
  - Before `record()`, the active recording is journaled to `active-recording.json` (`saveActiveRecording`); if journaling fails, the recorder is stopped, file deleted, error "Could not safely journal this Watch recording."
  - If `recorder.record()` returns false: active journal cleared, file removed, error "Could not start Watch recording."
  - `stopAndQueue(using:)`: stops recorder, computes duration `max(duration, recorder.currentTime)`, deactivates audio session, verifies file exists ("Watch recording file was not saved." if missing), journals a stop-state item, resolves location if preset policy requires it, upserts into queue index, clears active journal, sets message "Saved on Watch. Syncing to iPhone…", then calls `syncPending`.
  - `toggle(using:)` maps Record↔Stop based on `isRecording`.
  - `handleDeepLink(_:)` handles scheme `voxboardwatch` with hosts `start-recording`, `stop-recording`, `toggle-recording`; unknown hosts fall through to `start`.
  - Recording carries preset ID/name/snapshot from `bridge.snapshot` at start time.
- Constraints: watchOS; requires NSMicrophoneUsageDescription (present in `Voxboard Watch/Info.plist`). Preset gating only applies when the iPhone has sent the preset-availability payload (older/absent payload defaults to allowed).
- Evidence: `Voxboard Watch/WatchLocalRecorder.swift` — `Phase`, `start(using:)` (~L240-310), `stopAndQueue(using:)` (~L355-430), `recordingSettings`, `makeRecordingURL`, `recordingsDirectoryURL`; deep link constants in `Voxboard Watch Shared/WatchPhoneBridge.swift` `WatchRecordingDeepLink`.
- Status: shipped

### F-WT-02 Pause / resume recording
- Surface: Watch app recording screen (Pause/Resume button).
- Summary: Pauses the active AVAudioRecorder without ending the session; resume continues appending to the same file. UI shows paused state with accumulated duration and a "Resume • Stop • Cancel" hint.
- Details:
  - `pauseRecording()`: only from `.recording`; `recorder.pause()`, duration frozen at `max(duration, recorder.currentTime)`, timer stopped, phase → `.paused`.
  - `resumeRecording()`: only from `.paused`; if `recorder.record()` fails, non-destructive error message "Could not resume this recording. Stop to save what was captured." (stays paused).
  - `isRecording` includes `.paused`; `isPaused` exposes paused state.
  - Widget snapshot maps paused → `.paused` with frozen `recordingDuration`; inline widget shows "Paused m:ss".
  - Pause/Resume button disabled while `isSending`.
- Constraints: none beyond recording being active.
- Evidence: `Voxboard Watch/WatchLocalRecorder.swift` — `pauseRecording()`, `resumeRecording()`, `togglePause()`; `Voxboard Watch/WatchRecorderView.swift` — `pauseResumeButton`, `recordingStatusContent`.
- Status: shipped

### F-WT-03 Cancel recording (delete without sync)
- Surface: Watch app recording screen (Cancel button, below Stop/Pause).
- Summary: Stops and permanently deletes the in-progress recording and its audio file; nothing is journaled to the queue or synced.
- Details:
  - `cancelRecording()`: stops recorder, `recorder.deleteRecording()`, clears all state and the active journal, deactivates the audio session, removes the file if it still exists on disk.
  - If file deletion fails: phase `.error("Could not delete the canceled recording.")` and message "Recording stopped, but its file could not be deleted from this Watch."
  - Success: phase `.idle`, message "Recording canceled and deleted." Accessibility hint: "Stops and permanently deletes this recording without syncing it to your iPhone."
- Constraints: none.
- Evidence: `Voxboard Watch/WatchLocalRecorder.swift` — `cancelRecording()`; `Voxboard Watch/WatchRecorderView.swift` — `cancelRecordingButton`.
- Status: shipped

### F-WT-04 Recording timer
- Surface: Watch app recording card; widget timer text.
- Summary: Displays elapsed recording time, updated every 0.25 s from the recorder's device clock so the timer stays accurate.
- Details:
  - `Timer.scheduledTimer(withTimeInterval: 0.25)` polls `recorder.currentTime`; `duration = max(duration, currentTime)` (monotonic, never decreases).
  - Format `m:ss` or `h:mm:ss` (`formattedDuration`), monospaced digits, scale-to-fit.
  - Widget snapshot stores `recordingStartedAt = now - duration` while recording so the widget/inline can render a live `Text(date, style: .timer)`.
- Constraints: timer view only when `phase == .recording && recordingStartedAt != nil` (`shouldShowTimer`).
- Evidence: `Voxboard Watch/WatchLocalRecorder.swift` — `startTimer()`, `publishWidgetSnapshot()`; `Voxboard Watch Widget/VoxboardWatchRecordWidget.swift` — `shouldShowTimer` usage in `inline`/`subtitleText` (in WatchPhoneBridge.swift snapshot struct).
- Status: shipped

### F-WT-05 Recorder state machine & status UI
- Surface: Watch app status card, header badge, buttons.
- Summary: A 10-state phase machine drives localized title, subtitle, badge, icon, and tone. Status card collapses to a compact form when idle and expands when recording.
- Details:
  - Phases: `idle`, `recording`, `paused`, `locating`, `transferring`, `waitingForPhone`, `transcribing`, `delivering`, `transferred`, `error(String)`.
  - Badge labels: Live / Paused / Location / Sync / Queued / Text / Save / Sent / Alert / Ready|Queue.
  - Status symbols per phase (`waveform`, `pause.fill`, `location.fill`, `iphone.radiowaves.left.and.right`, `iphone.badge.checkmark`, `waveform.badge.magnifyingglass`, `arrow.up.doc`, `checkmark`, `exclamationmark.triangle.fill`, `tray.full`/`mic.fill`).
  - Tones: destructive (recording, error), active (mid-flight), neutral (idle, empty queue).
  - Transient success: after all recordings delivered, phase `.transferred` for 3.5 s then auto-reset to `.idle` (`scheduleTransientSuccessReset`, cancellable).
  - `phaseForMostAdvancedRemoteStatus()` ranks delivering > transcribing > transferring > transportFailed > failed > waitingForPhone across the queue and drives aggregate UI; `messageForMostAdvancedRemoteStatus()` prefers the iPhone's per-recording `remoteMessage` (trimmed, empty ignored).
  - Idle-with-queue title: "Saved"/"Ready", subtitle uses `queueSummary` including location-unavailable outcome counts (ask / send without location / cancel counts).
  - Animated waveform (`WatchWaveformView`, 9 sine-driven bars, `TimelineView(.animation(minimumInterval: 0.12))`) replaces a pause icon when paused; hidden from accessibility.
  - Accessibility: combined status card label ("Vox.md recording at m:ss. …"), per-button labels/hints in both English semantics and localized strings.
- Constraints: none.
- Evidence: `Voxboard Watch/WatchLocalRecorder.swift` — `Phase`, `title`, `subtitle`, `queueSummary`, `phaseForMostAdvancedRemoteStatus()`; `Voxboard Watch/WatchRecorderView.swift` — `statusCard`, `statusHeadline`, `phaseBadgeLabel`, `statusTone`, `statusSymbolName`, `accessibilityStatusLabel`.
- Status: shipped

### F-WT-06 Watch design system (Geist-on-watch)
- Surface: All watch app and preset-picker views.
- Summary: A compact translation of the iOS Geist theme: dark-only palette, fixed spacing tokens, pill status badges, and three button variants (primary/secondary/destructive) with 44 pt minimum tap height.
- Details:
  - `WatchGeist` color tokens (background 0.102, surface, border opacities, blue/red accents and their backgrounds), spacing 4/8/12/16, radii 8/12/full.
  - `WatchGeistButtonStyle`: primary (text-colored background), secondary (bordered), destructive (red); pressed-state color shifts; disabled opacity 0.55.
  - `.preferredColorScheme(.dark)` forced; scroll indicators hidden.
  - `WatchStatusBadge`: dot + label capsule, scale-to-fit text.
- Constraints: watchOS only file.
- Evidence: `Voxboard Watch/WatchRecorderView.swift` L10-160 (`WatchGeist`, `WatchStatusTone`, `WatchStatusBadge`, `WatchGeistButtonStyle`).
- Status: shipped

### F-WT-07 Capture Preset selection on Watch
- Surface: Watch app "Capture Preset" card → sheet picker (`WatchCapturePresetPickerView`).
- Summary: Lists preset summaries synced from iPhone; tapping one sends a durable, idempotent selection request that the iPhone must acknowledge with an exact request token before the Watch adopts the new preset. The full preset snapshot (not just a name) is confirmed and persisted, because recordings are processed with the preset captured at record time.
- Details:
  - Picker rows show symbol, display name, selected checkmark, or per-row `ProgressView` while pending; disabled (0.55 opacity) during recording.
  - Pending status text: "Waiting for iPhone. Until confirmed, recordings keep using the selected preset above." Auto-dismisses when the requested preset becomes the confirmed selection and state returns to `.idle`.
  - `selectPreset(id:)` local guards: preset not in `availablePresets` → "This Capture Preset is no longer available. Refresh from iPhone."; already selected → clears pending, no-op; WatchConnectivity unsupported → "WatchConnectivity is unavailable."
  - Durable request protocol (`PendingWatchPresetSelection`): UUID `requestID`, `epoch` + `sequence` counters (explicit Int64 for arm64_32 32-bit Int devices; sequence wraps at Int64.max by rolling epoch); persisted in UserDefaults (`watchPresetSelection.pending.v1`, `.epoch.v1`, `.sequence.v1`).
  - Ack protocol (`WatchPresetSelectionAcknowledgement`): outcome `accepted`/`rejected`/`stale`, matched only on exact (requestID, presetID, epoch, sequence). `stale`/`rejected` still adopt whatever preset iPhone currently confirms, then surface the error message.
  - Accepted requires iPhone to echo `selectedPresetID == pending.presetID` plus name and snapshot; otherwise failure "iPhone confirmed the preset but did not send its safe snapshot."
  - Transport: `sendMessage` when reachable; on unknown-outcome error the identical persisted payload is resent via `transferUserInfo` (idempotent). If companion app not installed: pending cleared, "Install Vox.md on iPhone to change presets."
  - Confirmed preset cached in UserDefaults `watchPresetSelection.confirmed.v1` and re-applied over the cached WCSession application-context snapshot at bridge init.
  - If iPhone reports `presetSelectionAvailable = false`: local selection cleared, confirmed store cleared, pending fails with "Enable a Capture Preset in Vox.md on iPhone first."
  - Empty state: iPhone icon + message ("Enable a Capture Preset…" vs "Open Vox.md on iPhone to sync your Capture Presets.") + Refresh button that calls `bridge.requestStatus()`.
  - Truncated preset list hint: "More presets are available in Vox.md on iPhone." (`presetSummariesAreTruncated`).
  - Errors shown in red with a Dismiss button (`clearPresetSelectionError()`).
- Constraints: Requires iPhone-side preset availability flag (payload-gated for backward compatibility); requires companion app installed for selection changes.
- Evidence: `Voxboard Watch Shared/WatchPhoneBridge.swift` — `WatchPresetSelectionStore`, `WatchConfirmedPresetStore`, `selectPreset(id:)`, `setSnapshot` acknowledgement handling; `Voxboard Watch/WatchRecorderView.swift` — `WatchCapturePresetPickerView`, `captureContextCard`.
- Status: shipped

### F-WT-08 Durable local recording queue
- Surface: Watch app queue count on Capture Preset card, sync flow; internal persistence.
- Summary: All Watch recordings persist in `Documents/WatchRecordings/` with an atomically-written `index.json` plus a write-ahead `active-recording.json` journal, with multi-layer crash recovery (journal, orphan `.m4a` scan, corrupt-index backup) so no captured audio is silently lost.
- Details:
  - `WatchLocalQueuedRecording`: id, filename, createdAt, duration, `transportState` (`local`/`transferring`/`uploaded`), `remotePhase`, `remoteRevision`, `remoteMessage`, presetID/Name/Snapshot, `locationOutcome`. Decoder defaults make older manifests forward-compatible.
  - `loadRecoveringInterruptedCapture()`: (1) loads index, drops entries whose audio file is missing or has unsafe filename; (2) recovers `active-recording.json` if its audio exists and isn't already queued — resets transport to `.local`, re-reads duration via `AVAudioPlayer`, backfills `.unavailable` location outcome if the preset's policy would have acquired location; (3) adopts orphan `.m4a` files not in the index (id from `watch-` prefix or filename stem, createdAt from file metadata); sorts by createdAt; (4) saves consolidated index, clears journal; if the index existed but failed to decode, the corrupt file is copied to `index-corrupt-<ts>.json` before rewrite.
  - Filename safety: `isSafeAudioFilename` requires lastPathComponent equality, no `/` or `\`, `.m4a` extension; `audioURL(for:)` uses `precondition` on violation; `save(_:)` throws `fileWriteInvalidFileName` for any unsafe entry.
  - Writes are `.atomic` and key-sorted for deterministic encoding.
  - `pruneMissingQueuedRecordings()` drops queue entries whose audio disappeared before each sync attempt.
  - Queue is unbounded — no count/size limit or eviction policy exists in code; items are removed only after iPhone reports terminal `delivered`/`discarded` (see F-WT-10) or user cancel.
  - Stop-time crash safety: after stop, an origin-time `locationOutcome` placeholder is journaled synchronously, then atomically replaced after location resolution, then the item is upserted into the queue and the journal cleared — each step has a distinct "recording is safe, reopen to recover" error message.
- Constraints: Watch-local Documents directory; not in the app group container (widget reads only the snapshot, not audio).
- Evidence: `Voxboard Watch Shared/WatchLocalRecordingQueueStore.swift` — entire file; `Voxboard Watch/WatchLocalRecorder.swift` — `stopAndQueue`, `upsertQueuedRecording`, `pruneMissingQueuedRecordings`.
- Status: shipped

### F-WT-09 Watch→iPhone file transfer (WatchConnectivity)
- Surface: Automatic after each stop; "Sync Queue (n)" button; launch-time sync.
- Summary: Audio files move to iPhone via `WCSession.transferFile` with rich metadata (recordingID, createdAt, duration, originalFilename, presetID/Name/Snapshot, encoded locationOutcome, sentAt). Transfers are durable and opportunistic; the Watch retains its copy until the iPhone reports end-to-end delivery.
- Details:
  - `transferWatchRecording` guards: WatchConnectivity unsupported → snapshot error "WatchConnectivity unavailable" and returns false; session not yet activated → "Watch sync is still connecting" (returns false); companion app not installed → "Install Vox.md on iPhone" (returns false).
  - Duplicate suppression: checks `session.outstandingFileTransfers` metadata for the same `recordingID`; if found, sets phase `.pending` "Watch recording already syncing" and returns true (not re-queued).
  - `syncPending` filters candidates to files that exist, `transportState != .uploaded`, and not in `inFlightTransferIDs`; each queued transfer marks the item `.transferring` and resets remote fields. If nothing was queued (e.g. session inactive) → error "Saved on Watch, but iPhone sync is unavailable." with retry hint.
  - `didFinish fileTransfer`: posts `watchRecordingTransferDidFinish` notification with success/errorMessage keyed by recordingID; on error sets snapshot error "iPhone sync failed: …"; on success sets `.pending` "Synced to iPhone queue" and sends a best-effort `status` message to wake the iPhone app (`wakeCompanionForQueuedRecording`) — explicitly documented as a hint only, never correctness-critical.
  - Recorder handles the notification: `.uploaded` → phase `.waitingForPhone`; iPhone-side `transportFailed` → item reset to `.local`, "Saved on Watch. Tap Sync Queue to retry."; hard transport error → `.error("Saved on Watch, sync failed.")` with the error message if present.
  - Empty queue + not recording → idle "No Watch recordings waiting to sync."
  - Launch flow (`WatchRecorderView.task`): bridge activates, waits 750 ms (DEBUG demo hooks first), reconciles remote statuses before scheduling any transfer (comment: prevents retransmitting delivered/discarded recordings), then `syncPending`. Re-syncs on every bridge snapshot change.
- Constraints: watchOS↔iOS; file transfer requires WatchConnectivity support and companion app installed.
- Evidence: `Voxboard Watch Shared/WatchPhoneBridge.swift` — `transferWatchRecording`, `wakeCompanionForQueuedRecording`, `session(_:didFinish:error:)`; `Voxboard Watch/WatchLocalRecorder.swift` — `syncPending`, `handleTransferFinished`, `inFlightTransferIDs`.
- Status: shipped

### F-WT-10 Remote status reconciliation & claim/ack protocol
- Surface: Watch app status phases (On iPhone / Transcribing / Saving / Saved); internal.
- Summary: iPhone pushes per-recording `WatchRemoteRecordingStatus` entries (phase, revision, message, updatedAt) in every snapshot payload. The Watch applies only monotonically newer revisions, tracks the iPhone pipeline remotely, removes recordings only on terminal states, and acknowledges terminal removals back to the iPhone.
- Details:
  - Remote phases: `queued`, `transcribing`, `delivering`, `delivered`, `failed`, `transportFailed`, `discarded`.
  - `reconcilingRemoteStatuses`: skips statuses whose `revision <= remoteRevision` (conflict/stale handling); `transportFailed` resets item to `.local` for retry; `delivered`/`discarded` remove the item and emit a terminal acknowledgement.
  - Terminal statuses for recordings no longer in the local queue still produce acknowledgements (dedup).
  - `applyRemoteStatusesPersisting` crash ordering: persist the shrunk queue index BEFORE deleting acknowledged audio files; a crash in between leaves an orphan file that `loadRecoveringInterruptedCapture` re-adopts as a visible recovery item rather than losing audio.
  - `bridge.acknowledge(recordingID:revision:)` sends an `acknowledge` command (sendMessage when reachable, else durable `transferUserInfo`).
  - UI: when the queue empties after terminal acks → `.transferred` with transient 3.5 s reset; otherwise aggregate most-advanced phase (see F-WT-05).
- Constraints: Requires iPhone to send `recordingStatuses` in the snapshot payload.
- Evidence: `Voxboard Watch Shared/WatchLocalRecordingQueueStore.swift` — `reconcilingRemoteStatuses`, `applyRemoteStatusesPersisting`; `Voxboard Watch/WatchLocalRecorder.swift` — `applyRemoteStatuses`; tests: `VoxboardTests/WatchRecordingInboxItemTests.swift`.
- Status: shipped

### F-WT-11 Snapshot state model & epoch/staleness protection
- Surface: All watch UI and widget; internal protocol.
- Summary: `WatchRecordingSnapshot` is the single shared state payload between iPhone, watch app, widget, and the app-group snapshot store. Incoming snapshots are only accepted if not older than current state (epoch → revision → sentAt waterfall), preventing stale/legacy payloads from clobbering state.
- Details:
  - Fields: phase, sentAt, stateEpoch, stateRevision, isQuickRecordEnabled, recordingStartedAt/Duration, message, queuedCount, selected preset id/name/snapshot, preset summaries + truncated flag + presence flags, presetSelection availability + presence flag, presetSelectionAcknowledgement, recordingStatuses.
  - Presence flags (`hasPresetSummariesPayload`, `hasPresetSelectionAvailabilityPayload`) implement partial payloads: fields absent from a payload never overwrite known values.
  - `remoteSnapshotIsCurrent`: epoch mismatch → only newer epoch wins; equal epoch → revision >= current; epoch-aware state never replaced by legacy epoch-less payloads; falls back to revision then sentAt.
  - `preservingRemoteContext` mode (used for local transient snapshots) keeps current sentAt/epoch/revision/remote statuses and takes `max(incoming, current)` queuedCount.
  - A specific rejection (preset ack) racing behind a newer general payload still resolves the exact pending token without adopting the older snapshot's preset metadata.
  - `WatchLocalSnapshotStore` persists the snapshot to app group `group.bontecou.Voxboard` under key `watchLocalRecordingSnapshot` (with `synchronize()`) so the widget process can read live recorder state; every phase/duration/message/queue change triggers a save plus `WidgetCenter.reloadTimelines(ofKind: "VoxboardWatchRecordWidget")`.
  - `isQuickRecordEnabled` phone toggle surfaces as subtitle "Quick Record off" in the snapshot's widget subtitle.
- Constraints: App group `group.bontecou.Voxboard` shared between watch app and widget extension.
- Evidence: `Voxboard Watch Shared/WatchPhoneBridge.swift` — `WatchRecordingSnapshot`, `WatchLocalSnapshotStore`, `remoteSnapshotIsCurrent`, `setSnapshot`.
- Status: shipped

### F-WT-12 Watch location capture (one-shot, per preset policy)
- Surface: Watch app "Adding Watch Location" phase after stop; queue summary location notices.
- Summary: If the selected preset's watch location-acquisition policy is enabled, the Watch performs a single one-shot location fix after stopping, honoring the preset's precision and label requirements, then embeds the outcome in the queued recording.
- Details:
  - `WatchCaptureLocationProvider` (CLLocationManager): `desiredAccuracy` best (exact) or kilometer (coarse); authorization paths — authorized → request; notDetermined → prompt with 60 s timeout; denied/restricted → `.unavailable(.permissionDenied/.restricted)`; exact precision with only reduced-accuracy authorization → `.unavailable(.reducedAccuracy)`; overall 15 s location timeout → `.unavailable(.timeout)`; cancellation → `.unavailable(.cancelled)`.
  - Only fixes with valid accuracy and timestamp within 30 s accepted (`didUpdateLocations` filter).
  - Labels: reverse geocoding via CLGeocoder with a 5 s racing timeout; geocode input uses the privacy-adjusted (city-precision) coordinates — comment: "City privacy is applied before any coordinate leaves the process through Apple's reverse-geocoding service."
  - Snapshot records `source: .watch`, requested `precision`, accuracy, timestamp, optional label (place/city/region/country).
  - Stop-time placeholder journaling ensures a crash during location work retains an unavailable outcome (see F-WT-08).
  - Queue summary (`queueSummary`) counts upcoming iPhone-side behavior for unavailable locations per each preset's `unavailableBehavior`: ask / send without location / cancel — e.g. "iPhone will ask about 2 unavailable locations."
- Constraints: Location Services enabled and per-preset `CaptureWatchLocationAcquisitionPolicy.shouldAcquire` (VoxboardCaptureCore) gate acquisition.
- Evidence: `Voxboard Watch/WatchLocalRecorder.swift` — `WatchCaptureLocationProvider` (bottom of file), `stopAndQueue` location block, `queueSummary`, `locationUnavailableBehavior`.
- Status: shipped

### F-WT-13 Record widget / complication
- Surface: watchOS widget — accessoryCircular, accessoryRectangular, accessoryInline, accessoryCorner (iOS also lists circular/rectangular/inline).
- Summary: A "Record voice note" complication that mirrors live recorder state from the app-group snapshot (falling back to the last WCSession application context), renders a state-tinted waveform mark, and deep-links to `voxboardwatch://toggle-recording` on tap.
- Details:
  - `VoxboardWatchRecordProvider.currentSnapshot()` = `WatchLocalSnapshotStore.load() ?? WatchPhoneBridge.cachedSnapshot()`; timeline is a single entry refreshed after 60 s.
  - Tap: `widgetURL(WatchRecordingDeepLink.toggleURL)`; families render via `RecordIntentButton` (a plain passthrough wrapper; the App Intents in `WatchRecordIntent.swift` all use `openAppWhenRun = true` and only reload timelines — actual start/stop is performed by the app via the deep link / `onOpenURL`).
  - Circular: vector waveform mark on `AccessoryWidgetBackground`; adapts to wide picker rows with "Record voice note / Tap to start" text; widget label "Record note". Comment: face-facing previews must stay vector-drawn — oversized raster assets fail on hardware.
  - Rectangular: mark + "Vox.md" + state dot + subtitle (live timer while recording, "Paused · m:ss", else phase subtitle).
  - Inline: state symbol + live timer / paused duration / phase title ("Recording", "Syncing", "Check Vox.md", "Open iPhone", queued-count subtitle when idle).
  - Corner: bare mark with corner label (Stop / Sync / Text / Save / Sent / Open / Sync|Record).
  - `VoxboardComplicationMark`: 5-bar waveform, geometry-scaled bars, status dot (red for recording/error/unavailable, blue for mid-flight, primary for idle) with glow shadow; `.widgetAccentable` throughout; accessibility-hidden (label comes from widget family semantics).
  - Dot/status color mapping mirrors the app's tone system.
- Constraints: watchOS 9+/WidgetKit AppIntent configuration; snapshot only as fresh as the last app-side save + 60 s timeline refresh.
- Evidence: `Voxboard Watch Widget/VoxboardWatchRecordWidget.swift` (entire file); `Voxboard Watch Widget/VoxboardWatchWidgetBundle.swift`; `Voxboard Watch Widget/WatchRecordIntent.swift`.
- Status: shipped

### F-WT-14 Sync Queue / Refresh Status button
- Surface: Watch app secondary button (appears only when queued recordings exist or phase is error).
- Summary: A context-aware secondary action that either retries transferring unsynced recordings or polls the iPhone for fresh per-recording statuses.
- Details:
  - `syncTitle`: "Sync Queue (n)" when unsynced, "Refresh Status" when everything uploaded, "Sync Status" when empty (recorder-side); view shows "Sync"/"Refresh" labels with spinner while `isSending`.
  - Disabled while recording or while another action is sending.
  - Refresh path: `await bridge.requestStatus()` then `applyRemoteStatuses` (a `status` sendMessage when reachable; falls back to cached application-context snapshot when not — never queues a background `status` via `transferUserInfo`).
  - Accessibility hints vary by whether a queue exists.
- Constraints: none.
- Evidence: `Voxboard Watch/WatchRecorderView.swift` — `secondarySyncButton`, `syncQueueOrRefreshStatus()`, `shouldShowSecondaryAction`; `Voxboard Watch/WatchLocalRecorder.swift` — `syncTitle`.
- Status: shipped

### F-WT-15 Command protocol & unreachable-phone fallbacks
- Surface: Internal bridge; affects UI messages.
- Summary: Commands (`start`, `stop`, `toggle`, `status`, `acknowledge`, `selectPreset`) are sent via `sendMessage` when reachable; otherwise `transferUserInfo` (durable) except `status`, which uses the cached application context.
- Details:
  - Legacy remote-record commands (`start`/`stop`/`toggle`) are still defined; queued background starts are suppressed unless the cached phase is `listening`/`recording` ("Open Vox.md or leave Keyboard mic on.") — a guard against the legacy phone-driven recording mode; the current watch app records locally and uses none of these to start audio.
  - Unreachable `status` returns the cached snapshot; other commands set `.pending` "Sent to iPhone" while preserving remote context.
  - `cachedSnapshot()` from `WCSession.receivedApplicationContext`; returns `.unavailable` ("Open Vox.md on iPhone once.") when empty or unsupported.
  - `companionAppIsInstalled` checked watch-side (`session.isCompanionAppInstalled`), true on iOS builds (file compiles into phone target).
  - Session lifecycle: `activate()` idempotent, applies received application context and resends any pending preset selection; iOS delegates no-op / reactivate on deactivate.
- Constraints: WatchConnectivity availability.
- Evidence: `Voxboard Watch Shared/WatchPhoneBridge.swift` — `WatchRecordingCommand`, `send(_:)`, `fallbackForUnreachablePhone`, `shouldAvoidQueuedBackgroundStart`, `activate()`, WCSessionDelegate extension.
- Status: shipped (start/stop/toggle remote commands: legacy)

### F-WT-16 Microphone permission handling
- Surface: Watch app on first Record tap.
- Summary: Requests record permission before every start, using the modern `AVAudioApplication` API on watchOS 10+ with an `AVAudioSession` fallback for older systems.
- Details:
  - Granted/denied/undetermined branches; undetermined suspends on the system prompt; unknown default treated as denied.
  - Denied → error phase "Microphone permission required on Apple Watch."
- Constraints: watchOS 10.0+ gate for `AVAudioApplication` path; `NSMicrophoneUsageDescription` present in `Voxboard Watch/Info.plist`.
- Evidence: `Voxboard Watch/WatchLocalRecorder.swift` — `requestMicrophonePermission()`.
- Status: shipped

### F-WT-17 Widget snapshot publication
- Surface: Widget/complication state freshness.
- Summary: Every change to recorder phase, start time, message, or queue publishes a `WatchRecordingSnapshot` to the app-group defaults and reloads the widget timeline.
- Details:
  - `didSet` observers on `phase`, `startedAt`, `message`, `queuedRecordings`.
  - `recordingStartedAt` reconstructed as `now - duration` so widget timers restart correctly after resume/pause cycles; nil unless actively recording.
  - Widget phase mapping: locating/waitingForPhone/transferred → `.pending`; error → `.error`; others direct.
- Constraints: App group container shared with widget extension.
- Evidence: `Voxboard Watch/WatchLocalRecorder.swift` — `publishWidgetSnapshot()`, `widgetPhase`.
- Status: shipped

### F-WT-18 DEBUG demo & localization-screenshot modes (hidden)
- Surface: Watch app under DEBUG builds only, driven by launch arguments.
- Summary: Hidden scripted flows and fixed states used for App Store screenshots and demo recordings without touching real audio.
- Details:
  - `--localization-screenshot <state>`: `01-ready`, `02-recording` (42 s fake duration), `03-synced` set fixed UI states.
  - `--voxboard-demo[=]|--watch-demo[=]` modes: `record-flow` (idle → recording → saved → syncing → transferred with timed steps) and `queue-flow` (2 queued → syncing → transferred); demo queue items are synthetic `demo-watch-recording-N` entries; demo task cancellable; `isRunningDemoScript` exposed.
  - Screenshot/demo hooks run before bridge activation/sync in `.task` and return early.
- Constraints: `#if DEBUG` compiled out of release builds.
- Evidence: `Voxboard Watch/WatchLocalRecorder.swift` — `configureLocalizationScreenshotIfNeeded`, `runDemoScriptIfNeeded`, `runDemoRecordFlow`, `runDemoQueueFlow`, `debugDemoMode`; `Voxboard Watch/WatchRecorderView.swift` — `.task` hook.
- Status: hidden (debug-only)

### F-WT-19 Recording Only mode (phone-side, context)
- Surface: Configured via Capture Preset on iPhone (`watchOutputMode == .recordingOnly`); executed entirely on iPhone when a Watch recording arrives.
- Summary: A preset output mode where the Watch's raw `.m4a` is copied directly into a user-chosen folder using a filename template — no transcription, no transcript store, no UI resume needed.
- Details:
  - Phone `WatchRecordingPipeline.deliverRecordingOnly` uses `RecordingOnlyFileExporter` with `CapturePresetWatchRecordingSettings` (folder bookmark, folder name, filename template e.g. `unattended-{id8}`).
  - Test evidence: queued Watch file is copied byte-identical, inbox item reaches `.delivered`, source inbox file is removed, and the background lease identifier ends exactly once.
  - Filename conflicts (`RecordingOnlyFileExportError.filenameConflict`) and pipeline errors have dedicated failure paths; Recording-Only delivery failures notify distinctly (`notifyRecordingOnlyDeliveryFailure`) vs transcribe-mode failures (which surface a transcription-failure message to the Watch — see `WatchRecordingTranscriptionFailureMessageTests`).
  - Preset snapshot changes that stay in Recording Only mode allow retarget of failed items (`isRecordingOnlyRetarget`).
  - Watch side is mode-agnostic: it always records raw audio and attaches the preset snapshot; the mode only changes iPhone-side processing.
- Constraints: Preset must be configured on iPhone with watch output mode + folder bookmark; watchOS records regardless.
- Evidence: `Voxboard/WatchRecordingPipeline.swift` L259-312, L438-474, `deliverRecordingOnly` L689-820; test `VoxboardTests/WatchRecordingBackgroundLeaseTests.swift` `testRecordingOnlyPipelineCopiesQueuedWatchFileWithoutUIResume`.
- Status: shipped

### F-WT-20 Background processing lease (phone-side, context)
- Surface: iPhone app processing Watch recordings; not a watch-side feature.
- Summary: When a Watch file transfer completes while the iPhone is backgrounded, the phone takes a UIKit background-task lease to finish draining/transcribing/delivering; the lease ends exactly once, handles expiration, and start-policy requires either an active lease or foreground.
- Details:
  - `WatchRecordingBackgroundExecutionPolicy.shouldStart(leaseIsActive:applicationIsActive:)` — either true.
  - `WatchRecordingBackgroundLease.begin(recordingID:service:onExpire:)`: exactly-once ending (tested against 100 concurrent `end(.completed)` calls); expiration fires the cancel callback once and ends with `.expired`; expiration during `begin` yields an inactive lease with reason `.expired`; invalid UIKit identifier → lease `.unavailable`, never calls `end`; completion before late expiration suppresses the callback.
  - Pipeline holds `activeBackgroundLease`/`pendingBackgroundLease` and adopts incoming leases while processing.
- Constraints: iOS only (UIKit); the Watch app itself has no wrist-lowering background-audio lease in code — wrist-down continuation is not explicitly managed in these files (see Uncertainties).
- Evidence: `Voxboard/WatchRecordingBackgroundLease.swift` L51-140; `Voxboard/WatchRecordingController.swift` L640; `VoxboardTests/WatchRecordingBackgroundLeaseTests.swift`.
- Status: shipped

### F-WT-21 Data retention & privacy behaviors (cross-cutting)
- Surface: Watch app, queue, transfers.
- Summary: The Watch is the source of truth: audio is retained on Watch until iPhone confirms delivery or discard; cancel deletes audio immediately; location is privacy-adjusted before any external geocode; nothing is deleted on transfer success alone.
- Details:
  - Terminal removal order: persist queue, then delete audio, then ack (crash-safe orphan recovery).
  - Cancel path deletes both the recorder's copy and any residual file.
  - Location coordinates are reduced to preset precision before reverse geocoding leaves the process; only a coarse CLLocation is geocoded even when exact precision was captured.
  - No telemetry/analytics calls anywhere in the watch sources; no cloud endpoints — all traffic is WatchConnectivity to the paired iPhone.
  - Audio lives in app Documents (excluded from backups not configured); widget process only reads a property-list snapshot, never audio.
- Constraints: none.
- Evidence: throughout `WatchLocalRecorder.swift`, `WatchLocalRecordingQueueStore.swift`, `WatchPhoneBridge.swift`.
- Status: shipped

---

## File-by-file coverage checklist

| File | Read | Notes |
|---|---|---|
| `Voxboard Watch/WatchLocalRecorder.swift` | ✅ full | Recorder engine, phases, location provider, demo modes |
| `Voxboard Watch/WatchRecorderView.swift` | ✅ full | UI, design system, preset picker |
| `Voxboard Watch/VoxboardWatchApp.swift` | ✅ full | App entry, onOpenURL |
| `Voxboard Watch/Info.plist` | ✅ (grep) | NSMicrophoneUsageDescription; no WKBackgroundModes |
| `Voxboard Watch Shared/WatchPhoneBridge.swift` | ✅ full | Protocol, stores, WCSession delegate |
| `Voxboard Watch Shared/WatchLocalRecordingQueueStore.swift` | ✅ full | Queue persistence & reconciliation |
| `Voxboard Watch Widget/VoxboardWatchRecordWidget.swift` | ✅ full | Widget families, complication mark |
| `Voxboard Watch Widget/WatchRecordIntent.swift` | ✅ full | Three open-app intents |
| `Voxboard Watch Widget/VoxboardWatchWidgetBundle.swift` | ✅ full | Single-widget bundle |
| `VoxboardTests/WatchRecordingBackgroundLeaseTests.swift` | ✅ full | Lease policy + Recording Only pipeline evidence |
| `VoxboardTests/WatchRecordingInboxItemTests.swift` | listed (not fully read) | Supplementary only; inbox is phone-side |
| `VoxboardTests/WatchRecordingTranscriptionFailureMessageTests.swift` | listed (not fully read) | Supplementary only; phone-side messaging |
| `Voxboard/WatchRecordingPipeline.swift`, `WatchRecordingController.swift`, `WatchRecordingBackgroundLease.swift` | targeted greps | Context-only, per scope |

Asset catalogs, entitlements, and xcstrings were enumerated but not itemized (binary/string resources, no behavior).

## Uncertainties

1. **Haptics**: The task scope mentions "haptics" as a local recording engine behavior, but no haptic API calls (`WKHapticEngine`, `sensoryFeedback`) exist anywhere in the watch sources. Either haptics are system-default from buttons, or the feature does not exist on this surface. Documented as absent.
2. **Wrist-lowering background recording (watch-side)**: No watch-side lease, `WKBackgroundModes`/audio background mode, or always-on session handling exists in `Voxboard Watch/Info.plist` or code. The only lease code is iPhone-side (F-WT-20). Wrist-down behavior is therefore governed by default watchOS audio-session policy, not explicit app code — the task prompt's "background recording lease (keep recording when wrist lowers)" appears to conflate the iPhone-side processing lease.
3. **Screen constraints**: No explicit screen-size constraints found; the design system uses scale-to-fit and fixed sizes that implicitly target 40–45 mm watches. No 38 mm-specific handling visible.
4. **Queue limits/eviction**: No count or byte cap exists in `WatchLocalRecordingQueueStore`; recordings accumulate until delivered/discarded. If product docs promise a limit, it is not in this code.
5. **Legacy remote-record mode**: `start`/`stop`/`toggle` commands and iPhone-driven phases (`listening`) remain in the protocol and in the widget's phase enum, but the Watch app itself never enters `.listening`. These appear to be legacy from a previous phone-driven recording architecture.
6. **Phone-side tests** (`WatchRecordingInboxItemTests`, `WatchRecordingTranscriptionFailureMessageTests`) were not read in full; conclusions about inbox/revision behavior rely on the queue-store code plus the lease test, which was read fully.
