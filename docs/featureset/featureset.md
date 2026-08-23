# Vox.md Featureset Registry

> The consolidated product featureset, generated from the per-surface inventories
> in [`inventory/`](./inventory/). See [`README.md`](./README.md) for conventions,
> status vocabulary, and maintenance rules.

**Legend:** Status — `shipped` / `gated` (shipped, needs OS/hardware/entitlement) /
`experimental` / `hidden` / `legacy` / `planned`. Platform — `iOS` `iPadOS` `mac`
`watch` `keyboard` `widget` `share` `shortcuts`. Docs — where the feature is
currently documented (`website` = website/docs guide, `readme` = repo README,
`appstore` = App Store metadata, `none` = undocumented gap).

Entry format: `F-ID — Name (platform; status; docs)`

---

## 1. Quick Capture & Input

*(from `inventory/ios-ui.md`; F-CP composer-engine and F-KW extension entries added during their synthesis)*

- F-IU-01 — Root Capture-First Navigation: no tab bar (iOS/iPadOS; shipped; website `#quick-capture`)
- F-IU-02 — Quick Capture Composer: root screen (iOS/iPadOS; shipped; website `#quick-capture`)
- F-IU-03 — Capture Preset Selection Row (iOS; shipped; website `#presets`)
- F-IU-04 — Capture Action Bar: History / Settings / Send / mic / keyboard (iOS; shipped; website `#quick-capture`)
- F-IU-05 — Voice Capture Button: tap / long-press (iOS; shipped; website `#inline-voice`)
- F-IU-06 — Detailed Recording Controls Bar (iOS; shipped; website `#inline-voice`)
- F-IU-07 — Inline Live Transcription Bar: Send Immediately (iOS 26 gated for live text; shipped; website `#inline-voice`)
- F-IU-08 — Keyboard Listening: return guidance & status (iOS/keyboard; shipped; website `#keyboard-workflow`)
- F-IU-09 — Photo / Screenshot Attachment Pickers (iOS; shipped; website `#capture-types`)
- F-IU-10 — Camera Capture (iOS; shipped; website `#capture-types`)
- F-IU-11 — File Attachment Importer (iOS/mac; shipped; website `#capture-types`)
- F-IU-12 — Document Scan: VisionKit, multipage, PDF, OCR (iOS; shipped; website `#capture-types`)
- F-IU-13 — Journal Page Capture & OCR: Capture Text (iOS; shipped; website `#capture-types`)
- F-IU-14 — Sketch Editor: PencilKit (iOS/mac; shipped; website `#capture-types`)
- F-IU-15 — Web Link Prompt (iOS/mac; shipped; website `#capture-bar`)
- F-IU-16 — Attachment Strip (iOS/mac; shipped; website `#durable-drafts`)
- F-IU-17 — Markdown Editor Toolbar: full command set (iOS/mac; shipped; website `#capture-bar`)
- F-IU-18 — Markdown Composer Text Engine & Undo (iOS; shipped; website `#capture-bar` note)
- F-IU-19 — Due Date Sheet: today/tomorrow/weekend ± offsets (iOS/mac; shipped; website `#capture-bar`)
- F-IU-20 — Internal Link Picker: `[[wiki links]]` (iOS/mac; shipped; website `#capture-bar`)
- F-IU-58 — Requested-Input Deep Links: photos/camera/files/scan/sketch/link/voice (iOS; shipped; readme URL-scheme section)
- F-CP-01 — Durable Quick Capture Draft: composer state machine, debounced saves, relaunch recovery (iOS/mac; shipped; website `#durable-drafts`)
- F-CP-03 — Live Transcript Preview in the Composer (iOS 26 gated; shipped; website `#inline-voice`)
- F-CP-04 — Committed Transcript Delivery into the Draft: idempotent, metered (iOS/mac; shipped; website `#pricing-limits` partial)
- F-CP-05 — Recorded-Origin Journaling for imported/external recordings (iOS; shipped; readme)
- F-CP-06 — Staged Attachments: images, files, audio, scans, sketches, URLs; 10-item / 250 MB budget (iOS/mac; shipped; website `#capture-limits`)
- F-CP-07 — OCR "Extract Text" Append to Draft (iOS; shipped; website `#capture-bar`)
- F-CP-08 — Send/Submit Pipeline: prepared-request reuse and rebasing (iOS/mac; shipped; website `#durable-drafts`)
- F-CP-13 — Capture Bar / Toolbar Customization (iOS/mac; shipped; website `#capture-bar`)
- F-CP-14 — Empty-Composer Inspiration Quotes: ZenQuotes, no draft content sent (iOS/mac; shipped; website privacy note)

## 2. Capture Presets & Routing

