# Vox.md (Voxboard) iOS/iPadOS UI Feature Inventory

LID: IU. Baseline inventory of every user-visible feature found in `Voxboard/Views/` and `Voxboard/Capture/`. Verified against source only; no invented features.

---

### F-IU-01 Root capture-first navigation (no tab bar)
- Surface: App root (`RootView`); all secondary screens pushed onto NavigationStack
- Summary: The Markdown capture composer is the app's root screen. There is no tab bar or sidebar; History, Settings, Models, Capture Presets, and App Language are pushed as secondary destinations, each reachable from the composer's action bar or Settings rows. Widget/keyboard launch pendings force navigation back to capture.
- Details:
  - `RootDestination` enum: `.capture`, `.history`, `.settings`, `.models`, `.capturePresets`, `.appLanguage` (RootView.swift:10-18)
  - `secondaryDestinationIsPresented` pops back to capture when dismissed (RootView.swift:84-89)
  - `pendingWidgetRecord` / `pendingKeyboardLaunch` onChange forces `.capture` (RootView.swift:48-56)
  - DEBUG-only localization screenshot story routing via `--localization-screenshot` launch argument mapping stories (`02-history`, `03-settings`, `04-models`, `05-capture-presets`, `06-privacy-local`, `07-keyboard`, `08-app-language`, `09-app-language-row`) to destinations (RootView.swift:20-37)
- Constraints: none beyond DEBUG gating of screenshot routing
- Evidence: `Voxboard/Views/RootView.swift` (lines 9-102)
- Status: shipped

### F-IU-02 Quick Capture composer (root screen)
- Surface: `QuickCaptureView` — app root; Markdown text editor
- Summary: A raw-Markdown `UITextView` composer where captures are typed. Shows a blinking caret placeholder when empty and unfocused, an inspiration quote (ZenQuotes API) or the preset's custom capture prompt when empty, and persists a durable draft on every change. Auto-focuses the composer on first load unless release notes are being shown or a modal is up.
- Details:
  - Composer is a `MarkdownComposerTextView` (GeistMono 16pt, Dynamic Type scaling, autocorrection+spellcheck ON, smart quotes/dashes/insert OFF, interactive keyboard dismiss) — QuickCaptureView.swift:1602-1620, MarkdownComposerTextView.swift:94-125
  - Draft autosave on changes to text, voxID, destinationID, entryTemplateID, placementOverride, relativeNotePathOverride (QuickCaptureView.swift:300-320)
  - Blinking caret overlay when empty & unfocused; respects Reduce Motion (530 ms blink) (QuickCaptureView.swift:2276-2305)
  - Inspiration placeholder: preset capture prompt if set, else ZenQuotes quote with attribution link to zenquotes.io (QuickCaptureView.swift:1622-1665)
  - "Capture Sent" toast after successful submit, 2 s, VoiceOver announced (QuickCaptureView.swift:1805-1813, presentSentToast 1502)
  - Background-scene draft save with `beginBackgroundTask` (handleScenePhaseChange 1423-1437)
  - Initial composer focus task with 180 ms delay, skipped if any capture modal is presented (fulfillInitialComposerFocusIfReady 1415-1448)
- Constraints: focus deferral while release-notes sheet is up (environment `defersCaptureInputFocusForReleaseNotes`)
- Evidence: `Voxboard/Views/QuickCaptureView.swift` (lines 74-2311); `Voxboard/Capture/MarkdownComposerTextView.swift` (all)
- Status: shipped

### F-IU-03 Capture Preset selection row
- Surface: Bottom control stack on Quick Capture
- Summary: A menu listing all enabled presets (falls back to defaults when none enabled) with symbol icons, plus a destination/route button showing the effective destination name or override path. An "Override" chip and reset button appear when a per-capture route override is active.
- Details:
  - Preset menu (`capture_vox_selector`), selection syncs Watch state via `WatchRecordingController.publishState()` (QuickCaptureView.swift:1245-1279, selectFlow 1730)
  - Route button label: override filename or destination rootName or "Set up destination" (routeLabel 1400-1405)
  - "Use Preset destination defaults" reset button when `hasAnyRouteOverride` (1272-1279)
- Constraints: only enabled presets listed; if all disabled, built-in defaults shown
- Evidence: `Voxboard/Views/QuickCaptureView.swift` (lines 1245-1281, 1730-1735)
- Status: shipped

### F-IU-04 Capture action bar (History / Settings / Send / mic / keyboard)
- Surface: Bottom bar above editor toolbar on Quick Capture
- Summary: Icon buttons for Recent captures (History sheet), Settings, remaining-free-capture counter, Send capture (or "Unlock unlimited captures" when at free limit), voice recording button, and a show/hide keyboard toggle.
- Details:
  - "Recent captures" button opens HistoryView sheet (1362-1367)
  - Settings button triggers `openSettings` (`capture_settings`) (1369-1373)
  - Free-capture counter shown when locked and ≥7 captures used; label `N free` or "Unlock"; opens paywall `.usageMeter` (1375-1391)
  - Send button: label "Sending capture" while submitting; disabled & 35% opacity when `!canSubmit` or blocked by media/recording/transcribing (`quick_capture_submit`) (1393-1407; captureSubmissionIsBlocked 1393)
  - Keyboard toggle button flips composer focus (1408-1415)
- Constraints: capture submission requires unlock when `usageTracker.isCaptureAtLimit && draft.deliveryKind == .standard`
- Evidence: `Voxboard/Views/QuickCaptureView.swift` (lines 1355-1420, 1389-1396)
- Status: shipped

### F-IU-05 Voice capture button (tap / long-press)
- Surface: Bottom action bar mic button on Quick Capture
- Summary: Single button that starts an inline recording (tap) or opens the detailed recording controls bar (long-press ≥0.45 s). While recording it shows elapsed time, a 7-bar live waveform (100 ms level updates via `TranscriptionIPC.readAudioLevel()`), and a red stop icon.
- Details:
  - Tap while recording always stops, even during unrelated media processing (handleVoiceCaptureTap 923-931)
  - Accessibility: label reflects state ("Stop voice recording, m:ss" / "Transcribing voice capture, N% complete" / "Unlock voice capture" / start hints); custom action "Show detailed recording controls" (557-586)
  - Dimmed to 35% opacity while media processing (586)
- Constraints: start blocked while `isProcessingMedia`, when mic permission missing (error banner prompts Settings), or when transcription usage limit hit (opens paywall `.recording`)
- Evidence: `Voxboard/Views/QuickCaptureView.swift` (lines 506-586, 923-931, 1687-1705, 2299-2311)
- Status: shipped

### F-IU-06 Detailed recording controls bar
- Surface: Expanding panel above the capture controls (`showsVoiceCaptureDetails`)
- Summary: Long-pressing the mic opens a panel with a status header (Recording / Transcribing % / Keyboard Listening On / Voice Capture), a Record/Stop primary button, a segmented mode picker ("Add to Draft" vs "Send Immediately"), preset menu, audio-attach toggle, audio file import, keyboard-listening toggle, usage meter, transcription result row with Copy, and speaker-diarization skip-reason warning.
- Details:
  - Segmented `Recording result` picker (`capture_recording_mode`) maps to `RecordingCompletionMode.captureDraft(attachAudio:)` or `.runVox(flowID:)` (625-630, 1669-1680)
  - "Attach audio to Capture" switch only in Draft mode (640-649)
  - "Import audio" button opens audio/movie fileImporter; import respects usage limit → paywall `.recording` (653-663, handleAudioImport 1742-1759)
  - Keyboard listening toggle: `capture_keyboard_listening`; stops set `autoListenEnabledKey=false` (665-676, togglePersistentListening 1707)
  - Usage meter (locked users): progress bar + "%.1f / 15 min free" or "Limit reached · Unlock"; tap opens paywall `.usageMeter` (698-719)
  - Last transcription result row: "Transcript added to Capture" / "Sent with Preset" + Copy button + diarization skip reason label (`speaker_diarization_skip_reason`) (709-726)
  - All options disabled while recording or processing media (`recordingOptionsAreLocked` 937)
- Constraints: unlocked features gated by `usageTracker.hasUnlocked`
- Evidence: `Voxboard/Views/QuickCaptureView.swift` (lines 588-726)
- Status: shipped

### F-IU-07 Inline live transcription bar (Send Immediately)
- Surface: Above attachment strip in Quick Capture while recording
- Summary: When recording with "Send Immediately" mode, shows a live transcript preview ("Live transcript · sending immediately") with finalized + volatile text, tail-truncated to last 320 characters, 4-line limit, "Listening for speech…" placeholder.
- Details: shown only when `persistentRecorder.isSegmentActive && isCaptureLiveTranscriptionActive && lastStartedRecordingMode == .preset`; VoiceOver label announces full transcript (448-456, 513-552)
- Constraints: Send-Immediately mode only
- Evidence: `Voxboard/Views/QuickCaptureView.swift` (lines 447-456, 487-552)
- Status: shipped

