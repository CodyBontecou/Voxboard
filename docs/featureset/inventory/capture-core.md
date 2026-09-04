# Capture Core (VoxboardCaptureCore) — Feature Inventory

LID: CC. Package: `Packages/VoxboardShared/Sources/VoxboardCaptureCore/` (framework-independent capture engine used by the iOS app, share extension, widgets, Shortcuts, Watch, and deep links). Every feature below is verified in source; tests in `Packages/VoxboardShared/Tests/VoxboardCaptureCoreTests/` are cited as supplementary evidence.

### F-CC-01 Capture Request model & payload kinds
- Surface: all capture entry points (app composer, keyboard, widget, shortcut, share extension, watch, mac, deep link, file import, voice)
- Summary: `CaptureRequest` is the durable, Codable unit of user intent captured at submission time. It snapshots the destination ID, payloads, preset profile, processing state, location outcome, and one-capture route overrides so retries never read live settings. `CapturePayload` enumerates the eight content kinds the engine can deliver.
- Details:
  - `CaptureSource` cases: `app, keyboard, widget, shortcut, shareExtension, watch, mac, deepLink, fileImport, voice`
  - `CapturePayload` cases: `text(String)`, `url(URL, title:)`, `audio(asset, transcript:)`, `retainedAudio(asset, embedPlacement:)`, `image(asset, altText:)`, `file(asset)`, `scannedDocument(pages, pdf?, extractedText?)`, `sketch(drawing, preview, altText?)`; encoded with a `kind` discriminator key for Codable
  - `CaptureDeliveryKind`: `standard` (consumes one free capture) vs `meteredVoiceTranscript` (voice text that already consumed transcription time bypasses the Capture allowance) — default `.meteredVoiceTranscript` when `source == .voice`, applied on both init and legacy decode
  - Request fields: `id, createdAt, source, deliveryKind, destinationID, payloads, frontmatter`, `voxProfile` (snapshotted preset), `voxProcessingState`, `locationOutcome`, `locationDecisionOverride`, `originDraftUpdatedAt` (version marker for prepared-request reuse), one-capture overrides: `relativeNotePathOverride`, `placementOverride`, `entryTemplateIDOverride`, `attachmentsFolderNameOverride` (nil = destination default; empty string = alongside the note)
  - Overrides explicitly outrank the snapshotted preset and survive deferred delivery without mutating the reusable destination
  - `voxReference` derives a lightweight `CapturePresetReference` from the snapshotted profile
  - Legacy decode defaults missing optional fields (frontmatter → `[:]`, processingState → `.notRequested`, deliveryKind by source)
- Constraints: none (pure model); entitlement accounting is injected at the pipeline level
- Evidence: `CaptureModels.swift` `CapturePayload` (lines ~193-330), `CaptureRequest` (lines ~350-470); tests `CaptureModelCodableTests.swift`
- Status: shipped

### F-CC-02 Capture asset reference & path/filename validation
- Surface: every attachment-bearing capture (audio, image, file, scan, sketch)
- Summary: `CaptureAssetReference` validates its relative path and original filename at construction/decode, so unsafe references cannot enter the durable store. `CapturePathValidation` is the package-wide path-safety gate.
- Details:
  - `validateRelativePath` rejects empty, leading `/`, leading `~`, backslashes, NUL scalars, and any `.`/`..`/empty path component
  - `validateFilename` rejects empty, `.`, `..`, `/`, `\`, NUL
  - `relativePath(for:containedIn:)` recovers a safe relative path for a file-picker selection by comparing standardized, symlink-resolved, canonical (`canonicalPathKey`), and file-resource-identity (`fileResourceIdentifierKey`) URL spellings; falls back to walking ancestors by resource identity for File Provider URLs with unrelated canonical spellings
  - `containedFileURL(relativePath:rootURL:)` performs both a lexical child check and a resolved-symlink child check (resolving only existing ancestors) so a symlink inside the root cannot redirect I/O
- Constraints: Darwin/macOS+iOS file APIs (`URLResourceKey.canonicalPathKey`); behavior degrades to throwing `invalidRelativePath` when identity checks fail
- Evidence: `CaptureModels.swift` `CapturePathValidation` (lines ~20-185), `CaptureAssetReference` (lines ~187-235); tests `CapturePathValidationTests.swift`
- Status: shipped

### F-CC-03 Capture Preset (CapturePresetProfile) data model
- Surface: Preset editors (app), Watch preset snapshots, voice flows, lightweight extension clients
- Summary: A modality-neutral preset policy snapshot (`CapturePresetProfile`, legacy alias `CaptureVoxProfile`) that shares coding keys with the legacy recording-flow format so lightweight clients can read presets without the transcription stack. Every field has a legacy-decode default.
- Details (every field):
  - `id: String`, `name: String` (empty → "Untitled Preset" via `displayName`), `symbolName` (default `"waveform"`), `isEnabled` (default true), `isBuiltIn` (default false)
  - `staticFrontmatter: [String: String]` (default `[:]`)
  - `locationPolicy: CapturePresetLocationPolicy` (missing → disabled defaults)
  - `metadataScope`: `.document` ("Note Frontmatter") or `.entry` ("Inline Entry Fields"); default `.document`
  - `postProcessingMode`: `.none` ("Keep Original"), `.clean` ("Clean Prose"), `.todoList` ("Todo Checklist"), `.meetingNotes` ("Meeting Notes"), `.custom` ("Custom Instruction"); default `.clean`
  - `customPostProcessingInstruction: String` (default "")
  - `captureProcessingEnabled: Bool` (master Apple Intelligence gate; defaults off for decoded, built-in, and newly created presets)
  - `captureProcessingScope: CapturePresetProcessingScope` (`.both`/`.voiceOnly`/`.textOnly` — which modalities the mode applies to when the gate is on; missing legacy values decode `.both`; the one-time `capturePresetProcessingGateMigrationVersion` migration preserves actual legacy behavior: toggle-on→gate on + `.both`, toggle-off with an active mode→gate on + `.voiceOnly` because voice processing was previously implicit, Keep Original→untouched; fresh installs skip migration and remain off)
  - Processor enforces scope per payload: `.text`/`.scannedDocument` need `appliesToTypedText`, `.audio` needs `appliesToVoice`
  - `capturePrompt: String` (local empty-state prompt shown when the preset is active)
  - `captureDestinationID: UUID?` (owned destination inherited by captures using the preset)
  - Legacy folded-into-route fields: `captureEntryTemplateID: UUID?`, `capturePlacementOverride: CapturePlacement?`
  - Computed: `resolvedPostProcessingInstruction` maps modes to fixed AI prompts (custom returns trimmed instruction or nil), `staticTags` parses `tags`/`tag` frontmatter, `staticCategory` reads `category`/`type`
- Constraints: none
- Evidence: `CaptureVox.swift` `CapturePresetProfile` (lines ~4-165), enums `CapturePresetMetadataScope`/`CapturePresetProcessingMode`/`CapturePresetProcessingState`; tests `CaptureVoxTests.swift`
- Status: shipped

### F-CC-04 Capture Preset selection & route resolution
- Surface: composer preset picker, capture entry points, Watch
- Summary: `CapturePresetProfileStore` reads/writes App Group UserDefaults preset records and resolves the selected preset; `CapturePresetRouteResolver` resolves which destination a capture uses without mutating reusable settings.
- Details:
  - Keys: `recordingFlows` (profiles blob), `selectedRecordingFlowId`, `selectedCaptureVoxId`, `capturePresetOwnedRouteMigrationVersion` (current `1`, `defaultProfileID = "general"`)
  - `selectedProfileID` prefers the capture-specific selection, falls back to the recording selection, then the first enabled profile; returns nil when no enabled profiles
  - `selectCaptureProfile(id:)` only selects enabled IDs and verifies the write round-tripped
  - Route precedence: explicit valid destination → preset `captureDestinationID` → library default (when `allowsLegacyFallback`) → first destination
- Constraints: UserDefaults access is injected; App Group suitability assumed
- Evidence: `CaptureVox.swift` `CapturePresetRouteResolver`, `CapturePresetProfileStore` (lines ~170-250)
- Status: shipped

### F-CC-05 Destination kinds & note targets
- Surface: destination editor (app), path previews, pipeline delivery
- Summary: `CaptureDestination` binds a security-scoped root bookmark (`rootBookmark`/`rootName` — works for Obsidian vaults and plain Files folders) to a note target; `CaptureNoteTarget` selects where the note lives.
- Details:
  - `CaptureNoteTarget.newNote(pathTemplate:)` — new note per capture, template-rendered and uniqueness-suffixed
  - `.rollingNote(pathTemplate:period:)` — `CaptureRollingPeriod` daily/weekly/monthly/quarterly/yearly (journal/daily-note style bucketing; see F-CC-08)
  - `.existingNote(relativePath:)` — validated relative path, re-validated on both encode and decode
  - `CaptureDestination` fields: `id, name, rootBookmark, rootName, noteTarget, placement, entryPrefix, entrySuffix, entryTemplateID?, markdownTemplatePath?, attachmentsFolderName` (default `"attachments"`), `retryProtectionEnabled` (default false)
  - Legacy decode defaults: placement `.append`, empty prefix/suffix, `"attachments"`, retry protection false
  - `CaptureLibraryEnvelope.resolvedDestination` resolves reusable templates at delivery time: a one-capture `overrideEntryTemplateID` (from the request) outranks and clears `markdownTemplatePath` without mutating the stored destination; otherwise a configured `markdownTemplatePath` is the live formatting source (inline prefix/suffix ignored as a snapshot); otherwise a bound library template's prefix/suffix is applied
- Constraints: none in core; root security scope owned by the caller
- Evidence: `CaptureModels.swift` `CaptureDestination`/`CaptureNoteTarget` (lines ~470-620), `CaptureLibraryEnvelope` (lines ~660-820)
- Status: shipped

### F-CC-06 Placement: append/prepend/beneath-heading
- Surface: destination editor, pipeline writes to existing/rolling notes
- Summary: `CapturePlacement` determines where the rendered capture block goes inside a note: `append` (end of body), `prepend` (top of body, after frontmatter), or `beneathHeading(CaptureHeadingSelector, missingHeadingBehavior:)`.
- Details:
  - `CaptureHeadingSelector {title, level?}` — level nil matches any level
  - `CaptureMissingHeadingBehavior`: `.fail` (throws `headingNotFound`, decode default) or `.create` (appends a heading at `level ?? 2`, validated to 1-6, before the capture block)
  - Heading detection ignores headings inside fenced code blocks (``` or ~~~ with ≥3 delimiters, closing fence must match char and length)
  - ATX heading parsing accepts up to 3 leading spaces/tabs, requires whitespace after `#`s, strips trailing `#`s
  - Codable with `kind`/`selector`/`missingHeadingBehavior` keys
