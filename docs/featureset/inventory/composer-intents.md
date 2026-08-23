# Composer & Intents Inventory — Voxboard App Shared layer

LID prefix: **CP**. Scope: `Voxboard App Shared/` (shared layer compiled into iOS and Mac apps). All findings verified directly in source; tests cited as supplementary evidence.

---

### F-CP-01 Durable Quick Capture draft (composer state machine)
- Surface: Quick Capture composer (iOS app, Mac app), all capture entry points (deep links, intents, share, keyboard, widgets, watch, watch file import)
- Summary: `QuickCaptureViewModel` is a `@MainActor @Observable` view model that owns the single observable `CaptureDraft`, the preset ("Vox"/Capture Preset) profile list, destinations, entry templates, history, and inbox state. It is the durable composer: every mutation is persisted to a shared-container-backed `CaptureDraftStore` under the capture root so a cold launch or crash recovers the in-progress draft.
- Details:
  - Init wires `CaptureLibraryStore`, `CaptureDraftStore`, `CaptureHistoryStore` from `AppConstants.captureDirectoryURL` (App Group container); if nil, all stores are nil and any operation surfaces "Shared capture storage is unavailable" (`QuickCaptureViewModelError.storageUnavailable`).
  - `load()` is idempotent and serialized via `initialLoadTask`; `performInitialLoad()` is the *only* destructive restore of the observable draft, guaranteeing a deep link cannot race the view task's disk load.
  - On load: restores first saved draft or creates a fresh one (`voxID` = selected preset, `destinationSelectionMode = .inherited`); resets `voxID` if the preset is missing/disabled; demotes an explicit destination to inherited if the preset route matches or the destination no longer exists; clears a stale `entryTemplateID`; applies `pendingCaptureSource`/`pendingVoxID` queued before load finished; immediately persists the restored draft and preserves `captureStart` timestamp; loads history records.
  - `scheduleDraftSave()` debounces saves 250 ms (cancels prior task); `saveDraftNow()` and `persistDurableDraft()` flush on demand; `flushDraftForTermination()` returns success/failure so macOS quit can be cancelled rather than silently losing final edits.
  - `saveDurableDraft` strips volatile Speech preview text before persisting (crash cannot persist tentative recognition words), sets `updatedAt`, and calls `draft.beginCaptureIfNeeded(at:)` so capture-start timestamps begin at first durable content.
  - `clearDraft()` completes the draft record, resets to a fresh draft seeded with the selected preset, saves it, and clears live transcript preview state.
  - Route overrides: `selectDestination` (explicit), `setPlacementOverride` (Top/Bottom/Heading), `setOneOffNote(url:)` (existing `.md` note inside the destination folder only — rejects non-Markdown, rejects notes outside destination root, uses security-scoped access), `clearRouteOverrides()`, `useVoxRouteDefaults()`, `hasAnyRouteOverride`, `hasExplicitDestinationOverride`.
  - `resolvedDestinationPreview` shows "VaultName / relative/path" using `CapturePathPlanner` with the one-off note override applied.
  - `effectivePlacementLabel` localizes Top/Bottom/Heading/Default from draft override → preset override → destination placement.
  - `saveSelectedPresetDestination(_:)` writes the preset's owned reusable destination into the library, retires the previous owned route, and clears the preset's entry template/placement overrides.
  - `requestCaptureSource(_:)` / `requestVox(_:)` queue pre-load requests as `pendingCaptureSource`/`pendingVoxID`.
  - `refreshLibrary()`, `refreshHistory()`, `clearHistory()`, `deleteHistory(requestID:)` manage the capture history store.
  - Error taxonomy: `QuickCaptureViewModelError` (storageUnavailable, staleDestination, unknownDestination, unknownVox, inboxRequestUnavailable, noteMustBeMarkdown, noteOutsideDestination, textTooLarge 100k-char limit, assetsTooLarge 250 MB total limit) — all localized.
  - `resolveRootURL(for:)` resolves destination security-scoped bookmarks and throws a friendly "Files permission expired" error for stale bookmarks.
- Constraints: Requires App Group / shared container (`AppConstants.captureDirectoryURL`); without it the composer degrades to read-only with an error. Text capped at `CaptureInputLimits.maximumTextCharacters` (100,000); attachments capped by `CaptureInputBudget` (250 MB total).
- Evidence: `Voxboard App Shared/CaptureComposerViewModel.swift` — `QuickCaptureViewModel` (lines ~8–70), `performInitialLoad` (~178–235), `scheduleDraftSave`/`saveDraftNow`/`flushDraftForTermination` (~417–445), `saveDurableDraft` (~452–468), `clearDraft` (~255–268), `QuickCaptureViewModelError` (~1800–1826).
- Status: shipped

### F-CP-02 Preset ("Vox") selection and destination routing resolution
- Surface: Composer preset picker, deep links, App Intents preset parameter
- Summary: Resolves which Capture Preset delivers the capture and which destination receives it, honoring legacy pre-owned-route fallbacks and one-off overrides.
- Details:
  - `selectedVoxProfile`: draft `voxID` → stored selected profile → first enabled profile.
  - `effectiveDestinationID` uses `CapturePresetRouteResolver.destinationID` with selection mode (explicit vs inherited), the preset's owned `captureDestinationID`, library default destination, and `allowsLegacyFallback` gated on `hasOwnedRouteMigration` (one-time ownership migration flag in shared defaults).
  - `selectVox(_:)` guards enabled membership, persists selection as app default via `CapturePresetProfileStore.selectCaptureProfile`, schedules save.
  - `refreshVoxProfiles()` reloads enabled profiles and resets `draft.voxID` to the app default when the current one is gone/disabled.
  - `useVoxRouteDefaults()` returns the draft to full preset inheritance.