- F-IU-32 — Capture Presets List Screen (iOS/mac; shipped; website `#preset-management`)
- F-IU-33 — Capture Preset Editor (iOS/mac; shipped; website `#preset-management`)
- F-IU-34 — Preset: Apple Watch Output Mode incl. Recording Only (iOS; shipped; website `#watch-recording-only`)
- F-IU-35 — Preset: Voice Processing — speaker diarization opt-in (iOS; shipped; website `#inline-voice`)
- F-IU-36 — Preset: Capture Processing — AI post-processing opt-in + modes (iOS/mac; shipped; website `#processing-modes`)
- F-IU-37 — Preset: Destination Section (iOS/mac; shipped; website `#destinations`)
- F-IU-38 — Preset: Metadata Scope & Static Frontmatter (iOS/mac; shipped; website `#preset-metadata`)
- F-IU-40 — Destination Library & Editor: vault/Files, note targets, placement, templates, retry protection (iOS/mac; shipped; website `#destinations` + `#placement-templates`)
- F-IU-41 — Preset: Legacy Voice File Export (iOS/mac; **legacy** — compatibility only; website `#audio-export`)
- F-IU-42 — Preset: Voice Audio Handling: save modes + Markdown audio embed (iOS/mac; shipped; website `#audio-export`)
- F-IU-43 — Preset Icon Picker (iOS/mac; shipped; website `#preset-management`)
- F-IU-24 — Destination-Not-Configured Banner & Setup (iOS/mac; shipped; website `#troubleshooting`)
- F-IU-25 — Capture Route Picker: per-capture overrides (iOS/mac; shipped; website `#capture-overrides`)
- F-IU-26 — Folder & Markdown Note Pickers: UIKit (iOS; shipped; website `#destinations`)
- F-CC-01 — Capture Request Model & Payload Kinds: 8 payload types, 10 sources, delivery kinds (all platforms; shipped; readme)
- F-CC-02 — Capture Asset Reference & Path/Filename Validation: traversal/symlink defense (all platforms; shipped; readme security note partial)
- F-CC-03 — Capture Preset Data Model: full profile fields incl. location/metadata/processing/audio (all platforms; shipped; website `#presets`)
- F-CC-04 — Preset Selection & Route Resolution precedence (all platforms; shipped; readme partial)
- F-CC-05 — Destination Kinds & Note Targets: new/rolling(5 periods)/existing (all platforms; shipped; website `#destinations`)
- F-CC-06 — Placement: append/prepend/beneath-heading L1–6, missing-heading fail/create (all platforms; shipped; website `#placement-templates`)
- F-CC-07 — Entry Formatting: YAML frontmatter merge, multiline entries, inline fields (all platforms; shipped; website `#preset-metadata`)
- F-CC-08 — Rolling Note Path Planning & Date Tokens incl. {period}/{week} (all platforms; shipped; website `#destinations`)
- F-CC-09 — Markdown Entry Rendering: payload → Markdown blocks, embeds, wiki/file links (all platforms; shipped; readme)
- F-CC-10 — Entry Templates Library + per-destination prefix/suffix (all platforms; shipped; website `#placement-templates`)
- F-CC-11 — Vault Markdown Templates: live file binding, Templater-style expressions (all platforms; shipped; website `#placement-templates`)
- F-CC-12 — Attachment Staging with content-type detection & limits (all platforms; shipped; website `#capture-limits`)
- F-CC-13 — Attachment Writing & Duplicate Reuse (all platforms; shipped; readme partial)
- F-CC-14 — Secure Capture File I/O: descriptor-based (all platforms; shipped; internal)
- F-CC-15 — Coordinated Cross-Process Writes (all platforms; shipped; readme partial)
- F-CC-16 — Retry Protection & Idempotency: markers, receipts, tombstones (all platforms; shipped; website `#placement-templates` partial + `#pricing-limits`)
- F-CC-17 — Capture Pipeline Stages & Process Gate: location validation → render → write → accounting (all platforms; shipped; internal core)
- F-CC-18 — Engine Policy: legacy/shadow/Rust routing (M2 Android parity experiment; **experimental**; docs: none — internal)
- F-CC-19 — Deep Link Parsing: every URL parameter + validation rules (all platforms; shipped; readme URL-scheme section)
- F-CC-20 — Input Limits & Bounded Input Budget: 100k/10/250MB transactional (all platforms; shipped; website `#capture-limits`)
- F-CC-21 — OCR to Markdown Formatting (all platforms; shipped; website `#capture-types`)
- F-CC-25 — Capture Library Store: schema-versioned envelope, migration (all platforms; shipped; internal)
- F-CC-26 — Draft Store Durability (all platforms; shipped; website `#durable-drafts`)
- F-CC-29 — Voice Lifecycle State Machine (all platforms; shipped; internal)
- F-CC-30 — Preset Request Processor: AI post-processing with deterministic fallback (all platforms; shipped; website `#processing-modes`)
- F-CC-31 — Composer Text Editor Commands: Markdown toolbar engine (all platforms; shipped; website `#capture-bar`)
- F-CC-32 — Insertion Formatter: due dates, wiki links, maps links (all platforms; shipped; website `#capture-bar`)
- F-CC-33 — Freemium Delivery Accounting Seam (all platforms; shipped; internal)

## 3. Location