- Constraints: none
- Evidence: `CaptureModels.swift` `CapturePlacement` (lines ~415-470); `MarkdownDocumentEditor.swift` `inserting`/`firstHeadingIndex`/`atxHeading`/`fenceDelimiter` (lines ~150-230); tests `MarkdownDocumentEditorTests.swift`, `CaptureInsertionFormatterTests.swift`
- Status: shipped

### F-CC-07 Entry formatting: YAML frontmatter merge
- Surface: every note write; per-note and per-entry metadata
- Summary: `MarkdownDocumentEditor.applying(_:to:)` merges capture frontmatter into the destination note's YAML header. Existing user values win; only additive keys (`tags`, `tag`, `audio`) union values; location metadata appends into its keyed collection.
- Details:
  - Leading frontmatter is only detected when it contains ≥1 top-level `key:` line — prevents a leading `---` horizontal rule from being absorbed into YAML
  - Merge order (existing → payload-leading frontmatter → request/preset frontmatter → prefix/suffix frontmatter); non-key lines are appended once if not already present
  - Additive keys: existing list values (inline `[a, b]` or block `- item` continuation) union with incoming values, deduplicated, rewritten as one inline list
  - Duplicate keys in ordered structured frontmatter throw `duplicateFrontmatterKey`
  - YAML scalar quoting: passthrough for `[...]`/`{...}`/`true|false|null|~`/numbers; otherwise double-quoted with `\ " \n \r` escapes; keys quoted only when not plain alphanumeric/`_`/`-`
  - `finalNewline` policy (`CaptureMarkdownWritePolicy.applyingFinalNewline`) — production callers default to no trailing LF; M2 bounded adapter passes true
  - Document assembly: frontmatter block then blank line then body; frontmatter-only result omits the trailing blank section; whole document boundary newlines trimmed
  - Idempotency: if the request marker is already present the document is returned unchanged (only final-newline policy applied); if the location metadata collection already contains the request ID the document is returned unchanged
- Constraints: none
- Evidence: `MarkdownDocumentEditor.swift` (lines ~85-535); tests `MarkdownDocumentEditorTests.swift`, `CapturePipelineTests.swift`
- Status: shipped

### F-CC-08 Rolling note path planning & date tokens
- Surface: rolling daily/weekly/monthly/quarterly/yearly journal pages, new-note name templates, entry prefix/suffix templates, vault templates
- Summary: `CapturePathPlanner` renders the destination path template with date/ID tokens; `CaptureDateTokenValues` computes zero-padded calendar components; rolling periods collapse `{period}` to the matching bucket.
- Details:
  - Path template tokens: `{period}, {timestamp}, {date}, {time}, {year}, {YR}, {month}, {day}, {week}, {hour}, {minute}, {second}, {id}, {id8}` (id = lowercase UUID, id8 = first 8 chars)
  - `{period}` buckets: daily `yyyy-MM-dd`; weekly `yyyy-Www` (yearForWeekOfYear); monthly `yyyy-MM`; quarterly `yyyy-Qn` (n = (month-1)/3+1); yearly `yyyy`; nil period → daily date
  - Rendered path is trimmed, gets `.md` appended when it has no extension, and is validated as a safe relative path
  - `newNote` uses `uniquePath` suffixes `-2, -3, …` against an `existingRelativePaths` set; the pipeline loops, checking the filesystem until a free candidate (or a same-request-id marker match) is found
  - Entry-template tokens (`CaptureEntryTemplateRenderer.render`) add `{source}` (capture source raw value) and `{location}`; payload text is never interpolated so literal user `{date}` survives
  - `CaptureEntryTemplateRenderer.locationToken` = `"{location}"` canonical spelling; `referencesLocation(in:)` used by editors/hints; `{location}` renders as `[Location](<google maps url>)` when the preset location policy is enabled and an available snapshot exists (city precision respected), otherwise empty string
  - Token values: timestamp `yyyy-MM-dd-HHmmss`, date `yyyy-MM-dd`, time `HHmmss`, weekToken `yyyy-Www`, shortYear last two digits; missing calendar components render as zero-padded `0`
