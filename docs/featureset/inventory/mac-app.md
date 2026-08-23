# Vox.md (Voxboard) Mac App — Feature Inventory

Scope: every feature verifiable in `Voxboard Mac/` (13 Swift files, ~10,757 lines). Shared types referenced here (e.g. `QuickCaptureViewModel`, `CapturePresetStore`, `RecordingJobQueue`, `AppConstants`, `FoundationModelsBackend`) live in `VoxboardShared` and are cited as dependencies only.

Workspaces (sidebar destinations in `MacRootView`): **Capture**, **Recording Queue**, **History**, **Settings** (plus a separate **Capture History** window scene and a Settings scene).

---

### F-MC-01 Main Navigation Window (Capture / Recording Queue / History / Settings)
- Surface: `VoxboardMacApp` `WindowGroup(id: "main")` → `MacRootView`
- Summary: A `NavigationSplitView` app with a sidebar of four destinations and a detail pane. Handles window-scoped routing via notifications and a `MacWindowCoordinator`, plus a Models sheet.
- Details:
  - Sidebar destinations: Capture (`square.and.pencil`), Recording Queue (`waveform.circle`), History (`clock.arrow.circlepath`), Settings (`gearshape.fill`); column width 150/180/220, min window 980×680.
  - Detail routing: `MacCaptureWorkspaceView`, `RecordingQueueView` (retry with selected/fallback model, selected language, delivery override; recovery presets from `CapturePresetStore.loadFlows()`), `MacHistoryView`, `MacSettingsView`.
  - `showsModels` sheet hosts `MacModelView` (760×620 min).
  - Notifications `.macShowCapture` / `.macShowHistory` / `.macChooseCaptureFiles` / `.macClearCaptureDraft` with an optional window-token `object` for targeted delivery.
  - DEBUG-only: `--localization-screenshot <story>` preselects destination or swaps detail for `MacModelView`/`MacCapturePresetSettingsView`; `MacLocalizationScreenshotRoot` renders full surfaces without vibrancy sidebar.
- Constraints: screenshot story handling compiled only `#if DEBUG`.
- Evidence: `Voxboard Mac/MacRootView.swift` (lines 10–160, `MacDestination`, `MacRootView.body`, `selectedDetail`); `Voxboard Mac/MacLocalizationScreenshotRoot` (lines ~160–205).
- Status: shipped (screenshot harness: hidden/debug)

### F-MC-02 Transcription Model Selection & Download (Whisper / Parakeet / Apple Speech)
- Surface: Settings → "Transcription Models" row; Models sheet; History detail metadata
- Summary: `MacModelView` lists downloadable Whisper GGML models (whisper.cpp + Metal) and Parakeet Core ML models, plus language selection. Supports "Use Existing" installs in place, downloads with progress, select, delete, cancel, and per-model labels (Bundled / Core ML / Existing Install).
- Details:
  - Sections "01 Whisper Models", "02 Parakeet Models" filtered by `WhisperModelInfo.availableModels` and `engine.isParakeet`; "03 Language" picker bound to `modelManager.selectedLanguage` (`availableLanguages`).
  - Download states: preparing, listingFiles ("Finding files…"), verifying, cancelling, transferring (per-file progress description or %); "Keep Vox.md open" hint; Cancel disabled while cancelling.
  - "Use Existing…" opens NSOpenPanel: Parakeet → folder containing Preprocessor/Encoder/Decoder/JointDecision `.mlmodelc` + `parakeet_vocab.json`; Whisper → single GGML `.bin`, used in place without copying. `Stop Using` (external) vs `Delete` for downloaded models.
  - Model operation failure alert via `modelManager.modelOperationError`.
  - Recording-time gating: `MacRecorder.validateSelectedModel` (MacRecorder.swift ~lines 630–645) — `automatic` backend allowed; otherwise model must be selected AND downloaded, with two distinct localized errors that the Capture error banner converts into a deep link to open Models (`shouldOpenModelsFromError`, MacCaptureWorkspaceView.swift).
- Constraints: automatic selection maps to Apple Speech backend (shared code); Whisper/Parakeet require local model files.
- Evidence: `Voxboard Mac/MacRootView.swift` `MacModelView` (~lines 205–425); `Voxboard Mac/MacRecorder.swift` `validateSelectedModel` (~630).
- Status: shipped

### F-MC-03 Capture Preset (Vox) Library Management
- Surface: Settings → "Capture Presets & Destinations" sheet (`MacCapturePresetSettingsView`); also Settings Global Keybinds reload
- Summary: Two-pane preset editor: sidebar list of presets with add (custom) and delete, editor form covering identity, capture processing, destination, legacy export, metadata, location, speaker ID, and audio retention.
- Details (editor sections, `MacCapturePresetEditor`, MacRootView.swift ~lines 470–1140):
  - **Identity**: name, icon picker (`MacFlowIconPickerView`, 50 curated SF Symbols in 5 categories with search), Enabled toggle, "Use as Capture Default" (disabled unless enabled; badge "Default for Capture").
  - **Capture Processing**: "Apply to Capture Text" toggle + info sheet `MacCaptureTextProcessingInfoView` (on-device Apple Intelligence, local fallback keeps original text); Mode picker (`none/clean/todoList/meetingNotes/custom` with per-mode help text); custom instruction TextEditor; "Empty Capture Prompt" text.
  - **Destination**: shows owned `CaptureDestination` (root name + "target · placement" summary) with Edit/Set Up sheet → `MacCaptureDestinationEditor`; route migration clears `captureEntryTemplateID`/placement override and legacy markdown template settings when destination defines its own template path (`CapturePresetStore.migratingLegacyMarkdownTemplate`).
  - **Legacy Voice File Export** (only when `captureDestinationID == nil`): exportEnabled toggle; export/audio/markdown-template folder pickers via security-scoped bookmarks; Format picker (`ExportFileFormat` incl. TXT/MD/JSON/YAML); New File vs Append mode; filename template tokens `{timestamp} {date} {time} {YR} {id8} {id} {model} {language}`; Obsidian Bases toggle; Markdown template file binding.
  - **Metadata**: scope picker (document note frontmatter vs entry inline `key:: value`); static frontmatter editor (monospaced TextEditor, sorted render, colon-parse on change).
  - **Location**: enable toggle; precision Exact/City; unavailable behavior Ask/Send-Without/Cancel; metadata output structured-fields (per-field toggles + custom output key) or advanced YAML template (placeholders `{{coordinates}} {{city}} {{timestamp}} {{id}}`); live delivery preview or validation error (`CaptureLocationConfigurationPreview`); scope-conflict warning (advanced template + entry scope) with fix button; "Reset Location Unavailable Choice" and "Reset Location Configuration"; privacy copy (reverse geocoder network use, no background tracking, provider-link disclosure).
  - **Voice Processing**: "Identify Speakers" diarization toggle with explanatory copy (on-device, model downloads on first use, best-effort with skip reason shown in History).
  - **Voice Audio**: Save Audio mode (off / attachmentsFolder / etc.), attachments folder name (relative to unified destination, blank = default), "Embed Audio in Markdown" (gated by `markdownAudioEmbedAvailable`: destination present OR md format OR markdown template OR yaml-with-.md) with embed-placement picker.
  - Deletion: only non-builtin; retires owned destination route via `CapturePresetStore.retirePreset`; falls selection back to first preset/`generalId` and repairs selected capture profile if needed.
  - Persistence: flows auto-saved on change; `onAppear` sets `usesCustomExportSettings = true` for legacy flows; async destination load keeps in-flight edits of route-owned fields only.