- Constraints: Legacy destination fallback only before the owned-route migration has run.
- Evidence: `CaptureComposerViewModel.swift` ~71–115, ~269–290; `VoxboardTests/RecordingCompletionModeTests.swift` (preset snapshot immutability tests).
- Status: shipped

### F-CP-03 Live (in-progress) transcript preview in the composer
- Surface: Composer text field during on-device voice recording (Apple Speech)
- Summary: Real-time recognized speech is rendered into the draft text as a *volatile* preview that is never persisted until Speech finalizes, with session-ID invalidation to reject stale callbacks.
- Details:
  - `updateLiveRecordedTranscript(sessionID:finalizedText:volatileText:)` guards against invalidated session IDs and against callbacks from a different active session, calls `load()` (revalidating after suspension because the recorder may have stopped), renders via `LiveTranscriptDraftPreview.render`, and enforces the 100k-char limit (error: `textTooLarge`).
  - Volatile text stays memory-only; durable draft saves strip it via `preview.cancel(in:)`.
  - `invalidateLiveRecordedTranscriptSession(_:)` permanently blacklists a session ID.
  - `cancelLiveRecordedTranscript(sessionID:)` restores pre-preview text and saves.
  - `hasLiveRecordedTranscriptPreview` exposes state; `submit()` refuses to send while a preview is active ("Finish the current recording before sending this Capture.").
- Constraints: None beyond shared storage.
- Evidence: `CaptureComposerViewModel.swift` ~470–520; `VoxboardTests/QuickCaptureRecognizedTextTests.swift::test_cancelledLiveTranscriptSessionRejectsStaleCallbacksWithoutClearingNewSession`; `VoxboardTests/RecordingDraftDeliveryTests.swift::testOlderJobCannotCommitOverNewerLivePreview`.
- Status: shipped

### F-CP-04 Committed transcript delivery into the draft (idempotent, metered)
- Surface: Recording completion (voice, watch, keyboard, clipboard), queued-recording playback
- Summary: Finalized transcripts append to the durable draft text with delivery-ID idempotency so a relaunched or retried delivery cannot duplicate text, and are marked as metered so sending does not consume a second capture allowance.
- Details:
  - `appendRecordedTranscript(_:sessionID:deliveryID:)`:
    - Returns true (no-op) if `deliveryID` already in `draft.appliedRecordingTranscriptIDs` — duplicate suppression after relaunch.
    - Refuses when another live recording session is active ("Another recording is still updating this Capture…").
    - Trims/normalizes; ignores empty; commits preview if present (else appends with `\n\n` separator when text non-empty).
    - Enforces 100k-char limit.
    - Sets `draft.deliveryKind = .meteredVoiceTranscript` (transcription seconds already consumed the Capture allowance).
    - Records `appliedRecordingTranscriptIDs`, calls `beginCaptureIfNeeded`, persists durably; on save failure rolls back draft/preview/session and surfaces the error.
- Constraints: Requires draft store.
- Evidence: `CaptureComposerViewModel.swift` ~650–715; `VoxboardTests/RecordingDraftDeliveryTests.swift::testTranscriptDeliveryReceiptSuppressesDuplicateAfterRelaunch`.
- Status: shipped

### F-CP-05 Recorded-origin journaling for imported/external recordings
- Surface: Watch recordings, file imports, external recorders feeding the composer
- Summary: Before audio conversion/transcription begins, the draft journals the recording's capture source, origin-time location outcome, and an immutable preset policy snapshot so later preset edits cannot retroactively change the capture's origin semantics.
- Details:
  - `journalRecordedOrigin(source:outcome:profileSnapshot:)`: loads, requires `draft.voxID == profileSnapshot.id`, journals via `draftStore.journalLocation(...)`, and re-checks draft ID/requestID/voxID after the actor suspension — if the debounced preset selection changed, re-saves the newer in-memory draft so a stale import snapshot cannot win on disk.
  - `clearRecordedOrigin(profileID:)`: clears the journal when the import is cancelled/replaced, same anti-stale-write guard.
  - On submit, `submittedDraft.voxProfileSnapshot ?? selectedVoxProfile` — a journaled snapshot owns delivery, never combined with later preset edits.
- Constraints: Preset snapshot identity must match the active draft preset.
- Evidence: `CaptureComposerViewModel.swift` ~522–648; `VoxboardTests/RecordingCompletionModeTests.swift::testPresetSnapshotRemainsImmutableWhenLivePresetChanges`, `testSegmentHandoffSnapshotPreservesDraftSessionAndPresetIdentity`.
- Status: shipped

