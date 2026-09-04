# iOS App Core — Engine/Service Feature Inventory (Vox.md / Voxboard)

LID = IC. Every feature below is verified in the root-level files of `Voxboard/`. Tests under `VoxboardTests/` referenced where they corroborate behavior.

---

### F-IC-01 Persistent Microphone Listener & Circular Buffer Recorder
- Surface: Capture screen inline recording controls; keyboard extension via IPC; app lifecycle
- Summary: `PersistentRecorder` (@Observable) is the always-on engine that captures mic audio into a 10-minute circular buffer (16 kHz mono, 16,000×60×10 samples ≈ 38 MB) via `AVAudioEngine` tap (4096-frame buffer) with an `AVAudioConverter` when hardware format differs. Segments are marked by buffer index; 2.0 s pre-roll is included before Start. Open once; the keyboard then controls it over IPC.
- Details:
  - `startListening(persistPreference:)` — checks `AVAudioSession.recordPermission`, sets category `.playAndRecord`, mode `.default`, options `[.defaultToSpeaker, .allowBluetooth, .mixWithOthers]`, activates session, installs tap, resets buffer, starts engine; on success registers command observers, starts 0.25 s command polling, starts 5 s IPC heartbeat timer, reloads `VoxboardRecordWidget` timelines, publishes Watch state, starts Live Activity via `LiveActivityController.shared.startIfNeeded()`, persists `autoListenEnabledKey` only when `persistPreference: true`, preloads model, tracks one-shot onboarding analytics markers.
  - `stopListening(endLiveActivity:)` — cancels active segment, removes tap, stops engine, deactivates session with `.notifyOthersOnDeactivation`, writes `isListening=false` IPC state, reloads widget, ends Watch/LiveActivity publication. One-shot recordings pass `endLiveActivity: false` to keep a lightweight processing state on the Lock Screen.
  - Audio interruption handling (`handleAudioInterruption`): `.began` → cancels segment (preserving audio for recovery); one-shot mode stops listening with "Recording interrupted — please try again". `.ended` → full `stopListening()`+`startListening()` restart because iOS silently disconnects taps during long interruptions (phone lock, calls, headphone swaps).
  - Segment safety stop: `maximumSegmentDuration = 9*60+45` (9:45) so the circular buffer's 10-minute retention guarantees finalization before pre-roll overwrite; auto-stop with localized "Recording reached the 9:45 safety limit..." error.
  - Segment too-short check (<0.3 s) and silence check (max amplitude < 0.005) produce "Recording too short" / "No speech detected".
  - Extraction failure self-heal: `endIndex == segmentStartIndex` (dead tap) → error response plus full engine restart (or stop for one-shot); overwritten data → "Audio buffer overwritten — try a shorter recording".
  - Durable segment journal: `IncrementalWAVWriter` writes `segment_active_<sanitized-id>_<uuid>.wav` to the recordings dir on a utility queue behind an `NSLock` so an abandoned/killed recording is recoverable; finalized at segment end, deleted on cancel unless `preserveAudioForRecovery`.
  - WAV export: manual RIFF/PCM16 mono header writer (`writeWAV`) into `recordingsDirectoryURL`.
  - Audio level metering: RMS computed in the tap, normalized `min(1.0, rms*6.0)`, throttled to ~12 Hz (`levelWriteInterval`), written via `TranscriptionIPC.writeAudioLevel` only while a segment is active.
  - `init` clears stale IPC state (listening/status/command/audioLevel/liveTranscription) from a killed previous process and ends orphaned Live Activities.
  - `configureLocalizationScreenshot(story:)` — DEBUG-only fake state for stories `02-live-recording`/`05-live-recording`.
  - DEBUG launch arg `--runtime-queue-pause-after-claim` stalls queued job execution 30 s for testing.
  - `deinit` stops listening and unregisters Darwin observers.
- Constraints: mic permission required; app must run foreground to start listening (background watch starts rejected — see F-IC-09); free-tier limit gates segment start (`usageTracker.isAtLimit` → `needsUnlock = true`).
- Evidence: `Voxboard/PersistentRecorder.swift` (entire file; esp. lines ~100-160 buffer/pre-roll, ~330-470 start/stop listening, ~470-560 interruption, ~3300-3410 duration/safety timer), `CircularAudioBuffer` (VoxboardShared).
- Status: shipped

### F-IC-02 Recording Completion Modes & Command Origins
- Surface: keyboard extension, in-app draft capture, immediate Preset runs, Watch, Live Activity, widgets
- Summary: `RecordingCompletionMode` (`keyboardTranscription`, `captureDraft(attachAudio:)`, `runVox(flowID:)`) determines post-transcription routing, queue delivery (`RecordingJobDelivery`), voice-processing configuration, and default `RecordingCommand.Origin`.
- Details:
  - `completionMode(forExternalCommand:fallbackFlowID:)` maps command origin: `.keyboardExtension` with empty flowId → keyboard transcription-only; pre-`origin` keyboard builds (nil) stay insertion-only; all other origins → Preset run with flowId or fallback.
  - `voiceProcessingConfiguration`: nil for keyboard/preset-delivery; preset-derived only for `captureDraft`.
  - `isAppRecordingSegmentActive` / `isAppRecordingTranscribing` exclude keyboard-origin recordings from app mic UI.
  - Overlapping-start protection: a new keyboard start while a segment is active is rejected with "Finish the current recording first" — the active capture is never inferred stale/canceled (explicit regression guard).
  - Duplicate stop ignored via retained `processingRequestId`; Live Activity stops with no active segment ignored.
- Constraints: none beyond recorder running.
- Evidence: `PersistentRecorder.swift` lines ~25-110, ~3090-3150 (`handleCommandFromBackground`).
- Status: shipped

### F-IC-03 Keyboard IPC Command Channel (Darwin notifications + file polling)
- Surface: Vox.md keyboard extension ⇄ main app
- Summary: The recorder consumes `RecordingCommand` (startSegment/stopSegment/stop) from `TranscriptionIPC` command files, driven by Darwin notifications (`commandNotificationName`, legacy `stopCommandNotificationName`) delivered on a `userInteractive` dispatch queue, plus a 0.25 s file-polling timer as ground truth because iOS can drop Darwin notifications during background transitions.
- Details:
  - `handleStartSegmentFast` marks the buffer position and writes IPC status immediately on the background queue before dispatching UI state to main.
  - `handleStartSegment` (main path) re-asserts the audio session category before each segment because LLM inference/notification sounds can reconfigure it, causing silent taps.
  - Responses written only for non-`inapp-`/`import-` request IDs (prevents stale response.json being pasted into the next text field); in-app errors surface via `lastError`.
  - Fast-path paywall check uses `UsageTracker.staticIsAtLimit`.