- Constraints: none beyond storage availability (`MacCapturePresetDestinationError.storageUnavailable` if `AppConstants.captureLibraryURL` nil).
- Evidence: `Voxboard Mac/MacRootView.swift` lines ~427–1142 (`MacCapturePresetSettingsView`, `MacCapturePresetEditor`, `MacFlowIconPickerView`, `MacCaptureTextProcessingInfoView`, `CapturePresetProcessingMode.helpText`).
- Status: shipped (Legacy Voice File Export section: legacy fallback for un-migrated presets)

### F-MC-04 Capture Workspace (Draft Composer, Attachments, Recording Controls)
- Surface: Capture destination (default); menu-bar "Show Capture"; app shortcuts/deep links
- Summary: The primary capture surface: durable Markdown draft composer (AppKit text view) with attachment strip, recording status bar, action bar, and Markdown toolbar. Shares the iOS durable-draft/delivery model via `QuickCaptureViewModel`.
- Details:
  - **Header**: status badge (Recording/Transcribing/Finishing Export/Draft Saved Locally); preset menu (enabled flows; disabled while recording); location pill ("Current Location On" / "Finding Location…") when preset location enabled; route button showing destination preview (or one-off note basename) opening `MacCaptureRouteInspector`; free-tier counter button ("N captures · N.N min" / "Unlock Capture") opening paywall; History and Settings icon buttons.
  - **Destination setup banner** (amber) when no destination configured and not in screenshot mode.
  - **Composer**: `MacMarkdownComposerTextView` (F-MC-12) filling space; drop destination for URLs with blue highlight + dashed overlay; empty-state prompt = preset capture prompt or a rotating `InspirationQuoteService` quote; hint "Type Markdown, dictate, paste, or drop files anywhere in this window."
  - **Attachment strip**: chips per payload (text/url/audio/retainedAudio/image/file/scannedDocument/sketch) with per-item remove; labels and icons per `payloadIcon`/`payloadLabel`.
  - **Recording status bar**: state text, meeting subtitle naming captured application ("Capturing X with separate System and Mic audio"), draft-mode subtitle, per-source System/Mic level meters + status text + last warning (meeting mode), Stop button, transcription percentage progress.
  - **Action bar**: History, "Reveal Last Capture" (Finder reveal of last receipt, security-scoped), input-mode segmented picker Microphone/Meeting (with help text), result picker "Add to Draft" vs "Send Immediately", "Audio" checkbox (draft mode: attach recording to draft), Record/Stop button, Send Capture (⌘↩, disabled while submitting/processing/recording/transcribing; shows "Unlock" when free standard capture is at limit). Free-limit path: `captureAllowanceBlocked` → paywall.
  - **Markdown toolbar**: "Add attachment" menu (Images or Screenshots…, Take Photo…, Import Scan or PDF…, Sketch…, Files…, Audio Attachment…, Transcribe Audio or Video…, Web Link…, Paste); Undo; Format menu (⌘B Bold, ⌘I Italic, Hashtag, Heading 1–6); Markdown link; Internal link `[[`; Due date; Checklist; Bullet list; Timestamp; Date (yyyy-MM-dd); Case menu (Lowercase/Uppercase/Sentence case/Capitalize Words/Slugify).
  - **Attachment ingestion** (`chooseImages`/`chooseScan`/`chooseFiles`/`chooseAudio`/`stageURLs`): NSOpenPanel per type; `CaptureInputBudget.reserveSharedItems` preflight; per-URL UTType detection; `viewModel.stageFile` with `embedAsImage`/`embedAsAudio` flags.
  - **Scan import**: images run through `MacDocumentScanProcessor` (F-MC-11) then `viewModel.stageScan(pageImages:pdfData:extractedText:)`; non-image PDFs staged as files.
  - **Paste** (`pasteIntoCapture`): pasteboard URLs → stage; PNG data → stage as pasted-image PNG; TIFF → converted PNG; http(s) string → `addURL`; other text → insert at selection.
  - **Link prompts**: alert with https URL validation; internal-link alert producing an Obsidian wiki link via `CaptureInsertionFormatter.wikiLink`.
  - **Due date sheet**: DatePicker (+ optional time) inserting a due-date token.
  - **Location decision dialogs**: interactive Retry / Send Without Location / Always Send Without Location for This Preset / Cancel; inbox-drain variant with Discard option and preset-named title.
  - **Error banner**: red banner for viewModel/recorder errors; model errors become clickable "Open Transcription Models"; inline "Retry queued captures" when `failedInboxCount > 0`; "Reveal preserved recording" when `lastRecoveryAudioURL` set.
  - **Sent toast**: "Capture Sent" capsule for 2s after `viewModel.lastReceipt`, then re-focus composer.
  - Lifecycle: draft autosave on text change (skipped while live transcript preview is active), save on disappear, `requestedInput` consumption (photos/screenshots/camera/files/scan/sketch/link/voice), notifications for show/chooseFiles/clearDraft, capture-workspace readiness registration with `MacWindowCoordinator`.
- Constraints: microphone permission required (`AudioRecorder.requestMicrophonePermission`) with localized error; free limit (15 min / 10 captures, from UsageTracker) gates recording/import and standard captures.
- Evidence: `Voxboard Mac/MacCaptureWorkspaceView.swift` lines 1–1259 (`MacCaptureWorkspaceView`), 1260–1450 (`MacCaptureRouteInspector`, `MacCaptureDueDateSheet`).
- Status: shipped

### F-MC-05 Capture Route Inspector (Per-Capture Route Overrides)
- Surface: Capture header route button; sheet `MacCaptureRouteInspector`
- Summary: One-off routing for the current capture: edit preset destination, choose per-capture placement, entry template, and a one-off target note; shows the resolved note preview.
- Details:
  - Preset section: preset identity; Edit/Set Up destination via `MacCaptureDestinationEditor` (fixed name = preset).
  - "Only for this Capture": Placement picker (Preset Default / Top / Bottom mapping to prepend/append overrides), Entry Template picker (Preset Default or any library template, saved to draft), "Choose another Markdown note" NSOpenPanel (`.md`, starting in vault root → `viewModel.setOneOffNote`), "Use Preset Defaults" reset when overrides exist.
  - Resolved Note section: monospaced `viewModel.resolvedDestinationPreview`, text-selectable.
  - Done persists draft immediately.
- Constraints: destination-dependent sections only when a destination exists.
- Evidence: `Voxboard Mac/MacCaptureWorkspaceView.swift` `MacCaptureRouteInspector` (~lines 1260–1420).
- Status: shipped

### F-MC-06 Temporary Transcription (Transcribe to Clipboard)
- Surface: Global keybind "Transcribe to Clipboard"; Capture menu "Start/Stop Recording" (⇧⌘R); Recording Queue results
- Summary: `MacRecordingCompletionMode.transcriptionOnly` records from anywhere and copies the finished transcript to the clipboard, or leaves it in Recording Queue for explicit copy when deferred.
- Details:
  - Recording jobs staged via `RecordingJobHandoffIntentStore` before enqueue (`source == .macClipboard`).
  - Immediate results auto-copy **once**: `markAutomaticClipboardDeliveryAttempted` is persisted *before* touching the pasteboard so a crash/relaunch can never overwrite newer clipboard content (MacRecorder.swift ~lines 1105–1125).
  - Deferred policy jobs return `transcriptText` for explicit Copy in Recording Queue.
  - Failure: clipboard copy failure surfaces "copy from the recording queue" error and preserves audio; `usageTracker.addUsage` on success; transcript persisted to TranscriptStore.
  - Meets free limit check both at record start and at queued-job execution (`MacRecordingHandoffError.transcriptionLimitReached`).