- Constraints: `Calendar` injected (tests use fixed calendars); week semantics follow the injected calendar
- Evidence: `CapturePathPlanner.swift` (whole file), `CaptureDateTokenValues.swift` (whole file), `CaptureEntryTemplateRenderer.swift` (whole file); tests `CapturePathPlannerTests.swift`, `CaptureEntryTemplateRendererTests.swift`
- Status: shipped

### F-CC-09 Markdown entry rendering (payload → Markdown blocks)
- Surface: every capture delivery; OCR scans, voice transcripts, sketches, files
- Summary: `CaptureMarkdownRenderer.render` converts the payload list into Markdown/Obsidian blocks joined by blank lines, embedding attachments via Obsidian wiki syntax and enforcing HTTP(S)-only links.
- Details:
  - `text` → trimmed block; `url` → `[label](url)` with `[]\` label escaping and `%28/%29` paren escaping; non-HTTP(S) schemes throw `unsafeURL`
  - `audio` → transcript block + `![[path]]` embed; `retainedAudio` → embed at `.top` (inserted after leading frontmatter), `.bottom`, or `.none` (kept out of the note; but if it is the capture's only content a plain `[[path|filename]]` link is kept so the renderer doesn't reject and roll back the copied attachment)
  - `image` → `![[path|alt]]` embed with optional alias; `file` → `[[path|originalFilename]]` link
  - `scannedDocument` → extracted text block + embed of the PDF if present, else embed of every page image
  - `sketch` → `![[preview|alt]]` embed + `[[drawing|Editable drawing]]` link
  - Attachment path = `attachmentsFolderName/originalFilename` (empty folder → alongside the note); override map from the copy transaction wins; validated then `]`-escaped
  - Empty payload list or fully-empty render throws `emptyRequest`; blank blocks filtered
  - Entry-scope metadata (preset `metadataScope == .entry`): preset frontmatter rendered as Dataview-style inline `key:: value` fields (sorted keys, newlines flattened) plus inline location lines, inserted after leading frontmatter
  - Alias escaping: `\|`, `\]`, newlines → spaces
- Constraints: none
- Evidence: `CaptureMarkdownRenderer.swift` (whole file); tests `CaptureMarkdownRendererTests.swift`
- Status: shipped

### F-CC-10 Entry templates (library) and per-destination prefix/suffix
- Surface: destination editor, entry-template library, one-capture template choice
- Summary: `CaptureEntryTemplate` is a reusable named prefix/suffix pair stored in the library envelope; destinations can bind one live (`entryTemplateID`) while retaining an inline snapshot; a request can override per capture.
- Details:
  - Template fields: `id, name, entryPrefix, entrySuffix` (defaults empty)
  - Resolution precedence (F-CC-05): request `entryTemplateIDOverride` → destination `markdownTemplatePath` (live vault file wins; inline values ignored) → destination `entryTemplateID` (prefix/suffix replaced at delivery) → inline destination prefix/suffix
  - Prefix/suffix are rendered with date/source/id/location tokens (F-CC-08); rendered vault template replaces both prefix and suffix (prefix + blank-line separation, suffix empty)
- Constraints: none
- Evidence: `CaptureModels.swift` `CaptureEntryTemplate` (lines ~630-650), `resolvedDestination` (lines ~770-810); `CapturePipeline.swift` `captureLocked`; tests `CaptureEntryTemplateRendererTests.swift`
- Status: shipped

### F-CC-11 Vault Markdown templates (live file + Templater-style expressions)
- Surface: destination editor "template from vault file", delivery pipeline
- Summary: A destination may point at a Markdown file inside its own vault (`markdownTemplatePath`); its live contents are read through the secure I/O layer at every capture and rendered as the note body skeleton.
- Details:
  - `CaptureVaultMarkdownTemplateLoader.load` validations: safe relative path; extension must be `.md`; template cannot equal the destination note path (`templateMatchesDestination`); must exist (`templateMissing`); must decode as UTF-8; bounded to `CaptureInputLimits.maximumTextCharacters` (100,000 chars, checked both as ≤4× bytes before decoding and after decode)
  - Renderer normalizes newlines, applies all entry tokens, then `<% … %>` expressions: `tp.date.now("pattern")` (default `YYYY-MM-DD`), `tp.file.creation_date("pattern")` (default `YYYY-MM-DD HH:mm:ss`), `crypto.randomUUID()` (new lowercase UUID); moment patterns translated `YYYY→yyyy`, `DD→dd`; unknown expressions left intact
  - Empty frontmatter fill: for keys `tags, title, category, summary, description` (case-insensitive), empty values (or `tags: []`) are filled from the request's static frontmatter
  - Payload text is appended later and never interpolated into the template
- Constraints: root security scope owned by the delivery caller
- Evidence: `CaptureVaultMarkdownTemplate.swift` (whole file); used in `CapturePipeline.swift` `captureLocked`; tests `CapturePipelineTests.swift`
- Status: shipped

### F-CC-12 Attachment staging (CaptureAssetStager)
- Surface: composer attachments, share extension, scanner, Photos/Files pickers
- Summary: An actor that durably stages user-selected media beside a capture draft, sanitizing filenames and enforcing per-file size limits. Actor isolation makes concurrent staging collisions deterministic.
- Details:
  - `stage(data:preferredFilename:contentTypeIdentifier:)` writes atomically; `stageCopy(from:…)` validates existence, rejects directories, checks source file size pre-copy and copied size post-copy (rollback removes the partial copy on failure)
  - Default limit `defaultMaximumByteCount` = 100 MB per asset (`assetTooLarge` error)
  - `sanitizedFilename`: takes the last path component after `\`→`/` normalization, replaces `/\\?%*|"<>:\n\r\t` with `-`, trims, strips leading dots, falls back to `attachment-<uuid>`, and appends a sanitized source extension when the name has none — shared with the share extension so provider-supplied names cannot escape staging
  - Collision handling: `-2, -3, …` suffixes within the staging directory
  - `remove(_:)` deletes via a contained-URL check (`unsafeStagedPath` otherwise)
- Constraints: none
- Evidence: `CaptureAssetStager.swift` (whole file); tests `CaptureAssetStagerTests.swift`
- Status: shipped

### F-CC-13 Attachment writing & duplicate reuse (CaptureAttachmentWriter)
- Surface: delivery pipeline for every attachment-bearing capture
- Summary: Copies staged assets into the destination root's attachments folder (or alongside the note when the folder name is empty; or the request's `attachmentsFolderNameOverride`), reusing an existing file when its contents are byte-identical, and rolling back created copies on failure.
- Details:
  - Requires `assetRootURL`; throws `assetRootRequired` for attachment payloads without one; throws `sourceMissing` for a staged asset that no longer exists
  - Destination candidate naming: base name, then `-2, -3, …`; each candidate containment-checked; `reusableOrAvailablePath` scans all uniqued candidates so a crash-retry that previously created `photo-2.jpg` reuses it instead of leaking `photo-3.jpg`
  - Byte-identical reuse via `SecureCaptureFileIO.contentsEqual` (64 KiB buffered comparison)
  - Failure path: created attachments removed in reverse via `removeIfContentsEqual` (only removed if still identical); the transaction `rollback` does the same after a later pipeline failure (e.g., render error)
  - `scannedDocument` copies the PDF when present, else all pages; `sketch` copies drawing + preview; payload asset extraction in `CapturePayload.captureAssets`
  - Returns mapping `staged relativePath → destination relativePath` used by the renderer plus destination URLs for the receipt