- F-IU-21 — Current Location Insertion: one-shot Maps link action (iOS/mac; shipped; website `#capture-bar` + location guide)
- F-IU-22 — Location-Unavailable Decision Dialogs: retry/cancel/send-without/always (iOS/mac; shipped; website `location/`)
- F-IU-23 — {location} Token Hint & One-Tap Enable (iOS/mac; shipped; website `location/`)
- F-IU-39 — Preset: Location Configuration: exact/city, structured fields, advanced YAML (iOS/mac; shipped; website `location/`)
- F-CP-09 — Location-Unavailable Decision Flow: ask/cancel/send-without/always-for-preset, journaled (iOS/mac; shipped; website `location/`)
- F-CP-20 — Location Configuration Preview in preset editors (iOS/mac; shipped; website `location/`)
- F-CP-21 — {location} Entry-Template Token: detection, hint, one-tap enable, sample preview (iOS/mac; shipped; website `location/`)

## 4. Voice Recording & Transcription

*(from `inventory/ios-core.md`; shared-package entries added during F-SH synthesis)*

- F-IC-01 — Persistent Microphone Listener & Circular Buffer Recorder (iOS; shipped; website `#audio-pipeline`)
- F-IC-02 — Recording Completion Modes & Command Origins (iOS/mac; shipped; website `#inline-voice`)
- F-IC-03 — Keyboard IPC Command Channel: Darwin notifications + file polling (iOS/keyboard; shipped; readme partial)
- F-IC-04 — One-Shot In-App / Widget / Shortcut Recording (iOS/widget/shortcuts; shipped; readme)
- F-IC-05 — Audio File Import Pipeline (iOS/mac; shipped; website `#inline-voice`)
- F-IC-06 — Durable Recording Queue & Job Execution (iOS/mac; shipped; website `#history` partial)
- F-IC-07 — Transcription Orchestration, Progress & Delivery (iOS; shipped; website `#models`)
- F-IC-08 — Live (Streaming) Transcription Preview (iOS 26 gated; website `#automatic-model`)
- F-IC-13 — Apple Speech Transcription Backend: Batch + Live (iOS 26 gated; website `#automatic-model`)
- F-IC-14 — Legacy Keyboard Transcription IPC Server (iOS/keyboard; **legacy — superseded by segment flow, still active**; readme partial)
- F-IC-19 — Live Segment Transcription Coordinator (iOS/keyboard; shipped; website `#keyboard-workflow`)
- F-IC-20 — Voice Auto-Stop: Voice Pause Detection (iOS/keyboard; gated on companion model; website `#parakeet-autostop`)
- F-IC-21 — Keyboard Recording Artifact Retention (iOS/keyboard; shipped; readme)
- F-SH-01 — App Group Container & Shared Configuration (all platforms; shipped; internal)
- F-SH-02 — Voice Auto-Stop Preferences (pause thresholds, companion model) (iOS/keyboard; shipped; website `#parakeet-autostop`)
- F-SH-05 — Microphone Recording: AudioRecorder (all; shipped; internal)
- F-SH-06 — Audio File Conversion (16kHz mono WAV for whisper) (all; shipped; internal)
- F-SH-07 — Incremental WAV Writer (all; shipped; internal)
- F-SH-08 — Circular Audio Buffer: 10-min ring + 2s pre-roll (iOS; shipped; website `#audio-pipeline`)
- F-SH-10 — File-Based Keyboard↔App IPC: TranscriptionIPC (iOS/keyboard; shipped; readme partial)
- F-SH-12 — Live Transcript Draft Preview Reconciliation (iOS; shipped; internal)
- F-SH-13 — Keyboard Live-Transcription Delivery Reducer (iOS/keyboard; shipped; internal)
- F-SH-14 — Transcription Insertion Planning: batch vs live reconciliation (iOS/keyboard; shipped; internal)
- F-SH-16 — On-Device Transcription Dispatcher (all; shipped; readme)
- F-SH-17 — whisper.cpp Backend: WhisperContext (all; shipped; website `#models`)
- F-SH-18 — Parakeet CoreML Backend: ParakeetContext (all; shipped; website `#models`)
- F-SH-21 — Model Download Transport & Manager: HF/FluidAudio, progress, cancel, delete (iOS/mac; shipped; website `#models`)
- F-SH-22 — Voice Activity Detection: Silero VAD (iOS/keyboard; gated on companion model; website `#parakeet-autostop`)
- F-SH-04 — Async Exclusive Gate utility (all; shipped; internal)
- F-SH-15 — Transcription Backend Model & Progress Types: truthful progress semantics (all; shipped; internal)
- F-SH-19 — Model Catalog & Integrity: 7-model registry, header/size validation (all; shipped; website `#model-options`)
- F-SH-20 — External Model Locations: macOS in-place use (mac; shipped; appstore release note)
- F-SH-11 — Live Activity Command Building & State (iOS; shipped; internal)
- F-SH-48 — Capture Bookmark Resolution: security-scoped + staleness (iOS/mac; shipped; internal)
- F-SH-49 — Smart Folders & Auto-Organize (all; **legacy — dormant off-by-default**; docs: none, intentionally)
- F-SH-51 — CaptureCore Re-Export surface (all; shipped; internal)

## 5. AI Enrichment