- Constraints: free tier limit; model validation.
- Evidence: `Voxboard Mac/MacRecorder.swift` `executeQueuedJob`, `finishSuccessfulTranscription` (clipboard branch), `MacRecordingHandoffError`.
- Status: shipped

### F-MC-07 Global Keyboard Shortcuts (Hotkeys, any app)
- Surface: Settings → "Global Keybinds"; Carbon hotkey registration; Capture menu; menu bar
- Summary: System-wide record start/stop hotkeys with three target types: Transcribe-to-Clipboard, Selected Capture Preset, and one binding per enabled Capture Preset. Carbon `RegisterEventHotKey` based.
- Details:
  - Targets (`MacHotKeyTarget`): `.transcriptionOnly`, `.selectedPreset`, `.preset(id)`. Preset bindings ignored (beep) if preset no longer exists/enabled at press time (`configureGlobalHotKeys`, VoxboardMacApp.swift).
  - `MacHotKeyShortcut`: requires ⌃/⌥/⌘ (⇧ combinable); key naming table for Return/Tab/Space/Delete/Escape/Clear/Enter, F1–F16, arrows; display string ⌃⌥⇧⌘+KEY.
  - Persistence (`MacHotKeyStore`, shared defaults): `macGlobalHotKeyShortcut` (legacy single selected-preset binding retained for compatibility), `macTranscriptionOnlyHotKeyShortcut`, `macCapturePresetHotKeyShortcuts` (JSON dictionary). `configuredBindings()` and `conflictingTarget(for:excluding:activePresetIDs:)` (conflicts with disabled presets ignored).
  - Recorder sheet `MacHotKeyRecorderSheet`: hidden `MacHotKeyCaptureNSView` (a `MacKeyboardHintSuppressingResponder`) captures keyDown/flagsChanged; Esc cancels; Shift-only warning; conflict validation inline and at save; Save/Clear/Cancel.
  - Registration `MacGlobalHotKeyCenter.reloadRegistration()`: unregisters all, registers enabled bindings with signature `VOXH`; per-shortcut OSStatus error surfaced as `lastRegistrationError` in Settings; all activity logged to `KeyboardDebugLog`.
  - Press behavior (`handleGlobalHotKey`): toggle — if recording, stop+transcribe; else free-limit check (needsUnlock + show Capture), microphone permission check (error + show Capture), then `startRecording` with flow/completion; if start failed, reveal Capture window with the error.
  - Menu equivalents: ⇧⌘C Show Capture, ⇧⌘H Show History, ⇧⌘R Start/Stop Recording, ⇧⌘A Add Files to Capture (VoxboardMacApp `CommandMenu("Capture")`).
  - "Clear Capture Draft" menu item (disabled when draft empty). Vox.md menu: Reveal Data Folder; Visibility submenu mirroring all four modes.
  - `MacKeyboardHintCenter` never triggers while a hotkey-recorder first responder is active.
- Constraints: hotkeys registered only while app runs; conflicting system shortcuts fail registration with an OSStatus message.
- Evidence: `Voxboard Mac/VoxboardMacApp.swift` (`MacHotKeyTarget`, `MacHotKeyShortcut`, `MacHotKeyStore`, `MacGlobalHotKeyCenter`, `macHotKeyHandler`, CommandMenus, `configureGlobalHotKeys`, `handleGlobalHotKey` — roughly lines 140–330, 700–1010); `Voxboard Mac/MacRootView.swift` `hotKeySettings`/`MacHotKeyRecorderSheet` (~lines 1900–2550).
- Status: shipped

### F-MC-08 Keyboard Hints (Control-B Vimium-style click labels)
- Surface: Any key app window; hidden feature
- Summary: Pressing ⌃B overlays yellow keyboard labels on every clickable control; typing label prefixes clicks the target.
- Details:
  - Trigger: unmodified Control-B (keyCode 11), non-repeat, on a visible non-miniaturized key window; beeps if no candidates. Skipped when the first responder is a `MacKeyboardHintSuppressingResponder` (hotkey recorder).
  - `MacKeyboardHintLabelGenerator`: prefix-free home-row-ordered alphabet labels ("asdfghjkl…" then "qwerty…" etc.), 1–2+ chars as needed.
  - Candidate discovery: enabled NSControls with actions, editable/selectible text fields, text views, NSSegmentedControl segments (per-segment frames), SwiftUI buttons via `FocusRingView` type-name heuristic (priority 1 vs native 0); dedup by 88% frame-overlap + activation-point proximity; min 4×4 visible frame.
  - Interaction: unmodified letters append prefix (prefix chars render inverted on badge), Delete backspaces, Esc/any mouse/scroll/modified key dismisses, unmatched key beeps + dismiss; activation synthesizes a left-click event pair.
  - Overlay: borderless non-key `NSPanel` child window, ignores mouse, yellow rounded badges clamped to bounds; sessions dismissed on app resign-active and window move/resize/key-loss/close.
- Evidence: `Voxboard Mac/MacKeyboardHintCenter.swift` (entire file, 617 lines).
- Constraints: none beyond platform minimums
- Status: hidden

### F-MC-09 Menu Bar Operation
- Surface: `MenuBarExtra` (visibility-gated); menu-bar icon
- Summary: A menu-bar item with live status icon/tooltip and a full quick-action menu when the visibility mode includes the menu bar.
- Details:
  - Icon: `record.circle.fill` (recording), `waveform.circle.fill` (transcribing/exporting), else `mic.circle`; tooltip text mirrors state.
  - Menu content (`MacMenuBarMenu`): status title (Ready/Recording/Transcribing/Finishing Export); live duration or last error or selected model name; Stop + Transcribe or Start Recording (titled "Unlock to Record" with lock icon at free limit); Import Audio… (NSOpenPanel audio/movie → `importAudioFile`); Copy Last Transcript; speaker-diarization skip reason row (orange); Reveal Last Export; Capture Preset picker (enabled flows, disabled while recording); Show Capture (⌘0), Show History, Reveal Data Folder, Quit (⌘Q).
  - Recording start from menu reuses the permission/limit/error flow and reveals Capture window on failure.
  - On appear: reload usage tracker and transcript store.
- Constraints: `MenuBarExtra(isInserted:)` bound to `visibilityMode.showsMenuBar` (see F-MC-10).
- Evidence: `Voxboard Mac/VoxboardMacApp.swift` `MenuBarExtra` scene + `MacMenuBarMenu` (~lines 1040–1350).
- Status: shipped

### F-MC-10 App Visibility Modes (Dock / Menu Bar / Hidden)
- Surface: Settings → Visibility; Vox.md menu → Visibility submenu; `MacAppVisibilityMode`
- Summary: Four user-selectable presence modes: Dock + Menu Bar, Menu Bar Only, Dock Only, Hidden.
- Details:
  - Modes map to `NSApplication.ActivationPolicy`: regular (dock modes) vs accessory (menu-bar-only, hidden); `apply()` / `applyImmediately()` switch policy async/synchronously; stored in shared defaults key `macAppVisibilityMode`; applied at launch (`applicationDidFinishLaunching`), on change, and on every window reveal (`showMain`/`showHistory` re-apply so an accessory app still comes forward).
  - Per-mode footnotes in Settings describing recovery (Spotlight/Finder/Launchpad for Hidden).