- Constraints: none
- Evidence: `CaptureAttachmentWriter.swift` (whole file); tests `CaptureAttachmentWriterTests.swift`
- Status: shipped

### F-CC-14 Secure capture file I/O (descriptor-based)
- Surface: all note and attachment reads/writes in the delivery path
- Summary: `SecureCaptureFileIO` performs all relative I/O through directory descriptors opened with `O_NOFOLLOW`, so a symlink swap between path planning and the coordinated write cannot redirect data outside the root. Writes are temp-file + fsync + rename atomic.
- Details:
  - `read` → nil for missing; `exists`; `copy` (O_EXCL create, EINTR-retry reads/writes, fsync, unlinks partial destination on failure); `writeAtomically` (`.vox-capture-<uuid>.tmp`, mode 0600, fsync, `renameat`, unlink on failure); `contentsEqual`; `removeIfContentsEqual`
  - Intermediate directories created on demand with `mkdirat` (mode 0700) only when `createMissing`; path split validates through `CapturePathValidation`
  - Root opened with `O_DIRECTORY|O_NOFOLLOW` after symlink-resolving the root URL
  - Errors surfaced as POSIX operation/code pairs with `strerror` descriptions
- Constraints: Darwin only (`import Darwin`); not available on non-Apple platforms
- Evidence: `SecureCaptureFileIO.swift` (whole file); exercised by `CaptureAttachmentWriterTests.swift`, `CoordinatedCaptureWriterTests.swift`
- Status: shipped

### F-CC-15 Coordinated cross-process writes (CoordinatedCaptureWriter)
- Surface: note mutation seam used by the pipeline (app + extensions writing the same vault)
- Summary: Combines a process-local `NSRecursiveLock` coordinator (`ProcessLocalCaptureFileCoordinator`) with `NSFileCoordinator(.forMerging)` (`NSFileCoordinatorCaptureFileCoordinator`) to serialize writes against document providers and other processes, then verifies the write.
- Details:
  - Prefers descriptor-relative secure I/O when the mutation carries `destinationRootURL` + `relativeNotePath`; falls back to `FileManager`/atomic `Data.write` for legacy callers without a root
  - Duplicate detection: `CaptureRequestMarker` HTML comment `<!-- vox-capture:<uuid> -->` (lowercased) checked in the existing content; already-applied requests skip the write entirely and return `wasAlreadyApplied: true`
  - Verification: content equality against edited text; when already applied or retry protection is on, marker presence suffices
  - Verification failure throws `verificationFailed(requestID)`; coordination not running throws `coordinatorDidNotRun`
  - Receipt `CaptureWriteReceipt {fileURL, requestID, byteCount, wasAlreadyApplied}`
- Constraints: none
- Evidence: `CoordinatedCaptureWriter.swift` (whole file); tests `CoordinatedCaptureWriterTests.swift`
- Status: shipped

### F-CC-16 Retry protection & idempotency
- Surface: destination setting "retry protection" (opt-in); freemium accounting; inbox retries
- Summary: Multiple layers prevent duplicate delivery: request-ID HTML comment markers, pipeline idempotency receipts via the accounting reservation, note-path allocation marker checks, attachment content-equal reuse, and inbox completion tombstones.
- Details:
  - `retryProtectionEnabled` (destination, default false to keep user Markdown free of Vox.md metadata) appends the marker beneath the capture block; enabled-marker presence makes the writer/editor treat a document as already applied
  - `CapturePipeline.capture`: `alreadyCounted` reservation returns a synthesized receipt without re-mutating the destination (explicitly true even when HTML markers are disabled); marker check in `availableNotePath` lets a new-note retry target the note it previously created
  - If final accounting commit fails, the reservation is retained so a retry with the same stable request ID finishes without opening a quota slot
  - Editor returns the document unchanged when the marker or the location collection already contains the request ID
- Constraints: retry markers are opt-in at the destination level; idempotency itself is not
- Evidence: `CapturePipeline.swift` (lines ~150-260, 280-310), `CoordinatedCaptureWriter.swift`, `MarkdownDocumentEditor.swift`; tests `CapturePipelineTests.swift`, `CoordinatedCaptureWriterTests.swift`
- Status: shipped

### F-CC-17 Capture pipeline stages & process gate
- Surface: the single delivery path for typed, voice, deep-link, and inbox captures
- Summary: `CapturePipeline` (actor; `CapturePipeline.shared` process-wide singleton) serializes note-path allocation and attachment transactions through stages: location-decision validation → engine-policy routing → process gate → quota reservation → path planning → vault template load → attachment copy → render → mutation → coordinated write → accounting commit.
- Details:
  - `validateLocationDecision`: enabled location policy requires an outcome; `.unavailable` with `.ask` behavior requires a `sendWithoutLocation` override, otherwise throws `locationDecisionRequired` ("Open Vox.md to retry, send without location, or cancel."); nil outcome also throws
  - `CapturePipelineGate` actor: strict acquire/release FIFO for one in-flight capture process-wide
  - Destination mismatch throws before any I/O; `attachmentsFolderNameOverride` applied to an effective destination copy only
  - Entry/preset metadata scope: `.entry` renders inline metadata and empty document frontmatter; `.document` merges frontmatter and typed location metadata
  - On write failure the attachment transaction rolls back; on quota failure the reservation is released and the gate released
  - `CaptureDeliveryAccounting` protocol (`reserve/commit/release`) with `UnmeteredCaptureDeliveryAccounting` default for core/tests; `CaptureDeliveryQuotaError.limitReached` message: "You've used all N free captures. Unlock Vox.md Unlimited to keep capturing."
- Constraints: freemium accounting injected by the app; core defaults unmetered
- Evidence: `CapturePipeline.swift` (whole file); tests `CapturePipelineTests.swift` (1009 lines covering stages, rollback, idempotency)
- Status: shipped

### F-CC-18 Engine policy: legacy / shadow / Rust routing (M2)
- Surface: internal routing decision before any pipeline side effect; experimental Rust shared core
- Summary: `CaptureCoreEnginePolicy` routes each capture to the legacy Swift pipeline, a shadow comparison against a portable (Rust "M2") core, or a Rust commit barrier. Admission (`CaptureCoreAdmission.admit`) converts the request into a bounded, binary-free DTO only when it fits the portable profile.
- Details:
  - Modes: `.legacy` (default), `.shadow(using:)` (admit best-effort; comparison errors swallowed; always returns legacy), `.rust(using:)` (`@_spi(Testing)` — Rust authority unavailable to normal product imports during M2; requires exact `CaptureCoreComparison` match or throws `rustComparisonFailed`; returns `rustCommitBarrier` which the pipeline turns into `rustCommitNotPromoted` — never falls back to Swift after Rust was selected)
  - Admission bounds: ≤128 payloads; text ≤65,536 chars; URL ≤8,192; label ≤4,096; ≤32 path segments, ≤255 scalars each; note template ≤1,024 chars; ≤128 frontmatter fields (name ≤128, value ≤8,192); entry prefix ≤256 MB; JSON control budget <1 MiB (fixed 64 KiB + per-payload 128 B + per-field 96 B, 6× JSON-escape worst case, 257 path repetitions); created-at epoch ms in [0, 4102444800000]; timezone ≤64 chars and must be a known identifier (fixed-offset rejected); locale 2-35 chars
  - Policy restrictions: only `.standard` delivery, `.notRequested` processing, no overrides/profile/location, destination must be `.newNote` + `.append` with empty suffix/template bindings; folder segments may not contain output-affecting tokens; filename may not contain `{period}` or `{source}`; share-extension entry prefix may not contain `{source}`; boundary whitespace rejected; calendar must be Gregorian or ISO8601 when calendar tokens used; `{week}` requires Monday first weekday + minimumDaysInFirstWeek 4; leading frontmatter in payload text or prefix rejected (merge-order divergence); sources `mac/deepLink/fileImport/voice` unsupported (shareExtension → "share")
  - `CaptureCoreComparison` (privacy-safe booleans: readiness/logicalPath/bytes/resultHash matched); 256-candidate materialization bound: longest `-256` suffix must stay ≤255 scalars