### F-CP-06 Staged attachments (images, files, audio, scans, sketches, URLs)
- Surface: Composer attachment pickers, share sheet, drag-and-drop, recording completion, OCR, scanning, sketch
- Summary: All binary content is staged into a per-draft staging directory (`<captureRoot>/staging/<draft-id>/`) by `CaptureAssetStager` and appended to `draft.additionalPayloads` with rollback that removes staged bytes on failure.
- Details:
  - `stageImage(data:filename:contentTypeIdentifier:altText:)` — staged image with optional alt text.
  - `stageFile(at:filename:contentTypeIdentifier:embedAsImage:embedAsAudio:)` — security-scoped copy; type decides payload kind (image / audio / generic file).
  - `stageVoiceRecording(at:transcript:)` — `Recording-<timestamp>.m4a`, `public.mpeg-4-audio`, cancellation-aware (removes staged asset on `CancellationError`).
  - `updateStagedVoiceRecording(_:transcript:)` — rewrites the transcript attached to a staged audio payload with rollback.
  - `removeStagedVoiceRecording(_:)` — removes matching audio payload.
  - `stageRecordedAudio(at:deliveryID:)` — idempotent via `draft.stagedRecordingAudioReceipts[deliveryID]`; if the receipt exists and the staged file still exists, returns the existing asset; otherwise stages `Recording-<deliveryID>.<ext>`, removes the stale receipt/asset, and records a new receipt. Rolled back (asset removed, draft restored) on failure.
  - `stageScan(pageImages:pdfData:extractedText:)` — stages `scan-page-N.jpg` pages, optional `scan.pdf`, appends a `.scannedDocument` payload with extracted text; removes all newly staged assets on failure.
  - `stageSketch(drawingData:previewData:altText:...)` — stages `sketch.drawing` (PencilKit) + `sketch.png` preview into a `.sketch` payload; rollback removes both.
  - `addURL(_:title:)` — accepts only http/https schemes, else error "Enter a complete http:// or https:// link.".
  - `removePayload(at:)` — awaits any pending save first, persists the *removal* before deleting bytes (so a failed delete still leaves a valid durable draft), restores the payload on save failure, surfaces (non-fatal) cleanup failure.
  - `appendStagedPayload` enforces the `CaptureInputBudget` (250 MB total attachments) *before* mutating, removes staged bytes on budget failure, and rolls back the payload + audio receipt on durable-save failure.
  - `attachmentsFitInputBudget` reserves each asset's `byteCount`.
- Constraints: 250 MB total attachment budget; 100k-char text limit; shared storage required.
- Evidence: `CaptureComposerViewModel.swift` ~716–960 (`stageRecordedAudio`, `stageImage`, `stageFile`, `stageVoiceRecording`, `updateStagedVoiceRecording`, `stageScan`, `stageSketch`, `addURL`, `removePayload`, `appendStagedPayload`, `attachmentsFitInputBudget`, `stagingDirectoryURL` ~1555); `VoxboardTests/RecordingDraftDeliveryTests.swift` (audio delivery receipt tests, missing-receipt-asset replacement).
- Status: shipped

### F-CP-07 OCR "Extract Text" append to draft
- Surface: Composer "Extract Text" quick action (journal-image OCR)
- Summary: Recognized image text is formatted to Markdown (`CaptureOCRMarkdownFormatter`) and appended to the draft text, persisted durably without adding attachments.
- Details:
  - `appendRecognizedText(_:)` refuses while a live transcript preview is active ("Finish the current recording before extracting text from images.").
  - Normalizes, ignores empty, appends with `\n\n` separator, enforces 100k limit.
  - Save failure: rolls back only if nothing newer replaced the candidate; otherwise preserves and reschedules a save (concurrent typing wins).
- Constraints: 100,000-character shared text limit enforced; refused while a live transcript preview is active.
- Evidence: `CaptureComposerViewModel.swift` ~760–800; `VoxboardTests/QuickCaptureRecognizedTextTests.swift::test_appendRecognizedTextPersistsEditableMarkdownWithoutAttachments`.
- Status: shipped

### F-CP-08 Send/submit pipeline with prepared-request reuse and rebasing
- Surface: Composer Send button
- Summary: `submit()` performs guarded validation, resolves location per preset policy, journals the outcome, then delivers through `CaptureDraftStore.submit` + `AppCapturePipeline` with reuse of a prepared (preset-processed) request and post-send rebasing of concurrent edits.
- Details:
  - Guards: no live transcript preview; text ≤ 100k; attachments within budget; storage available; `canSubmit` (not submitting, destination resolved, draft has content).
  - Cancels/awaits the pending debounced save; sets `submittedAt`, `beginCaptureIfNeeded`, persists the draft; loads `loadPreparedRequest` and reuses it via `CapturePreparedRequestReuse.matches` (idempotent preset post-processing).
  - Location phase (only if preset `locationPolicy.isEnabled` and no reusable prepared request): uses an explicit "send without location" outcome if pending; else the durable journaled `locationOutcome` (suspended/relaunched Send reuses the exact origin result); else resolves fresh via `locationProvider.resolveLocation` (`isResolvingLocation` flag). Journals outcome + decision override (`journalLocation`) *before* any decision UI or async processing, merging concurrent draft edits.
  - On `.unavailable` outcome without a send-without override, `unavailableBehavior` routes: `.ask` → present `locationDecision` and stop; `.cancel` → silently stop; `.sendWithoutLocation` → continue.
  - Delivery closure: reloads library, resolves destination (one-off template ID → preset template ID → destination template), applies placement override (draft → preset), applies validated one-off note path (must be `.md`), builds the request (or reuses prepared), persists the prepared request, resolves the destination root via security-scoped bookmark, and calls `pipeline.capture(request:destination:rootURL:assetRootURL:)` with the draft staging dir as asset root.
  - Success: sets `lastReceipt`, clears `needsCaptureUnlock`, removes prepared request, records a delivered `CaptureHistoryRecord` (destination name, relative note path, attachment count), reloads the concurrently edited draft and *rebases* it after the submitted snapshot — if the rebased draft still has content it becomes the new draft; else the draft is completed and reset (seeded with the just-used preset).
  - Quota failure (`CaptureDeliveryQuotaError.limitReached`): sets `needsCaptureUnlock = true` with no error string (paywall/unlock surface).
  - Other failures: record a failed history record with a failure category (`historyFailureCategory`: CaptureDraftError→invalidRequest, template error→destinationUnavailable, attachment error→attachment, model/pipeline→invalidRequest, view-model error→destinationUnavailable, default→fileWrite) and surface `errorMessage`.