- Evidence: `Voxboard Mac/VoxboardMacApp.swift` `MacAppVisibilityMode` (~lines 630–700); `Voxboard Mac/MacRootView.swift` `visibilitySettings`.
- Constraints: none beyond platform minimums
- Status: shipped

### F-MC-11 Window Coordination, Deep Links, Termination Safety
- Surface: App lifecycle; `voxmd://` URLs; Dock reopen; quit flow
- Summary: `MacWindowCoordinator` routes commands to the correct scene window; the app delegate handles URLs, activation, reopen, and a draft-flush-on-quit gate.
- Details:
  - Coordinator tracks main windows by token (registered via `MacSceneWindowRegistrar`/`WindowProbeView`), history window, pending requests; prefers key window then any visible/miniaturized; deminiaturizes and activates; falls back to `openWindow` + activate when none; `chooseFiles` waits for capture-workspace readiness (`.macChooseCaptureFiles` notification) — no timing heuristic.
  - Deep links (`handleURL`): `voxmd://capture` / `voxmd://capture-request` (parsed by `CaptureDeepLinkParser` → `viewModel.handleDeepLink`) and `voxmd://listen`; window shown first, parse errors surfaced in viewModel. Scene `.handlesExternalEvents(matching: ["capture","capture-request","listen"])`.
  - Cross-launch handoff: `consumePendingQuickCaptureOpenIfNeeded` reads shared-defaults pending-open flags (source, vox ID, requested input) written elsewhere (e.g. iOS/watch) and routes into Capture.
  - `applicationShouldTerminate`: asynchronous reply; if recording or exporting, refuses quit with "Wait for the current recording or Capture export to finish before quitting." and reveals Capture; otherwise flushes the durable draft (`flushDraftForTermination`).
  - Reopen (Dock click with no windows) shows Capture; `applicationDidBecomeActive` resumes the recording queue and retries the failed inbox.
  - Periodic inbox drain: a `while` loop in the main window scene task sleeps 300s and calls `processPendingInbox()` so queued captures retry without foreground activation; also drained at launch and on unlock.
- Evidence: `Voxboard Mac/VoxboardMacApp.swift` (`MacWindowCoordinator`, `VoxboardMacAppDelegate`, `handleURL`, `consumePendingQuickCaptureOpenIfNeeded`, scene `.task`).
- Constraints: none beyond platform minimums
- Status: shipped

### F-MC-12 Markdown Composer (AppKit text engine)
- Surface: Capture workspace composer
- Summary: `NSTextView`-backed editor (`MacMarkdownComposerTextView`) wrapped for SwiftUI, retaining native undo, find panel, spell checking, Services, selection, and drag behavior.
- Details:
  - Controller API: focus/dismissFocus, undo/redo, replaceAll (with undo registration + "Edit Markdown" action name), replaceSelection (optional select-inserted), UTF16-clamped ranges.
  - Config: plain text (non-rich), no graphics import, allowsUndo, usesFindPanel; quote/dash/text-replacement substitution disabled; continuous spell checking on; GeistMono 16pt (fallback monospace system); insertion point styled.
  - Accessibility: label "Capture note", identifier `mac_quick_capture_text`.
  - Coordinator publishes text/selection/focus bindings bidirectionally; programmatic focus deferred to next runloop.
- Evidence: `Voxboard Mac/MacMarkdownComposerTextView.swift` (entire file, 210 lines).
- Constraints: none beyond platform minimums
- Status: shipped

### F-MC-13 Microphone Recording (Queue-backed, crash-safe)
- Surface: Capture workspace Record button; global hotkeys; menu bar
- Summary: `MacRecorder.startRecording` captures mic audio into a durable recording-job pipeline: handoff intent journaled before transcription, capture lease held during recording, live transcript preview for draft mode, and full crash recovery via the shared Recording Queue.
- Details:
  - Guards: not already recording/starting/finalizing; free limit → `needsUnlock` + error; model validation; `AudioRecorder.startRecording` failure → microphone privacy error.
  - Stop path (`stopAndTranscribe`): staged `RecordingJobHandoffIntent` saved to the recordings directory before enqueue; origin-location snapshot journaled (see F-MC-14); enqueue with model/fallback/language, delivery, voice-processing config, queue preferences; any handoff failure preserves original audio at `lastRecoveryAudioURL`.
  - Live preview (draft mode only): Apple Speech `SFSpeechAudioBufferRecognitionRequest` with `requiresOnDeviceRecognition`, partial results, fed from the recorder's audio buffer tap; finalized vs volatile text pushed as `liveTranscript` events; invalidation handler on stop; requires authorized on-device recognizer for the selected locale.
  - Queued execution (`executeQueuedJob`): draft audio staging event; transcription with progress; speaker diarization resolution (skip reason surfaced & logged); transcript persistence with persistence-error propagation; usage accounting; per-mode completion (clipboard / draft events / preset export).
  - DEBUG runtime validation hooks: `--runtime-queue-pause-after-claim` (sleep 30s in executor), `--runtime-queue-validation` + `--runtime-microphone-capture` + `VOXBOARD_SHARED_CONTAINER_OVERRIDE` env → automated 2s mic capture and queue result file under `/tmp/VoxQueueRuntimeValidation`.
- Constraints: free limit checked at start and execution; mic permission.
- Evidence: `Voxboard Mac/MacRecorder.swift` lines 60–300, 1060–1200 (`startRecording`, `stopAndTranscribe`, `executeQueuedJob`, `startLivePreviewIfSupported`, debug hooks).
- Status: shipped (debug hooks: hidden)

### F-MC-14 Origin-Time Location Resolution (Crash-safe journaling)
- Surface: Capture preset location policy (F-MC-03) applied to recordings and imports
- Summary: When a preset enables location, the origin boundary is journaled durably: a stop-time "unavailable" placeholder is persisted, then atomically replaced with the resolved outcome, so a later retry can never acquire a *newer* location for the same capture.
- Details:
  - `beginOriginLocationResolution` builds a `MacOriginLocationResolution` task: reuse existing snapshot for the same retained recording; re-key a recovery recording ID when preset matches; otherwise save placeholder → `CaptureLocationService().resolveLocation(policy:source:)` → save final snapshot.
  - Draft-mode journal events (`.origin`/`.clearOrigin`) must be acknowledged (`true`) or `originMetadataPersistenceFailed` aborts; on partial failure the durable draft retains the placeholder.
  - Import path re-keys the origin store from the retained source copy to the converted WAV, deleting prior entries; cancellation cleans store entries.
  - Snapshots removed after successful delivery (`canRemoveOriginSnapshot`).
- Evidence: `Voxboard Mac/MacRecorder.swift` `beginOriginLocationResolution`, `MacOriginLocationResolution` (~lines 620–760, 2060).
- Constraints: none beyond platform minimums
- Status: shipped