- Constraints: keyboard requires the app to have been opened and listening (IPC heartbeat with `lastHeartbeatAt`).
- Evidence: `PersistentRecorder.swift` lines ~3030-3170 (observers/polling/handlers), ~2780-2800 (writeErrorResponse).
- Status: shipped

### F-IC-04 One-Shot In-App / Widget / Shortcut Recording
- Surface: Capture inline controls, Lock Screen/Control Center widget, Shortcuts, Live Activity intents
- Summary: `startOneShotInAppSegment(flowId:completionMode:origin:draftRequestID:)` starts the engine only for this segment when not already listening (`shouldAutoStopListeningAfterCurrentRecording = true`, `persistPreference: false`), then tears down capture immediately on stop so system haptics recover while transcription finishes; the Live Activity optionally lingers in processing state (`shouldEndLiveActivityAfterCurrentTranscription`).
- Details:
  - Guarded by paywall (`isAtLimit` → needsUnlock, "Free limit reached — unlock Vox.md to keep recording").
  - `startInAppSegment` resolves the flow (validated enabled) or falls back to `CapturePresetStore.selectedFlowId()`; builds a `RecordingCommand` with requestId `inapp-<uuid>`.
  - Background task (`beginBackgroundTask`) acquired before audio-session teardown so lock-screen-stopped one-shots can finish transcription.
  - `stopInAppSegment` builds a stop command from the active `segmentRequestId`.
- Constraints: mic permission; Quick Record toggle for external origins; paywall.
- Evidence: `PersistentRecorder.swift` lines ~575-670.
- Status: shipped

### F-IC-05 Audio File Import Pipeline
- Surface: Capture import (file picker / share)
- Summary: `importAudioFile(from:flowId:completionMode:draftRequestID:)` copies a security-scoped source into the recordings dir, converts to Whisper WAV via `AudioFileConverter`, stages a durable `RecordingJobHandoffIntent` before conversion, resolves origin location, and enqueues into the durable recording queue with `source: .importedAudio`.
- Details:
  - Paywall-gated; blocked while a segment is active ("Finish the current recording before importing audio").
  - Original source preserved on any failure ("The imported source was preserved"); draft origin journal cleared on failure.
  - Duration computed from converted then source file; handoff intent finalized with origin/location snapshot; capture queue marked active during staging.
- Constraints: recordings directory access; paywall.
- Evidence: `PersistentRecorder.swift` lines ~680-870.
- Status: shipped

### F-IC-06 Durable Recording Queue & Job Execution
- Surface: all app-owned recordings, imports, Watch pipeline bypass
- Summary: `recordingQueue` (`RecordingJobQueue` over `RecordingJobStore` rooted at `AppConstants.recordingJobsDirectoryURL`) delivers audio through `executeQueuedJob`, holding a `UIBackgroundTask` ("RecordingJob-<id>") for each job, with system-expiration interruption (`interruptForSystemExpiration`) and interactive-work interruption for keyboard requests (`interruptForInteractiveWork`, plus `finishInteractiveWork(includeIdle:)`).
- Details:
  - `setCaptureActive(true/false)` around capture phases; `enqueueAppRecording` snapshots delivery, removes fallback recovery journal on success, and preserves original audio with a user-facing error on enqueue failure.
  - Checkpointing: successful ASR result added to `TranscriptStore` and `UsageTracker.addUsage` **before** external delivery — retries are exactly-once by transcript/delivery ID.
  - Handoff intents (`RecordingJobHandoffIntentStore`) staged before extraction and finalized after origin resolution; failure keeps audio with "The recording was preserved in the queue." / "The original audio was preserved."
  - `PersistentRecordingJobError` failure stages (delivery/storage/transcription) for queue retry classification.
- Constraints: paywall re-checked per job (`transcriptionLimitReached`).
- Evidence: `PersistentRecorder.swift` lines ~1890-2000 (enqueue/executeQueuedJob), ~100-140 (queue setup), `VoxboardTests/` recording queue tests.
- Status: shipped

### F-IC-07 Transcription Orchestration, Progress & Delivery
- Surface: keyboard, in-app, Watch, imports
- Summary: `transcribe(...)` runs backend ASR (with optional fallback model), optional speaker diarization pass, draft staging events, transcript persistence, usage accounting, review-prompt triggers, IPC response for keyboard, and configured export (Preset destination, Smart Folders, Auto-Organize, audio attachment) with checkpointing.
- Details:
  - Live Apple Speech result reuse: if a live coordinator published finalized text, its text is used; if speaker diarization is enabled a timestamped batch pass is preferred, falling back to the live text on failure ("keeping live transcript").
  - Progress handling (`acceptTranscriptionProgress` / `stopAcceptingTranscriptionProgress`): monotonic-only exact fraction; whole-percent dedupe; published to IPC (keyboard mode) and Live Activity only when no segment is active.
  - Speaker diarization: `SpeakerDiarizationService.resolve`; skip reason surfaced as `lastSpeakerDiarizationSkipReason`; only app-owned presets invoke it (keyboard/draft never).
  - Export routing (iOS 26+, `FoundationModelsBackend.isAvailable`): Smart Folders routing skipped when the flow has an explicit export folder; Auto-Organize subfolder generation fallback; both deadline-bounded by `exportRoutingTimeout = 30` s (`withRunningTask(timeout:)`) so a stalled model session never blocks delivery.
  - Precise capture export via `ConfiguredTranscriptCaptureDestinationExporter` (destination IDs, `.queuedForRetry`, `.locationUnavailableCancelled` handling); legacy `TranscriptFileExporter.exportConfigured` path with `folderURLOverride`/`autoOrganizeSubfolder`; `.disabled` export + requested audio → failure event.
  - Audio attachment via `CheckpointedAudioDelivery.deliver` with note/audio/audio-reference transaction directories and queue checkpoints (`markExportedNote`, `markExportedAudio`, `markAudioReferenceAttached`); retained audio removed only when safely deliverable.
  - AI enrichment: if `transcriptEnricher` and `flow.usesAIEnrichment`, `enrichAndUpdate` runs before export so enriched title/tags land in the exported file.
  - Empty text → "No speech detected" response and origin snapshot removal; origin/location persistence failure aborts with "Shared capture storage is unavailable." while preserving audio.
  - `ReviewPromptManager.recordSuccessfulTranscription` called after save; onboarding-completed analytics one-shot.
- Constraints: paywall (`transcriptionLimitReached`); entitlement state affects queue resumption (see F-IC-24).
- Evidence: `PersistentRecorder.swift` lines ~2380-2770.
- Status: shipped