- Constraints: `rust` mode is `@_spi(Testing)`; hidden/experimental; shadow mode never blocks delivery
- Evidence: `CaptureCoreEnginePolicy.swift` (whole file); tests `CaptureCoreEnginePolicyTests.swift` (619 lines)
- Status: experimental (legacy shipped; shadow/rust gated)

### F-CC-19 Deep link parsing (voxboard:// URLs)
- Surface: app/extension URL handling, widgets, Shortcuts, automation
- Summary: `CaptureDeepLinkParser` parses `voxboard://` capture links into a composer draft or an inbox-request action, with a strict allowlist, duplicate detection, and per-parameter validation.
- Details:
  - Host `capture`: allowed parameters `text, url, destination, preset, vox, action, source` (any other → `forbiddenParameter`; repeats → `duplicateParameter`)
    - `text`: ≤100,000 chars (`maximumTextLength` = `CaptureInputLimits.maximumTextCharacters`), else `payloadTooLarge`
    - `url`: must parse and be http/https, else `invalidURL`
    - `destination`: UUID, else `invalidDestination`
    - `preset`/`vox`: legacy + modern spellings; both present → `duplicateParameter`; trimmed non-empty ≤160 chars, else `invalidVox` (exposed as `presetID`)
    - `action`: `CaptureRequestedInput` = photos, screenshots, camera, files, scan, sketch, link, voice; unknown → `invalidAction`
    - `source`: only `widget` accepted, else `invalidSource`
  - Host `capture-request`: only `id`; must be a UUID (`invalidRequestID`) → `.processInboxRequest(id)`
  - Wrong scheme → `invalidScheme`; unknown host → `unknownAction`
- Constraints: none
- Evidence: `CaptureDeepLinkParser.swift` (whole file); tests `CaptureDeepLinkParserTests.swift`
- Status: shipped

### F-CC-20 Input limits & bounded input budget
- Surface: share extension, composer, deep links, vault templates
- Summary: `CaptureInputLimits` defines shared denial-of-service limits and `CaptureInputBudget` tracks cumulative input transactionally before a capture is accepted.
- Details:
  - Limits: `maximumTextCharacters = 100_000`, `maximumSharedItemCount = 10`, `maximumAggregateAssetByteCount = 250 MB`
  - Budget reservations: `reserveSharedItems`, `reserveText(characters:)`, `reserveAsset(bytes:)` — each rejects negative counts (`invalidNegativeCount`) and overflow; a rejected value never changes recorded totals
  - Error messages are user-readable (counts formatted; MB conversion for assets)
  - Vault templates and deep links reuse `maximumTextCharacters`
- Constraints: per-asset size additionally bounded by `CaptureAssetStager.defaultMaximumByteCount` (100 MB, F-CC-12)
- Evidence: `CaptureInputLimits.swift` (whole file); tests `CaptureInputBudgetTests.swift`
- Status: shipped

### F-CC-21 OCR to Markdown formatting
- Surface: document scanner capture flow
- Summary: `CaptureOCRMarkdownFormatter.render(pageTexts:)` converts ordered OCR page output into plain Markdown for the capture editor.
- Details:
  - Normalizes CRLF/CR to LF; trims each page's whitespace; omits empty pages; preserves page order and intra-page line breaks; joins pages with a blank line
- Constraints: none
- Evidence: `CaptureOCRMarkdownFormatter.swift` (whole file, 21 lines); tests `CaptureOCRMarkdownFormatterTests.swift`
- Status: shipped

### F-CC-22 Durable capture inbox (queue, states, tombstones)
- Surface: background/deferred delivery from extensions, Watch, intents; foreground retry UI
- Summary: `CaptureInbox` is an actor-based file queue under `<root>/capture-inbox/{pending,processing,completed,failed}` with atomic state transitions, privacy-safe completion tombstones, orphan-staging purge, and stale-processing recovery.
- Details:
  - `enqueue` is idempotent per request ID (skips when any state file exists); writes atomically under coordination
  - `claimNext(excludingRequestIDs:)` claims oldest-first (by createdAt then ID); `claim(requestID:)` for targeted foreground processing; claiming is a move pending→processing with a refreshed modification-date lease so stale recovery measures active work, not queue wait time; decode failure after claim moves to failed
  - `replaceProcessingRequest` swaps in the exact AI-processed request so retries never rerun a nondeterministic processor (`requestNotProcessing` otherwise)
  - `complete` writes the `CaptureCompletionReceipt` tombstone (schemaVersion, requestID, completedAt only — deliberately no content/paths/attachment names) before deleting the request; inbox-staging cleanup is best-effort
  - `fail`, `retryFailed`, `retryAllFailed` (failed→pending, dedup-safe), `returnToPending` (quota block ≠ delivery failure), `discard` (only pending/failed; never processing/completed — lets users drop a failed Watch recording so it cannot deliver later)
  - `sendWithoutLocation(requestID:)` applies the one-capture decision override to the exact durable request (pending or failed; failed is moved/reconciled with pending) without touching the preset snapshot
  - `rerouteRequests(from:to:)` and `rerouteOrphanedRequests(validDestinationIDs:to:)` rewrite requests before/after destination removal
  - `purgeOrphanedStaging(olderThan:)` removes abandoned staging dirs past a grace period only when no live request references them; `purgeCompleted(olderThan:)`; `recoverStaleProcessing(olderThan:)` returns stale processing to pending, failed on undecodable, and deletes processing when a completed tombstone exists (crash between tombstone-write and delete must never redeliver)
  - `sanitizeLegacyCompletedRequests` (run on every directory ensure): replaces legacy payload-bearing completed files with tombstones, removes invalid filenames; `request(requestID:states:)` loads a private request for foreground UI only (never from completed)
- Constraints: privacy/data-retention — completed requests retain only request ID + timestamp
- Evidence: `CaptureInbox.swift` (whole file); tests `CaptureInboxTests.swift` (594 lines)
- Status: shipped