- Constraints: Purchase/quota gate surfaces through `CaptureDeliveryQuotaError.limitReached` → `needsCaptureUnlock`.
- Evidence: `CaptureComposerViewModel.swift` `submit()` ~961–1180, `historyFailureCategory` ~1600, `historyRelativeNotePath` ~1585.
- Status: shipped

### F-CP-09 Location-unavailable decision flow (ask / cancel / send-without / always-for-preset)
- Surface: Composer alert when origin-time location is required but unavailable
- Summary: When a preset requires location and resolution fails, the composer offers retry, send-without-location (optionally persisting that choice for the preset), or cancel — all journaled so the exact invocation survives relaunch.
- Details:
  - `locationDecision: CaptureLocationDecision` (reason, attemptedAt, presetID) keeps the draft intact while the UI asks.
  - `retryUnavailableLocation()` clears journal + pending outcome and re-submits (fresh location resolution).
  - `sendWithoutUnavailableLocation(alwaysForPreset:)` journals an explicit `.sendWithoutLocation` decision override and the *original* unavailable outcome (never re-acquires), optionally persists `setLocationUnavailableBehavior(.sendWithoutLocation)` for the preset, then submits.
  - `cancelUnavailableLocation()` clears the location journal.
  - `pendingSendWithoutLocationOutcome` bridging ensures the submit pass consumes the exact decision without re-resolving.
- Constraints: requires the preset's location policy to be enabled with `.ask` unavailable behavior; OS location permission is a gate, never an opt-in.
- Evidence: `CaptureComposerViewModel.swift` ~1181–1330 (`retryUnavailableLocation`, `sendWithoutUnavailableLocation`, `cancelUnavailableLocation`, `CaptureLocationDecision` struct ~1775).
- Status: shipped

### F-CP-10 Shared capture inbox drain and inbox location decisions
- Surface: App foreground (pending inbox processing), deep link `processInboxRequest`
- Summary: External captures (intents, share extension, watch, widgets) enqueue into a durable `CaptureInbox`; the composer drains it, handles quota blocks, location decisions, orphan rerouting, retries, and discard.
- Details:
  - `processPendingInbox()`: `CaptureInboxDeliveryService.drain` processes queue; sets `needsCaptureUnlock` on quota-blocked requests; surfaces the first required location decision as `inboxLocationDecision`; updates `failedInboxCount`; surfaces a queued-for-retry error with latest failure detail.
  - `sendInboxRequestWithoutLocation(alwaysForPreset:)`: marks the request send-without-location (exact persisted invocation, never re-acquires), optionally persists preset behavior, reprocesses, posts `.captureInboxDecisionResolved` (discarded: false), re-drains.
  - `discardInboxLocationRequest()`: discards the request, posts notification (discarded: true), re-drains.
  - `retryFailedInbox()`: reroutes orphaned failed requests to a valid destination (library default → first destination) and retries all failed.
  - `processInboxRequest(id:)` (deep link): recovers orphans, claims the request; tolerates races with the app-wide drain (`.completed`/`.processing` → no-op); retries then re-claims failed requests; processes claimed requests through the pipeline; on quota error returns to pending and sets `needsCaptureUnlock`; on `CapturePipelineError.locationDecisionRequired` preserves the exact processed request in pending and raises `inboxLocationDecision`; on other failures records failed history and fails the request.
- Constraints: shared App Group capture storage required; free-tier Capture quota can hold requests pending unlock; background drain availability is iOS-scheduled (BGProcessingTask).
- Evidence: `CaptureComposerViewModel.swift` ~1400–1765 (`processPendingInbox`, `sendInboxRequestWithoutLocation`, `discardInboxLocationRequest`, `retryFailedInbox`, `recoverOrphanedInboxRequests`, `processInboxRequest`, `processClaimedInboxRequest`, `CaptureInboxLocationDecision` ~1765).
- Status: shipped

### F-CP-11 Deep-link composer intake
- Surface: Custom URL scheme / system deep links (`CaptureDeepLinkAction`)
- Summary: `handleDeepLink(_:)` opens the composer with source/preset/destination/text/URL/requested-input, or processes an inbox request by ID.
- Details:
  - `.openComposer`: sets `captureSource` (incoming or `.deepLink`); validates and selects a preset (persisting it as app default), else `unknownVox`; validates destination, else `unknownDestination`; appends incoming text with `\n\n` separator; appends incoming URL payload; sets `requestedInput`; persists durably.
  - `.processInboxRequest(requestID)`: routes to F-CP-10.
  - Quota errors map to `needsCaptureUnlock`.