### F-IU-08 Keyboard listening (return guidance & status)
- Surface: Quick Capture nav bar trailing button, detail bar toggle, and top banner
- Summary: Enables the shared keyboard-extension voice pipeline. When the keyboard launches Vox.md (pendingKeyboardLaunch), a dismissible banner guides the user: "Turning on keyboard listening" → "Keyboard listening is on" / error with mic-access hint; auto-dismisses after 6 s. Nav-bar headphones button stops listening when active.
- Details:
  - `KeyboardLaunchPhase`: starting/ready/error with distinct icons/colors; blue info vs red error styling (733-796)
  - `handleKeyboardLaunch` prepares backend, posts accessibility announcements, tracks OnboardingAnalytics keyboard setup started/completed (1726-1741)
  - Nav bar stop button visible when `persistentRecorder.isListening && autoListenEnabledKey` (229-243)
- Constraints: requires microphone access; DEBUG screenshot story can pre-open details
- Evidence: `Voxboard/Views/QuickCaptureView.swift` (lines 214-243, 459-467, 733-796, 1707-1741, 1775-1803)
- Status: shipped

### F-IU-09 Photo / screenshot attachment pickers
- Surface: Editor toolbar Add Media menu (Photo, Screenshot)
- Summary: Two PhotosUI pickers (images vs screenshots), each limited to 10 selections, staging picked images as draft payloads. Screenshots get localized alt text "Screenshot"; filenames are `photo-<uuid>.<ext>` / `screenshot-<uuid>.<ext>`.
- Details: `.photosPicker` modifiers (607-625); `importPhotos`/`importScreenshots` stage via `viewModel.stageImage`, set `isProcessingMedia`, refocus composer on completion, per-item error surfacing (1520-1570)
- Constraints: max 10 per batch; media processing blocks recording start and send
- Evidence: `Voxboard/Views/QuickCaptureView.swift` (lines 607-625, 1520-1570)
- Status: shipped

### F-IU-10 Camera capture
- Surface: Editor toolbar Add Media → Camera
- Summary: Presents `UIImagePickerController` (camera, falls back to photo library when camera unavailable), captures a JPEG at 0.9 quality, and stages it as `camera-<yyyyMMdd-HHmmss>.jpg`.
- Details: cancel refocuses composer; capture sets `isProcessingMedia` during staging (641-654, MultimodalCaptureViews.swift:58-92)
- Constraints: device camera availability
- Evidence: `Voxboard/Views/QuickCaptureView.swift` (lines 641-656); `Voxboard/Capture/MultimodalCaptureViews.swift` (lines 58-92)
- Status: shipped

### F-IU-11 File attachment importer
- Surface: Editor toolbar "Add files" button
- Summary: Presents a native UIKit document picker (`UIDocumentPickerViewController`, `.data` content types, multiple selection, copy mode — chosen over SwiftUI fileImporter for on-device reliability) and stages files; images embed as images, audio embeds as audio, others as generic files.
- Details: respects `CaptureInputBudget` shared-item reservation; cancel refocuses composer (627-640, importFiles 1571-1592; MultimodalCaptureViews.swift:9-56)
- Constraints: staged files share the `CaptureInputBudget` shared-item reservation; otherwise none beyond platform minimums
- Evidence: `Voxboard/Views/QuickCaptureView.swift` (lines 627-640, 1571-1592); `Voxboard/Capture/MultimodalCaptureViews.swift` (lines 9-56)
- Status: shipped

### F-IU-12 Document scan (VisionKit)
- Surface: Editor toolbar "Scan document"
- Summary: Presents `VNDocumentCameraViewController`; scanned pages are OCR'd (accurate, language correction, no auto language detection, unreadable pages skipped) and assembled into a US-Letter PDF, then staged as a scannedDocument payload with page images, PDF, and extracted text.
- Details: `DocumentScanProcessor.process` (MultimodalCaptureViews.swift:262-294); PDF renderer insets 24 pt, fit-scales each page (296-313); scanner errors surface in the error banner (QuickCaptureView.swift:657-670)
- Constraints: button hidden unless `VNDocumentCameraViewController.isSupported`
- Evidence: `Voxboard/Views/QuickCaptureView.swift` (lines 657-672, 1593-1604); `Voxboard/Capture/MultimodalCaptureViews.swift` (lines 94-118, 262-313)
- Status: shipped

### F-IU-13 Journal page capture & OCR (Capture Text)
- Surface: Editor toolbar "Extract text" menu → "Capture Journal Pages" / "Choose Journal Photos"
- Summary: Manual multi-page camera capture (native shutter only, avoiding VisionKit auto-capture) up to 10 pages, or ordered photo selection, followed by on-device Vision OCR (accurate, language correction, automatic language detection, unreadable page → hard error) that appends recognized Markdown text directly into the composer.
- Details:
  - Manual journal sheet: thumbnail strip with numbered pages, page counter (a11y id `journal_capture_page_count`), "Capture Page/Next Page", "Remove Last Page", "Use Pages" disabled when empty, auto-presents camera on open, VoiceOver "Page N captured" announcements (MultimodalCaptureViews.swift:126-251)
  - "Extracting text on this device…" progress banner with `capture_ocr_progress` id (QuickCaptureView.swift:161-174)
  - OCR blocked while any voice capture/transcription/watch processing is active — error "Finish the current voice capture before extracting journal text." (`requireIdleVoiceCaptureForOCR` 933-945); re-checked before appending so Watch delivery can't merge transcripts into one draft (extractJournalText 1640-1655)
  - `JournalImageOCRProcessorError`: noImages / unreadableImage(page) / noTextRecognized with photography guidance (MultimodalCaptureViews.swift:252-260)
  - Photo route uses ordered selection (`.ordered`) PhotosPicker (QuickCaptureView.swift:615-621)
- Constraints: camera required for page capture; max 10 pages
- Evidence: `Voxboard/Views/QuickCaptureView.swift` (lines 615-621, 932-945, 1539-1555, 1606-1655); `Voxboard/Capture/MultimodalCaptureViews.swift` (lines 120-260, 315-382)
- Status: shipped

### F-IU-14 Sketch editor (PencilKit)
- Surface: Editor toolbar Add Media → Sketch (and dedicated sketch toolbar action)
- Summary: Full-screen PencilKit canvas with system tool picker (pen, black, width 4, any input). "Add" exports the PKDrawing data plus a 2× PNG preview (bounds +24 pt inset, default 1024×768 when empty) as a sketch payload; disabled with no strokes.
- Details:
  - "Add" exports `drawing.dataRepresentation()` plus a 2x PNG via `drawing.image(from:scale: 2)` using `drawing.bounds.insetBy(dx: -24, dy: -24)` or a default 1024x768 rect when empty; disabled while `drawing.strokes.isEmpty` (MultimodalCaptureViews.swift `CaptureSketchEditor`)
  - Canvas: `PKCanvasView` with default `PKInkingTool(.pen, color: .black, width: 4)`, `drawingPolicy = .anyInput`, a visible `PKToolPicker` with the canvas made first responder; drawing synced through `PKCanvasViewDelegate` (`PencilCanvas`)
  - Saving sets `isProcessingMedia` while `viewModel.stageSketch` runs, then refocuses the composer; cancel dismisses and refocuses (QuickCaptureView.swift sketch sheet)
- Constraints: `drawingPolicy = .anyInput` supports finger + pencil
- Evidence: `Voxboard/Views/QuickCaptureView.swift` (lines 693-707); `Voxboard/Capture/MultimodalCaptureViews.swift` (lines 385-461)
- Status: shipped

### F-IU-15 Web link prompt
- Surface: Editor toolbar Add Media → Web Link
- Summary: Alert with a URL keyboard text field; valid URLs are added as a `url` payload to the durable draft, invalid input shows "Enter a valid link." Message reassures "The link stays in your durable draft until the note is captured."
- Details:
  - Alert titled "Capture Link" with a URL-keyboard TextField (`https://example.com`, autocapitalization off); Cancel clears the entered text (QuickCaptureView.swift link alert)
  - Add trims whitespace, parses with `URL(string:)`, and calls `viewModel.addURL`; parse failure sets error "Enter a valid link."
- Constraints: none beyond platform minimums
- Evidence: `Voxboard/Views/QuickCaptureView.swift` (lines 709-726, presentedContent alert 730-747)
- Status: shipped