### F-CC-23 Capture history store (coarse metadata, retention, quarantine)
- Surface: in-app capture history list
- Summary: `CaptureHistoryStore` persists privacy-limited delivery metadata (`CaptureHistoryRecord`), coordinated across processes, capped, deduplicated by request ID, with corrupt-file quarantine and best-effort semantics that never fail a completed capture.
- Details:
  - Record fields (no content/URLs/coordinates/roots/bookmarks/attachment names): requestID, createdAt, deliveredAt, source, outcome (`delivered`/`failed`), destinationID, destinationName (+`destinationNameSnapshot` alias), voxID/voxName, relativeNotePath (validated: safe relative path, first component must not contain `:`), attachmentCount (≥0), failureCategory
  - Failure categories with display names: destinationUnavailable, permissionDenied, invalidRequest, attachment, fileWrite, storage, unknown
  - `defaultMaximumRecordCount = 500`; normalization dedupes by requestID keeping the newer (deliveredAt ?? createdAt, then createdAt) and sorts newest-first
  - Upsert of a delivered record also records a `CaptureActivityEvent` in the activity ledger, best-effort (`try?`)
  - Legacy v0 bare-array files migrate to the versioned envelope on next write; newer-schema files are never moved or overwritten (forward compatibility); other decode errors quarantine to `<file>-corrupt/` with unique suffixes
  - `upsertBestEffort`/`clearBestEffort` return `CaptureHistoryWriteError` (operation + underlying) for logging instead of throwing; `remove(requestIDs:)` deletes the file when it would become empty; `writeCompatibilityFixture` is package-internal for repo fixtures
- Constraints: none
- Evidence: `CaptureHistoryStore.swift` (whole file); tests `CaptureHistoryStoreTests.swift`
- Status: shipped

### F-CC-24 Activity stats store (content-free lifetime ledger)
- Surface: stats/paywall surfaces, onboarding milestones
- Summary: `ActivityStatsStore` maintains a coordinated, content-free ledger of completed recordings and captures (`activity-stats-v1.json`), idempotent by stable IDs and independent of user content deletion or history trimming.
- Details:
  - `RecordingActivityEvent {id (transcript ID), date, duration}` (clamped ≥0); `CaptureActivityEvent {id (request ID), date, source, attachmentCount}`
  - `record(_:)` adds/replaces one event; `reconcile(recordings:captures:)` backfills pre-ledger history, replacing rather than double-counting existing IDs
  - Normalization dedupes by ID keeping the later date, sorts by date then ID; schemaVersion 1 enforced both directions (newer-schema files never quarantined/overwritten)
  - Corrupt files quarantined to `<file>-corrupt/…<timestamp>[uuid].corrupt`; empty ledger returned
- Constraints: App Group file expected in production
- Evidence: `ActivityStatsStore.swift` (whole file); tests `ActivityStatsStoreTests.swift`
- Status: shipped

### F-CC-25 Capture library store
- Surface: destination/template library persistence (app)
- Summary: `CaptureLibraryStore` (actor) loads/saves the `CaptureLibraryEnvelope` (`capture-library-v1.json`) under file coordination with schema-version enforcement and read-modify-write transactions.
- Details:
  - `load` returns an empty envelope for a missing file; `save` rejects non-current schemaVersion
  - `update(_:)` read-modify-write; `updateReturning(_:)` commits the file and returns a derived value under the same lock (used when an App Group defaults publication must match the committed file exactly)
  - Encoding is pretty-printed, sorted-keys JSON written atomically
  - `legacyFlowBindings` decode-only input from the retired duplicate route-binding map; new saves omit it
- Constraints: none
- Evidence: `CaptureLibraryStore.swift` (whole file); tests `CaptureLibraryStoreTests.swift`
- Status: shipped

### F-CC-26 Draft store durability
- Surface: composer drafts surviving suspension/crash; prepared requests; staging directories
- Summary: `CaptureDraftStore` (actor) persists `CaptureDraft` JSON under `<root>/drafts/`, prepared exact requests under `prepared-requests/`, staging under `staging/<draftID>/`, and quarantines corrupt drafts to `drafts-corrupt/`.
- Details:
  - Draft model: `captureStartedAt` assigned once when substantive content first arrives (`beginCaptureIfNeeded` — route changes/provenance/whitespace-only edits never start it; legacy drafts without substantive content keep nil); `effectiveCreatedAt` = captureStartedAt ?? createdAt; `preserveCaptureStart` merges a durable start into a concurrent in-memory copy without refreshing it
  - Destination semantics: `selectDestination(id:)` (explicit; clears an existing-note override that could cross vault roots), `selectVox(id:)` (returns routing to inherited, clears placement/template overrides and any preset-scoped location outcome — a snapshot belongs to the preset/Send attempt that created it), `useInheritedDestination()`, `inheritDestinationIfEquivalent(to:)` removes redundant explicit destinations from older drafts
  - `rebased(afterSubmitting:)`: converts concurrent edits into a fresh idempotency request — identical text → empty; append-only extension (newline-led) → residual suffix only; prefix-matching payloads → residual payload suffix; arbitrary rewrites kept intact; residual becomes `.standard` delivery (no inherited voice exemption)
  - `makeRequest` requires a resolved destination (`destinationRequired`); derives `voxProcessingState` (pending when preset processing enabled + mode ≠ none + instruction present; applied otherwise; notRequested without preset); uses `captureSource ?? source` and `effectiveCreatedAt`
  - `CapturePreparedRequestReuse.matches` — a prepared request is reusable only when requestID, `originDraftUpdatedAt`, destination, preset ID match and processing isn't pending (immutable snapshot: live preset edits can't invalidate it)
  - Store ops: `save` (preserves capture start from the persisted copy, begins capture as needed), `load`, `journalLocation` (atomic add of the origin-time location outcome/preset snapshot/source with optional voxID guard), `clearLocationJournal` (guarded against stale imports erasing a newer preset/location pair), `loadAll` (newest-first, corrupt drafts quarantined), `complete` (removes draft, prepared request, and best-effort staging), `submit(draftID:operation:)` deletes only the exact submitted version — concurrent edits survive
  - Prepared-request save/load/remove persists the exact processed request before any destination write so a failed delivery retries without rerunning AI or reading changed settings
- Constraints: voice idempotency extras (`stagedRecordingAudioReceipts`, `appliedRecordingTranscriptIDs`) optional so older drafts decode without migration
- Evidence: `CaptureDraftStore.swift` (whole file); tests `CaptureDraftStoreTests.swift` (802 lines)
- Status: shipped

### F-CC-27 Location policy, snapshots & precision
- Surface: preset location settings, capture origin-time acquisition, Watch snapshots
- Summary: `CapturePresetLocationPolicy` defines opt-in origin-time location capture (isEnabled), independent metadata output, precision, unavailable behavior, output mode, and keys; `CaptureLocationSnapshot` stores the privacy-adjusted origin-time value.
- Details:
  - Policy fields: `isEnabled` (default false), `metadataOutputEnabled` (legacy: defaults to isEnabled; disabled/new policies start false), `precision` `.exact`/`.city`, `unavailableBehavior` `.ask`/`.sendWithoutLocation`/`.cancel` (default ask), `outputMode` `.structured`/`.advancedTemplate`, `structuredFields` (default [coordinates, place, appleMapsURL, timestamp, source, id]), `collectionKey` (default `locations`), `advancedTemplate`
  - `CaptureLocationStructuredField` decodes both a legacy bare field and the `{field, outputKey}` shape (renameable keys)
  - `requiresLabels` computed on the pure model (Watch uses it): structured needs labels when any of place/city/region/country selected; advanced when the template references those tokens
  - Snapshot: city precision rounds coordinates to 2 decimals on init and on encode and drops the point-of-interest `place` label before it can enter a durable request; `horizontalAccuracy` optional
  - `CaptureLocationOutcome`: `.available(snapshot)` or `.unavailable(reason, attemptedAt:)` with reasons: permissionDenied, restricted, notDetermined, reducedAccuracy (approximate granted while exact required — must not be labeled exact), timeout, cancelled, unavailable; legacy decode falls back to `legacyUnknownAttemptedAt` (epoch 0)
  - `CaptureWatchLocationAcquisitionPolicy.shouldAcquire` — Watch acquires only when the preset snapshot enables location and `watchOutputMode != "recordingOnly"`
  - `CaptureLocationDecisionOverride.sendWithoutLocation` — request-scoped only, never mutates future captures