- Constraints: deep-link input validation and shared limits enforced by `CaptureDeepLinkParser` (bounded text, HTTP(S) URLs only, safe preset identifiers, unknown/duplicate parameters rejected).
- Evidence: `CaptureComposerViewModel.swift` `handleDeepLink` ~1331–1375.
- Status: shipped

### F-CP-12 Capture history log
- Surface: Composer history UI (via view model API)
- Summary: Every delivered or failed capture is upserted into `CaptureHistoryStore` with destination, preset, relative note path, attachment count, outcome, and a failure category; users can list, delete per-request, or clear all.
- Details:
  - `recordHistory(...)` builds `CaptureHistoryRecord` and uses `upsertBestEffort` (never fails delivery).
  - Relative note paths computed against the destination root; deleted/unavailable destinations fall back to "Deleted destination" / "Unavailable destination" names or the note filename.
  - `refreshHistory`, `clearHistory`, `deleteHistory(requestID:)` exposed; history list is refreshed in-memory after each record.
- Constraints: history writes are best-effort and never fail a delivery; records carry coarse delivery metadata only (no note text, URLs, coordinates, or attachment filenames).
- Evidence: `CaptureComposerViewModel.swift` ~1586–1620; `performInitialLoad` history load ~220.
- Status: shipped

### F-CP-13 Capture bar / toolbar customization
- Surface: iOS Settings → "Capture Bar" (`CaptureToolbarSettingsView`, iOS only), capture bar quick actions in composer
- Summary: Users reorder, show/hide 17 quick actions in the capture bar via a persisted Codable configuration in UserDefaults, plus a voice-note review toggle and reset.
- Details:
  - `CaptureToolbarAction` cases: addMedia, addFiles, scanDocument, extractText, undo, formatMarkdown, markdownLink, dueDate, checklist, bulletList, paste, internalLink, sketch, currentLocation, timestamp, date, textCase — each with localized title, accessibility label, SF Symbol (internalLink uses `[[` text icon; textCase uses `Abc`).
  - `CaptureToolbarPreferences` stores `StoredConfiguration {order, hidden}` JSON under key `capture.toolbar.configuration.v1`; persists on every change.
  - Migration: `migratedActionOrder` deduplicates stored order and appends missing cases; newly introduced `.extractText` inserts right after `.scanDocument` for existing custom bars so OCR stays discoverable.
  - `visibleActions`, `isVisible`, `setVisible`, `moveActions(from:to:)`, `reset()`.
  - Voice Notes section: "Review Before Adding" toggle (key `capture.voice.confirmBeforeAdding.v1`, default off); footer explains off = auto-add recording + on-device transcript after Done, on = play/retry/copy/review first. Accessibility identifier `capture_voice_review_before_adding`.
  - Settings list uses persistent edit mode for drag-reorder; destructive "Reset Quick Actions".
  - `nonisolated deinit {}` avoids actor-isolated synthesized destructor.
- Constraints: `CaptureToolbarSettingsView` is `#if os(iOS)`; the preferences model is shared.
- Evidence: `Voxboard App Shared/CaptureToolbarPreferences.swift` (whole file); `VoxboardTests/CaptureToolbarPreferencesTests.swift::test_newExtractTextActionFollowsDocumentScanByDefault`, `test_migrationPreservesCustomOrderAndInsertsExtractTextAfterScan`.
- Status: shipped

### F-CP-14 Empty-composer inspiration quotes (ZenQuotes)
- Surface: Empty Quick Capture composer prompt
- Summary: `InspirationQuoteService` rotates through a locally cached batch of quotes fetched from zenquotes.io, refreshing every 2 hours, with a built-in fallback quote offline.
- Details:
  - Actor-isolated; `nextQuote()` loads cache (memory → UserDefaults key `inspiration-quotes.zenquotes.v1`), refreshes when cache is nil, future-dated, or ≥ 2 h old; on fetch failure keeps serving the older batch.
  - Fetch: `GET https://zenquotes.io/api/quotes`, `Accept: application/json`, 10 s timeout, `reloadIgnoringLocalCacheData`; requires 2xx; filters quotes to non-empty text ≤ 280 chars with non-empty author; throws if none usable.
  - Rotates `nextIndex` modulo batch size; persists cache after each read.
  - Fallback: localized "Do what you can, with what you have, where you are." — Theodore Roosevelt.
  - Privacy: quotes fetched over network and cached in standard UserDefaults; no other data leaves the device.
- Constraints: Network-dependent; degrades to fallback/cached quotes offline.
- Evidence: `Voxboard App Shared/InspirationQuoteService.swift` (whole file).
- Status: shipped

### F-CP-15 App Intents — entities and queries
- Surface: Shortcuts / App Intents (iOS 17+, macOS 14+)
- Summary: Two App Entities expose Capture Destinations and Capture Presets ("Vox") to Shortcuts parameter pickers, with enumerable queries filtered by enabled/active state.
- Details:
  - `CaptureDestinationEntity` (id = lowercase UUID string, name, folder icon); `CaptureDestinationEntityQuery`: `entities(for:)` resolves including retired destinations; `suggestedEntities`/`allEntities` show only destinations bound to an active preset route (`CapturePresetStore.loadFlows().captureDestinationID`).
  - `CaptureVoxEntity` (id, displayName, symbolName); `CaptureVoxEntityQuery`: enabled profiles only; `defaultResult()` = selected app default profile or first.