### F-IU-16 Attachment strip
- Surface: Below composer when the draft has payloads
- Summary: Horizontally scrolling capsule chips for each staged payload (text, URL, audio/retained audio, image, file, scan "N page(s)", sketch) with icon, label, and per-item remove button; each removal calls `viewModel.removePayload`.
- Details:
  - One capsule chip per `viewModel.draft.additionalPayloads` in a horizontal ScrollView: payload icon, one-line label, and an `xmark.circle.fill` remove button calling `viewModel.removePayload(at:)` with a11y label "Remove <item>" (QuickCaptureView.swift `attachmentStrip`)
  - Strip hidden when the payload list is empty; container carries a11y label "Capture attachments"; `payloadIcon`/`payloadLabel` map payload kinds to SF Symbols/labels
- Constraints: none beyond platform minimums
- Evidence: `Voxboard/Views/QuickCaptureView.swift` (lines 1421-1450, payloadIcon/payloadLabel 2256-2274)
- Status: shipped

### F-IU-17 Markdown editor toolbar (full command set)
- Surface: Horizontally scrolling 48 pt toolbar above the keyboard area, driven by user-configurable `CaptureToolbarPreferences.visibleActions`
- Summary: Every action: Add Media (menu: Sketch/Camera/Photo/Screenshot/Web Link), Add files, Scan document, Extract text (menu: Capture Journal Pages / Choose Journal Photos), Undo, Format Markdown (menu: Bold/Italic/Hashtag/Heading 1-6), Markdown link, Due date, Checklist, Bullet list, Paste, Internal link `[[ ]]`, Sketch, Current location, Timestamp, Date, Text case (menu: Lowercase/Uppercase/Sentence case/Capitalize case/Slugify case).
- Details:
  - `CaptureEditorToolbarCommand` enum: undo, bold, italic, hashtag, heading(Int), markdownLink, checklist, bulletList, paste, internalLink, timestamp, date, lowercase, uppercase, sentenceCase, capitalizeWords, slugify (CaptureEditorToolbar.swift:3-21)
  - Command dispatch in `handleToolbarCommand` (QuickCaptureView.swift:1270-1310): paste pulls `UIPasteboard.general.string`; timestamp/date use POSIX formatters (`yyyy-MM-dd`); internalLink opens vault picker; text transforms via `CaptureComposerTextEditor().applying(...)` with selection-aware replace + undo registration
  - Disabled states: media actions while `isProcessingMedia`; extract-text while busy or `!canExtractText`; journal pages require camera; location button shows filled icon while locating and is disabled
  - Reorderable/hideable via Capture Bar settings (F-IU-29)
- Constraints: journal page capture requires a camera; media actions disabled while `isProcessingMedia`; otherwise none beyond platform minimums
- Evidence: `Voxboard/Capture/CaptureEditorToolbar.swift` (all); `Voxboard/Views/QuickCaptureView.swift` (lines 1270-1316)
- Status: shipped

### F-IU-18 Markdown composer text engine & undo
- Surface: Backing engine for the composer and all toolbar commands
- Summary: `MarkdownComposerController` wraps the UITextView with selection-aware `replaceAll`/`replaceSelection` that register undo actions ("Edit Markdown") sharing the same undo stack as typing; selection is clamped to UTF-16 length; edits scroll range to visible. `MarkdownComposerTextView` syncs text/selection/focus bindings and queues focus until the view is attached.
- Details: undo via `textView.undoManager` (MarkdownComposerTextView.swift:24-80); focus plumbing with window-attached check (128-137)
- Constraints: none beyond platform minimums
- Evidence: `Voxboard/Capture/MarkdownComposerTextView.swift` (all)
- Status: shipped

### F-IU-19 Due date sheet
- Surface: Editor toolbar due-date action → sheet
- Summary: Graphical date picker with quick buttons (Today/Tomorrow/This Weekend showing weekday+date), optional Time toggle revealing an hour/minute picker and ±15m/±30m/±1h adjustment chips. Insert writes a due-date token at the composer selection via `CaptureInsertionFormatter.dueDateToken(includeTime:)` and refocuses.
- Details: quick dates preserve currently selected time (default 9:00); insert button label previews the formatted date; `.presentationDetents([.large])` (CaptureDueDateSheet.swift)
- Constraints: none beyond platform minimums
- Evidence: `Voxboard/Capture/CaptureDueDateSheet.swift` (all); `Voxboard/Views/QuickCaptureView.swift` (lines 466-473)
- Status: shipped

### F-IU-20 Internal link picker ([[wiki links]])
- Surface: Editor toolbar internal-link action → sheet
- Summary: Builds an on-device index of Markdown notes (max 5,000, hidden files skipped, path-validated, sorted) under the selected preset root and lets the user search filenames, insert today's date as a link, type a custom target, or pick a note to insert a `[[wiki link]]` at the composer selection.
- Details: `CaptureVaultNoteIndex` actor with security-scoped access and 5,000-note cap (CaptureInternalLinkPicker.swift:9-48); states: "Choose a destination first." (no root), "No Markdown notes found.", indexing spinner, error text; search filters path and display name; custom target requires non-empty
- Constraints: requires a configured destination root; link formatting errors surface inline
- Evidence: `Voxboard/Capture/CaptureInternalLinkPicker.swift` (all); `Voxboard/Views/QuickCaptureView.swift` (lines 474-480, 1290-1292)
- Status: shipped

### F-IU-21 Current location insertion
- Surface: Editor toolbar location action; also preset location status bar
- Summary: One-shot `CLLocationManager` request inserts a Google Maps Markdown link (lat/long/label) at the composer selection; shows a "Finding Location…" status bar while active; cancelled when leaving Capture; errors surface in the error banner. When the selected preset has location enabled, a persistent "Current Location On · <preset>" status bar is shown (or Finding Location… while the recorder resolves).
- Details: `locationRequestTask` cancellation on background/disappear (1423-1443, 1450-1469); accessibility ids `capture_finding_preset_location` / `capture_active_preset_location` (1196-1235)
- Constraints: location permission; one-shot only, not background tracking
- Evidence: `Voxboard/Views/QuickCaptureView.swift` (lines 1186-1235, 1450-1469)
- Status: shipped

### F-IU-22 Location unavailable decision dialogs
- Surface: Quick Capture confirmation dialogs at send time
- Summary: If a capture's origin-time location is unavailable, a dialog offers Retry / Send Without Location / Always Send Without Location for This Preset / Cancel ("Your draft is preserved."). Background-originated inbox captures (keyboard) get a separate dialog: Send Without Location / Always… / destructive "Cancel and Discard Capture".
- Details: bound to `viewModel.locationDecision` and `viewModel.inboxLocationDecision` (QuickCaptureView.swift:347-400); inbox title includes preset name
- Constraints: preset `unavailableBehavior == .ask`
- Evidence: `Voxboard/Views/QuickCaptureView.swift` (lines 347-400, 1398-1399)
- Status: shipped

### F-IU-23 {location} token hint & one-tap enable
- Surface: Status bar above controls in Quick Capture; also in Route Picker sheet
- Summary: When resolved entry formatting uses the `{location}` token but the delivering preset has location off, a non-blocking hint ("{location} needs Current Location for this Preset") offers a one-tap "Use Current Location" button that enables the preset's location capture without writing metadata.
- Details: a11y id `capture_entry_location_token_hint`; route-picker variant includes enable button `capture_entry_location_token_enable` and footnote about first-use permission prompt (QuickCaptureView.swift:1237-1281; CaptureRoutePickerView.swift:73-89)
- Constraints: one-tap enable triggers the first-use system location permission prompt (per route-picker footnote); otherwise none beyond platform minimums
- Evidence: `Voxboard/Views/QuickCaptureView.swift` (lines 1237-1281); `Voxboard/Capture/CaptureRoutePickerView.swift` (lines 60-89)
- Status: shipped

### F-IU-24 Destination-not-configured banner & setup
- Surface: Quick Capture top banner when no destination is selected
- Summary: "Destination Not Configured — Set up where this Capture Preset writes Markdown" banner with "Set Up" affordance opens the Route Picker sheet; the picker offers the same setup, inline preset destination editing, per-capture overrides, and a resolved-note preview.
- Details: a11y id `capture_destination_banner` (QuickCaptureView.swift:1100-1130)
- Constraints: none beyond platform minimums
- Evidence: `Voxboard/Views/QuickCaptureView.swift` (lines 174-179, 1100-1130); see F-IU-25
- Status: shipped