- Constraints: reverse geocoding (Apple) needed only when `requiresLabels`; acquisition itself is an app concern
- Evidence: `CaptureLocationMetadata.swift` (lines ~1-345); tests `CaptureLocationMetadataTests.swift` (647 lines)
- Status: shipped

### F-CC-28 Location metadata rendering (structured & advanced YAML templates)
- Surface: location metadata in note frontmatter or inline entry fields
- Summary: `CaptureLocationMetadataRenderer` renders an available snapshot as YAML mapping lines under the collection key (structured mode) or from a constrained YAML template with `{{field}}` placeholders (advanced mode); `CaptureLocationFormatter` produces the formatted field values.
- Details:
  - Formatter fields: coordinates (`lat, lon`), latitude, longitude, place, city, region, country, appleMapsURL, googleMapsURL, openStreetMapURL, geoURI (`geo:lat,lon;u=acc`), accuracy (`N m`), timestamp (ISO8601 with fractional seconds, GMT), source, id (request UUID lowercase)
  - Precision: city → 2 decimals + zoom 10 label fallback city→region→country→pair; exact → 6 decimals + zoom 16 label fallback place→city→pair; coordinates range-checked (±90/±180, finite) else `invalidCoordinate`; accuracy included only when finite and ≥0
  - Structured rendering: `id` always first with `location.id::` inline; per-field output keys validated (alphanumeric/`_`-led, ≤64 bytes; `id` reserved; duplicates rejected); typed YAML values (coordinates as flow number sequence, latitude/longitude/accuracy numbers, rest quoted strings); missing values (e.g., accuracy without data) omitted with their key
  - Advanced mode: template ≤8,192 UTF-8 bytes and ≤128 lines, nesting depth ≤8; constrained parser rejects tabs, odd indentation, comments, `---`/`...`, unsafe scalars (`#`, `: `, `&`, `*`, `!`, `|`, `>`, `<<:`), duplicate keys, malformed `{{…}}`, unknown fields; `id` key reserved; a `{{field}}` resolving to nothing drops the whole mapping entry; root must be a mapping (or a single-item sequence of one)
  - Output bounded to 16,384 UTF-8 bytes; advanced template requires document scope (`advancedTemplateRequiresDocumentScope` when preset scope is `.entry`)
  - Document-scope merge (MarkdownDocumentEditor): appends `id: …`-keyed item lines under the collection key; existing collection parsed with the same constrained parser to detect request-ID presence (already applied → no-op); collisions (non-list value, malformed continuation, `[]` with content, duplicate/missing ids) throw `frontmatterCollision`; `key: []` is converted to a block list
- Constraints: advanced mode gated to Note Frontmatter scope; all limits fail closed
- Evidence: `CaptureLocationMetadata.swift` (lines ~350-1071) incl. `CaptureLocationConstrainedYAMLParser`, `CaptureLocationYAMLRenderer`; `MarkdownDocumentEditor.swift` `validatedLocationCollectionContains`/`appendingLocation`; tests `CaptureLocationLocationMetadataTests` (`CaptureLocationMetadataTests.swift`)
- Status: shipped

### F-CC-29 Voice lifecycle state machine
- Surface: voice capture (app/Watch), audio attachment flows
- Summary: `CaptureVoiceLifecycle` is a pure, generation-guarded state machine (idle → recording → transcribing/review | failed) that makes interruption, retry, cancellation, and late transcription deterministic and testable independently of the audio engine.
- Details:
  - Phases: idle, recording, transcribing, review, failed(microphoneBusy | permissionDenied | couldNotStart | noUsableAudio | encoding)
  - `beginAttempt` increments generation and resets; every transition validates both the generation and the legal source phase (e.g., `encoding` only from recording; start-failures only from idle)
  - `finishRecording(duration:fileExists:fileByteCount:wantsTranscript:modelAvailable:)` → rejectAudio when unusable (duration < `minimumUsableDuration` default 0.3s, or missing/empty file → failed noUsableAudio), transcribeAudio when transcript wanted and model available, else reviewAudio
  - `backgrounded` completes to review (usable audio is kept when the app backgrounds mid-recording); `transcriptionFinished` moves transcribing → review; `cancel`/`inserted` invalidate (generation bump) and reset so late callbacks are ignored
- Constraints: audio engine and transcription model are app concerns
- Evidence: `CaptureVoiceLifecycle.swift` (whole file); tests `CaptureVoiceLifecycleTests.swift`
- Status: shipped

### F-CC-30 Capture Preset request processor (AI post-processing with deterministic fallback)
- Surface: preset processing of typed text, audio transcripts, and OCR text before delivery
- Summary: `CapturePresetRequestProcessor.process` applies the snapshotted preset to every text-bearing payload (text, audio transcript, scanned extracted text) while preserving payload associations; backend failures fall back to deterministic/raw transformations so delivery never depends on AI availability.
- Details:
  - Runs only when `voxProcessingState == .pending` with a profile; always sets state to `.applied`
  - AI results used only when non-empty; otherwise `deterministicText`: todoList mode formats a checklist (existing `- [ ]`/`- [x]` preserved; `- `/`* ` bullets stripped; plain lines split on `.` into capitalized `- [ ]` items; empty result keeps original text); other modes return text unchanged
  - Metadata merge: first non-empty generated title → `frontmatter["title"]` when unset; generated category → `category` (when `category`/`type` unset); tags = preset `staticTags` ∪ generated tags, deduped case-insensitively, serialized as `[a, b]`
  - URL/retainedAudio/image/file/sketch payloads untouched
- Constraints: AI processor injected via `CapturePresetTextProcessing`; none in core
- Evidence: `CaptureVoxRequestProcessor.swift` (whole file); tests `CapturePipelineTests.swift`
- Status: shipped