- Constraints: `@available(iOS 17.0, macOS 14.0, *)`.
- Evidence: `Voxboard App Shared/CaptureAppIntents.swift` ~11–91.
- Status: shipped

### F-CP-16 App Intents — Capture Text / Link / File (background enqueue)
- Surface: Shortcuts automation & manual runs
- Summary: Three delivery intents enqueue captures into the shared inbox without opening the composer UI (though `openAppWhenRun = true` launches the app), staging file bytes into `inbox-staging/<requestID>/` and honoring preset routing, post-processing state, and origin-time location policy.
- Details:
  - `CaptureTextIntent` "Capture Text to Markdown": `Text` param (≤ 100k chars, else `CaptureIntentError.textTooLarge`), optional `Preset`, optional `Legacy Destination Override` (explicitly labeled retained for existing shortcuts).
  - `CaptureURLIntent` "Capture Link to Markdown": `URL` param, must be http/https else `invalidURL`.
  - `CaptureFileIntent` "Capture File to Markdown": `IntentFile` param; stages bytes; classifies as image / audio / file by UTType conformance; cleans up the staging directory on failure unless the failure was `locationDecisionRequiresApp` (bytes then owned by the durable request).
  - Shared `CaptureIntentSupport.enqueue`: resolves profile after library load (post-migration); resolves destination ID via `CapturePresetRouteResolver` with legacy `legacyFlowBindings` fallback pre-migration; sets `voxProcessingState` (.pending if preset post-processing enabled and mode ≠ none; .notRequested if no profile; else .applied); if preset location policy enabled, resolves location *if authorized* (`resolveLocationIfAuthorized` — never prompts): unavailable + `.cancel` → throws `locationUnavailableCancelled`; `.ask` → enqueues the exact invocation then throws `locationDecisionRequiresApp` (app must never re-acquire); `.sendWithoutLocation` → proceed; builds `CaptureRequest(source: .shortcut, ...)` and enqueues into `CaptureInbox`.
  - Errors (`CaptureIntentError`): storageUnavailable, destinationRequired ("Configure a destination for a Capture Preset…"), invalidURL, textTooLarge, locationDecisionRequiresApp ("Open Vox.md to send this exact Capture without location or discard it"), locationUnavailableCancelled.
  - All three intents have convenience inits for programmatic invocation.
- Constraints: iOS 17 / macOS 14; requires shared container; no location prompt from background intents (only pre-authorized resolution).
- Evidence: `CaptureAppIntents.swift` ~93–270 (`CaptureTextIntent`, `CaptureURLIntent`, `CaptureFileIntent`, `CaptureIntentSupport.enqueue` ~196–270, file staging ~272–315, `selectedDestinationID` ~317–345, `resolvedProfile` ~347–354).
- Status: shipped

### F-CP-17 App Intents — composer-opening intents
- Surface: Shortcuts, Siri, Mac App Shortcuts
- Summary: Four intents open the durable composer, optionally requesting a specific input mode (voice, screenshots, scan) and selecting a preset.
- Details:
  - `OpenQuickCaptureIntent` "Open Quick Capture" — optional `Preset`; requests composer with no specific input.
  - `OpenCaptureVoiceIntent` "Record a Capture" — `requestedInput = .voice`, "entirely on device".
  - `OpenCaptureScreenshotIntent` "Capture a Screenshot" — `requestedInput = .screenshots`.
  - `OpenCaptureScanIntent` "Capture a Scan" — `requestedInput = .scan`.
  - `CaptureIntentSupport.requestComposer` writes shared-defaults flags: `pendingQuickCaptureOpenKey=true`, `pendingQuickCaptureSourceKey=.shortcut`, `pendingQuickCaptureInputKey` (set/cleared), selects the resolved preset as app default and stores `pendingQuickCaptureVoxIdKey` (or clears).
  - All `openAppWhenRun = true`, `@MainActor` perform.
- Constraints: iOS 17 / macOS 14.
- Evidence: `CaptureAppIntents.swift` ~168–218.
- Status: shipped

### F-CP-18 Mac App Shortcuts provider
- Surface: macOS Shortcuts app / Siri App Shortcuts (zero-setup phrases)
- Summary: `VoxboardMacShortcutsProvider` (`#if os(macOS)`) registers six zero-setup App Shortcuts.
- Details:
  - "Quick Capture" (`square.and.pencil`): phrases "Quick capture with \(.applicationName)", "Open capture in \(.applicationName)".
  - "Capture Voice" (`waveform`): "Record a capture with …", "Record \(\.$vox) with …" (parameterized phrase referencing the Preset parameter).
  - "Capture Screenshot" (`rectangle.inset.filled.and.person.filled`): two phrases.
  - "Capture Text" (`text.badge.plus`), "Capture Link" (`link.badge.plus`), "Capture File" (`doc.badge.plus`): two phrases each.
  - Note: no Scan shortcut phrase set on Mac despite `OpenCaptureScanIntent` existing (scan intent remains available in the Shortcuts editor, just not a zero-setup phrase).