### F-IU-25 Capture route picker sheet (per-capture overrides)
- Surface: Sheet from route button / banner
- Summary: Shows the selected preset, its vault/folder, an "Edit/Set Up Preset Destination" button (opens `CaptureDestinationEditorView` with fixed preset name), and per-capture-only overrides: Placement (Preset Default/Top/Bottom), Entry template (Preset Default or any template), "Choose another note in this vault" (Markdown note picker → one-off note override), "Use Preset defaults" reset, a "Resolved note" monospaced preview, and the {location} hint section. Done saves the draft immediately.
- Details: placement override mapping prepend/append (CaptureRoutePickerView.swift:60-131); one-off note set via `viewModel.setOneOffNote(url:)`
- Constraints: none beyond platform minimums
- Evidence: `Voxboard/Capture/CaptureRoutePickerView.swift` (lines 8-131)
- Status: shipped

### F-IU-26 Folder & Markdown note pickers (UIKit)
- Surface: Destination editor, route picker, vault template selection
- Summary: Security-scoped UIKit pickers: `CaptureFolderPicker` (folders only, no copy) and `CaptureMarkdownNotePicker` (.md only, shows file extensions, no copy, starts at vault root). Both expose cancel callbacks that refocus the composer.
- Details:
  - `CaptureFolderPicker`: `UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)`, single selection, opens at `initialDirectoryURL`, a11y label "Choose vault or folder" (CaptureRoutePickerView.swift)
  - `CaptureMarkdownNotePicker`: same no-copy picker restricted to Markdown content types, starting at the vault root; both delegate callbacks invoke `onPick`/`onCancel`
- Constraints: requires user-granted security-scoped access to the vault/folder; content types restricted to folders / Markdown notes respectively
- Evidence: `Voxboard/Capture/CaptureRoutePickerView.swift` (lines 137-198)
- Status: shipped

### F-IU-27 Watch recording status card & queue entry
- Surface: Top card on Quick Capture when Watch items are visible
- Summary: A live status card for the current Watch pipeline item (title/subtitle/symbol per phase: queued/transcribing/delivering/delivered/failed) that opens the Watch Recording Queue sheet; shows a spinner while transcribing/delivering, a "Get Vox.md Unlimited" button when waiting on the transcription upgrade, or a "Retry" button when failed.
- Details: a11y id `watch_recording_status`; delivered Watch recordings refresh history/usage and show the Capture Sent toast (onChange of `lastDeliveredRecordingID`) (QuickCaptureView.swift:190-212, 359-366)
- Constraints: shown only when `watchRecordingPipeline.hasVisibleItems`; "Get Vox.md Unlimited" CTA only while an item waits on the free-tier transcription upgrade (paywall `.limit`)
- Evidence: `Voxboard/Views/QuickCaptureView.swift` (lines 190-212, 359-366)
- Status: shipped

### F-IU-28 Watch recording queue sheet
- Surface: Sheet from status card
- Summary: Lists Watch recordings (excluding discarded and acknowledged-terminal), pull-to-refresh, per-item status title/subtitle/symbol, preset name and duration, and failure recovery: "Choose Preset" menu (when preset selection required), "Retry", "Change Preset" menu (recording-only presets), destructive "Discard" with confirmation ("removes the retained audio and any capture still queued"), "Capture Recording Without Transcript" (transcription-stage failures with audio, non-recording-only), and "Get Unlimited" paywall when a queued item hit the transcription limit.
- Details: `WatchRecordingInboxItem` extensions `watchStatusTitle/Subtitle/Symbol`, `isWaitingForTranscriptionUpgrade`, `canCaptureRecordingWithoutTranscript` (WatchRecordingQueueView.swift:110-258); empty state ContentUnavailableView
- Constraints: paywall gated on free-tier transcription limit
- Evidence: `Voxboard/Views/WatchRecordingQueueView.swift` (all)
- Status: shipped

### F-IU-29 Settings screen (MetaSettingsView)
- Surface: Pushed Settings destination
- Summary: Sectioned settings: Vox.md Unlimited (access status, price, Family upgrade), Activity (Stats), Recording Queue, Customization (Models / Capture Presets / Capture Bar / App Language), Keyboard (Haptic Feedback), Lock Screen (Live Activity Monitor, Lock Screen Record Button), About (engine/privacy/version/Apple Intelligence status), Feedback (Discord, Send Feedback), Debug (View Debug Log).
- Details:
  - Upgrade row shows free usage "x.x / 15 min · N / 10 captures used", "From <price>" / "Checking price…", Purchased/Family badge (MetaSettingsView.swift:99-165)
  - Live Activity toggle starts/ends `LiveActivityController` when listening (275-297)
  - Lock Screen Record toggle reloads the `VoxboardRecordWidget` timelines and iOS 18+ `VoxboardRecordControl` (299-323)
  - About rows: default transcription (Apple Speech), optional whisper.cpp, optional Parakeet (FluidAudio CoreML), on-device processing, privacy, version (build); Apple Intelligence row only on iOS 26+ (327-360)
  - Send Feedback uses MFMailCompose when possible, else mailto URL with diagnostics payload (361-460)
  - StoreKit prepareForPurchases on appear so existing owners see the Family offer (84-86)
- Constraints: Lock Screen Record uses the iOS 18+ `VoxboardRecordControl` (widget-only reload before that); Apple Intelligence About row is iOS 26+; purchase/pricing rows depend on StoreKit product/entitlement readiness
- Evidence: `Voxboard/Views/MetaSettingsView.swift` (all)
- Status: shipped

### F-IU-30 Capture Bar customization (toolbar settings)
- Surface: Settings → Customization → Capture Bar (push)
- Summary: Lets the user choose, reorder, and hide quick actions in the editor toolbar via `CaptureToolbarPreferences`. (Referenced view `CaptureToolbarSettingsView` lives outside in-scope files; the preferences object drives `CaptureEditorToolbar.visibleActions`.)
- Details:
  - Settings row pushes `CaptureToolbarSettingsView(preferences: captureToolbarPreferences)` (MetaSettingsView.swift customization section)
  - `CaptureToolbarPreferences` persists an action order plus a `hiddenActions` set; `visibleActions` = ordered actions minus hidden (`Voxboard App Shared/CaptureToolbarPreferences.swift:117-171`); toolbar renders `ForEach(preferences.visibleActions)` (CaptureEditorToolbar.swift:45)
- Constraints: none beyond platform minimums
- Evidence: `Voxboard/Views/MetaSettingsView.swift` (lines 228-236); `Voxboard/Capture/CaptureEditorToolbar.swift` (preferences usage); tests `VoxboardTests/CaptureToolbarPreferencesTests.swift`
- Status: shipped

### F-IU-31 Debug log viewer
- Surface: Settings → Debug → View Debug Log sheet
- Summary: Monospaced scrollable log from `KeyboardDebugLog` with Clear Log (destructive), reload (↺), Copy Log, and Done; shows "(empty)"/"(cleared)" placeholders. Text selection enabled.
- Details:
  - `SettingsDebugLogView` (MetaSettingsView.swift:622-685): monospaced footnote text in a ScrollView showing "(empty)" when there is no content; Clear Log writes "(cleared)" after `KeyboardDebugLog.shared.clear()`
  - Toolbar: destructive-styled "Clear Log" (leading); trailing reload button reading `KeyboardDebugLog.shared.read()`, "Copy Log" via `UIPasteboard`, and "Done" to dismiss; text selection enabled
- Constraints: none beyond platform minimums
- Evidence: `Voxboard/Views/MetaSettingsView.swift` (lines 490-540)
- Status: shipped

### F-IU-32 Capture Presets list screen
- Surface: Settings → Customization → Capture Presets (also a root destination)
- Summary: Lists all presets with icon, name, and output descriptor ("Recording Only (Watch)" or processing mode); badges "Default" (profile-selected) and "Keyboard" (keyboard-selected); swipe-delete for non-built-in presets with ownership retirement and selection fallback; "Add Preset" creates a custom preset; "Entry Templates" link; intro explainer section. Edits publish Watch state (debounced 300 ms) and update iOS 18 App Shortcuts parameters.
- Details:
  - Rows: preset symbol, name, and output descriptor ("Recording Only (Watch)" for recording-only presets, else `postProcessingMode.displayName`); "Default" badge when profile-selected, "Keyboard" badge when `CapturePresetStore.selectedFlowId()` matches (FlowSettingsView.swift list rows)
  - Swipe delete (non-built-in presets only) calls `CapturePresetStore.retirePreset` and falls selection back to the first remaining preset or `generalId`
  - Edits persist via `saveFlows`, publish Watch state debounced 300 ms and again on disappear, and update App Shortcuts parameters on iOS 18+ (`scheduleWatchStatePublish`, onChange of flows)