### F-MC-15 Audio & Video Import for Transcription
- Surface: Capture toolbar "Transcribe Audio or Video…"; menu bar "Import Audio…"
- Summary: Import an audio or movie file and run it through the same preset/queue pipeline as recordings; source is copied into app storage and converted to Whisper WAV off-main-thread.
- Details:
  - NSOpenPanel accepts `.audio`/`.movie`; free-limit and model gates; busy guard ("Finish the current recording before importing audio.").
  - Security-scoped access on the source; copy to `mac_import_source_<uuid>.<ext>`; `AudioFileConverter.convertToWhisperWAV` → `mac_import_<uuid>.wav`; duration from converted or source file; recovery-origin detection when re-importing a preserved recording.
  - Handoff intent staged & finalized with `captureSource = .fileImport`, `source = .importedAudio`; draft-mode origin journaling (including a no-location profile snapshot event); failure preserves the imported source copy at `lastRecoveryAudioURL` and clears draft origin.
  - Non-audio "audio attachment" import path separately stages files as draft payloads (F-MC-04).
- Constraints: free limit; one import at a time.
- Evidence: `Voxboard Mac/MacRecorder.swift` `importAudioFile` (~lines 300–470).
- Status: shipped

### F-MC-16 Meeting Capture (ScreenCaptureKit + mic, app picker, dual stems)
- Surface: Capture workspace input-mode "Meeting"
- Summary: `MacMeetingCaptureCoordinator` records one selected application's system audio via ScreenCaptureKit while simultaneously recording the microphone via AVCaptureSession, chunking both stems to disk with a recovery manifest.
- Details:
  - Picker: `SCContentSharingPicker` in `.singleApplication` mode, change disallowed, excludes Vox.md itself; cancel → `pickerCancelled`; failure callback surfaced as state error. Selected app name resolved via `filter.includedApplications` (macOS 15.2+; nil and "Selected application" fallback on macOS 14 without guessing).
  - SCStream config: audio only (2×2px dummy video, 1fps), 48kHz stereo, excludes current-process audio; chunked `ChunkedSampleBufferWriter` per source with a shared `MeetingTimelineClock` (host clock origin).
  - Manifest (`manifest.json` in `Recordings/meeting-<uuid>/`): state machine preparing→recording→(captured|interrupted|normalizing→queued|consumed), per-chunk receipts (`.m4a.chunk.json`), timeline events, warnings; snapshots persisted atomically on a utility queue, best-effort async during capture.
  - Interruption handling: per-source one-shot latches for mic (AVCaptureSession interrupted / runtime error / device disconnected) and system (stream stop error) → warning + `interruptionHandler` → `MacRecorder.handleMeetingInterruption` finalizes the meeting.
  - Stop: single-stop task; finalize both writers via dispatch group; drain finalization mailbox; warn if a stem empty; state = completed (no warnings) or interrupted; picker deactivated.
  - Live UI: `microphoneLevel`/`systemLevel` RMS meters (down-sampled, clamped ×4), per-source status text (Waiting/Listening/Capturing/Stopped/Error), `warnings`.
- Constraints: ScreenCaptureKit screen-recording permission implied by picker; macOS 15.2+ for app-name resolution.
- Evidence: `Voxboard Mac/MacMeetingCaptureCoordinator.swift` (entire file, 650 lines).
- Status: shipped

### F-MC-17 Meeting Pipeline: Normalize, Mix, Dual-Stem Transcription, Timeline
- Surface: Post-stop processing in `MacRecorder` + shared `MeetingTranscriptAssembler`
- Summary: Interrupted-or-completed meetings are normalized (per-stem WAV from chunks), mixed for playback, and enqueued as a bundle; transcription runs on each stem separately and results are interleaved on the manifest timeline.
- Details:
  - Recovery (`recoverInterruptedMeetingSessions` on every `resumeRecordingQueue`): scans `Recordings/meeting-*` directories with symlink/containment safety checks, skips the active/finalizing session, dedups in-flight directories, recovers orphaned chunk receipts (validates filename/byte-count/duration), reconciles against existing durable jobs by session ID (marks consumed + deletes staging, or re-queues), marks preparing/recording → interrupted with "Recovered after Vox.md was interrupted." warning, then normalizes.
  - `normalizeAndEnqueueMeeting`: `AudioFileConverter.normalizeMeetingStem` per source, `mixWhisperWAVStreaming` mix; bundle artifacts with roles `.playbackMix`, `.meetingTimeline` (manifest), `.meetingMicrophone`, `.meetingSystem`; manifest state → queued *before* staging cleanup (crash-reconciliation boundary).
  - `executeMeetingJob`: transcribes each stem with progress; maps segments to the manifest timeline (`mapToMeetingTimeline`) or falls back to whole-file timed units with a warning; interleaves turns (`turns(from:)`); optional diarization on the system stem for remote speakers (`role: .remoteAnonymous`, speaker numbers offset), skipped-with-warning on error; rendered text prefixed with "⚠️ Incomplete meeting capture:" + warnings when any; backend name joined "A + B"; transcript persisted & clipboard policy applied (`MeetingClipboardPolicy`); delivery through `finishSuccessfulTranscription` with the playback mix as audio.
  - Zero chunks at stop → staging directory deleted (nothing recoverable); finalize failure leaves chunks recoverable in Recordings with an error message.
- Evidence: `Voxboard Mac/MacRecorder.swift` (`recoverInterruptedMeetingSessions`, `recoverMeetingSession`, `recoverFinalizedChunkReceipts`, `isSafeMeetingDirectory`, `stopMeetingAndTranscribe`, `normalizeAndEnqueueMeeting`, `executeMeetingJob` — roughly lines 760–1050 and 1200–1310).
- Constraints: none beyond platform minimums
- Status: shipped

### F-MC-18 Preset-Driven Capture Export & Apple Intelligence Enrichment
- Surface: Background delivery after preset recordings/imports
- Summary: `finishSuccessfulTranscription` (preset branch) formats the transcript per preset, persists it, optionally enriches it with Apple Intelligence, then delivers Markdown (+ audio) to the configured destination or legacy file export, with checkpointed audio delivery and recovery-preserving failure semantics.
- Details:
  - `TranscriptFlowFormatter.apply(flow:to:)` then TranscriptStore persistence; usage added only after successful delivery.
  - AI enrichment: `TranscriptEnricher` with `FoundationModelsBackend` — gated to macOS 26+ and `FoundationModelsBackend.isAvailable`, else nil (Settings row shows READY/UNAVAILABLE/macOS 26+). Enrichment runs only when `flow.usesAIEnrichment`.
  - Unified destination path: `ConfiguredTranscriptCaptureDestinationExporter.export(...)`; errors classified — `.queuedForRetry` (audio+outcome copied to durable inbox, retry handler `processPendingInbox` invoked, delivery treated as success), `.locationUnavailableCancelled` ("Capture canceled because this preset requires an origin-time location."), others surface "Your transcript was saved locally. …" and expose recovery audio when not yet durable.
  - Legacy export routing (destination-less): Smart Folder routing (only when preset has no explicit export folder, `smartFoldersEnabled`) and Auto-Organize subfolder naming via FoundationModels — both deadline-bounded at **30s** (`exportRoutingTimeout`) so a stalled model can't hang delivery; folder listing under security scope for existing-name awareness.
  - `prepareFlowForFileExportIfNeeded`: prompts for a missing/expired per-flow or global export-folder permission via NSOpenPanel (security-scoped bookmark), persisting only folder fields onto the current stored flow (immutable-snapshot safe).
  - Audio: `retainAudioIfNeeded` copies to `mac_export_audio_<uuid>`; `CheckpointedAudioDelivery` delivers audio + Markdown reference with note/audio/audio-reference transaction directories and queue checkpoints (`markExportedNote/Audio/AudioReferenceAttached`); retained audio deleted only after durable success; failures keep it for recovery with tailored messages ("The note was saved, but its audio attachment failed. …").
  - Export mode checkpointing reuses previously exported note path if the file still exists (retry-idempotent).
  - `isExporting` UI state; `lastExportURL` for menu-bar reveal.