- F-IC-15 — Apple Intelligence / Foundation Models Backend (iOS/macOS 26 gated; website `#processing-modes`)
- F-SH-23 — Speaker Diarization: anonymous best-effort labels, 6 skip reasons (iOS/mac/watch; shipped; website `#inline-voice` + llms.txt)
- F-SH-24 — Meeting Capture Domain: dual stems, manifest v2, timeline, lifecycles (mac; shipped; appstore release note)
- F-SH-25 — Meeting Chunk Sample Writer: 30s AAC chunks, receipts, rollover (mac; shipped; internal)
- F-SH-38 — Capture AI Text Processing Bridge: opt-in enrichment persistence (all; shipped; website `#presets`)
- F-SH-39 — On-Device LLM Enrichment: TranscriptEnricher (all; iOS/macOS 26 gated; website `#processing-modes`)
- F-SH-40 — Deterministic Flow Formatter: AI fallback for Todo/Meeting modes (all; shipped; website `#processing-modes` fallback table)
- *(SmartFolder routing / auto-organize folder naming exist in F-IC-15's backend but are dormant product surfaces — registry records them as legacy; see llms.txt scope notes)*

## 6. Entry Points & System Integration

*(from `inventory/ios-core.md`; F-CP / F-KW entries added during their synthesis)*

- F-IC-27 — Record App Intent & Widget Flow Selection (iOS; shipped; website `#shortcuts`)
- F-IC-28 — Quick Capture Open Intent (iOS/mac; shipped; website `#shortcuts`)
- F-IC-29 — App Shortcuts Provider: Siri Phrases (iOS; shipped; readme)
- F-IC-31 — App Lifecycle, Composition Root & Entry Points (incl. deep links `capture`/`capture-request`/`listen`/`record`/`widget-record`) (iOS; shipped; readme URL-scheme section)
- F-IC-17 — Live Activity Controller (iOS 16.1+; shipped/gated; website `#control-center-live-activities`)
- F-IC-18 — Live Activity Recording Intents (iOS; shipped; website `#control-center-live-activities`)
- F-IC-22 — Capture Inbox Background Drain: BGProcessingTask (iOS; shipped; readme partial)
- F-CP-11 — Deep-Link Composer Intake: `handleDeepLink` open/process paths (iOS/mac; shipped; readme URL-scheme section)
- F-CP-15 — App Intents Entities & Queries: presets, destinations (iOS/mac; shipped; website `#shortcuts`)
- F-CP-16 — App Intents: Capture Text / Link / File background enqueue with location policy (iOS/mac; shipped; website `#shortcuts`)
- F-CP-17 — App Intents: Composer-Opening Intents: Open Quick Capture / Record a Capture / Screenshot / Scan (iOS/mac; shipped; website `#shortcuts`)
- F-CP-18 — Mac App Shortcuts Provider (mac; shipped; readme)
- F-KW-01 — Keyboard Activation & Setup: persistent-listening architecture, no audio in extension (iOS/keyboard; shipped; website `#keyboard-setup`)
- F-KW-02 — Full Access Requirement gating (iOS/keyboard; shipped; website `#keyboard-setup`)
- F-KW-03 — Persistent Listening + IPC Segment Control: start/stop without app switching (iOS/keyboard; shipped; website `#keyboard-workflow`)
- F-KW-04 — Listening-State Heartbeat Freshness & "Open Vox.md" Prompt (iOS/keyboard; shipped; website `#keyboard-workflow`)
- F-KW-05 — Streaming Insertion: finalized deltas insert, tentative tail display-only (iOS/keyboard; iOS 26 gated; shipped; website `#keyboard-workflow`)
- F-KW-06 — Session Recovery Across Keyboard Reload/Suspension (iOS/keyboard; shipped; website `#keyboard-workflow`)
- F-KW-07 — Model Selection from Keyboard: ‹ MODEL › navigator (iOS/keyboard; shipped; website `#keyboard-customization`)
- F-KW-08 — Capture Preset Selection from Keyboard (iOS/keyboard; shipped; internal)
- F-KW-09 — Free-Tier Usage Limit Enforcement in Keyboard (iOS/keyboard; shipped; website `#keyboard-customization`)
- F-KW-10 — Sound Wave Visualization (iOS/keyboard; shipped; website `#keyboard-workflow`)
- F-KW-11 — Voice-Pause Auto-Stop from Keyboard (iOS/keyboard; gated on companion model; shipped; website `#parakeet-autostop`)
- F-KW-12 — Callout Actions: long-press accent alternates, 10 languages (iOS/keyboard; shipped; website `#keyboard-customization`)
- F-KW-13 — Keyboard Haptics Setting (iOS/keyboard; shipped; website `#keyboard-customization`)
- F-KW-14 — Keyboard Debug Logging (iOS/keyboard; shipped; internal)
- F-KW-15 — Recording Artifact Retention: WAV + journal receipts (iOS/keyboard; shipped; internal)
- F-KW-16 — Pending-Text Data Retention: insert on next appearance (iOS/keyboard; shipped; website `#keyboard-workflow`)
- F-KW-17 — Widget Bundle Composition: 5 widgets, availability-gated (iOS/widget; shipped; internal)
- F-KW-18 — Quick Record Widget: lock screen + home screen (iOS/widget; shipped; website `#widgets`)
- F-KW-19 — Widget Recording Flow Selection (iOS/widget; shipped; internal)
- F-KW-20 — Quick Capture Widget: multi-action grid, preset-aware deep links (iOS/widget; shipped; website `#widgets`)
- F-KW-21 — Live Activity + Dynamic Island (iOS; shipped; website `#control-center-live-activities`)
- F-KW-22 — Record Control (Control Center / lock-screen bottom slot, iOS 18) (iOS; gated iOS 18; shipped; website `#control-center-live-activities`)
- F-KW-23 — Quick Capture Control (Control Center, iOS 18) (iOS; gated iOS 18; shipped; website `#control-center-live-activities`)
- F-KW-24 — Share Extension UI & Load Flow (iOS/share; shipped; website `#share-extension`)
- F-KW-25 — Accepted Input Types & limits (iOS/share; shipped; website `#share-extension`)
- F-KW-26 — Preset Routing & Destination Resolution (iOS/share; shipped; website `#share-extension`)
- F-KW-27 — Inbox Claim Flow: queue → open app (iOS/share; shipped; website `#share-extension`)
- F-KW-28 — Location Policy Handling in Share Sheet (iOS/share; shipped; website `#share-extension`)
- F-KW-29 — Optional Capture Note (iOS/share; shipped; website `#share-extension`)

## 7. Apple Watch

*(from `inventory/ios-core.md`; F-WT watch-side entries added during their synthesis)*

- F-IC-09 — Watch Remote Recording Control: WCSession, preset epoch/ack protocol, state snapshots (iOS⇄watch; shipped; website `#watch-recording`)
- F-IC-10 — Watch Recording Inbox: durable per-item sidecars, privacy tombstones, orphan recovery (iOS; shipped; website `#watch-queue` partial)
- F-IC-11 — Watch Recording Pipeline: phone-side transcribe/enrich/deliver incl. Recording-Only + capture-without-transcript paths, limit handling, retry/discard (iOS; shipped; website `#watch-queue`)
- F-IC-12 — Watch Background Execution Lease: exactly-once UIBackgroundTask ownership, drain policy (iOS; shipped; readme partial)
- F-WT-01 — Watch Local Recording: AAC 16kHz mono, journaled before record, deep links `voxboardwatch://start|stop|toggle-recording` (watch; shipped; website `#watch-recording`)
- F-WT-02 — Pause / Resume Recording (watch; shipped; website `#watch-recording`)
- F-WT-03 — Cancel Recording: delete without sync (watch; shipped; website `#watch-recording`)
- F-WT-04 — Recording Timer (watch; shipped; internal UI)
- F-WT-05 — Recorder State Machine & Status UI: 10-phase (watch; shipped; website `#watch-recording`)
- F-WT-06 — Watch Design System: Geist-on-watch (watch; shipped; internal)
- F-WT-07 — Capture Preset Selection on Watch: pending-confirmation UX (watch; shipped; website `#watch-presets`)
- F-WT-08 — Durable Local Recording Queue: interrupted-capture recovery, safe filenames (watch; shipped; website `#watch-recording`)
- F-WT-09 — Watch→iPhone File Transfer: WatchConnectivity (watch/iOS; shipped; website `#watch-recording`)
- F-WT-10 — Remote Status Reconciliation & Claim/Ack Protocol (watch/iOS; shipped; internal)
- F-WT-11 — Snapshot State Model & Epoch/Staleness Protection (watch/iOS; shipped; internal)
- F-WT-12 — Watch Location Capture: one-shot, per preset policy, Watch-origin (watch; shipped; website `#watch-recording`)
- F-WT-13 — Record Widget / Complication: 4 families, 10-phase rendering (watch; shipped; website `#watch-complication`)
- F-WT-14 — Sync Queue / Refresh Status Button (watch; shipped; website `#watch-recording`)
- F-WT-15 — Command Protocol & Unreachable-Phone Fallbacks (watch/iOS; shipped; internal)
- F-WT-16 — Microphone Permission Handling (watch; shipped; internal)
- F-WT-17 — Widget Snapshot Publication (watch; shipped; internal)
- F-WT-18 — DEBUG Demo & Screenshot Modes (watch; **hidden**; internal)
- F-WT-19/20/21 — Recording-Only context, background lease context, data-retention cross-cutting — see F-IC-11/12 and category 12 (watch/iOS; shipped)

## 8. macOS Companion

*(from `inventory/mac-app.md`)*

- F-MC-01 — Main Navigation Window: Capture / Recording Queue / History / Settings (mac; shipped; website `#mac`)
- F-MC-02 — Transcription Model Selection & Download: Whisper / Parakeet / Apple Speech (mac; shipped; website `#mac-history`)
- F-MC-03 — Capture Preset (Vox) Library Management (mac; shipped; website `#presets`)
- F-MC-04 — Capture Workspace: Draft Composer, Attachments, Recording Controls (mac; shipped; website `#mac-workspace`)
- F-MC-05 — Capture Route Inspector: Per-Capture Route Overrides (mac; shipped; website `#capture-overrides`)
- F-MC-06 — Temporary Transcription: Transcribe to Clipboard (mac; shipped; website `#mac-keybinds`)
- F-MC-07 — Global Keyboard Shortcuts / Hotkeys (mac; shipped; website `#mac-keybinds`)
- F-MC-08 — Keyboard Hints: Control-B Vimium-style Click Labels (mac; hidden; **docs: none — undocumented by design**)
- F-MC-09 — Menu Bar Operation (mac; shipped; website `#mac-menu-bar`)
- F-MC-10 — App Visibility Modes: Dock / Menu Bar / Hidden (mac; shipped; website `#mac-menu-bar`)
- F-MC-11 — Window Coordination, Deep Links, Termination Safety (mac; shipped; readme URL-scheme section)
- F-MC-12 — Markdown Composer: AppKit Text Engine (mac; shipped; website `#mac-workspace`)
- F-MC-13 — Microphone Recording: Queue-Backed, Crash-Safe (mac; shipped; website `#mac-workspace`)
- F-MC-14 — Origin-Time Location Resolution: Crash-Safe Journaling (mac; shipped; website `location/`)
- F-MC-15 — Audio & Video Import for Transcription (mac; shipped; website `#mac-workspace`)
- F-MC-16 — Meeting Capture: ScreenCaptureKit + Mic, App Picker, Dual Stems (mac; shipped; website `#mac-meeting` + appstore release note — gap closed 2026-08-22)
- F-MC-17 — Meeting Pipeline: Normalize, Mix, Dual-Stem Transcription, Timeline (mac; shipped; website `#mac-meeting` — gap closed 2026-08-22)
- F-MC-18 — Preset-Driven Capture Export & Apple Intelligence Enrichment (mac; gated macOS 26 + Apple Intelligence; website `#models`)
- F-MC-19 — Speaker Diarization: Identify Speakers (mac; shipped; website `#inline-voice`)
- F-MC-20 — Capture Destination Library: Vault Routing (mac; shipped; website `#destinations`)
- F-MC-21 — Entry Template Library (mac; shipped; website `#placement-templates`)
- F-MC-22 — History Browsing, Search, Detail, Delete, Reveal (mac; shipped; website `#mac-history`)
- F-MC-23 — Recording Queue: Retry & Recovery (mac; shipped; website `#history`)
- F-MC-24 — StoreKit Purchases & Paywall: Individual / Family / Family Upgrade (mac; shipped; website `#pricing-limits`)
- F-MC-25 — Settings Surface: Companion Info, Configuration, Keybinds, Visibility, About, Debug (mac; shipped; website `#settings-map` partial)
- F-MC-26 — Camera Capture: Photo into Capture (mac; shipped; website `#mac-workspace`)
- F-MC-27 — Sketch Editor (mac; shipped; website `#mac-workspace`)
- F-MC-28 — Document Scan Processing: OCR + PDF (mac; shipped; website `#capture-types` iOS-focused)
- F-MC-29 — Retry Inbox Draining & Folder-Permission Recovery (mac; shipped; readme)
- F-MC-30 — Data Folder & Local Storage (mac; shipped; readme partial)
- F-MC-31 — App Shortcuts / Deep-Link Entrypoints (mac; shipped; readme URL-scheme section)

## 9. History, Stats & Data Management

- F-IU-27 — Watch Recording Status Card & Queue Entry (iOS; shipped; website `#watch-queue`)
- F-IU-28 — Watch Recording Queue Sheet: retry/reassign/discard/capture-without-transcript (iOS; shipped; website `#watch-queue`)
- F-IU-47 — History Screen: unified transcripts + capture records, search (iOS; shipped; website `#history`)
- F-IU-48 — Transcript Edit Sheet: title/tags/category/cleaned/raw (iOS/mac; shipped; website `#history`)
- F-IU-49 — Transcript Export & Share (iOS/mac; shipped; website `#history`)
- F-IU-50 — Stats Screen: private activity totals, 7-day chart, source breakdown (iOS; shipped; website `#stats` + readme — gap closed 2026-08-22)
- F-IU-55 — Error Banner & Queued-Capture Retry (iOS/mac; shipped; website `#history`)
- F-IU-56 — File Export Toast (iOS; shipped; internal polish)
- F-IU-31 — Debug Log Viewer (iOS; shipped; website `#settings-map` Debug row)
- *(Private Activity Stats: ledger stays on device, excludes content/filenames/destinations — anchored first-hand in ActivityStatsStore.swift)*
- F-SH-09 — Keyboard Debug Log (iOS/keyboard; shipped; internal)
- F-SH-26 — Transcript Record Model (all; shipped; internal)
- F-SH-27 — Transcript Store: history persistence, cross-process coordination (all; shipped; readme)
- F-SH-28 — Transcript Search: raw/cleaned/title/tags/category (all; shipped; website `#history`)
- F-SH-29 — Activity Stats Ledger (all; shipped; readme)
- F-SH-30 — Capture Presets (RecordingFlow): persisted model & store incl. watch/voice settings (all; shipped; website `#presets`)
- F-SH-31 — Recording Job Queue & Store: durable jobs, sources, retention (iOS/mac; shipped; website `#history` partial)
- F-SH-35 — Capture Inbox Delivery Service (all; shipped; readme)
- F-SH-37 — Recording Origin Store (iOS; shipped; internal)
- F-SH-44 — External File Delivery Transactions: crash-safe publishing (all; shipped; internal)
- F-SH-46 — Watch Recording-Only File Export (watch/iOS; shipped; website `#watch-recording-only`)
- F-SH-47 — Transcript → Capture Destination Export (all; shipped; internal)

## 10. Monetization & Entitlements

- F-IC-16 — StoreKit Purchases, Entitlements & Restore (iOS; shipped; website `#pricing-limits`)
- F-SH-32 — Usage Metering: free transcription minutes, idempotent receipts (all; shipped; website `#pricing-limits`)
- F-SH-33 — Usage Metering: free Capture deliveries, Keychain high-water mark (all; shipped; website `#pricing-limits`)
- F-SH-34 — Purchase Access Model: individual/family/upgrade levels (all; shipped; website `#pricing-limits`)
- Free-tier quotas (15 min / 10 captures), receipt-idempotent usage ledger, Keychain high-water mark, legacy paid-app grandfathering, individual/family access levels — evidence anchored first-hand in `UsageTracker.swift` + `CaptureDeliveryUsageStore.swift`

## 11. Settings & Preferences

*(F-IU-29..53 settings entries added after ios-ui normalization; support features from `inventory/ios-core.md`)*

- F-IU-29 — Settings Screen: MetaSettingsView hub (iOS; shipped; website `#settings-map`)
- F-IU-30 — Capture Bar Customization: reorder/hide actions (iOS; shipped; website `#capture-bar`)
- F-IU-44 — Models Screen: download/select/delete, language (iOS/mac; shipped; website `#models`)
- F-IU-45 — Voice Auto-Stop Configuration (iOS/keyboard; shipped; website `#parakeet-autostop`)
- F-IU-46 — Transcription Language Picker (iOS/mac; shipped; website `#model-languages`)
- F-IU-51 — Paywall: Vox.md Unlimited (iOS/mac; shipped; website `#pricing-limits`)
- F-IU-52 — Recording Flow Screen: keyboard-relay recording (iOS; shipped; readme partial)
- F-IU-60 — Release-Notes Focus Deferral (iOS; shipped; internal)
- F-IC-23 — App Store Review Prompt Manager: usage-day + retry gating (iOS; shipped; **docs: none — internal, intentionally undocumented**)
- F-IC-24 — Feedback Helper: diagnostic email + Discord (iOS/mac; shipped; website `#troubleshooting`)
- F-IC-25 — Release Notes Viewer: post-update what's-new (iOS; shipped; website `#settings-map`)
- F-IC-26 — Geist Design System & Theme (iOS/mac; shipped; **docs: none — internal design system**)
- F-IC-30 — App Delegate: Early WatchConnectivity Activation (iOS; shipped; internal)

## 12. Privacy & Data Handling

*(capture-core + shared-core entries; F-WI worker privacy contract added during its synthesis)*

- F-CC-22 — Durable Capture Inbox: queue states, content-free tombstones after delivery (all platforms; shipped; website `#privacy-data`)
- F-CC-23 — Capture History Store: coarse metadata only, retention, quarantine, legacy sanitization (all platforms; shipped; website `#privacy-data`)
- F-CC-24 — Activity Stats Store: content-free lifetime ledger (all platforms; shipped; readme)
- F-CC-27 — Location Policy, Snapshots & Precision: exact/city, one origin-time fix (all platforms; shipped; website `location/`)
- F-CC-28 — Location Metadata Rendering: structured fields + advanced YAML, idempotent capture-ID collection (all platforms; shipped; website `location/`)
- F-SH-03 — In-App Language Override: shared defaults, launch reconciliation (iOS; shipped; website `#settings-map`)
- F-SH-36 — Capture Location Service: one-shot origin fix, privacy adjustment (all; shipped; website `location/`)
- F-SH-41 — Transcript File Export: TXT/MD/YAML/JSON, templates, frontmatter merge, audio refs (all; legacy compatibility path; website `#audio-export`)
- F-SH-42 — Obsidian-Style Template Rendering (all; shipped; website `#placement-templates`)
- F-SH-43 — ExportKit Adapter (all; shipped; internal)
- F-SH-45 — Audio Attachment Export: M4A, checkpointed delivery (all; shipped; website `#audio-export`)
- F-SH-50 — Onboarding Analytics: 13-event funnel, first-party worker, production default-off (iOS/mac; shipped; docs/onboarding-analytics.md)
- *(Model downloads contact Hugging Face/FluidAudio — privacy note in website `#privacy-data`)*

## 13. Localization & Accessibility

- F-IU-53 — In-App Language Override: 23 languages + System; native-script names; `AppleLanguages` mirror applies next launch; explicit system-sentinel vs never-set preserved (iOS; shipped; website `#settings-map`; anchored first-hand in `AppLanguagePreference.swift`)
- F-IU-59 — OCR progress VoiceOver announcements (iOS; shipped; website `#capture-types` a11y note — gap closed 2026-08-22)
- *(App Store localization surface: 40 locales of metadata — recorded in category 15 from F-WI inventory)*
- *(Keyboard alternate-character callouts: 10 languages — recorded in category 6 from F-KW inventory)*

## 14. In-Development Platform: Android/Wear

*(from `inventory/android-port.md`; 45 entries. Milestone roadmap: M0 ✅ · M1 ✅ · M2 ✅ hosted-qualified (rev `450abca`) · M3 in progress — foundations qualified, vertical slice incomplete · M4–M10 pending. **All entries below are planned/experimental; none shipped.**)*

- F-AP-01..06 — Contract families: capture-preparation-input, required-observations, capture-materialization-input, artifact-plan, wearable-protocol, core-api/UniFFI (planned; contract-level, implemented in Rust/Kotlin substrate)
- F-AP-07..29 — ADR-defined capabilities: shared-core ownership, exact Markdown parity, prepared-plan commit barrier, existing-note retry markers, template/observation freeze, backup exclusion, wear ack/retention/recording-only, Play Billing isolation, quota reinstall grandfathering, location-label consent, advanced local intelligence, bounded UniFFI sessions, fixture mirror sequencing, offline ASR baseline, IME visible-activity fallback, toolchain pinning, core API readiness, durable package/journal authority, SAF ambiguity reconciliation, codec v1 durable enqueue, journal lease/quota Room v2, lazy UniFFI packaging, prepared-artifact SAF executor (ADR-0001..0023; planned/experimental — substrate tested on JVM/Pixel 7, not production-wired)
- F-AP-30..45 — Planned Android product capabilities: text/link capture, onboarding+SAF picker, durable inbox/history tombstones, foreground-service voice recording, local transcription+models, transcript editing/search/history, Markdown editor/Capture Bar/presets/templates, multimodal inputs, preset location, stats/quota, system entry points (Sharesheet/shortcuts/Glance/Quick Settings/Live-Activity-equivalent), Android IME, Wear OS app, Play Billing lifetime purchase, queue scheduling/recovery, security/privacy baseline (planned; M4–M9 scope)

## 15. Supporting Surfaces

*(from `inventory/web-infra.md`; supporting surfaces, not app features)*

- F-WI-01 — Domain Redirect Worker: 308 → vox.isolated.tech (supporting; internal)
- F-WI-02 — Onboarding Analytics Worker: D1 ingestion, 13-event whitelist, coarse buckets only, content rejected, optional token, **production disabled by default** (supporting; docs/onboarding-analytics.md)
- F-WI-03 — Website Homepage (supporting; self-documenting)
- F-WI-04 — Website Documentation Hub: 10-section feature guide (supporting; the primary docs surface)
- F-WI-05 — Website Location Deep-Dive: 14 subsections (supporting)
- F-WI-06 — Website Blog: voice-to-text keyboard SEO post (supporting)
- F-WI-07 — Privacy Policy & Terms pages (supporting; legal)
- F-WI-08 — llms.txt (LLM fact sheet) + sitemap + robots (supporting; llms.txt mirrors docs)
- F-WI-09 — App Store Metadata Pipeline: fastlane, 40 locale dirs (supporting; appstore)
- F-WI-10 — App Store Strings Packages: 38-locale description/keywords/whatsNew + 38-locale app-info (supporting; appstore)
- F-WI-11 — App Store Privacy Declaration: 3 Analytics/Not-Linked categories (supporting; legal)
- F-WI-12 — In-App Runtime Localization: 23-locale catalogs, 1,389 keys, glossary, remediation table, screenshot matrices (supporting; process + app UI)
- F-WI-13 — Support & Changelog Surface: email-only support, per-locale whatsNew, no web changelog (supporting)

---

## Documentation gap register

Derived from the `docs:` dispositions above and verified against all doc surfaces
(website docs, README, llms.txt, App Store metadata).

### Real gaps — shipped features without user-facing docs

**All closed 2026-08-22** — documented in `website/docs/index.html` and mirrored in `website/llms.txt`:

| ID | Feature | Resolution |
|---|---|---|
| F-MC-16/17 | Mac Meeting Capture + dual-stem pipeline | Added `#mac-meeting` subsection to website docs `#mac` |
| F-IU-50 | Private Activity Stats screen | Added `#stats` subsection to `#history-settings` |
| F-IU-59 | OCR progress VoiceOver announcements | Added a11y note to `#capture-types` |

No open real gaps remain. New gaps should be added here as they are discovered.

### Intentionally undocumented (document the decision, not the feature)

| ID | Feature | Rationale |
|---|---|---|
| F-MC-08 | ⌃B keyboard hints (Mac) | Power-user easter egg; discovery is the feature |
| F-IC-23 | Review prompt policy | Internal growth mechanics |
| F-IC-26 | Geist design system | Internal implementation detail |
| F-CC-18 | Engine policy (Rust shadow routing) | Experimental M2 parity substrate |
| F-SH-49 | Smart Folders / Auto-Organize | Dormant off-by-default; llms.txt scope notes exclude from shipped docs |
| F-WT-18 | Watch DEBUG demo/screenshot modes | Debug-only |

### Legacy surfaces that docs must not present as current

- F-IU-41 / F-SH-41 — Legacy Voice File Export (kept for un-migrated presets only; docs already label it compatibility)
- F-IC-14 — Legacy IPC transcription server (superseded by persistent recorder segment flow)
- F-IU-52 — Recording flow screen (retained; primary path is inline recorder)

### Docs-coverage summary

- 270+ of 277 registry entries map to at least one docs surface.
- Website docs guide is current and thorough; the three known gaps were closed on 2026-08-22, so the shipped-feature docs coverage is complete as of that date.