- Constraints: delete disabled for built-in presets; App Shortcut parameter updates require iOS 18+; otherwise none beyond platform minimums
- Evidence: `Voxboard/Views/FlowSettingsView.swift` (lines 12-138)
- Status: shipped

### F-IU-33 Capture Preset editor
- Surface: Pushed from preset list
- Summary: Full preset configuration form with sections: Identity (name, icon picker link, Enabled toggle), Apple Watch Output, Voice Processing, Capture Processing, Destination, Metadata (frontmatter), Location, Legacy Voice File Export (only when no unified destination), Voice Audio.
- Details:
  - Section composition is conditional: Recording Only presets show only Identity + Apple Watch Output; otherwise Voice Processing, Capture Processing, Destination, then Legacy Voice File Export only when `flow.captureDestinationID == nil`, then Metadata + Location (per `showsFrontmatterSection`), then Voice Audio (FlowSettingsView.swift editor body)
  - Destination editor sheet passes `fixedName: flow.displayName` and saves via `saveOwnedDestination`; frontmatter TextEditor seeded in `init` and re-parsed on change
- Details per section in F-IU-34…F-IU-39; destination editor opened as sheet with fixed preset name; frontmatter parsed one `key: value` per line on disappear and on change (FlowSettingsView.swift:140-227, 596-610)
- Constraints: legacy export and metadata/location sections hidden when a unified destination is set or the watch output is Recording Only; otherwise none beyond platform minimums
- Evidence: `Voxboard/Views/FlowSettingsView.swift` (lines 140-227)
- Status: shipped

### F-IU-34 Preset: Apple Watch output mode
- Surface: Preset editor "Apple Watch Output" section
- Summary: Picker over `CapturePresetWatchOutputMode`; "Recording Only" switches Watch recordings to raw M4A copy into a user-visible Files folder (skipping transcription/AI/usage). Config: Recording Folder bookmark picker, Clear, filename template with tokens ({timestamp},{date},{time},{YR},{id8},{id},{preset},{original}), warning when no folder chosen, notification-permission check with "Open Notification Settings" deep link when denied (alerts requested with .alert+.sound).
- Details: selecting Recording Only triggers notification authorization request; footer explains background delivery, iOS delays, force-quit caveat, and safe retry queue (FlowSettingsView.swift:229-286, notification helpers 1097-1119)
- Constraints: requires chosen Files folder before Watch use; notifications optional but warned
- Evidence: `Voxboard/Views/FlowSettingsView.swift` (lines 229-286, 1097-1119)
- Status: shipped

### F-IU-35 Preset: Voice Processing (speaker diarization)
- Surface: Preset editor "Voice Processing" section
- Summary: "Identify Speakers" toggle enabling fully on-device multi-voice labeling appended after transcription; footer notes first-use model download and best-effort behavior (falls back to normal transcript).
- Details:
  - `Toggle("Identify Speakers", $flow.speakerDiarizationEnabled)`; when on, caption "Speaker labels are added after transcription." (FlowSettingsView.swift:332-339)
  - Footer: detection runs entirely on device, the speaker model downloads the first time the preset uses it, and identification is best-effort (falls back to the normal transcript)
- Constraints: speaker-diarization model downloads on first use (network/storage); otherwise none beyond platform minimums
- Evidence: `Voxboard/Views/FlowSettingsView.swift` (lines 288-303)
- Status: shipped

### F-IU-36 Preset: Capture Processing (AI post-processing)
- Surface: Preset editor "Capture Processing" section
- Summary: "Use Apple Intelligence" master toggle gating on-device processing, "Apply To" scope picker (`both/voiceOnly/textOnly` → Voice & Text / Voice Only / Text Only, shown when toggled on), scope-aware caption under the Mode picker, Mode picker (none/clean/todoList/meetingNotes/custom with per-mode help title+text), custom instruction TextEditor (min 90 pt), and "Empty Capture Prompt" text field (2-4 lines, e.g., "What do you want to remember?").
- Details: info sheet at `.medium/.large` detents with drag indicator (FlowSettingsView.swift:305-366, 827-880); footer: voice always uses selected mode; typed text opt-in; deterministic/original fallback when AI unavailable
- Constraints: on-device Apple Intelligence availability
- Evidence: `Voxboard/Views/FlowSettingsView.swift` (lines 305-366, 827-880, 1245-1284)
- Status: shipped

### F-IU-37 Preset: Destination section
- Surface: Preset editor "Destination" section
- Summary: Shows the preset-owned destination (vault name + monospaced "target · placement" summary) with Edit, or a ContentUnavailableView + "Set Up Destination" when unconfigured; storage load errors shown in red. Saving runs legacy Markdown-template migration and clears conflicting legacy template settings.
- Details:
  - Configured state: "Vault / Folder" `LabeledContent` with the root name, monospaced destination summary, and "Edit Destination" button; unconfigured: `ContentUnavailableView("Destination Not Configured")` plus "Set Up Destination" (FlowSettingsView.swift:400-425)
  - Storage load error rendered in red; footer enumerates what the destination owns (note target, placement, entry formatting, attachments folder, retry behavior)
- Constraints: none beyond platform minimums
- Evidence: `Voxboard/Views/FlowSettingsView.swift` (lines 368-393, 679-731); destination editor covered in F-IU-40
- Status: shipped

### F-IU-38 Preset: Metadata scope & static frontmatter
- Surface: Preset editor "Metadata" section
- Summary: Scope picker (Note Frontmatter vs Inline Entry Fields) with contextual guidance (document scope caution on rolling notes; entry scope writes `key:: value` lines), plus a monospaced TextEditor (min 120 pt) of one-per-line `key: value` static frontmatter parsed live.
- Details:
  - Scope picker over `CapturePresetMetadataScope.allCases` with contextual caption: frontmatter warns about rolling notes, entry scope writes `key:: value` lines (FlowSettingsView.swift:439-447)
  - Caption "One `key: value` per line. Example: `tags: [journal, idea]`."; monospaced TextEditor (min 120 pt) parsed via `parseFrontmatter` on every change
- Constraints: none beyond platform minimums
- Evidence: `Voxboard/Views/FlowSettingsView.swift` (lines 395-416, 1121-1144)
- Status: shipped

### F-IU-39 Preset: Location configuration
- Surface: Preset editor "Location" section
- Summary: "Use Current Location" toggle; Precision picker (Exact / City); "When Location Is Unavailable" picker (Ask / Send Without Location / Cancel Capture); "Write Location Metadata" toggle revealing output Configuration (Structured Fields / Advanced YAML Template — the latter disabled under entry scope with an error label + "Use Note Frontmatter Scope" fix button), collection key field (document scope only), per-field structured toggles (`CaptureLocationField.allCases`) each with a custom Output key field, or a monospaced Advanced YAML Template editor (min 160 pt) with `{{coordinates}}`, `{{city}}`, `{{timestamp}}`, `{{id}}` placeholders; live Delivery Preview (success card, selectable, scrollable) or validation error; reset buttons ("Reset Location Unavailable Choice", destructive "Reset Location Configuration").
- Details: a11y ids `preset_location_enabled/precision/unavailable_behavior/metadata_output_enabled/output_mode/scope_error/collection_key/key_<field>/advanced_template/preview/validation_error/reset_*`; footers clarify reverse-geocoder network use for place fields, provider-link disclosure only when opened, single request at send/stop, no background tracking (FlowSettingsView.swift:418-536)
- Constraints: Advanced YAML template requires document scope
- Evidence: `Voxboard/Views/FlowSettingsView.swift` (lines 418-536, 538-570); tests `CaptureLocationConfigurationSupportTests.swift`, `CaptureEntryLocationTokenSupportTests.swift`
- Status: shipped

### F-IU-40 Destination library & editor
- Surface: Preset editor destination sheet; also `CaptureDestinationLibraryView.swift` hosts the editor, entry-template library/editors
- Summary: `CaptureDestinationEditorView` form: Identity (optional name or fixed preset name; Vault/Folder picker), Note Target segmented picker (New Note / Rolling Note / Existing Note) with path template field + contextual token help, rolling Period picker (daily…yearly), "Choose Existing Note…" browser, Placement segmented (Bottom/Top/Heading) with heading title, level Stepper 1-6, missing-heading behavior (Show Error / Create Heading), Entry Formatting (vault template selection with live "edits in Obsidian apply automatically" behavior, reusable-template picker with Custom fallback, prefix/suffix monospaced editors, `{location}` sample preview, attachments folder field), Delivery ("Retry Protection" toggle adding a vox-capture HTML comment), inline error section, Cancel/Save with Saving… state. Save preflights: folder required, relative-path validation, heading required, existing-note existence + mutation dry run, vault-template existence/size (≤ max text chars), template≠destination, stale bookmark detection.
- Details:
  - Token sets per target documented in `pathHelp` (CaptureDestinationLibraryView.swift:434-442)
  - Error enum messages: folderRequired, headingRequired, existingNoteMissing, folderPermissionExpired, noteOutsideRoot, templateOutsideRoot, markdownTemplateRequired (852-877)
  - Entry template library: list with swipe-delete (destinations referencing a deleted template get its prefix/suffix copied), Add Template editor, Import Markdown Template file importer (md-only, ≤4×char bytes and char-count limits, UTF-8 required), token footer, error section (14-120)
  - Template delete cascades: `CapturePresetStore.clearCaptureEntryTemplate(id)` (122-144)