### F-IC-08 Live (Streaming) Transcription Preview
- Surface: keyboard mic preview, Capture inline recording (incl. draft live transcript), Immediate Preset runs
- Summary: For `TranscriptionBackendID.automatic` recordings, `startLiveTranscriptionIfSupported` opens an Apple Speech live session fed by `LiveSegmentTranscriptionCoordinator` polling the circular buffer, publishing incremental finalized/volatile text to IPC (keyboard) and to `liveFinalizedTranscription`/`liveVolatileTranscription`/Capture draft events (app).
- Details:
  - Enabled only when origin is `.keyboardExtension` or requestId has prefix `inapp-`, and model is automatic; draft publishing only for `captureDraft` completion mode.
  - `liveCaptureRequestId`/`liveCaptureSessionID` guard against stale sessions replacing newer text; `clearCaptureLiveTranscription` cancels draft preview via `.cancelLiveTranscript`.
  - On live setup failure → silent batch fallback (log only). On stop, `coordinator.finish(through: endIndex)` returns the live text; `usesLiveDelivery` recorded in the IPC response (`usesLiveTranscription: true`).
  - Immediate Preset runs preview live text without adding it to the Capture draft.
- Constraints: iOS 26+ Apple Speech availability; automatic backend only.
- Evidence: `PersistentRecorder.swift` lines ~1400-1490; `LiveSegmentTranscriptionCoordinator.swift` (full).
- Status: shipped (gated on iOS 26/Apple Speech)

### F-IC-09 Watch Remote Recording Control (WCSession)
- Surface: Apple Watch app ⇄ iPhone
- Summary: `WatchRecordingController` (singleton) receives start/stop/toggle/status/acknowledge/selectPreset commands over WatchConnectivity, routes them into the one-shot recorder, and publishes rich state snapshots (phase, message, queued count, preset summaries, per-recording statuses) via `updateApplicationContext` + immediate `sendMessage` when reachable.
- Details:
  - `startRecordingFromWatch`: guarded by `AppConstants.lockScreenQuickRecordEnabled`; rejected if recorder busy; rejected when app is backgrounded and not already listening ("iOS blocks background mic start. Open Vox.md or leave Keyboard mic on.").
  - `handlePresetSelection`: epoch/sequence staleness protocol with persisted acknowledgements (`watchPresetSelection.*` keys) → outcomes accepted/rejected/stale; selects via `CapturePresetProfileStore.selectCaptureProfile`.
  - State publishing: monotonic epoch + revision counters (revision rollover at Int.max bumps epoch); phase derivation ordered recording → transcribing → delivering → pending → error → listening → idle/unavailable; usage-limit message when the active/selected preset isn't recording-only; preset summaries capped at 32 entries with `presetSummariesTruncated`, sanitized names (64 chars), validated IDs (≤256 bytes, no control chars), symbol whitelist fallback "waveform".
  - Per-recording status batches: ≤30 in-progress, ≤40 queued, ≤20 failed, ≤40 unacknowledged terminal, plus a rotating cursor-batched ≤40 transport-failure entries.
  - `didReceive file`: acquires a `WatchRecordingBackgroundLease` **before** returning (WCSession temp files must be moved synchronously), enqueues into `WatchRecordingInbox`, hands the lease to the pipeline, notifies via local notification when app not active; failure stores transport-failure entry + "Tap Sync on Watch to retry."
  - `notifyWatchRecordingReadyIfNeeded`: singular/plural "Watch recording(s) ready" notifications; suppressed for recording-only successful deliveries.
  - Session activation from `VoxboardAppDelegate` (`activateForBackgroundDelivery`) so background file launches dispatch without a UI scene; `sessionDidDeactivate` reactivates.
- Constraints: WatchConnectivity support; Quick Record setting; notifications authorization (authorized/provisional/ephemeral).
- Evidence: `WatchRecordingController.swift` (full, 833 lines); `VoxboardAppDelegate.swift`.
- Status: shipped