- Constraints: `@available(macOS 14.0, *)`; macOS only.
- Evidence: `Voxboard App Shared/VoxboardMacShortcutsProvider.swift` (whole file, 63 lines).
- Status: shipped

### F-CP-19 Recording Queue views (queue UI + queue preferences)
- Surface: "Recording Queue" screen (iOS & Mac), Recording Queue settings disclosure
- Summary: `RecordingQueueView` lists durable pre-transcription recording jobs with per-job actions (process now, retry, choose preset for recovered jobs, copy transcript, share/reveal audio, per-job retention, delete), plus a "Queue Settings" disclosure for processing policy and original-audio retention.
- Details:
  - Queue Settings (`RecordingQueuePreferencesView`):
    - "After Recording" processing policy: Immediately / When Idle / Manually (`.immediate` / `.whenIdle` / `.manual`); localized detail strings differ per platform (iOS notes background execution not guaranteed).
    - "Original Audio" retention: After Processing (`.deleteAfterSuccess`) / For a Period (`.timed`, stepper 1–365 days) / Permanently (`.permanent`); footer: "Failed recordings stay here until you retry or delete them."
    - Saves via `RecordingQueuePreferences.save(RecordingQueueConfiguration(...))` on every change.
  - Queue list: `queue.actionableJobs` cards with title by delivery kind (preset name / "Capture Draft Recording" / "Clipboard Transcription" / "Keyboard Transcription" / "Recovered Recording"), phase status (Queued / Transcribing / Saving / Completed / "Needs attention" / Discarded) with symbol + color, created date, duration `m:ss`, status message (failed in error color), and live transcription `ProgressView` when it is the active job.
  - Toolbar "Retry All" (when eligible jobs exist); pull-to-refresh and on-appear `queue.refresh(recoverInterrupted: true)`; `queue.monitorDurableChanges()` task.
  - Per-job primary action by phase: queued → "Process Now"; failed+recovery → "Choose Preset" menu (enabled `recoveryPresets`, or "No enabled Capture Presets"); failed → "Retry Recording"; completed+transcript → none. Retry routes through injectable `RecordingQueueRetryCoordinator` (`retryOverride` for tests/app wiring).
  - "Copy Transcript" when transcript exists (pasteboard on both platforms; acknowledges via `queue.acknowledgeCopiedResult`); audio action: macOS "Reveal Audio" (Finder) vs iOS "Share Audio" (`ShareLink`); "Keep Audio" per-job retention menu (delete after / timed using configured interval / permanent); destructive "Delete Recording" hidden while processing/finalizing.
  - Empty state: "No Recordings Yet" card explaining staging and interrupted-recording recovery.
  - Accessibility: dynamic-type adaptations (single-column grid at accessibility sizes, inline vs stacked title/status), labeled menus/steppers, hidden decorative symbols; navigation title adapts at accessibility sizes on iOS.
  - Error alert "Recording Queue Error" bound to `queue.lastError`.
  - Hidden debug/runtime validation (DEBUG builds only): with launch args `--runtime-queue-validation --runtime-queue-activate-actions` (+ optional `--runtime-queue-activate-extended-actions`) and a `/tmp/VoxQueueRuntimeValidation` shared-container override, the view self-drives queue actions (retry, process now, retention update, copy acknowledgement, discard, retry-all) and exposes status via accessibility label `recording-queue-runtime-actions`.
- Constraints: Debug-only runtime validation is additionally gated on the override path being under `/tmp/VoxQueueRuntimeValidation/` and matching `AppConstants.sharedContainerURL`.
- Evidence: `Voxboard App Shared/RecordingQueueViews.swift` (whole file, 791 lines) — `RecordingQueuePreferencesView` ~12–160, `RecordingQueueView` ~190–430, DEBUG validation ~330–430, `RecordingQueueRow` ~440–791; `VoxboardTests/RecordingCompletionModeTests.swift` (completion modes/origins).
- Status: shipped (debug validation path: hidden / DEBUG-only)

### F-CP-20 Location configuration preview (preset editors)
- Surface: Capture Preset editors (iOS & Mac) — location configuration section
- Summary: `CaptureLocationConfigurationPreview` renders a deterministic, privacy-safe sample of what a preset's location metadata will look like in delivered notes, exercising the real delivery renderer and document merger so editors surface the same failures Capture would.
- Details:
  - Fixed sample snapshot: San Francisco Civic Center coordinates (37.774929, −122.419416), accuracy 8.5 m, fixed timestamp (2024-01-01), with the preset's configured `precision` (exact vs city).
  - `result(profile:source:)` returns `.success(rendered)` or a failure carrying a localized message; `CaptureLocationMetadataError` messages deliberately contain only configuration keys/line numbers/structural descriptions — never coordinates or note text.
  - `render`: builds a synthetic `CaptureRequest` with `.available` location; `metadataScope == .entry` → inline lines joined by newline; document scope → renders via `MarkdownDocumentEditor().applying(MarkdownCaptureMutation(...))` including static frontmatter (surfaces collection collisions).
  - Field display names for all `CaptureLocationField` cases (coordinates, latitude, longitude, place, city, region, country, Apple/Google/OpenStreetMap URLs, geo URI, accuracy, timestamp, source, id).
  - `CaptureSource.configurationDisplayName` localizes all 10 sources (App, Keyboard, Widget, Shortcut, Share, Apple Watch, Mac, Deep Link, File Import, Voice).