- Constraints: Save preflights enforce folder required, relative-path validation, heading required for heading placement, existing-note existence + mutation dry run, vault-template existence/size caps, template≠destination, and non-stale folder bookmarks
- Evidence: `Voxboard/Views/CaptureDestinationLibraryView.swift` (all)
- Status: shipped

### F-IU-41 Preset: Legacy Voice File Export
- Surface: Preset editor "Legacy Voice File Export" section (only when no unified destination)
- Summary: "Save Notes to Files" toggle; Export Directory folder bookmark row + Clear; Format picker (TXT/MD/JSON/YAML); MD-only "Obsidian Bases" toggle; YAML-only ".md Extension" toggle and YAML properties toggles (minimum one enforced, last disabled); Mode picker (New File with filename template tokens {timestamp},{date},{time},{YR},{id8},{id},{model},{language} / Append filename); "Use Markdown Template" toggle + template file picker. All edits mark settings per-flow (`usesCustomExportSettings = true`).
- Details:
  - "Save Notes to Files" toggle; Export Directory bookmark row + Clear; Format picker TXT/MD/JSON/YAML; MD-only "Obsidian Bases" toggle; YAML-only ".md Extension" toggle + YAML properties picker (FlowSettingsView.swift:642-706)
  - Mode picker: New File (filename template with {timestamp},{date},{time},{YR},{id8},{id},{model},{language} tokens) or Append filename; "Use Markdown Template" toggle + md template bookmark picker; every edit calls `markPerFlow()` setting `usesCustomExportSettings`
- Constraints: section shown only when the preset has no unified destination (`flow.captureDestinationID == nil`); applies only to direct voice runs
- Evidence: `Voxboard/Views/FlowSettingsView.swift` (lines 572-655, 733-761)
- Status: legacy (compatibility; footer: "apply to direct voice runs only when no unified Capture route is selected")

### F-IU-42 Preset: Voice Audio handling
- Surface: Preset editor "Voice Audio" section
- Summary: "Save Audio" picker over `CapturePresetAudioSaveMode` (off / alongside transcript / attachments folder); attachments-folder mode shows either a relative attachments folder field (unified destination) or legacy bookmark picker + clear + fallback field; when not off, "Embed Audio in Markdown" toggle (gated on availability: unified destination, MD format, template, or YAML+.md) with "Embed Position" picker; contextual footer and help text describe legacy vs unified behavior.
- Details:
  - "Save Audio" picker over `CapturePresetAudioSaveMode`; attachments-folder mode shows a relative Attachments Folder field when a unified destination exists, else a legacy audio bookmark picker + Clear + fallback relative field (FlowSettingsView.swift:725-775)
  - Selecting `alongsideTranscript` clears legacy audio bookmarks; "Embed Audio in Markdown" toggle disabled unless `markdownAudioEmbedAvailable`, revealing an "Embed Position" picker when on; contextual help footer (FlowSettingsView.swift:770-790)
- Constraints: Markdown audio embed requires a unified destination, MD format, a Markdown template, or YAML with .md extension
- Evidence: `Voxboard/Views/FlowSettingsView.swift` (lines 657-714, 716-731)
- Status: shipped

### F-IU-43 Preset icon picker
- Surface: Pushed from preset editor Identity row
- Summary: Searchable categorized SF Symbol grid (Writing/Voice/Tasks/Personal/Work, 10 icons each) with selected-icon preview card, selection highlight ring, keyword search across name+title, "No matching icons" empty state; choosing dismisses.
- Details:
  - `FlowIconPickerView` (FlowSettingsView.swift:1115-1348): `.searchable` grid over `iconCategories` (Writing/Voice/Tasks/Personal/Work); keyword filter matches names and titles, falls back to all categories for empty queries, and shows a "No matching icons" empty state
  - Selecting an option writes the preset's icon and dismisses; the current selection is highlighted in the grid and preview card
- Constraints: none beyond platform minimums
- Evidence: `Voxboard/Views/FlowSettingsView.swift` (lines 1135-1300)
- Status: shipped

### F-IU-44 Models screen
- Surface: Settings → Customization → Models (root destination)
- Summary: On-device model management: Native "Automatic" card (Apple Speech; availability label ready/supported/unavailable; Use Automatic button; auto-prepares when selected and caches `automaticBackendReadyKey`), Whisper model list, Parakeet model list (download/select/delete/cancel with progress phases preparing/finding files/verifying/cancelling/transferring and "Keep Vox.md open" hint; bundled badge), Voice Auto-Stop section, and Transcription Language picker.
- Details:
  - Model rows: name, "Bundled" badge, size, description; Select Model / Selected chip / trash delete; download cancel disabled while cancelling (ModelTabView.swift:172-265)
  - Model operation failures surface in an alert ("Model Operation Failed")
  - Parakeet selection replaces the language picker with an auto-detection note
- Constraints: none beyond platform minimums (model downloads require network/storage; the Apple Intelligence row is informational and iOS 26+ only)
- Evidence: `Voxboard/Views/ModelTabView.swift` (all)
- Status: shipped

### F-IU-45 Voice Auto-Stop configuration
- Surface: Models screen section
- Summary: Companion ~1 MB voice-activity model download/delete/cancel; "Enable Voice Auto-Stop" toggle (disabled until downloaded); per-capture-path toggles (Keyboard, In-App · Add to Draft, In-App · Send Immediately, Widgets & Quick Record, Live Activity, Apple Watch) with descriptions; "Pause Length" picker (0.5/0.75/1/1.5/2 s); footnote that every path works with all engines and timing is approximate; until downloaded, recordings use manual stop.
- Details:
  - Voice Pause Detection card: "Installed · Runs on device" vs "Optional companion model · About 1 MB"; download/cancel with progress + phase status text; trash delete when installed (ModelTabView.swift:347-433)
  - "Enable Voice Auto-Stop" toggle plus per-path toggles (Keyboard, In-App · Add to Draft, In-App · Send Immediately, Widgets & Quick Record, Live Activity, Apple Watch) each with a description; "Pause Length" menu picker (0.5-2 s); footer switches between configured copy and the "manual stop until downloaded" note (ModelTabView.swift:435-476)
- Constraints: enable toggle and path/duration controls disabled until the companion model is downloaded; recordings use manual stop until then
- Evidence: `Voxboard/Views/ModelTabView.swift` (lines 267-385); tests `VoiceAutoStopCoordinatorTests.swift`
- Status: shipped

### F-IU-46 Transcription language picker
- Surface: Models screen bottom
- Summary: Menu picker over `modelManager.availableLanguages` (menu style); when Automatic is selected, a hint explains System Language vs explicit selection. Hidden (replaced by auto-detection note) for Parakeet.
- Details:
  - Menu picker over `modelManager.availableLanguages`; an Automatic selection shows the System Language hint; a Parakeet selection replaces the picker with the automatic-language-detection note (ModelTabView.swift:538-578)
- Constraints: manual language selection unavailable with the Parakeet engine (auto-detection only); otherwise none beyond platform minimums
- Evidence: `Voxboard/Views/ModelTabView.swift` (lines 387-417)
- Status: shipped

### F-IU-47 History screen
- Surface: Sheet from Quick Capture ("Recent captures") and root `.history` destination
- Summary: Unified, reverse-chronological list of transcripts and capture delivery records with pull-to-refresh, search (matches transcript text via `TranscriptSearch` plus capture metadata haystack), empty and no-results states, a "Needs attention" section with "Retry N queued capture(s)" when the inbox has failures, and a destructive toolbar trash that clears all history after confirmation ("does not delete exported Markdown notes or attachments").
- Details:
  - Transcript rows: title, relative date ("just now"/"Nm/Nh ago"/short date), duration, Delivered/Delivery failed label, speaker count, diarization skip reason, cleaned/raw text preview (5 lines), tag chips (first 5)
  - Capture rows: outcome icon, destination name, relative delivered time, note path, source label (App/Keyboard/Widget/Shortcut/Share/Watch/Mac/Deep Link/File Import/Voice), preset name, attachment count, failure category
  - Actions per transcript: Copy menu (Copy cleaned / Copy raw), ellipsis menu and context menu with Edit / Export / Delete
  - Persistence errors surface in a "History Error" alert with clear-error handling