### F-IC-10 Watch Recording Inbox (Durable Store)
- Surface: Watch queue UI; pipeline; recovery flows
- Summary: `WatchRecordingInbox` persists `WatchRecordingInboxItem`s (phase queued/transcribing/delivering/delivered/failed/discarded; failure stages storage/transcription/delivery) to `WatchInbox/index.json` plus per-item sidecar JSON files, under the recordings directory. Original audio is retained until delivery success or explicit discard.
- Details:
  - `enqueue`: dedupes by recordingID; a retry transfer into a missing-audio non-terminal item restores it to `.queued` ("Received retry from Apple Watch"); duplicates of present audio are deleted. Metadata: createdAt, duration, originalFilename, presetID, presetSnapshot JSON, locationOutcome; incompatible snapshot/location payloads mark the item failed with "Update Vox.md on iPhone..." messages.
  - Filename `watch-<sanitized-id>.<ext|m4a>`; sidecar written before moving the temp file (interrupt-safe).
  - `loadUnlocked` recovery: merges higher-revision sidecars; migrates unscrubbed terminal records (privacy scrub `scrubSensitivePayloadForTombstone` removes locationOutcome, flowSnapshot/payload, requiresPresetSelection, folder bookmark); adopts orphan `.m4a` files as failed items requiring preset selection ("Recovered after an interrupted save. Choose a Preset to continue."); backs up corrupt index as `index-corrupt-<ts>.json`; lazily back-fills sidecars for old queues.
  - `transition` increments attemptCount on `.transcribing`, stamps deliveredAt, scrubs sensitive payload at terminal states; `markDelivered`/`discard` delete the audio file; `acknowledgeTerminalState(id:revision:)` records Watch acknowledgement (idempotent; delayed duplicate transfers can't recreate work).
  - `shouldCancelForUnavailableLocation`: preset requires origin-time location with `unavailableBehavior == .cancel` and outcome isn't available → auto-cancel.
- Constraints: shared recordings directory availability.
- Evidence: `WatchRecordingInbox.swift` (full, 628 lines).
- Status: shipped

### F-IC-11 Watch Recording Pipeline (Phone-Side Processing/Delivery)
- Surface: Watch queue UI, background delivery
- Summary: `WatchRecordingPipeline` (@MainActor @Observable) drains queued Watch recordings: transcribes on-device, applies Preset formatting + optional AI enrichment + speaker diarization, and delivers via `ConfiguredTranscriptCaptureDestinationExporter` (Capture inbox) or `RecordingOnlyFileExporter` (raw Files copy), tracking per-item phases and driving Watch state.
- Details:
  - Paths per item: recording-only mode → Files copy with reserved filename (3 conflict-retry loop, reservation persisted with paired folder bookmark; reservation bound to one folder — mismatch errors); `capturesRecordingWithoutTranscript` → audio-only capture delivery; normal → transcribe → deliver; existing transcript (delivery-only retry) skips transcription.
  - Free-limit handling: items that need no transcription usage (recording-only, capture-without-transcript, delivery-only retries) still process when at limit; others marked `transcriptionLimitReached` status and held.
  - Recorder-busy coexistence: recording-only/capture-without-transcript items may run while the app recorder is active; others wait.
  - Capture inbox integration: `recoverStaleProcessing(olderThan: 5*60)`, state reconciliation (completed → complete; failed → retryFailed; processing → "Capture delivery is still in progress. Try again shortly."), `reconcileDeliveredCaptureRequests` on capture-inbox decision notifications; discard flow verifies inbox state before deleting (refuses while processing/completed).
  - Failure recovery: `recoverInterruptedItems` requeues transcribing/delivering items on resume; `ensureProcessingIsActive` guards every await; cancellation requeues ("Waiting for iPhone").
  - Retry actions: `retry(_:)` (updates frozen recording-only settings unless filename reserved), `captureRecordingWithoutTranscript(_:)` (only after transcription-stage failure with audio), `choosePreset(_:for:)` (requiresPresetSelection or recording-only retarget), `discard(_:)` (with inbox verification).
  - Transcription: converts to Whisper WAV (cancellation-aware detached task), uses selected model/language/fallback; failure messages from `WatchRecordingTranscriptionFailureMessage` (audio preparation vs recognition, always noting "The Watch recording is saved for retry.").
  - Completed deliveries recorded into `ActivityStatsStore` (`recordCompletedRecording`).
  - Background notification only when the actual Files write fails ("Watch recording needs attention") and app not active; generic lock-screen body for privacy.
- Constraints: shared capture storage; preset destination configured ("Set a destination for ... on iPhone, then retry."); paywall for transcription.
- Evidence: `WatchRecordingPipeline.swift` (full, 1090 lines).
- Status: shipped

### F-IC-12 Watch Background Execution Lease
- Surface: WatchConnectivity delivery, background pipeline drain
- Summary: `WatchRecordingBackgroundLease` gives exactly-once ownership of one `UIBackgroundTask` identifier across queues (begin on WCSession delegate queue, expire on MainActor, end anywhere), behind the injectable `WatchRecordingBackgroundTaskServicing` boundary.
- Details:
  - States starting/active/ended; end reasons: completed, coalesced, noProcessableWork, enqueueFailed, pipelineUnavailable, unavailable, expired; invalid identifier → ended `.unavailable`.
  - `WatchRecordingBackgroundExecutionPolicy.shouldStart(leaseIsActive:applicationIsActive:)` — drain only starts with a live lease or foreground app; otherwise the durable item stays queued for a later retry.
  - Lease adoption while processing (`adoptLeaseWhileProcessing`): coalesce when active; queue a replacement lease if currently stopping after expiration; replace an inactive lease.
  - Expiration cancels the processing task and clears `activeRecordingID`.
  - All lease transitions logged under subsystem `bontecou.Voxboard`, category `WatchRecordingBackground`.
- Constraints: UIKit background-task budget (~30 s background).
- Evidence: `WatchRecordingBackgroundLease.swift` (full, 229 lines).
- Status: shipped

### F-IC-13 Apple Speech Transcription Backend (Batch + Live)
- Surface: default "automatic" transcription backend for recordings, imports, Watch, keyboard
- Summary: `AppleSpeechTranscriptionBackend` (actor, iOS 26+) wraps `SpeechTranscriber`/`SpeechAnalyzer`: batch transcription with timed segments, live streaming sessions with volatile+finalized text, asset/locale reservation management, and speech-authorization handling. Composed via `AppTranscriptionServices.shared` for the main app only.
- Details:
  - Batch: `transcribe(audioURL:language:)` uses preset `.transcription`, attribute `.audioTimeRange`; reduces `transcriber.results`, keeps only `isFinal` text; empty → `OnDeviceTranscriptionError.noSpeechDetected`.
  - Timed segments: per-run `audioTimeRange` attributes; if any run is untimed or invalid, falls back to one coarse segment covering the full result range (never drops untimed words).
  - Live: `startLiveTranscription` with `.volatileResults` reporting; `AppleSpeechLiveTranscriptionSession` actor owns the analyzer, AsyncStream input (`bufferingOldest(32)`), converter, revision counter; `append` throws on dropped input (backpressure) or terminated stream; `finish` finalizes through end-of-input with a bounded 50×10 ms drain window for the final phrase, then requires all final results consumed; `cancel` tears down cleanly. Final/volatile text published via `SystemTranscriptionUpdate`.
  - Asset management (`ensureAssets`): per-app locale reservation required even for installed assets ("unallocated locale"/"not subscribed" SFSpeechError guard); releases one stale reservation when at `AssetInventory.maximumReservedLocales` (single selected language policy); downloads `.supported`/`.downloading` assets; pending install throws "still preparing the ... language model. Keep Vox.md open...".
  - Authorization: `SFSpeechRecognizer.requestAuthorization` when notDetermined; denied/restricted/notDetermined surfaced with localized guidance (Settings / Screen Time).
  - Language: `"auto"` or empty → `Locale.current`, matched via `SpeechTranscriber.supportedLocale(equivalentTo:)`; unsupported → localized error naming the language.
  - `availability(language:)`: ready/supported/downloading → `.ready`/`.supported`; unsupported or transcriber unavailable → `.unavailable`.
- Constraints: iOS 26.0+; Apple on-device speech support; speech permission.
- Evidence: `AppleSpeechTranscriptionBackend.swift` (full, 603 lines).
- Status: shipped (gated iOS 26+)

### F-IC-14 Legacy Keyboard Transcription IPC Server
- Surface: keyboard extension full-file transcription requests (legacy flow)
- Summary: `TranscriptionServer` listens for `TranscriptionIPC.requestNotificationName` Darwin notifications, reads `TranscriptionRequest` files (model, language, audio filename), transcribes with the full app memory budget, and writes `TranscriptionResponse` back; started at app appear, re-checked on foreground (`checkForPendingRequest`).
- Details:
  - Ignores stale requests older than 60 s (clears the request file).
  - Single-flight (`isProcessing`); each request holds a `UIBackgroundTask` so completion survives app switching.
  - Audio-not-found error response; falls back to configured `selectedFallbackModelKey`.
- Constraints: shared recordings directory; request freshness ≤60 s.
- Evidence: `TranscriptionServer.swift` (full, 143 lines).
- Status: legacy (superseded by persistent recorder segment flow; still active)

### F-IC-15 Apple Intelligence / Foundation Models Backend
- Surface: transcript enrichment (title/tags/category/cleanedText), Smart Folders routing, Auto-Organize folder naming, Preset text-processing modes
- Summary: `FoundationModelsBackend: LLMBackend` (iOS/macOS 26+) exposes `complete(prompt:)`, `enrichNative(rawText:)` via `@Generable` guided generation, `routeToFolder(transcript:folders:)` (returns index or nil for -1/no match), and `generateFolderName(transcript:existingFolders:)` (reuse-or-invent, sanitized name). Lives in app targets only — FoundationModels is out of the keyboard extension's budget and rate-limited there.
- Details:
  - `isAvailable` mirrors `SystemLanguageModel.default.availability == .available`; otherwise `.unavailable(reason)` errors.
  - Enrichment schema: title (≤6 words guide), 0–5 lowercase single-word tags (hyphens allowed), category enum (note, idea, task, meeting, journal, message, reminder, other), cleanedText preserving Markdown structure and meaning ("never add information that wasn't in the original").
  - Auto-Organize instructions: 1–3 lowercase hyphenated words; `sanitizeFolderName` strips filesystem-invalid characters, lowercases, hyphenates spaces, trims `-.` edges; empty → nil.
  - Routing: enumerated folder list with name + description; returns -1 when no reasonable match → nil index.
  - Prompts include title/tags/category lines when present and prefer `cleanedText` over raw text.
  - Constructed in `VoxboardApp.init` only when `#available(iOS 26, *) && FoundationModelsBackend.isAvailable`; ineligible devices fall back to deterministic formatting or raw transcripts. Also powers `EnrichedCapturePresetTextProcessor` for Capture draft processing modes (Clean Prose, Todo Checklist, Meeting Notes, Custom Instructions per release notes).
- Constraints: iOS 26+, Apple Intelligence capable and enabled.
- Evidence: `FoundationModelsBackend.swift` (full, 233 lines); `VoxboardApp.swift` lines ~50-60.
- Status: shipped (gated by AI availability)

### F-IC-16 StoreKit Purchases, Entitlements & Restore
- Surface: PaywallView, unlock screen, onboarding paywall, Settings
- Summary: `StoreManager` (@MainActor @Observable) manages lifetime `individual`, `family`, and `familyUpgrade` products (`VoxboardPurchaseProduct`), transaction listening, entitlement reconciliation, legacy paid-app grandfathering, and restore with full diagnostics.
- Details:
  - Legacy migration: `AppTransaction.shared`/`refresh` verification; `originalAppVersion ≤ lastPaidBuildNumber (4)` → `usageTracker.completeLegacyAccessClassification(isOriginalPaidAppOwner: true)`; sandbox/TestFlight placeholder `1.0` never grandfathers; one-shot flag `v3_verifiedLegacyPaidAccessMigrationDone`; failures surface "Could not verify your App Store purchase history. Try Restore Purchases."
  - `purchase(_:context:)`: re-verifies app transaction and entitlements first (reinstall/refund/Family-Sharing change); eligibility via `usageTracker.purchaseOptions` (family upgrade only for existing Unlimited owners); full analytics funnel (started/finished with outcomes succeeded/failed/cancelled/pending and error categories); pending (ask-to-buy) state message.
  - `restorePurchases`: `AppStore.sync()` + forced AppTransaction refresh + entitlement sync; success when restored products non-empty or unlocked non-pending legacy classification; diagnostics recorded.
  - `syncCurrentEntitlements`: iterates `Transaction.currentEntitlements`, finishes verified transactions, records `PurchaseEntitlementObservation` (verified/recognized/revoked/upgraded/ownership/environment/verificationError), reconciles via `usageTracker.reconcileStoreEntitlements` (app-group defaults are wiped on uninstall while StoreKit persists); sets `isEntitlementStateReady`.
  - `recordRestoreDiagnostics`: storefront country code, per-product `Transaction.latest` observations, loaded vs requested product IDs → `PurchaseRestoreDiagnostics` (also logged to KeyboardDebugLog).
  - `listenForTransactions`: `Transaction.updates` loop finishing verified transactions and re-syncing (revocations pass empty additional products).
  - Product loading with missing-offer detection ("Some purchase options are temporarily unavailable." / "Purchases are not available right now.").
  - Note: free-tier allowance minutes and keychain high-water mark live in `UsageTracker` (VoxboardShared) — `isAtLimit`, `needsUnlock`, `addUsage(seconds:deliveryID:)` idempotent receipts, `reload()` — referenced throughout this file set.
- Constraints: StoreKit 2; products configured in App Store Connect.
- Evidence: `StoreManager.swift` (full, 462 lines); PersistentRecorder paywall checks.
- Status: shipped

### F-IC-17 Live Activity Controller (Lock Screen / Dynamic Island Monitor)
- Surface: Lock Screen, Dynamic Island
- Summary: `LiveActivityController` (singleton) owns the `VoxboardActivityAttributes` Live Activity: `startIfNeeded()` when listening starts, `update(isSegmentActive:isTranscribing:startedAt:requestId:transcriptionProgress:)` on segment transitions, and `end()` when listening stops entirely.
- Details:
  - Gated by `AppConstants.liveActivityMonitorEnabled` (user setting) and `ActivityAuthorizationInfo().areActivitiesEnabled`.
  - Reuses an existing activity, dismissing duplicates (ActivityKit preserves activities across process termination); tracks `endingActivityIDs` and defers a replacement start until pending ends complete (activity-count limit protection); `shouldStartAfterPendingEnd` retry.
  - All mutations serialized through a chained `activityMutationTask` on MainActor; iOS 16.2 `ActivityContent` API with 16.1 fallback; `end()` uses `.immediate` dismissal on the **entire** `Activity<...>.activities` collection, not just the tracked one.
  - Recorder init ends orphaned activities from a previous process.
- Constraints: iOS 16.1+; Live Activities enabled; user setting.
- Evidence: `LiveActivityController.swift` (full, 205 lines).
- Status: shipped (gated)

### F-IC-18 Live Activity Recording Intents
- Surface: Live Activity buttons (start/stop on Lock Screen / Dynamic Island)
- Summary: `StartRecordingLiveActivityIntent` and `StopRecordingLiveActivityIntent` (`LiveActivityIntent`, iOS 17+) enqueue start/stop commands through `LiveActivityCommandBuilder` into the recorder's command stream.
- Details:
  - Start gated by `liveActivityMonitorEnabled`; uses selected model/language and `CapturePresetStore.selectedFlowId()`.
  - Stop requires a non-empty `requestId` parameter bound to the segment displayed by that exact activity — a stale duplicate can never stop a newer recording that reused the monitor.
- Constraints: iOS 17+; Live Activity monitor enabled.
- Evidence: `LiveActivityRecordingIntents.swift` (full, 52 lines).
- Status: shipped

### F-IC-19 Live Segment Transcription Coordinator
- Surface: live transcription engine feeding (F-IC-08)
- Summary: `LiveSegmentTranscriptionCoordinator` (actor) polls the circular buffer every 80 ms and feeds 4,096-sample chunks into the Apple Speech live session, keeping all actor work, allocations, IPC, and Speech APIs off the AVAudioEngine real-time callback.
- Details:
  - `finish(through: endIndex)` stops the feeder, drains remaining audio, verifies `cursor == endIndex` (else `audioOverwritten`), then finishes the session; failure cancels the session.
  - `LiveTranscriptionProgress` actor tracks monotonic finalized text (`hasPrefix` guard) to answer `hasPublishedFinalizedText()` for live-vs-batch delivery decisions.
- Constraints: buffer retention window (10 min).
- Evidence: `LiveSegmentTranscriptionCoordinator.swift` (full, 135 lines).
- Status: shipped

### F-IC-20 Voice Auto-Stop (Voice Pause Detection)
- Surface: keyboard, Quick Capture, widgets, Live Activities, Apple Watch (per-path toggles)
- Summary: `VoiceAutoStopCoordinator` (actor) feeds exact 4,096-sample 16 kHz frames from the rolling buffer into a FluidAudio/Silero VAD streaming session and fires `onSpeechEnd` when speech ends after at least 0.3 s of speech, auto-stopping the recording segment.
- Details:
  - Armed by `startVoiceAutoStopIfSupported` only when `VoiceAutoStopPolicy.capturePath(for:)` applies, `AppConstants.voiceAutoStopEnabled(for:)` is on for that path, and `VoiceActivityModelAsset.isInstalled` (explicitly downloaded companion model); silence threshold `AppConstants.voiceAutoStopPauseDuration`.
  - Speech shorter than the minimum (0.3 s) is ignored; audio overwritten past buffer retention stops detection (manual stop remains); setup failure falls back to manual stop silently.
  - Stops are delivered as normal stop commands with trigger `.endOfSpeech`; the recorder guards against racing manual/VAD stops via `processingRequestId`.
- Constraints: VAD model downloaded; per-capture-path setting; offline Silero loader.
- Evidence: `VoiceAutoStopCoordinator.swift` (full, 129 lines); `PersistentRecorder.swift` `startVoiceAutoStopIfSupported`.
- Status: shipped (gated on optional model download)

### F-IC-21 Keyboard Recording Artifact Retention
- Surface: keyboard-origin recordings' cleanup
- Summary: `KeyboardRecordingArtifactRetention.perform` couples destructive deletion of the WAV and recovery journal to successful keyboard transcript delivery — any error escapes before either artifact is removed, so relaunch orphan recovery can surface the recording.
- Details:
  - Before deleting, writes a `RecordingArtifactDeliveryReceipt` beside every surviving source; if receipt writing fails, nothing is deleted and the result reports retained/unprotected counts.
  - Journal removed first; if that fails the WAV is kept so a recoverable pair remains; if WAV deletion fails the receipt deliberately remains for queue orphan-retry (no re-transcription of delivered audio).
  - Returns `KeyboardRecordingArtifactCleanupResult(retainedArtifactCount:unprotectedRetainedArtifactCount:)`; recorder logs non-clean results.
- Constraints: none.
- Evidence: `KeyboardRecordingArtifactRetention.swift` (full, 101 lines); used in `PersistentRecorder.handleStopSegment` keyboard path.
- Status: shipped

### F-IC-22 Capture Inbox Background Drain (BGProcessingTask)
- Surface: background app refresh scheduler
- Summary: `CaptureInboxBackgroundDrain` registers `com.bontecou.Voxboard.captureInboxDrain` and drains the shared capture inbox via `CaptureInboxDeliveryService.drain` from a `BGProcessingTask` so queued captures retry while backgrounded (#11), not only on foreground.
- Details:
  - `register()` must run before launch finishes (called in `VoxboardApp.init`); expiration cancels the drain task; success = no setup error.
  - `schedule(after: 15*60)` re-submitted each background transition; duplicate pending requests replace the previous schedule; submission failures (simulator etc.) logged and tolerated — foreground drain still covers delivery.
  - No network or external power required.
- Constraints: BGTaskScheduler availability/approval.
- Evidence: `CaptureInboxBackgroundDrain.swift` (full, 55 lines); `VoxboardApp.swift` scenePhase handler.
- Status: shipped

### F-IC-23 App Store Review Prompt Manager
- Surface: StoreKit review prompt after value moments
- Summary: `ReviewPromptManager` (singleton) triggers `SKStoreReviewController.requestReview` only after real value: ≥3 successful Capture submissions, or ≥5 successful transcriptions across ≥2 distinct local calendar days, with no attempt in the last 90 days.
- Details:
  - Counters stored in shared defaults (`reviewPrompt.*.v1` keys); usage day identifiers recorded from transcript dates + now, and from `recordAppUsageDay()` on foreground so the two-day guard reflects general usage.
  - Eligibility sets a persisted `pendingPrompt`; the actual prompt fires only in a foregroundActive scene with a key window, delayed 0.9 s (`promptDelayNanoseconds`); pending prompts retried on foreground via `requestPendingPromptIfPossible`.
  - Counters use `max(stored+1, total)` to stay consistent with store-driven totals.
- Constraints: Apple's requestReview throttling still applies; requires a foreground window scene.
- Evidence: `ReviewPromptManager.swift` (full, 168 lines); triggered from `PersistentRecorder.transcribe` and `VoxboardApp` scene handlers.
- Status: shipped

### F-IC-24 Feedback Helper (Email + Diagnostics)
- Surface: Settings/feedback surfaces (iOS + macOS)
- Summary: `FeedbackHelper` builds a mailto payload to `cody@isolated.tech` with subject "<App> Feedback" and a diagnostics block (app name/version/build, platform + OS version, device model), supporting both `mailto:` URL fallback and `MFMailComposeViewController` on iOS.
- Details:
  - `MailComposeView` UIViewControllerRepresentable wrapper with dismiss-on-finish delegate; `canSendMail` capability check; display name resolution order CFBundleDisplayName → CFBundleName → "Vox.md".
- Constraints: iOS uses MessageUI; macOS path exists via AppKit mailto.
- Evidence: `FeedbackHelper.swift` (full, 136 lines).
- Status: shipped

### F-IC-25 Release Notes Viewer
- Surface: What's-new sheet on update
- Summary: `VoxboardReleaseNotes` wraps the Notelet sheet with curated per-version notes for 1.9 → 2.2 (Presets, Watch recording, Voice Auto-Stop, speaker labels, durable recording queue, location metadata, meeting stems, {location} token, etc., including an embedded Watch feature video for 1.9.5).
- Details:
  - Presented only when the current CFBundleShortVersionString has non-empty notes and differs from `NoteletStorage.getLatestSeenAppVersion` (shared defaults); `--disable-release-notes` launch argument suppresses.
  - Custom button tint adaptive to dark/light mode for contrast; `defersCaptureInputFocusForReleaseNotes` environment value defers Capture input focus while the sheet is up.
- Constraints: localized notes shipped across 23 locales (per 2.1 notes).
- Evidence: `ReleaseNotes.swift` (full, 418 lines).
- Status: shipped

### F-IC-26 Geist Design System & Theme
- Surface: entire app UI (and keyboard backdrop parity)
- Summary: `Geist` is the design-token layer: spacing (4–96), radii (6/12/16/full), control heights (32/40/48), a full adaptive light/dark palette (grays, grays-alpha, blue, red, amber, green scales), semantic roles (bg, surface, surface2, border, borderHi, text, muted, faint, error, focus, success), Geist/GeistMono custom fonts with Dynamic-Type-relative sizing, and shared components.
- Details:
  - Typography helpers `display/heading/label/body/caption/mono` with explicit per-text-style size maps; macOS registers bundled TTFs via `CTFontManagerRegisterFontsForURL`.
  - `adaptive(light:dark:)` resolves per userInterfaceStyle on both UIKit and AppKit; 8-digit hex alpha supported.
  - Components: `GeistButtonStyle` (primary/secondary/tertiary/destructive × small/medium/large, pressed/disabled/focused states with double focus ring), `GeistDivider`, `GeistStatusBadge` (active/inactive), `GeistSectionLabel`, `GeistCardModifier`/`geistCard()`, `IdleWaveformView` (animated 9-bar sine waveform at 0.15 s, accessibility-hidden), `TranscribingDotsView`, `GeistGridBackground` (deliberately renders no decoration — API-compatible retained stub).
  - Design source of truth vendored in `docs/geist/design.md` and `design.dark.md`; no product-specific colors introduced.
- Constraints: fonts bundled in app.
- Evidence: `GeistTheme.swift` (full, 434 lines).
- Status: shipped

### F-IC-27 Record App Intent & Widget Flow Selection
- Surface: Shortcuts, Lock Screen widgets, Control Center controls
- Summary: `OpenVoxboardRecordIntent` ("Record with Vox.md", opens app) persists a pending widget-record request (`pendingWidgetRecordKey`) plus resolved Capture Preset flow ID (`pendingWidgetRecordFlowIdKey`) which the app consumes to start a one-shot recording. `VoxEntity`/`VoxEntityQuery` expose enabled Presets as an App Entity (enumerable, suggested, default = selected flow); `SelectVoxboardRecordVoxIntent` (iOS 18 `ControlConfigurationIntent`) configures which Preset a control uses.
- Details:
  - `WidgetRecordingFlowSelection.persistRequestedFlowID(from:)` parses `?flowId=` from widget deep links; `resolve` validates enabled flow or falls back to the selected flow.
  - Intent no-ops when Quick Record is disabled; resolved flow must be enabled.
- Constraints: iOS 17+ (control config 18+); Quick Record setting.
- Evidence: `OpenVoxboardRecordIntent.swift` (full, 174 lines).
- Status: shipped

### F-IC-28 Quick Capture Open Intent
- Surface: widget/Shortcuts quick-capture button
- Summary: `OpenVoxboardQuickCaptureIntent` (iOS 18+) unlocks and opens Vox.md to the durable Markdown capture draft by setting `pendingQuickCaptureOpenKey` + source (`widget`) + selected Preset ID (and clearing pending input), consumed by the app's `consumePendingQuickCaptureOpenIfNeeded`.
- Details:
  - `authenticationPolicy = .requiresLocalDeviceAuthentication` (device unlock required); `openAppWhenRun = true`; iOS 26 `supportedModes = .foreground(.immediate)`.
- Constraints: iOS 18+; local authentication.
- Evidence: `OpenVoxboardQuickCaptureIntent.swift` (full, 27 lines); `VoxboardApp.swift` consume logic.
- Status: shipped

### F-IC-29 App Shortcuts Provider (Siri Phrases)
- Surface: Siri / Shortcuts app
- Summary: `VoxboardShortcutsProvider` registers eight App Shortcuts with spoken phrases: Record with Preset, Quick Capture, Capture Voice, Capture Screenshot, Capture Scan, Capture Text, Capture Link, Capture File — each using `\(.applicationName)` and parameterized `\(\.$vox)` phrases where relevant.
- Details:
  - `updateAppShortcutParameters()` called on iOS 18+ at launch to refresh parameter donations.
  - Backing intents (`OpenQuickCaptureIntent`, `OpenCaptureVoiceIntent`, etc.) live outside this in-scope file.
- Constraints: iOS 17+; per-intent availability (18+ for some).
- Evidence: `VoxboardShortcutsProvider.swift` (full, 80 lines).
- Status: shipped

### F-IC-30 App Delegate: Early WatchConnectivity Activation
- Surface: process launch
- Summary: `VoxboardAppDelegate.application(didFinishLaunchingWithOptions:)` activates `WatchRecordingController`'s WCSession at the earliest launch hook so a queued Watch file can launch and be processed without presenting a SwiftUI scene.
- Details:
  - Registered as `@UIApplicationDelegateAdaptor`; runs before any SwiftUI scene exists.
  - Calls `WatchRecordingController.shared.activateForBackgroundDelivery()`, letting iOS dispatch queued Watch application-context/file transfers while the app stays in the background.
  - Without this, a Watch-launched process would wait for the `WindowGroup` scene and could be suspended before receiving the file.
- Constraints: none beyond platform minimums; only meaningful when a Watch session exists.
- Evidence: `VoxboardAppDelegate.swift` (full, 16 lines).
- Status: shipped

### F-IC-31 App Lifecycle, Composition Root & Entry Points
- Surface: app launch, scene phase, deep links
- Summary: `VoxboardApp` builds the dependency graph (TranscriptStore, UsageTracker, StoreManager, TranscriptEnricher when AI available, SpeakerDiarizationService, QuickCaptureViewModel with `EnrichedCapturePresetTextProcessor`, PersistentRecorder with the Capture draft event handler, WatchRecordingPipeline), and drives foreground/background behaviors and URL entry points.
- Details:
  - Launch: `AppLanguagePreference.applyAtLaunch()` (in-app language override, applies next launch), `CaptureInboxBackgroundDrain.register()`, pending widget-record pre-read, DEBUG localization-screenshot destinations, DEBUG `--runtime-queue-validation` arg renders `RecordingQueueView` instead of the standard root.
  - onAppear: configure Watch controller, resume Watch pipeline + recording queue, consume pending widget record / quick capture open, start `TranscriptionServer`, `storeManager.start()`, sync entitlements + reload usage + process pending capture inbox, one-shot onboarding-started analytics, review-prompt usage day + pending retry, auto-start listening if `autoListenEnabledKey`.
  - scenePhase `.active`: re-check pending requests, entitlements sync, pipelines/inbox resume (Watch twice), review prompt, auto-listen restart if the engine stopped. `.background`: schedule capture-inbox drain; idle timer disabled only while actively downloading models in foreground (`updateIdleTimer`).
  - Unlock transition (`usageTracker.hasUnlocked`): resumes Watch pipeline, recording queue, and pending inbox.
  - Model readiness task keyed on selected model/language: `service.prepare(...)` with fallback model; writes `automaticBackendReadyKey` (false during automatic selection, true/false by outcome via `canTranscribe`).
  - Capture draft event handler bridges recorder events (origin/clearOrigin/audio staging with draftRequestID verification/liveTranscript/cancelLiveTranscript/transcript with session+delivery IDs) into `QuickCaptureViewModel`.
  - Deep links (`onOpenURL`, scheme `AppConstants.urlScheme`): hosts `capture`/`capture-request` → `CaptureDeepLinkParser` (query values never logged — may contain private text), `listen` and legacy `record` → Capture inline controls with `pendingKeyboardLaunch`, `widget-record` → one-shot record with `?flowId=` persistence (guarded by Quick Record setting); unknown hosts/schemes logged and ignored.
- Constraints: various per sub-feature; localization screenshot behavior DEBUG-only.
- Evidence: `VoxboardApp.swift` (full, 417 lines).
- Status: shipped

### F-IC-32 Pause / Resume In-App Recording
- Surface: Capture Bar one-tap pause toggle; detailed recording controls Pause/Resume button; VoiceOver action on the voice button
- Summary: `PersistentRecorder.pauseInAppSegment()` / `resumeInAppSegment()` / `toggleInAppSegmentPause()` let one in-app recording be paused to gather thoughts and resumed as a single note. Paused intervals are excluded from the durable segment journal, the reported duration, the live transcription feed, voice auto-stop, and the extracted WAV.
- Details:
  - Pause records the circular-buffer write index; resume closes a `(start, end)` paused sample range and shifts the duration time base so the clock only counts recorded time. The 9:45 safety stop stays armed (the listening buffer keeps filling during a pause).
  - `extractSegmentSamples(from:startIndex:endIndex:pausedRanges:)` concatenates only non-paused spans — including when the segment start (pre-roll) lands inside a pause and when the recording is stopped while paused (open range closes at the extraction end index).
  - `LiveSegmentTranscriptionCoordinator` and `VoiceAutoStopCoordinator` gained actor `pause()`/`resume()`; feeders suspend while paused and skip buffered audio on resume so ambient noise is neither transcribed nor able to trigger end-of-speech auto-stop. Stopping while paused resumes the live feed past the paused tail before `finish(through:)`.
  - Journal writes are gated by a `segmentJournalLock`-guarded `journalPaused` flag so the real-time tap never records paused audio; audio-level IPC writes are suppressed while paused.
  - `WatchRecordingController` publishes a `.paused` phase (existing Watch snapshot state) while the phone recording is paused.
- Constraints: in-app app-owned segments only (keyboard-extension-origin segments cannot be paused); Live Activity keeps counting wall-clock while paused.
- Evidence: `PersistentRecorder.swift` `pauseInAppSegment`/`resumeInAppSegment`/`extractSegmentSamples`/duration timer/`appendToSegmentJournal`; `LiveSegmentTranscriptionCoordinator.swift`; `VoiceAutoStopCoordinator.swift`; `WatchRecordingController.swift` phase mapping; `QuickCaptureView.swift` `voiceCapturePauseToggle` (AnyView-erased — see F-IC-31 sibling note on deep ViewBuilder types overflowing the Swift runtime metadata demangler on device) — `VoxboardTests/RecordingPauseResumeTests.swift`.
- Status: shipped

---

## File-by-File Coverage Checklist

| File | Lines | Read |
|---|---|---|
| Voxboard/PersistentRecorder.swift | 3434 | ✅ complete (3 passes) |
| Voxboard/WatchRecordingPipeline.swift | 1090 | ✅ complete |
| Voxboard/WatchRecordingController.swift | 833 | ✅ complete |
| Voxboard/WatchRecordingInbox.swift | 628 | ✅ complete |
| Voxboard/WatchRecordingBackgroundLease.swift | 229 | ✅ complete |
| Voxboard/AppleSpeechTranscriptionBackend.swift | 603 | ✅ complete |
| Voxboard/TranscriptionServer.swift | 143 | ✅ complete |
| Voxboard/FoundationModelsBackend.swift | 233 | ✅ complete |
| Voxboard/StoreManager.swift | 462 | ✅ complete |
| Voxboard/LiveActivityController.swift | 205 | ✅ complete |
| Voxboard/LiveSegmentTranscriptionCoordinator.swift | 135 | ✅ complete |
| Voxboard/VoiceAutoStopCoordinator.swift | 129 | ✅ complete |
| Voxboard/KeyboardRecordingArtifactRetention.swift | 101 | ✅ complete |
| Voxboard/CaptureInboxBackgroundDrain.swift | 55 | ✅ complete |
| Voxboard/ReviewPromptManager.swift | 168 | ✅ complete |
| Voxboard/FeedbackHelper.swift | 136 | ✅ complete |
| Voxboard/ReleaseNotes.swift | 418 | ✅ complete |
| Voxboard/GeistTheme.swift | 434 | ✅ complete |
| Voxboard/OpenVoxboardRecordIntent.swift | 174 | ✅ complete |
| Voxboard/OpenVoxboardQuickCaptureIntent.swift | 27 | ✅ complete |
| Voxboard/LiveActivityRecordingIntents.swift | 52 | ✅ complete |
| Voxboard/VoxboardShortcutsProvider.swift | 80 | ✅ complete |
| Voxboard/VoxboardAppDelegate.swift | 16 | ✅ complete |
| Voxboard/VoxboardApp.swift | 417 | ✅ complete |

## Uncertainties

- **UsageTracker internals**: free-tier allowance minutes, keychain high-water mark persistence, `purchaseOptions`, `reconcileStoreEntitlements`, and `completeLegacyAccessClassification` live in VoxboardShared (`UsageTracker`), which is outside this task's file scope; mechanics summarized from call sites only.
- **VoxboardTests coverage**: tests were allowed as supplementary evidence but were not exhaustively enumerated; behaviors above are code-verified from production sources.
- `OpenQuickCaptureIntent` and other capture intents referenced in `VoxboardShortcutsProvider` are defined outside the in-scope files (presumably elsewhere in Voxboard/), so their internals are unverified here.
- `LiveActivityCommandBuilder`, `CaptureDeepLinkParser`, `CheckpointedAudioDelivery`, `RecordingOnlyFileExporter`, `CaptureInboxDeliveryService`, `TranscriptionIPC`, `AppConstants` keys (e.g., `voiceAutoStopPauseDuration` default value, `smartFoldersEnabled`, `autoOrganizeEnabled`) are referenced but defined in VoxboardShared/other files; exact defaults unverified in this pass.
- Whether `TranscriptionServer` (legacy IPC) is still reachable from current keyboard builds is not determinable from these files alone; it is registered and running at app launch.
- `AppConstants.urlScheme` value not read here (likely "voxmd"); deep-link host list is complete regardless.