- Constraints: enrichment and smart routing require macOS 26 + Apple Intelligence; everything on-device.
- Evidence: `Voxboard Mac/MacRecorder.swift` `finishSuccessfulTranscription` (~lines 1500–1730); `VoxboardMacApp` init for enricher gating (lines 30–45); `MacRootView.swift` `appleIntelligenceStatus/Detail`.
- Status: shipped (enrichment/routing: gated on macOS 26+)

### F-MC-19 Speaker Diarization (Identify Speakers)
- Surface: Preset "Voice Processing" toggle; History rows; menu bar
- Summary: On-device speaker identification labels multiple voices after transcription; best-effort with visible skip reasons.
- Details:
  - `SpeakerDiarizationService.resolve(audioURL:transcription:configuration:)` — configuration nil for transcription-only mode (no labels for clipboard jobs); skip reason stored on the transcript (`lastSpeakerDiarizationSkipReason`) and logged via `KeyboardDebugLog`.
  - History rows and detail show "N speaker(s)" and the skip-reason warning label; menu bar shows the reason in orange.
  - Meeting mode uses diarize on the system stem for remote speakers (F-MC-17); speaker model downloads on first use (per Settings copy).
  - Turn structure preserved (`speakerTurns` on `Transcript`).
- Constraints: model download on first use; may skip (reason surfaced).
- Evidence: `Voxboard Mac/MacRecorder.swift` (resolve call sites); `Voxboard Mac/MacRootView.swift` `MacHistoryView`/`MacTranscriptDetailView`.
- Status: shipped

### F-MC-20 Capture Destination Library (Vault Routing)
- Surface: Preset editor destination sheet; Route Inspector; `MacCaptureDestinationEditor`
- Summary: Full editor for a `CaptureDestination`: vault/folder security-scoped root, note target (new/rolling/existing), placement, entry formatting (library template, vault template, or prefix/suffix), attachments folder, and retry protection.
- Details:
  - Target kinds: New Note (path template), Rolling Note (period picker `CaptureRollingPeriod`), Existing Note (relative path with "Choose Existing Note…" picker constrained to root). Path tokens listed: `{date} {time} {hour} {minute} {second} {timestamp} {year} {YR} {month} {day} {period} {week} {id8}`.
  - Placement: append / prepend / beneath heading (heading title, level stepper 1–6, missing-heading behavior Show Error vs Create Heading).
  - Entry formatting: vault Markdown template (`markdownTemplatePath`, read fresh from the vault every capture so Obsidian edits apply; supports `{location}`) OR reusable library template (picker disables prefix/suffix fields) OR custom prefix/suffix TextEditors; entry tokens incl. `{source}`, `{id}`, `{location}` with a rendered `{location}` sample preview.
  - Delivery: "Retry Protection" toggle — adds a `vox-capture` HTML comment per entry to prevent duplicates on retry (disclosed as possibly visible while editing).
  - Validation & preflight: folder required; relative-path validation for path and attachments folder; heading required; existing-note existence + `MarkdownDocumentEditor` mutation dry-run; template inside root + ≤ `CaptureInputLimits.maximumTextCharacters`; template may not equal destination note; stale bookmark → "permission expired, choose again" error; detailed `MacCaptureRouteError` messages.
  - Save path persists via caller-provided closure (`CaptureLibraryStore.update`, default destination assigned if none) — editor itself is UI-only.
- Evidence: `Voxboard Mac/MacCaptureDestinationLibraryView.swift` (entire file, 424 lines).
- Constraints: none beyond platform minimums
- Status: shipped

### F-MC-21 Entry Template Library
- Surface: Settings → "Entry Templates" (`MacEntryTemplateLibraryView`)
- Summary: Create/edit/delete reusable Markdown entry templates (name + prefix + suffix) stored in the shared capture library; import from a `.md` file.
- Details:
  - List with per-template line-count summary, Edit/Delete; empty-state ContentUnavailableView.
  - Import: `.md` only, UTF-8, size guards (bytes ≤ 4× limit, chars ≤ `maximumTextCharacters`), name from filename ("Imported Template" fallback), opens in editor for confirmation.
  - Editor sheet: monospaced prefix/suffix editors, token help line, `{location}` sample preview; name required.
  - Delete: removes template, and for destinations referencing it copies the removed prefix/suffix inline and clears `entryTemplateID` (no dangling references); also `CapturePresetStore.clearCaptureEntryTemplate`.
- Constraints: shared capture storage must be available.
- Evidence: `Voxboard Mac/MacEntryTemplateLibraryView.swift` (entire file, 271 lines).
- Status: shipped