- Constraints: none beyond platform minimums
- Evidence: `Voxboard/Views/HistoryView.swift` (all)
- Status: shipped

### F-IU-48 Transcript edit sheet
- Surface: History → Edit
- Summary: Form editing Title, comma-separated Tags, Category, Cleaned text, and Raw transcript; Save applies via `transcript.withEdits` (empty strings become nil; empty tag list becomes nil).
- Details:
  - `TranscriptEditView` (HistoryView.swift:441-490): form fields Title, "Tags, comma separated" TextField, Category TextField, cleaned-text TextEditor (min 140 pt), raw transcript TextEditor (min 180 pt)
  - Save calls `transcript.withEdits`; empty strings and an empty tag list become nil
- Constraints: none beyond platform minimums
- Evidence: `Voxboard/Views/HistoryView.swift` (lines 385-430)
- Status: shipped

### F-IU-49 Transcript export/share
- Surface: History → Export
- Summary: Exports the transcript as a new Markdown file (`transcript-{date}-{id8}`) into a temp `VoxboardHistoryExports` folder via `TranscriptFileExporter` and opens a share sheet (`UIActivityViewController`); export failures surface in the History Error alert.
- Details:
  - `export` writes into `temporaryDirectory/VoxboardHistoryExports` via `TranscriptFileExporter.export(transcript, format: .md, mode: .newFile, newFileNameTemplateOverride: "transcript-{date}-{id8}")` and sets `sharePayload`, presented as a sheet (HistoryView.swift:102-108, 362-375)
  - Export failures surface via `exportError` in the History Error alert
- Constraints: none beyond platform minimums
- Evidence: `Voxboard/Views/HistoryView.swift` (lines 364-377)
- Status: shipped

### F-IU-50 Stats screen
- Surface: Settings → Activity → Stats
- Summary: Lifetime on-device activity overview: Overview cards (Recordings, Captures, Recorded duration, Attachments) with numeric content transitions; "Last 7 Days" stacked bar chart (recordings vs captures per weekday with legend, accessibility value "N recordings, N captures" per day); Capture Sources breakdown (icon, name, count across all 10 sources); pull-to-refresh; privacy footnote "No captured content, filenames, or destinations are stored with stats"; error card when shared activity storage is unavailable.
- Details: reconciles `ActivityStatsLedger` from TranscriptStore + CaptureHistoryStore; delivered captures only (StatsView.swift:224-263)
- Constraints: none beyond platform minimums; an error card is shown when shared activity storage is unavailable
- Evidence: `Voxboard/Views/StatsView.swift` (all)
- Status: shipped

### F-IU-51 Paywall (Vox.md Unlimited)
- Surface: Sheet from usage limits, Settings upgrade row, watch queue, usage meter
- Summary: Lifetime purchase screen with hero (status badge Free Tier / Limit Reached / Individual / Family Unlimited and contextual copy), Free Usage card (Transcription "x.x / 15 min" and Capture "N / 10" progress meters + remaining-status message), purchase section (Checking Purchases… state; free: Individual + Family offer cards with price/"one time"/FAMILY badge; individual: Upgrade to Family with EXISTING OWNER PRICE badge; family: unlocked confirmation), Included feature list (Unlimited Capture/Transcription, on-device, all models, Family Sharing, lifetime), Restore Purchases button with restoring state, StoreKit error banner, Close. Shown-context is tracked via `OnboardingAnalyticsPaywallContext` (limit, usageMeter, captureLimit, recording, settings, restore).
- Details: purchase buttons disabled while purchasing or product unavailable; `prepareForPurchases` on appear (PaywallView.swift)
- Constraints: StoreKit products/entitlement readiness
- Evidence: `Voxboard/Views/PaywallView.swift` (all)
- Status: shipped

### F-IU-52 Recording flow screen (keyboard-relay recording)
- Surface: `CapturePresetView` full recording UI driven by `CapturePresetController`
- Summary: Phase-based full-screen recording UI for keyboard-initiated app recordings: Starting…, Recording (large duration m:ss.t, "Return to Your App" swipe-back prompt telling the user recording continues and to tap Stop on the keyboard), Transcribing (percent + progress bar or animated dots, "Processing audio on-device"), Transcript Ready (result preview 5 lines), Error. Bottom action: destructive "Stop and Transcribe" while recording; Close X when done/error. Controller records via AudioRecorder, listens for the keyboard stop command via Darwin notification + 0.5 s poll timer, transcribes in a background task with monotonic progress publishing over IPC, saves to TranscriptStore, deletes audio on successful delivery, and writes IPC status/response for the keyboard extension.
- Details: error path writes error response over IPC and keeps phase .error (RecordingFlowView.swift:20-160); mic-unavailable and no-audio error messages
- Constraints: used for keyboard-relay flow; success feeds `ReviewPromptManager`
- Evidence: `Voxboard/Views/RecordingFlowView.swift` (all)
- Status: shipped

### F-IU-53 App Language settings
- Surface: Settings → App Language row (shows current selection/device language) and pushed screen
- Summary: Radio-style list: "Use System Language" (caption "Follows your device language") plus one row per supported `AppLanguage` in its native display name with a checkmark on the selection; footer "Language changes take effect the next time Vox.md is opened." Persisted via `AppLanguagePreference`.
- Details:
  - "Use System Language" row captioned "Follows your device language"; one row per `AppLanguage.allCases` (excluding `.system`) using `nativeDisplayName` with a checkmark on the current selection (AppLanguageSettingsView.swift)
  - Tapping persists via `AppLanguagePreference.set`; the Settings row shows the current selection label and pushes this screen (MetaSettingsView.swift `appLanguageRow`)
- Constraints: language change takes effect on the next app launch; otherwise none beyond platform minimums
- Evidence: `Voxboard/Views/AppLanguageSettingsView.swift` (all); `Voxboard/Views/MetaSettingsView.swift` (lines 238-268); tests `AppLanguagePreferenceTests.swift`
- Status: shipped

### F-IU-54 Voice note session (attach-audio flow, legacy composer voice)
- Surface: `QuickCaptureVoiceView` sheet driven by `QuickCaptureVoiceSession`
- Summary: Full voice-note attachment flow: auto-starts recording on present (12-bar live mic level meter with speech/quiet a11y, monospaced elapsed time, "Generate Transcript" toggle defaulting to backend readiness), Done → Saving ("Saving the recording to your durable draft…") → Transcribing (percent progress, "Transcribing entirely on this device…", "recording remains available even if transcription fails") → Review (transcript text selectable, Play/Pause with duration, Retry, Copy transcript, "Add to Note") or Error view with Try Again. Audio is staged to the durable draft before transcription; interactive dismissal disabled while recording/saving/transcribing; auto-adds on review unless the confirm-before-adding preference is on.
- Details (session): mic-busy and permission error paths; AAC 44.1 kHz mono 96 kbps recording; audio-session interruption and app-backgrounding finalize to review with explanatory messages; encoding-error handling; stale temp audio purged after 24 h; transcript-attach failure keeps audio staged with message; cancel removes staged audio (error if removal fails); review-prompt data
- Constraints: transcription toggle disabled without a backend (guidance caption); permission required
- Evidence: `Voxboard/Capture/QuickCaptureVoiceSession.swift` (all); `Voxboard/Capture/QuickCaptureVoiceViews.swift` (all)
- Status: shipped (session/view retained; primary capture path uses the inline recorder in F-IU-05/06)

### F-IU-55 Error banner & queued-capture retry
- Surface: Top banner on Quick Capture
- Summary: Red-bordered dismissible error banner (composer or recorder errors), VoiceOver-announced when messages change; when inbox captures failed, offers "Retry queued captures". A `captureInboxDecisionRequired` notification also triggers background inbox processing.
- Details:
  - Red-bordered banner (`red100` background, `red400` stroke) with warning icon, message, and a dismiss button clearing `viewModel.errorMessage` else `persistentRecorder.lastError` (QuickCaptureView.swift `errorBanner`)
  - "Retry queued captures" button appears only for viewModel errors when `failedInboxCount > 0`, calling `retryFailedInbox()`; the banner is suppressed during DEBUG localization-screenshot runs
- Constraints: none beyond platform minimums
- Evidence: `Voxboard/Views/QuickCaptureView.swift` (lines 195-211, 321-325, 359-362, 1466-1489)
- Status: shipped