- Constraints: None beyond shared framework types.
- Evidence: `Voxboard App Shared/CaptureLocationConfigurationSupport.swift` (whole file, 127 lines); `VoxboardTests/CaptureLocationConfigurationSupportTests.swift` (structured entry preview, token-only profile, frontmatter collision, advanced template + entry scope rejection).
- Status: shipped

### F-CP-21 `{location}` entry-template token support
- Surface: Entry-template editors and the capture composer
- Summary: The `{location}` token renders a map link in entry prefix/suffix only when the delivering preset enables Current Location, independent of metadata output; shared helpers detect the dependency, hint in the composer, preview rendering, and offer a one-tap fix.
- Details:
  - `referencesLocation(prefix:suffix:)` — true when either field contains `{location}` (via `CaptureEntryTemplateRenderer.referencesLocation`).
  - `needsPresetOptIn(library:destinationID:oneOffTemplateID:preset:)` — true only when the preset has Current Location disabled, a destination resolves, no vault Markdown template replaces inline formatting, and the resolved entry prefix/suffix references the token. Mirrors delivery-time precedence: one-capture template override > preset template; vault Markdown templates suppress the hint entirely.
  - `renderedSample(prefix:suffix:precision:)` — renders through the real delivery renderer with a synthetic available location (San Francisco sample), joining non-empty trimmed prefix/suffix with " … "; returns nil when the token is absent; honors exact vs city precision.
  - `CaptureEntryLocationTokenPreview` view: monospaced sample (text-selectable) plus an explanatory caption ("map link only when the Capture Preset delivering the capture uses Current Location. Location metadata is optional."); combined accessibility element.
  - Composer integration: `QuickCaptureViewModel.entryLocationTokenHint` (F-CP-01) non-blocking hint naming the preset, and `enableEntryLocationTokenForPreset()` one-tap fix — enables location on the stored preset *without* metadata output (`setLocationEnabled(true, metadataOutputEnabled: false)`), refreshes profiles, and patches a journaled snapshot so the very next Send resolves the token without changing note metadata.
- Constraints: token renders empty when the delivering preset has Current Location off or the origin-time fix is unavailable; live vault Markdown templates suppress the inline hint (read only at delivery).
- Evidence: `Voxboard App Shared/CaptureEntryLocationTokenSupport.swift` (whole file, 100 lines); `CaptureComposerViewModel.swift` `entryLocationTokenHint`/`enableEntryLocationTokenForPreset` ~140–168; `VoxboardTests/CaptureEntryLocationTokenSupportTests.swift` (9 tests covering nil-without-token, deterministic map link, city precision, opt-in conditions, template precedence, missing destination/preset).
- Status: shipped

---

## File-by-file coverage checklist

| File | Lines | Read |
|---|---|---|
| `Voxboard App Shared/CaptureComposerViewModel.swift` | 1826 | ✅ complete (all 1826 lines, 3 passes) |
| `Voxboard App Shared/RecordingQueueViews.swift` | 791 | ✅ complete |
| `Voxboard App Shared/CaptureAppIntents.swift` | 516 | ✅ complete |
| `Voxboard App Shared/CaptureToolbarPreferences.swift` | 279 | ✅ complete |
| `Voxboard App Shared/InspirationQuoteService.swift` | 127 | ✅ complete |
| `Voxboard App Shared/CaptureLocationConfigurationSupport.swift` | 127 | ✅ complete |
| `Voxboard App Shared/CaptureEntryLocationTokenSupport.swift` | 100 | ✅ complete |
| `Voxboard App Shared/VoxboardMacShortcutsProvider.swift` | 63 | ✅ complete |

Supplementary test files (test names inventoried via grep, not full reads): `CaptureToolbarPreferencesTests.swift`, `RecordingCompletionModeTests.swift`, `RecordingDraftDeliveryTests.swift`, `CaptureEntryLocationTokenSupportTests.swift`, `CaptureLocationConfigurationSupportTests.swift`, `QuickCaptureRecognizedTextTests.swift`.

## Uncertainties

- **No donation of App Intents is performed in this layer.** No `donate`/`SiriManager`/`Suggestion` calls appear in `CaptureAppIntents.swift`; donation may happen elsewhere (e.g., app layer or implicitly via App Shortcuts). Uncertain whether the task's "donation" expectation is satisfied by system App Shortcuts behavior alone.
- `CaptureToolbarSettingsView` is iOS-only in this file; whether Mac has a separate capture-bar settings UI lives outside this layer (not verified).
- `QuickCaptureViewModel` references many framework types from `VoxboardShared` (`CaptureDraftStore`, `CaptureInboxDeliveryService`, `CapturePreparedRequestReuse`, `LiveTranscriptDraftPreview`, `CaptureInputBudget`, etc.) whose internals are out of scope; behavioral details (e.g., exact retry backoff in the inbox service, retention cleanup timing) are inferred from call sites, not the implementations.
- Quota/entitlement mechanics behind `CaptureDeliveryQuotaError.limitReached` and `needsCaptureUnlock` (what unlocks, free-tier limits) live in `VoxboardShared` and were not verified here.
- Mac has no zero-setup phrase for `OpenCaptureScanIntent`; unverified whether that is intentional or an oversight.
- Debug runtime queue validation (F-CP-19) was verified as code-only; its test harness scripts were not examined.