### F-MC-22 History Browsing, Search, Detail, Delete, Reveal
- Surface: History destination + "Capture History" window scene; unified list
- Summary: Unified history merging local transcripts (with delivery outcome) and capture-delivery records, searchable, with detail sheet, copy, delete, clear-all, and Finder reveal.
- Details:
  - Merge: transcripts from `TranscriptStore` joined to `CaptureHistoryRecord` by request ID (delivery badge Delivered/Failed); capture-only records (no transcript) listed separately; sorted by date desc.
  - Search: `.searchable` over `TranscriptSearch.matches` plus capture haystack (destination, preset, note path, source, outcome, failure category).
  - "Needs Attention" section: `failedInboxCount > 0` → "Retry 1/N queued captures" button (`retryFailedInbox`).
  - Transcript rows: title (or relative date), date · model · duration, speaker count, diarization skip reason, delivery badge, Open/Copy/Delete buttons, 6-line preview, tap/click and accessibility action open detail; capture rows show outcome icon, destination, note path, source, preset, attachment count, failure category, Reveal (when delivered with path) and Delete.
  - Detail sheet: cleaned vs raw transcript sections (copy menu chooses), header metadata (duration, model, language, category, tags as #chips, speakers), text selection enabled.
  - Clear All confirmation dialog: clears transcript content and capture delivery metadata explicitly **not** deleting exported Markdown notes or attachments.
  - Reveal: resolves destination bookmark (stale → "Reauthorize the destination in Capture Presets"), validates contained file URL, activates Finder selection (`MacHistoryRevealError.destinationMissing/.permissionExpired`).
  - Toolbar: Reload (store + records), Clear All (disabled when empty).
- Evidence: `Voxboard Mac/MacRootView.swift` `MacHistoryView`, `MacTranscriptDetailView`, `MacUnifiedHistoryItem`, `MacHistoryRevealError` (~lines 1520–1790).
- Constraints: none beyond platform minimums
- Status: shipped

### F-MC-23 Recording Queue (Retry & Recovery)
- Surface: "Recording Queue" sidebar destination (`RecordingQueueView`, shared component); History retry button
- Summary: Durable queue of recording jobs with per-job retry (model, language, delivery override, recovery presets), transcript checkpoints for clipboard jobs, automatic-clipboard-attempt tracking, and export path checkpointing.
- Details (Mac-side behaviors):
  - Retry action wired in `MacRootView`: `recorder.recordingQueue.retry(job, modelID: selected, fallbackModelID:, replaceFallbackModelID: true, language:, delivery:)`.
  - Capture leases serialize live recording vs queue execution; queue resumed on launch, activation, and after finishes; recovery preset flows offered for jobs requiring re-routing (`recoveryRoutingRequired` error: "Choose a Capture Preset before retrying this recovered recording.").
  - Queued execution failure preserves audio ("The recording was preserved in the queue.") and classifies failure stage (delivery/storage/transcription) via `MacRecordingHandoffError.recordingJobFailureStage`.
  - Queue root: `AppConstants.recordingJobsDirectoryURL` with temp-directory fallback.
- Evidence: `Voxboard Mac/MacRootView.swift` `selectedDetail` queue case; `Voxboard Mac/MacRecorder.swift` init, `resumeRecordingQueue`, `executeQueuedJob`.
- Constraints: none beyond platform minimums
- Status: shipped

### F-MC-24 StoreKit Purchases & Paywall (Individual / Family / Family Upgrade)
- Surface: Settings "Vox.md Unlimited"; paywall sheets (settings + capture-limit contexts)
- Summary: StoreKit 2 lifetime purchases: Individual Unlimited, Family Unlimited, and a discounted Family Upgrade for existing Individual owners; restore with diagnostics; transaction listener for refunds/reinstalls.
- Details:
  - `MacStoreManager.start()`: closes pending iOS-only legacy paid-app migration as non-owner on Mac ("Mac access must be backed by a current StoreKit transaction"); installs `Transaction.updates` listener (verified → finish + resync; revocation handled), then `prepareForPurchases()` (sync entitlements + load products).
  - Purchase flow: pre-sync entitlements (resolves reinstall/refund/family-change before upgrade-eligibility), eligibility check against `usageTracker.purchaseOptions` (Family upgrade only for Individual owners), product availability check, purchase → verify → `applyVerifiedPurchase` → finish → resync; states pending/cancelled/unknown tracked via `OnboardingAnalyticsClient` with paywall context and quota state.
  - Restore: `AppStore.sync()` then entitlement resync; "No Vox.md Unlimited purchase was found." when nothing restored; `recordRestoreDiagnostics` builds a `PurchaseRestoreDiagnostics` (platform macOS, sync error type, requested/loaded product IDs, storefront country, per-product `Transaction.latest` observations incl. verified/revoked/upgraded/ownership/environment/verification error) logged to KeyboardDebugLog — this is the family-restore troubleshooting surface.
  - Entitlement sync: iterates `Transaction.currentEntitlements`, skips revoked/unrecognized, finishes verified transactions, reconciles `UsageTracker.reconcileStoreEntitlements`, sets `isEntitlementStateReady`.
  - Paywall UI (`MacPaywallView`): access-level-dependent offers (free → Individual+Family cards; individual → Upgrade-to-Family card; family → unlocked badge), live prices ("PRICE UNAVAILABLE"/"CHECKING PRICE" fallbacks), usage line ("%.1f / 15 min transcription · %d / 10 captures"), Restore Purchases (disabled while restoring/purchasing), error text, Done.
  - Settings summary row shows usage, "FROM price", and Upgrade/Family buttons with accessibility IDs (`settings.familyUpgradeButton`/`settings.lifetimeOptionsButton`); Settings re-runs `prepareForPurchases` on task because app-level StoreKit may finish after Settings opens ("existing owners always see the Family upgrade").
- Constraints: purchase gating enforced by `UsageTracker` limits (15 min / 10 captures free).
- Evidence: `Voxboard Mac/MacStoreManager.swift` (entire file, 357 lines); `Voxboard Mac/MacRootView.swift` `MacSettingsView` unlimited section + `MacPaywallView` (~lines 1800–1900, 2620–2760).
- Status: shipped

### F-MC-25 Settings Surface (Companion Info, Configuration, Keybinds, Visibility, About, Debug)
- Surface: Settings destination / Settings scene
- Summary: Six-section settings: Unlimited/paywall, Mac Companion info rows, Capture Configuration navigation, Global Keybinds, Visibility, About, Debug.
- Details:
  - "Mac Companion" rows: ON-DEVICE TRANSCRIPTION (LOCAL), APPLE INTELLIGENCE (status/detail per macOS 26 gating), FILE EXPORT (local app storage note), KEYBOARD + LOCK SCREEN (iOS-specific features marked "IOS").
  - Configuration rows open sheets: Capture Presets & Destinations, Entry Templates, Transcription Models (keybind config reloads on presets-sheet dismiss).
  - About: version+build string, "Voice and text stay on-device." (PRIVATE).
  - Debug: "View Debug Log" sheet (`MacDebugLogView`) reading `KeyboardDebugLog.shared` with Clear/Copy/Done — surfaces hotkey registration events, recorder/exporter errors, restore diagnostics.
- Evidence: `Voxboard Mac/MacRootView.swift` `MacSettingsView`, `MacDebugLogView` (~lines 1790–2100, 2770–2800).
- Constraints: none beyond platform minimums
- Status: shipped (Debug section: shipped but developer-facing)

### F-MC-26 Camera Capture (Photo into Capture)
- Surface: Capture toolbar "Take Photo…"; requested input `.camera`
- Summary: Sheet hosting an AVCaptureSession photo capture with preview, delivering JPEG data to the draft as "camera-photo.jpg".
- Details:
  - Device: default video device (built-in/external/Continuity Camera); `.photo` preset; JPEG `AVCapturePhotoSettings`; permission flow with "Open Camera Privacy Settings" deep link (`x-apple.systempreferences:...Privacy_Camera`) on denial.
  - States: configuring spinner, error states ("No camera is available. Connect a camera or enable Continuity Camera.", configuration failure, "did not return an image"), shutter disabled until ready; session start/stop on appear/disappear off-main.
- Evidence: `Voxboard Mac/MacCameraCaptureView.swift` (entire file, 199 lines).
- Constraints: none beyond platform minimums
- Status: shipped

### F-MC-27 Sketch Editor
- Surface: Capture toolbar "Sketch…"; requested input `.sketch`
- Summary: Mouse/trackpad/tablet drawing canvas saved to the draft as both a JSON vector document (`sketch.voxsketch`, content type `application/vnd.voxmd.sketch+json`) and a 2× PNG preview.
- Details:
  - Stroke capture via DragGesture(minimumDistance: 0); single points render as 4pt dots; 4pt round black strokes on white; Clear/Cancel/Add to Capture (Add disabled with no strokes).
  - Document: `MacSketchDocument {canvasWidth, canvasHeight, strokes:[[x,y]]}` encoded JSON; PNG rendered via `ImageRenderer(scale: 2)`; staged via `viewModel.stageSketch(drawingData:previewData:altText:"Sketch created on Mac")`.
- Evidence: `Voxboard Mac/MacSketchEditor.swift` (entire file, 146 lines).
- Constraints: none beyond platform minimums
- Status: shipped

### F-MC-28 Document Scan Processing (OCR + PDF)
- Surface: Capture toolbar "Import Scan or PDF…"
- Summary: `MacDocumentScanProcessor` turns selected images into page image data, a combined PDF, and Vision OCR text, staged via `viewModel.stageScan`.
- Details:
  - OCR: `VNRecognizeTextRequest`, `.accurate` recognition, language correction on, per-page line joining, pages joined with blank lines; empty text → nil.
  - PDF: `PDFDocument` from `NSImage` pages; throws "The selected scan images could not be read." if no readable pages.
  - Runs OCR detached at userInitiated priority; security-scoped read per image URL; non-image selections from the same panel staged as generic files.
- Evidence: `Voxboard Mac/MacDocumentScanProcessor.swift` (entire file, 72 lines); staging call in `MacCaptureWorkspaceView.chooseScan`.
- Constraints: none beyond platform minimums
- Status: shipped

### F-MC-29 Retry Inbox Draining & Folder-Permission Recovery
- Surface: Background (app runtime, activation, unlock); History "Needs Attention"; Capture error banner
- Summary: Failed capture deliveries accumulate in a durable inbox drained at launch, every 5 minutes, on activation, and on unlock; export-folder permission loss triggers an in-flow NSOpenPanel re-authorization.
- Details:
  - Drain triggers: main scene `.task` loop (300s), `applicationDidBecomeActive` (`retryFailedInbox`), `onAppear` (`processPendingInbox`), `usageTracker.hasUnlocked` transition, and after a queued-for-retry export (`pendingCaptureRetryHandler`).
  - Visibility: History "Retry N queued captures" row; Capture error banner inline retry; inbox location decision dialog (Send Without / Always Without / Discard) for queued requests whose preset requires origin-time location.
  - Permission recovery: `prepareFlowForFileExportIfNeeded` / `prepareGlobalExportFolderIfNeeded` (MacRecorder) resolve per-flow/global bookmarks; stale or missing → titled NSOpenPanel ("Vox.md needs permission to save notes for the X Capture Preset.") creating a fresh `.withSecurityScope` bookmark persisted only to the folder fields of the stored flow (concurrent Settings edits preserved). History Reveal reports stale bookmarks with "Reauthorize the destination in Capture Presets."
  - Destination editor also detects stale bookmarks at edit time (`folderPermissionExpired`).
- Evidence: `Voxboard Mac/VoxboardMacApp.swift` (drain triggers); `Voxboard Mac/MacRecorder.swift` (permission recovery); `Voxboard Mac/MacRootView.swift` (`MacHistoryRevealError`); `Voxboard Mac/MacCaptureWorkspaceView.swift` (inbox location dialog).
- Constraints: none beyond platform minimums
- Status: shipped

### F-MC-30 Data Folder & Local Storage
- Surface: Vox.md menu + menu bar "Reveal Data Folder"
- Summary: Reveals the shared app container (`AppConstants.sharedContainerURL`) in Finder; recordings, job queue, transcripts, and capture library live in local app storage.
- Details:
  - Storage constants used throughout: `recordingsDirectoryURL` (recording files, meeting staging `meeting-*`, retained export audio, import copies), `recordingJobsDirectoryURL` (temp-dir fallback when unavailable), `captureLibraryURL` (destinations + entry templates; "Shared capture storage is unavailable." errors when nil), `captureDirectoryURL` (origin snapshots).
  - Recovery preservation: every failure path that could lose audio sets `lastRecoveryAudioURL` with a "recording was preserved" message; audio deleted only after durable delivery (exporter inbox, checkpointed audio, or successful legacy export).
- Evidence: `Voxboard Mac/VoxboardMacApp.swift` (menu items); `Voxboard Mac/MacRecorder.swift` (storage + retention logic).
- Constraints: none beyond platform minimums
- Status: shipped

### F-MC-31 App Shortcuts / Deep-Link Entrypoints
- Surface: `voxmd://` URL scheme; shared-defaults pending-open handoff; `handlesExternalEvents`
- Summary: Mac entry points for triggering capture: URL scheme hosts `capture`, `capture-request` (deep-link actions via `CaptureDeepLinkParser`), `listen`; and cross-app pending-open flags. No AppIntents-based App Shortcuts are defined in the in-scope Mac files (see Uncertainties).
- Details:
  - URL handling queues until the SwiftUI handler is configured (`pendingOpenURLs` in the app delegate).
  - Pending-open keys consumed on appear/activation: `pendingQuickCaptureOpenKey`, `...SourceKey` (CaptureSource), `...VoxIdKey`, `...InputKey` (CaptureRequestedInput → auto-invokes camera/files/scan/sketch/link/voice input).
- Evidence: `Voxboard Mac/VoxboardMacApp.swift` `handleURL`, `consumePendingQuickCaptureOpenIfNeeded`.
- Constraints: none beyond platform minimums
- Status: shipped (App Shortcuts proper: not present in scope)

---

## File-by-file coverage checklist

| File | Lines | Read | Notes |
|---|---|---|---|
| `Voxboard Mac/MacRootView.swift` | 2897 | ✅ full (1–2898, 3 reads) | Navigation, Models, Presets editor, History, Settings, Paywall, Hotkey UI, Debug |
| `Voxboard Mac/MacRecorder.swift` | 2100 | ✅ full (2 reads) | Recording, import, queue, meeting pipeline, export, location, hotkey errors |
| `Voxboard Mac/MacCaptureWorkspaceView.swift` | 1465 | ✅ full (2 reads) | Capture workspace, route inspector, due date sheet |
| `Voxboard Mac/VoxboardMacApp.swift` | 1349 | ✅ full (2 reads) | App scenes, menus, coordinator, delegate, visibility, hotkeys, menu bar |
| `Voxboard Mac/MacMeetingCaptureCoordinator.swift` | 650 | ✅ full | Picker, dual stems, manifest, interruption, meters |
| `Voxboard Mac/MacKeyboardHintCenter.swift` | 617 | ✅ full | Control-B hints |
| `Voxboard Mac/MacCaptureDestinationLibraryView.swift` | 424 | ✅ full | Destination editor |
| `Voxboard Mac/MacStoreManager.swift` | 357 | ✅ full | StoreKit 2 |
| `Voxboard Mac/MacEntryTemplateLibraryView.swift` | 271 | ✅ full | Template library |
| `Voxboard Mac/MacMarkdownComposerTextView.swift` | 210 | ✅ full | NSTextView composer |
| `Voxboard Mac/MacCameraCaptureView.swift` | 199 | ✅ full | Camera |
| `Voxboard Mac/MacSketchEditor.swift` | 146 | ✅ full | Sketch |
| `Voxboard Mac/MacDocumentScanProcessor.swift` | 72 | ✅ full | OCR/PDF |

## Uncertainties

1. **App Shortcuts (AppIntents)**: The task mentions "Mac App Shortcuts"; no AppIntents/`AppShortcut` declarations exist in the 13 in-scope files. The Mac's external entry points are the `voxmd://` URL scheme and shared-defaults pending-open handoff (F-MC-31). App Shortcuts may exist elsewhere in the project (not in scope).
2. **Application Support fallback for unsigned dev builds**: Constantly referenced as `AppConstants.sharedContainerURL` / `captureLibraryURL` etc., which live in `VoxboardShared` (out of scope). The debug env override `VOXBOARD_SHARED_CONTAINER_OVERRIDE`/`AppConstants.debugSharedContainerOverrideEnvironmentKey` implies a container-override mechanism whose production fallback behavior (App Support vs. app group) could not be verified from these files.
3. **TXT/MD/JSON/YAML export formatting details**: Format rendering (e.g., `yamlUsesMarkdownExtension`, Obsidian Bases behavior) is implemented in shared `TranscriptFileExporter` / `ExportFileFormat`; only the UI options and delivery flow were verifiable here.
4. **RecordingQueueView internals** (per-job actions, transcription checkpoint UI) are a shared component; only the Mac retry wiring was in scope.
5. **Usage limit numbers** (15 min / 10 captures) are read from localized strings and `UsageTracker` display code; the authoritative constants live in shared code.