### F-CC-31 Composer text editor commands (Markdown toolbar)
- Surface: Quick Capture composer formatting bar (app, keyboard, share extension)
- Summary: `CaptureComposerTextEditor` applies selection-aware Markdown edits with no UIKit/SwiftUI dependency; input is LF-normalized with UTF-16 offsets translated before edits, and selections are expanded to composed-character boundaries (emoji/grapheme safe).
- Details:
  - Commands: toggleBold (`**`), toggleItalic (`*`), insertHashtag, heading(level 1-6, out-of-range is a no-op), taskCheckbox (`- [ ] `), bullet (`- `), markdownLink(destination:), wikiLink(target:), replaceSelection(with:), lowercase, uppercase, sentenceCase, capitalizeWords, slugify (plus `bold`/`italic` compatibility aliases)
  - Bold/italic toggling: unwraps a fully-wrapped selection; unwraps surrounding markers when the empty-range cursor sits between an exact marker pair; avoids `***`-run ambiguity for `*`/`**` (`hasExactMarkerRun`, `isExactFullWrapper`)
  - Line-prefix commands operate on every selected line, preserving leading indentation and replacing an existing heading/list prefix (task/bullet/ordered regex `^(?:[-+*][ \t]+(?:\[[ xX]\](?:[ \t]+|$))?|[0-9]+[.)][ \t]+)`) in one pass; selection offsets remapped through the edits
  - Markdown link: selected text becomes the escaped label (destination left selected for typing); no selection → `link text` label selected; provided destination escaped (`\)`, newlines stripped); wiki link: selected text or target or `Note` becomes the body, selected for editing when sensible
  - Text transforms use en_US_POSIX locale; sentence case capitalizes after `. ! ? \n` and start; word capitalization keeps apostrophes inside words (don't → Don'T avoided by tracking in-word state); slugify folds diacritics/width, lowercases, replaces non-alphanumerics with single `-`
  - Selection clamping: location/length clamped to the text; negative length treated as empty; CRLF/CR offsets remapped (`normalizedUTF16Offset`)
- Constraints: none
- Evidence: `CaptureComposerTextEditor.swift` (whole file); tests `CaptureComposerTextEditorTests.swift`
- Status: shipped

### F-CC-32 Insertion formatter (due dates, wiki links, maps links)
- Surface: capture composer due-date shortcuts and metadata insertions
- Summary: `CaptureInsertionFormatter` provides deterministic date output and sanitized Obsidian/Markdown fragment generation with explicit Calendar/Locale/TimeZone injection.
- Details:
  - `dueDateToken(for:includeTime:)` → `(@yyyy-MM-dd[ hh:mm a])`; `currentTimestamp`/`timestamp(for:)` → `h:mm a yyyy-MM-dd`
  - `wikiLink(for:)`: rejects controls, absolute/`~` paths, Windows drive prefixes, `[`, `]`, `|`, and traversal components; normalizes `\`→`/`; strips a case-insensitive trailing `.md`; returns `[[path]]`
  - `googleMapsLink(latitude:longitude:label:)`: validates ranges (±90/±180, finite), POSIX decimal formatting (`%.6f`, `-0` normalized to `0`), Markdown-escaped label
  - Due-date shortcuts (`CaptureDueDateShortcut`): today, tomorrow (+1 day), thisWeekend (returns the reference date when already a weekend; else scans up to 8 days via the calendar); `adjusting(_:by:unit:)` adds minutes/hours with calendar arithmetic (DST/midnight follow the injected calendar)
- Constraints: none
- Evidence: `CaptureInsertionFormatter.swift` (whole file); tests `CaptureInsertionFormatterTests.swift`
- Status: shipped

### F-CC-33 Freemium delivery accounting seam
- Surface: free-capture limit enforcement, "Vox.md Unlimited" upsell
- Summary: `CaptureDeliveryAccounting` (reserve/commit/release) is the durable one-free-capture claim protocol; reservations carry a token so one failed duplicate cannot release another caller's slot. Core ships unmetered by default; the app injects the production metering.
- Details:
  - `CaptureDeliveryReservation`: `.bypassed(requestID:)`, `.alreadyCounted(requestID:)` (idempotency receipt — pipeline returns a receipt without re-mutating), `.reserved(requestID:token:)`
  - Reserve errors (e.g., `CaptureDeliveryQuotaError.limitReached(limit:)` → "You've used all N free captures. Unlock Vox.md Unlimited to keep capturing.") release the process gate and propagate; commit failure keeps the reservation
  - Voice delivery classified as `.meteredVoiceTranscript` bypasses the separate Capture allowance (F-CC-01)
  - Inbox `returnToPending` exists so a quota block is not classified as a delivery failure (F-CC-22)
- Constraints: entitlement gating implemented by the app layer; core only defines the seam
- Evidence: `CapturePipeline.swift` (lines ~40-105, 150-215)
- Status: shipped (gated in product: limit enforcement is app-injected)

## File-by-file coverage checklist (all read completely)

| File | Read | Notes |
|---|---|---|
| ActivityStatsStore.swift | ✅ | F-CC-24 |
| CaptureAssetStager.swift | ✅ | F-CC-12 |
| CaptureAttachmentWriter.swift | ✅ | F-CC-13 |
| CaptureComposerTextEditor.swift | ✅ | F-CC-31 |
| CaptureCoreEnginePolicy.swift | ✅ | F-CC-18 |
| CaptureDateTokenValues.swift | ✅ | F-CC-08 |
| CaptureDeepLinkParser.swift | ✅ | F-CC-19 |
| CaptureDraftStore.swift | ✅ | F-CC-26 (truncated console output re-read via targeted reads of lines 1-40 and model body) |
| CaptureEntryTemplateRenderer.swift | ✅ | F-CC-08/10 |
| CaptureHistoryStore.swift | ✅ | F-CC-23 (head re-read via `head -c 22000`) |
| CaptureInbox.swift | ✅ | F-CC-22 |
| CaptureInputLimits.swift | ✅ | F-CC-20 |
| CaptureInsertionFormatter.swift | ✅ | F-CC-32 |
| CaptureLibraryStore.swift | ✅ | F-CC-25 |
| CaptureLocationMetadata.swift | ✅ | F-CC-27/28 (read in three passes covering lines 1-1071) |
| CaptureMarkdownRenderer.swift | ✅ | F-CC-09 |
| CaptureModels.swift | ✅ | F-CC-01/02/05/06 |
| CaptureOCRMarkdownFormatter.swift | ✅ | F-CC-21 |
| CapturePathPlanner.swift | ✅ | F-CC-08 |
| CapturePipeline.swift | ✅ | F-CC-17 |
| CaptureVaultMarkdownTemplate.swift | ✅ | F-CC-11 |
| CaptureVoiceLifecycle.swift | ✅ | F-CC-29 |
| CaptureVox.swift | ✅ | F-CC-03/04 |
| CaptureVoxRequestProcessor.swift | ✅ | F-CC-30 |
| CoordinatedCaptureWriter.swift | ✅ | F-CC-15/16 |
| MarkdownDocumentEditor.swift | ✅ | F-CC-07 |
| SecureCaptureFileIO.swift | ✅ | F-CC-14 |
| VoxboardCaptureCore.swift | ✅ | Single line: `import Foundation` (empty umbrella file) |

Supplementary test evidence consulted: `Packages/VoxboardShared/Tests/VoxboardCaptureCoreTests/` — 24 test files enumerated; per-file behaviors cross-checked where cited above.

## Uncertainties

- "Journal page handling" (task wording): no type named "journal" exists in the package; the closest verified features are rolling daily/weekly/monthly/quarterly/yearly note targets (F-CC-08) and daily-note-style path templates. Journal-specific behavior, if any, lives in the app layer.
- `VoxboardCaptureCore.swift` is an empty umbrella file (`import Foundation` only); nothing to inventory there.
- Exact UI surfacing (settings screens, buttons) for each core feature is app-layer; "Surface" entries name the app surfaces implied by types/comments, not verified UI code.
- The M2/Rust shared core (F-CC-18) is documented in-code as experimental; whether any shipping build enables shadow mode is decided in the app target and not verifiable from this package.
- Production freemium capture limit number, retention intervals for inbox purges, and history max-records overrides are injected by the app layer; only defaults (500 records, etc.) are verifiable here.