### F-IU-56 File export toast
- Surface: Top toast on Quick Capture after recorder file export
- Summary: "Export Ready" toast with filename and "Open File" action opens the exported file in Files (falls back to opening its folder); auto-dismisses after 3.5 s; export failures replace the toast with a localized recorder error noting the transcript was saved locally.
- Details:
  - `FileExportToastView` button shows "Export Ready" + filename + "Open File"; tap calls `openExportedFileInFiles`, which security-scopes the URL, opens it via `UIApplication.open`, and falls back to opening its folder (QuickCaptureView.swift:2252-2266, 2355-2375)
  - Auto-dismisses after 3.5 s; export failures rewrite `persistentRecorder.lastError` to "Your transcript was saved locally, but file export failed. …"
- Constraints: none beyond platform minimums
- Evidence: `Voxboard/Views/QuickCaptureView.swift` (lines 212-229, 1761-1770, 2199-2230)
- Status: shipped

### F-IU-57 Quick Record widget / pending-launch consumption
- Surface: Background of Quick Capture (no dedicated UI)
- Summary: When the Lock Screen Quick Record control/widget launches the app (`pendingWidgetRecord`), the app resolves the requested preset (explicit or default via `WidgetRecordingFlowSelection`), selects it, and immediately starts a Send-Immediately one-shot recording with `.quickRecord` origin. Keyboard launches instead show the listening guidance banner.
- Details:
  - `consumePendingWidgetRecordIfNeeded` clears the flag, reads and removes `pendingWidgetRecordFlowIdKey`, resolves `WidgetRecordingFlowSelection`, selects an explicitly requested preset, forces `lastStartedRecordingMode = .preset`, clears `lastTranscriptionResult`, and starts `persistentRecorder.startOneShotInAppSegment(... completionMode: .runVox(flowID:), origin: .quickRecord)` (QuickCaptureView.swift:2199-2217)
  - Triggered by onChange of `pendingWidgetRecord` (QuickCaptureView.swift:333-336)
- Constraints: gated by `AppConstants.lockScreenQuickRecordEnabled`
- Evidence: `Voxboard/Views/QuickCaptureView.swift` (lines 348-357, 1787-1801); tests `WidgetRecordingFlowSelectionTests.swift`
- Status: gated (settings toggle)

### F-IU-58 Requested-input deep links (CaptureRequestedInput)
- Surface: Quick Capture presentation logic
- Summary: External requests (photos/screenshots/camera/files/scan/sketch/link/voice) auto-present the matching input surface when the app opens; voice requests switch recording mode to Add-to-Draft and start inline recording immediately.
- Details:
  - `presentRequestedInput` maps photos/screenshots/camera to their pickers, files to the document importer, scan to the VisionKit scanner only when `VNDocumentCameraViewController.isSupported`, sketch/link to their sheets, and voice to `.draft` recording mode plus `startInlineRecording()` (QuickCaptureView.swift:1761-1777)
  - Consumed both on initial load (`loadAndPresentRequestedInput`) and on `handleRequestedInputChange`; the requested input is cleared after presenting (QuickCaptureView.swift:1739-1760, 1609-1613)
- Constraints: scan deep link requires VisionKit document-camera support; camera deep link requires a camera; otherwise none beyond platform minimums
- Evidence: `Voxboard/Views/QuickCaptureView.swift` (lines 333-336, 1450-1500)
- Status: shipped

### F-IU-59 OCR progress & accessibility announcements
- Surface: Quick Capture OCR banner; VoiceOver across capture flows
- Summary: Broad accessibility support: error message announcements, "Capture sent", "Transcript added to Capture", "Extracting text on this device", "Extracted text added to Capture", journal page-count announcements, mic-level speech/quiet values, waveform accessibility-hidden, combined labels on status bars. OCR shows a dedicated progress banner row under the nav bar.
- Details:
  - OCR banner row under the nav bar: small ProgressView + "Extracting text on this device…", a11y id `capture_ocr_progress`, hidden during DEBUG localization screenshots (QuickCaptureView.swift:161-173)
  - Announcements posted via `UIAccessibility.post`: error messages, "Capture sent", "Transcript added to Capture"; the waveform view is marked accessibility-hidden
- Constraints: none beyond platform minimums
- Evidence: `Voxboard/Views/QuickCaptureView.swift` (lines 161-174, 326-329, 1502-1518, 1539-1655); `QuickCaptureVoiceViews.swift`; `MultimodalCaptureViews.swift`
- Status: shipped

### F-IU-60 Release-notes focus deferral
- Surface: Quick Capture composer focus
- Summary: When release notes are presented on launch, initial composer auto-focus is deferred (composer dismissed) until deferral ends; focus task id includes the deferral flag.
- Details:
  - Composer-focus task id `InitialComposerFocusTaskID` includes `defersCaptureInputFocusForReleaseNotes`; when deferral becomes true the composer is dismissed via `dismissComposer()` (QuickCaptureView.swift `draftLifecycleContent`)
  - `fulfillInitialComposerFocusIfReady` bails while the flag is set, so initial focus is only attempted after the release-notes sheet ends
- Constraints: active only when a release-notes sheet is presented at launch; otherwise none beyond platform minimums
- Evidence: `Voxboard/Views/QuickCaptureView.swift` (lines 274-298, 1401-1413); tests `ReleaseNotesPresentationTests.swift`
- Status: shipped

---

## Coverage checklist (every in-scope file read completely)

| File | Lines | Read |
|---|---|---|
| Voxboard/Views/RootView.swift | 102 | ✅ |
| Voxboard/Views/QuickCaptureView.swift | 2375 | ✅ (two passes) |
| Voxboard/Views/FlowSettingsView.swift | 1374 | ✅ (two passes) |
| Voxboard/Views/CaptureDestinationLibraryView.swift | 887 | ✅ |
| Voxboard/Views/MetaSettingsView.swift | 686 | ✅ |
| Voxboard/Views/ModelTabView.swift | 581 | ✅ |
| Voxboard/Views/HistoryView.swift | 521 | ✅ |
| Voxboard/Views/PaywallView.swift | 380 | ✅ |
| Voxboard/Views/RecordingFlowView.swift | 396 | ✅ |
| Voxboard/Views/StatsView.swift | 387 | ✅ |
| Voxboard/Views/WatchRecordingQueueView.swift | 258 | ✅ |
| Voxboard/Views/AppLanguageSettingsView.swift | 78 | ✅ |
| Voxboard/Capture/MultimodalCaptureViews.swift | 492 | ✅ |
| Voxboard/Capture/QuickCaptureVoiceSession.swift | 571 | ✅ |
| Voxboard/Capture/QuickCaptureVoiceViews.swift | 281 | ✅ |
| Voxboard/Capture/CaptureRoutePickerView.swift | 263 | ✅ |
| Voxboard/Capture/CaptureEditorToolbar.swift | 201 | ✅ |
| Voxboard/Capture/MarkdownComposerTextView.swift | 187 | ✅ |
| Voxboard/Capture/CaptureDueDateSheet.swift | 155 | ✅ |
| Voxboard/Capture/CaptureInternalLinkPicker.swift | 151 | ✅ |

Tests referenced as supplementary evidence: CaptureToolbarPreferencesTests, AppLanguagePreferenceTests, CaptureEntryLocationTokenSupportTests, CaptureLocationConfigurationSupportTests, VoiceAutoStopCoordinatorTests, WidgetRecordingFlowSelectionTests, ReleaseNotesPresentationTests, JournalImageOCRProcessorTests, RecordingCompletionModeTests, WatchRecordingInboxItemTests, KeyboardRecordingArtifactRetentionTests, QuickCaptureRecognizedTextTests (names only; not read in full).

## Uncertainties
- `CaptureToolbarSettingsView` (Capture Bar customization UI, F-IU-30) and `RecordingQueueView` (Settings → Recording Queue) live outside the in-scope directories; only their entry points and preference model interactions are inventoried.
- `QuickCaptureVoiceView`/`QuickCaptureVoiceSession` appear to be an attach-voice-note flow whose presenter was not found in the in-scope files; it may be invoked from code outside scope (possibly legacy or share-extension flows). Status labeled "shipped" for the components themselves; primary in-app voice capture is the inline recorder.
- Exact contents of `CaptureToolbarAction` ordering/defaults live in shared code (`VoxboardShared`), not read here; only the command dispatch and visible-actions mechanism were verified.
- `AppLanguage` supported-language list not enumerated (defined in shared code).
- Which surfaces present `QuickCaptureVoiceView` (e.g., a voice-attachment entry point removed from the current toolbar) could not be confirmed from the in-scope files.
