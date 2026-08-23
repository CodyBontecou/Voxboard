# Vox.md — VoxboardShared Package Feature Inventory

Package: `Packages/VoxboardShared/Sources/VoxboardShared/` (+ `Analytics/`). All paths below are relative to that directory. This package backs iOS app, Mac app, keyboard extension, widgets, Watch app, Live Activity, and share extension via the shared App Group (`group.bontecou.Voxboard`).

---

### F-SH-01 App Group container & shared configuration
- Surface: all targets (app, Mac, keyboard, widgets, Watch, share extension)
- Summary: `AppConstants` defines the App Group identifier, directory layout (`WhisperModels/`, `Recordings/RecordingJobs/`, `Capture/`), every shared `UserDefaults` key, and computed container URLs. It is the single source of truth for cross-process storage.
- Details:
  - `sharedContainerURL` falls back on macOS to `~/Library/Application Support/Voxboard` when unsigned dev builds lack an App Group; nil elsewhere.
  - DEBUG-only `VOXBOARD_SHARED_CONTAINER_OVERRIDE` environment variable redirects the container for tests.
  - `sharedDefaults` uses `UserDefaults(suiteName:)`; macOS falls back to `.standard` when the App Group is unavailable.
  - URL scheme `voxboard://` with `recordURL(model:lang:requestId:)` builder for keyboard→app launches.
  - Keys: selected model/language/fallback model, external model bookmarks, transcription selection migration, `automaticTranscriptionBackendReady`, capture usage files/mirror, capture history/library/activity stats, file-export settings (12+ keys), haptics, auto-listen, live activity/lock-screen toggles, pending widget/quick-capture handoff keys, smart folders, auto-organize, enrichment export toggles, app language override.
  - Typed convenience accessors with `boolOrDefault` defaults (haptics/liveActivity/lockScreen default true).
  - macOS fallback keeps legacy `ggml-base` default; `defaultTranscriptionBackendID` is `automatic` on iOS, `ggml-base` elsewhere.
- Constraints: App Group entitlement required for cross-process sharing; DEBUG overrides compiled out in release.
- Evidence: `AppConstants.swift` (whole file; `AppConstants`, `VoiceAutoStopCapturePath`)
- Status: shipped

### F-SH-02 Voice auto-stop (pause detection) preferences
- Surface: keyboard, in-app draft/immediate, quick record, live activity, Watch recording
- Summary: Global master switch plus per-capture-path overrides for stopping live capture after locally detected silence. Raw defaults keys retain legacy `parakeetKeyboard*` names for compatibility.
- Details:
  - Pause duration clamped to 0.5–2.0 s, default 0.75 s.
  - `VoiceAutoStopCapturePath` enum: keyboard, inAppDraft, inAppImmediate, quickRecord, liveActivity, watch — each with an independent `voiceAutoStop.capturePath.<path>.enabled` key (default true).
  - Effective check = global master AND path toggle.
  - Legacy aliases `parakeetKeyboardAutoStopEnabled`, `parakeetKeyboardPauseDuration` kept source-compatible.
- Constraints: requires the Silero VAD model to be downloaded (see F-SH-30) to actually function; preferences alone are inert.
- Evidence: `AppConstants.swift` (voiceAutoStop* sections); `VoiceActivityDetection.swift` (`VoiceAutoStopPolicy.capturePath(for:)`)
- Status: shipped

### F-SH-03 In-app language override
- Surface: iOS/macOS Settings → Interface Language picker
- Summary: `AppLanguage` enumerates 23 fully localized languages plus `system`; `AppLanguagePreference` persists the choice in the App Group and mirrors it into `AppleLanguages` so the next launch resolves the matching `.lproj`.
- Details:
  - Language list: system, ar, bn, zh-Hans, zh-Hant, nl, en, fr, de, hi, id, it, ja, ko, pl, pt-BR, ru, es, ta, th, tr, uk, ur, vi.
  - Native display names are never localized (picker stays legible in any UI language).
  - `matching(languageIdentifier:)`: exact match else longest shared prefix ("zh-Hans-SG" → Simplified Chinese).
  - `applyAtLaunch` reconciles early and is idempotent; explicitly distinguishes "never set" from an explicit `system` sentinel so users who picked a per-app language in iOS Settings keep it; unreadable stored values are left untouched.
  - Change takes effect at next app open because `Bundle.main` caches localization.
- Constraints: none beyond Foundation; main-app process mirrors to standard defaults.
- Evidence: `AppLanguagePreference.swift` (`AppLanguage`, `AppLanguagePreference.set/applyAtLaunch`)
- Status: shipped

### F-SH-04 Async exclusive gate (utility)
- Surface: internal (Parakeet, diarization inference serialization)
- Summary: `AsyncExclusiveGate` actor providing a cancellation-aware FIFO mutex for single-flight async resources.
- Details: waiters queued FIFO; cancellation removes queued waiters; ownership transferred on release; cancellation-after-acquire releases and propagates `CancellationError`.
- Constraints: none beyond platform minimums (pure Swift concurrency, Foundation only).
- Evidence: `AsyncExclusiveGate.swift` (whole file)
- Status: shipped (infrastructure)

### F-SH-05 Microphone recording (AudioRecorder)
- Surface: app/keyboard recording flows (iOS, macOS)
- Summary: `AudioRecorder` records 16 kHz mono 16-bit WAV via `AVAudioEngine` input tap (chosen because `AVAudioRecorder.record()` fails in keyboard extensions). It journals hardware-format audio incrementally to a `.caf` file and converts on stop.
- Details:
  - Requests mic permission synchronously via semaphore on iOS; checks `AVCaptureDevice` authorization on macOS.
  - iOS session: `.playAndRecord` + `defaultToSpeaker` + `allowBluetooth` for background recording (`UIBackgroundModes: audio`), `.mixWithOthers` avoided interrupting others.
  - Durable `.caf` journal flushed per buffer → crash-recoverable audio; converted to 16 kHz WAV by `AudioFileConverter.convertToWhisperWAV` only after stop; journal deleted on success, kept on failure.
  - Optional locked `audioBufferHandler` for live-transcription previews (runs on render queue).
  - 0.1 s duration timer; diagnostics (frames, maxAmp/RMS, silence warning) logged to `KeyboardDebugLog`.
  - Session-unique `recording_<uuid>.wav` filename so a second recording cannot overwrite audio still being transcribed.
  - `requestMicrophonePermission()` async wrapper for both platforms.
- Constraints: `#if os(iOS) || os(macOS)`; requires mic permission and recordings directory.
- Evidence: `AudioRecorder.swift` (`startRecording`, `stopRecording`, `writeWAV`)
- Status: shipped

### F-SH-06 Audio file conversion (AudioFileConverter)
- Surface: recording stop, meeting normalization, transcription prep, duration probing
- Summary: AVFoundation-based conversion of any input audio to 16 kHz mono 16-bit WAV, plus meeting-timeline assembly, concatenation, mic/system mixing, container sniffing, duration probing, and direct WAV writing.
- Details:
  - `convertToWhisperWAV` (in-memory), `convertToWhisperWAVStreaming` (chunked, meeting path — no full-recording buffer).
  - `normalizeMeetingStem(chunks:...)`: sorts chunks by start time, inserts silence for leading offsets/gaps, clips overlaps at a published frontier.
  - `concatenateToWhisperWAVStreaming`: sequential normalization + concat.
  - `mixWhisperWAVStreaming`: mixes mic + system stems (gain 0.5 each when both present, 1.0 single) into clamped Float32 WAV.
  - `duration(of:)` guards with `hasAudioContainerHeader` (recognizes MP4/M4A `ftyp`, CAF, RIFF/WAVE, AIFF/FORM, OggS, fLaC, ID3, bare MP3 sync word) so malformed files never reach crashy `AVAudioFile` teardown paths — used by orphaned-file recovery probing.
  - `writeWAV(samples:)` / `writeWAV(int16Samples:)` with hand-built RIFF headers and atomic writes.
- Constraints: `#if canImport(AVFoundation)`.
- Evidence: `AudioFileConverter.swift` (whole file)
- Status: shipped

### F-SH-07 Incremental WAV writer
- Surface: persistent recorder / live segment journaling
- Summary: `IncrementalWAVWriter` is a thread-safe 16 kHz mono PCM WAV journal that refreshes RIFF/data lengths after every append and fsyncs at least once per second, so the flushed prefix remains readable if the process dies mid-recording.
- Details: Float→Int16 conversion with clamping; `finalize()` idempotent; `recordedDataByteCount` accessor; data size bounded to `UInt32.max - 36`.
- Constraints: none beyond platform minimums (Foundation file I/O only).
- Evidence: `IncrementalWAVWriter.swift` (whole file)
- Status: shipped

### F-SH-08 Circular audio buffer
- Surface: always-on persistent recorder, keyboard segment extraction
- Summary: `CircularAudioBuffer` is a fixed-capacity ring buffer of Float samples (e.g., ~5 min @16 kHz ≈ 19.2 MB) letting the keyboard request transcription of any rolling window at any time.
- Details: lock-guarded append (zero-copy from unsafe pointers); absolute-index `extract(from:to:)` returning nil for overwritten ranges; `extractAvailable(from:through:maxCount:)` atomic cursor extraction with optional stop boundary; `earliestAvailableIndex`; `reset()`; monotonic `totalSamplesWritten`.
- Constraints: buffer capacity is allocated up front and fixed (~19.2 MB for 5 min @16 kHz); overwritten samples are permanently unavailable.
- Evidence: `CircularAudioBuffer.swift` (whole file)
- Status: shipped

### F-SH-09 Keyboard debug log
- Surface: keyboard extension + main app debug log viewer
- Summary: `KeyboardDebugLog` is a crash-safe file-backed logger in the App Group (`keyboard_debug.log`) that flushes every line immediately, records per-entry memory stats, and is readable by the main app.
- Details: RSS via `mach_task_basic_info`; remaining-before-jettison via `os_proc_available_memory()` (iOS 13+); trims to last 32 KB past 64 KB keeping whole lines; `clear()`, `read()` APIs; entries timestamped `HH:mm:ss.SSS` with function name.
- Constraints: memory stats iOS-only; shared container required.
- Evidence: `KeyboardDebugLog.swift` (whole file)
- Status: shipped (debug surface)

### F-SH-10 File-based keyboard↔app IPC (TranscriptionIPC)
- Surface: keyboard extension, main app persistent recorder, Live Activity, quick-capture widgets
- Summary: JSON documents in `TranscriptionIPC/` inside the App Group plus Darwin notifications implement the always-on recording handshake and the legacy URL-scheme flow between keyboard and app.
- Details:
  - Documents: `request.json`, `response.json`, `status.json` (phase listening/recording/transcribing/done/error, startedAt/stoppedAt, exact transcriptionProgress, updatedAt heartbeat), `command.json` (`startSegment`/`stopSegment`/legacy `stop`, origins keyboardExtension/inAppDraft/inAppImmediate/quickRecord/liveActivity/watch), `listening_state.json` (with `lastHeartbeatAt`), `audio_level.bin` (raw 4-byte Float RMS), `live_transcription.json`, `live_delivery_checkpoint.json`.
  - Darwin notifications: request/response/stop/command/listeningState (all under `group.bontecou.Voxboard.*`).
  - `writeRequest` clears stale response/status/command first; cumulative `LiveTranscriptionSnapshot` makes missed notifications harmless.
  - `listeningStateFreshnessInterval` 45 s — keyboard treats `isListening=true` without a recent heartbeat as stale (iOS may have killed the app).
  - `RecordingCommand.resolvedStopRequestId` requires exact request-id identity so stale extensions can't stop a newer recording.
  - Package-level compatibility-fixture decoding for all seven document types.
- Constraints: App Group required; `voxboard://` scheme for legacy flow.
- Evidence: `TranscriptionIPC.swift` (whole file)
- Status: shipped (legacy URL flow retained as fallback)

### F-SH-11 Live Activity command building & state
- Surface: Lock Screen / Dynamic Island (iOS)
- Summary: `LiveActivityCommandBuilder` writes start/stop `RecordingCommand` files from App Intents (which run in the main app process) and posts the Darwin notification the persistent recorder already observes. `VoxboardLiveActivityState` is the Codable content state shared by lock-screen and Dynamic Island presentations.
- Details:
  - `buildStartCommand(requestId:modelId:language:flowId:)` → `.startSegment`, origin `.liveActivity`; `buildStopCommand(requestId:)` → `.stopSegment`.
  - `enqueue(command:commandURL:notify:)` is test-injectable.
  - State fields: `isSegmentActive`, `isTranscribing`, `segmentStartedAt`, `segmentRequestId` (optional for old-version decode), `transcriptionProgress` clamped 0–1 and non-finite→nil.
- Constraints: ActivityKit gated `@available(iOS 16.1, *)` (attributes only; state struct is platform-independent for testing).
- Evidence: `LiveActivityCommandBuilder.swift`; `VoxboardLiveActivity.swift` (`VoxboardLiveActivityState`, `VoxboardActivityAttributes`)
- Status: shipped

### F-SH-12 Live transcript draft preview reconciliation
- Surface: in-app Capture composer with live Apple Speech transcription
- Summary: `LiveTranscriptDraftPreview` maintains a single replaceable preview block inside an editable draft so volatile (revisable) Apple Speech results replace rather than duplicate; finalization swaps the block for the committed transcript.
- Details: preserves user edits outside the block; `cancel()` removes the preview entirely; merged finalized+volatile text joined with space; block separator `\n\n` only when draft non-empty; backwards search for the rendered block if the suffix changed.
- Constraints: none beyond platform minimums (pure Foundation string operations).
- Evidence: `LiveTranscriptDraftPreview.swift` (whole file)
- Status: shipped

### F-SH-13 Keyboard live-transcription delivery reducer
- Surface: keyboard extension live insertion
- Summary: `LiveTranscriptionDeliveryReducer` implements deterministic persist-before-insert transitions so the keyboard never double-inserts finalized Apple Speech deltas even if iOS terminates the extension between checkpoint and insertion (at-most-once by design).
- Details:
  - Outcomes: `ignoredStale` (non-increasing revision), `ignoredNonMonotonic` (finalized text not a prefix extension), `persistenceFailed`, `committed(state:delta:)`.
  - `restoredState(from:)` validates checkpoint `requestId` match.
  - Checkpoint persisted through `TranscriptionIPC.writeLiveDeliveryCheckpoint`.
- Constraints: checkpoint durability depends on the App Group `TranscriptionIPC` container; reducer itself is pure Foundation logic.
- Evidence: `LiveTranscriptionDeliveryReducer.swift` (whole file)
- Status: shipped

### F-SH-14 Transcription insertion planning (batch vs live reconciliation)
- Surface: app/keyboard when a batch fallback transcript must complete live-inserted text
- Summary: `TranscriptionInsertionPlanner` computes the not-yet-inserted suffix, tolerating punctuation/case/spacing differences between live Apple output and batch fallback.
- Details: plans `insert(String)` / `alreadyComplete` / `unsafeMismatch`; word-level comparison with case/diacritic-insensitive matching; if live text already carries punctuation, only whitespace separator is carried from the fallback (avoids ".!"); never guesses across a word mismatch.
- Constraints: none beyond platform minimums (pure Foundation string logic).
- Evidence: `TranscriptionInsertionPlanner.swift` (whole file)
- Status: shipped

### F-SH-15 Transcription backend model & progress types
- Surface: all transcription consumers
- Summary: Shared backend identifiers (`automatic`, `apple-speech`), the `SystemTranscriptionBackend`/`SystemLiveTranscriptionSession` protocols (implemented in the iOS app to avoid linking Speech.framework into keyboard/widgets/Watch/macOS), and truthful progress types.
- Details:
  - `TranscriptionProgress`: `.preparing` (indeterminate) or `.exactAudioCoverage` (strictly finite 0–1); `wholePercentCompleted` floors (never 99.x→100); locale-aware display string.
  - `MonotonicAudioCoverageProgressRelay` filters to strictly advancing finite <1 fractions; completion reserved for result validation.
  - `ParakeetProgressObservationPolicy`: observe only audio > 15 s (FluidAudio 0.13.4 `> 240_000` sample branch), unknown duration never subscribes.
  - `SystemTranscriptionAudioChunk` keeps AVFoundation out of the shared type.
  - `OnDeviceTranscriptionResult` records backend id/name/kind + timed segments.
- Constraints: none beyond platform minimums for the types/protocols themselves; Speech-backed implementations are injected from the iOS app target only.
- Evidence: `TranscriptionBackend.swift` (whole file)
- Status: shipped

### F-SH-16 On-device transcription dispatcher
- Surface: app recording flows, Watch imports, keyboard queue execution (main app process)
- Summary: `OnDeviceTranscriptionService` (actor) dispatches one-shot transcription: Automatic prefers the injected Apple Speech backend and falls back only to models the user already downloaded; explicit model IDs route to Whisper or Parakeet. It never initiates a model download.
- Details:
  - `availability`/`canTranscribe`/`prepare`/`transcribe`/`transcribeResult`; errors: modelUnavailable, systemBackendUnavailable/Failed, noAvailableBackend, audioConversionFailed, modelLoadFailed, noSpeechDetected (each localized).
  - Live sessions only for Automatic + injected backend; not gated on cached availability (starting resolves permission/asset states).
  - Fallback resolution: persisted `selectedFallbackTranscriptionModel` → `ggml-base` if downloaded → any downloaded model; gated by `usesDownloadedLocalFallbacks`.
  - Non-WAV inputs converted to a temp 16 kHz WAV first (deleted after).
  - Caches one Whisper or Parakeet context + `InstalledModelAccess` (keeps external security scope alive for the context's lifetime); cache invalidated on model/source/URL change.
  - Whisper `whisper_full` is non-interruptible — result discarded if the caller was cancelled (`Task.checkCancellation` after the call).
  - `noSpeechDetected` from Apple Speech short-circuits (never runs a second recognizer over genuine silence); nonempty result reported as `exactAudioCoverage(1)`.
  - GPU: Whisper uses GPU on macOS only; Parakeet token timings → word segments.
- Constraints: `#if os(iOS) || os(macOS)` for local model paths; Apple Speech only where injected (iOS app).
- Evidence: `OnDeviceTranscriptionService.swift` (whole file)
- Status: shipped

### F-SH-17 whisper.cpp backend (WhisperContext)
- Surface: explicit Whisper model transcription
- Summary: `WhisperContext` wraps the whisper.cpp C API for greedy decoding of 16 kHz WAVs with token timestamps, exact source-audio progress callbacks, WAV chunk-walking loader, and hallucination filtering.
- Details:
  - `init(modelPath:useGPU:flashAttn:)` (GPU off on iOS per caller); threads = min(maxThreads, cores-1); `token_timestamps`, `split_on_word`, native `vad = false` so progress maps to source timeline.
  - Word-level timed segments from token data with per-segment fallback to segment timestamps when partial timing would drop text (coverage-verified).
  - Hallucination filter: exact matches against ~22 known phrases ("thank you.", "[Music]", "(silence)", …), plus any short (<40 char) all-bracketed/parenthesized output.
  - WAV loader walks RIFF chunks to find `data` (handles fact/LIST chunks); legacy offset-44 fallback; silent-audio (maxAmp<0.01) diagnostics.
- Constraints: `#if os(iOS) || os(macOS)`; must run off the main thread.
- Evidence: `WhisperContext.swift` (whole file)
- Status: shipped

### F-SH-18 Parakeet CoreML backend (ParakeetContext)
- Surface: Parakeet v2/v3 model transcription (main app only — ~800 MB RAM)
- Summary: `ParakeetContext` wraps FluidAudio's `AsrManager` for NVIDIA Parakeet-TDT on-device transcription via CoreML/Neural Engine, with an exclusive session gate, external (read-only, non-repairing) model loading, progress observation, and token-timing→word-segment conversion.
- Details:
  - App-managed repos use FluidAudio's repair-and-redownload load; external security-scoped folders load compiled assets directly (Preprocessor CPU-only, Encoder/Decoder/JointDecision, vocabulary JSON) and never trigger recovery that could delete user files.
  - Progress stream only for verified >15 s input; relayed through `MonotonicAudioCoverageProgressRelay`; stream drained (not cancelled) to avoid poisoning FluidAudio's cached stream.
  - `<blank>`/`<pad>` tokens skipped; SentencePiece `▁` markers split words; failures return nil (logged) rather than throwing.
- Constraints: `#if os(iOS) || os(macOS)`; main-app memory budget only.
- Evidence: `ParakeetContext.swift` (`load`, `transcribeResult`, `timedWords`)
- Status: shipped

### F-SH-19 Model catalog & integrity (WhisperModelInfo / ModelEngine)
- Surface: Models settings UI, download flows, fallback resolution
- Summary: Catalog of 7 models — Whisper tiny/base/small/medium/large-v3-turbo (HuggingFace ggml downloads with exact byte counts and trusted file headers) and Parakeet v2 (English-only) / v3 (25 languages) (~800 MB estimate each). `isValidInstallation` turns completeness into deterministic byte-size checks.
- Details:
  - Per-artifact expected byte sizes for all Parakeet `.mlmodelc` files and `parakeet_vocab.json` (v2 and v3 differ).
  - Whisper validation: exact size + trusted leading bytes (hex-encoded GGML header per model).
  - `installedModelAccess` prefers a valid external (macOS bookmark) location over the app-managed copy.
  - `removeInvalidExistingParakeetArtifacts` deletes known-bad paths before FluidAudio download (which skips existing paths).
  - `localizedModelDescription` localizes the two known description strings.
- Constraints: external-location preference is `#if os(macOS)`-gated; a model counts as installed only if byte sizes and (for Whisper) trusted headers validate exactly.
- Evidence: `WhisperModelInfo.swift` (whole file; `ModelEngine`, `WhisperModelInfo.availableModels`)
- Status: shipped

### F-SH-20 External model locations (macOS)
- Surface: macOS Models UI — "Use Existing Model…"
- Summary: `ExternalModelBookmarkStore` + `InstalledModelAccess` let the Mac use a model stored anywhere on disk via a security-scoped bookmark, without copying into the container, holding the security scope for the inference context's lifetime.
- Details: bookmark key `externalTranscriptionModelBookmark.v1.<modelID>`; stale bookmarks refreshed opportunistically; "Forget" removes the bookmark without deleting the file and reverts to app-managed copy/default backend; validation must pass before selection is accepted (error names expected item).
- Constraints: macOS only.
- Evidence: `ExternalModelLocation.swift` (whole file)
- Status: shipped

### F-SH-21 Model download transport & manager
- Surface: Models settings UI (download/cancel/delete), macOS sleep prevention
- Summary: `ModelManager` (@MainActor, @Observable) manages backend selection, opt-in downloads (Whisper via explicit URLSessionDownloadTask with real byte progress; Parakeet/VAD via FluidAudio repo download with file-count progress), storage preflight, sleep prevention on macOS, and deletion.
- Details:
  - `ModelDownloadState`: phases preparing→listingFiles→transferring→verifying→cancelling; monotonic phase acceptance so late callbacks can't regress; byte fraction only when the transport provides one (file counts are never shown as bytes).
  - `ModelDownloadOperationRegistry` operation IDs prevent stale progress from a cancelled retry mutating a newer attempt; retry blocked until cancellation fully unwinds.
  - Storage preflight: download size + max(128 MB, size/5) headroom vs volume capacity.
  - Whisper install: staging file on models volume, validate (HTTP status, exact size, trusted header) then atomic move/replace.
  - Parakeet: `DownloadUtils.downloadRepo`, invalid-artifact cleanup first, post-download completeness check.
  - Voice-activity (Silero VAD) download via `DownloadUtils.downloadRepo(.vad)`; separate download/cancel/delete APIs.
  - macOS `ProcessInfo.beginActivity` prevents display/system sleep during downloads.
  - Selection migration: iOS fresh installs and former implicit Base default move to `automatic`; legacy Base retained as fallback; migration flag `transcriptionSelectionMigration.v1`.
  - Language pickers: 23 Whisper languages, Automatic "System Language" + same list, Parakeet v3 25 European languages, Parakeet v2 English-only; unsupported stored language auto-corrected.
  - Delete: external source forgets bookmark; deleting selected/fallback model resets defaults; `installedModelsRevision` bumps for SwiftUI refresh.
- Constraints: Parakeet/VAD downloads unavailable off iOS/macOS.
- Evidence: `ModelManager.swift` (whole file); `ModelDownloadSupport.swift` (`WhisperModelDownloadTransport`, `WhisperDownloadTaskDelegate`, `WhisperModelInstaller`, `WhisperModelDownloadValidator`, `ModelDownloadStorage`)
- Status: shipped

### F-SH-22 Voice activity detection (Silero VAD)
- Surface: live capture paths with auto-stop enabled (keyboard, app, quick record, Live Activity, Watch)
- Summary: `VoiceActivityDetectionService` loads the explicitly downloaded Silero VAD model (no implicit network fetch) and creates per-segment streaming sessions that emit speechStarted/speechEnded sample indices for pause-based auto-stop.
- Details:
  - Model asset: `silero-vad` repo, compiled `silero-vad-unified-256ms-v6.0.0.mlmodelc`, 4096-sample (256 ms) chunks @16 kHz; installed check requires `coremldata.bin`, `model.mil`, `weights/weight.bin`.
  - `stateMachineSilenceDuration` subtracts one frame so the user-facing pause matches wall-clock silence.
  - `speechPadding: 0` so a single 256 ms noise frame can't satisfy a 0.3 s minimum-speech gate.
  - Strict chunk-size validation error; cached `VadManager` (cpuAndNeuralEngine) reused across sessions.
  - `VoiceAutoStopPolicy` maps recording command origins to capture paths.
- Constraints: `#if os(iOS) || os(macOS)`; requires model download; invalid if FluidAudio absent.
- Evidence: `VoiceActivityDetection.swift` (`VoiceActivityModelAsset`, `VoiceActivityDetectionService`, `FluidAudioVoiceActivitySession`)
- Status: shipped (gated on optional model download)

### F-SH-23 Speaker diarization (best-effort anonymous labels)
- Surface: per-Capture-Preset "Speaker identification" opt-in, applied after voice transcription
- Summary: `SpeakerDiarizationService` (actor, exclusive gate) runs FluidAudio's offline diarizer on completed recordings, attributes timed ASR segments to anonymous "Speaker N" turns by overlap scoring, and preserves the raw transcript with a durable skip reason when anything fails.
- Details:
  - Pre-checks: timed segments exist; alphanumeric-normalized coverage of transcript text is complete; models directory available; `SpeakerDiarization/` model directory prepared (downloads on first opt-in use); processing success; at least one turn produced.
  - Skip reasons (localized, persisted on the transcript): timestampsUnavailable, incompleteTimestamps, noSpeakersDetected, storageUnavailable, modelPreparationFailed, processingFailed.
  - Attribution: per text segment choose speaker segment maximizing overlap (1000 + overlap) else nearest midpoint; first-seen speaker IDs renumbered from 0; adjacent same-speaker turns merged with punctuation-aware joining.
  - Rendered text "Speaker N:\n<text>" blocks; cancellation always propagates; failures logged to `KeyboardDebugLog`.
  - `RecordingVoiceProcessingConfiguration` snapshots `presetID` + `speakerDiarizationEnabled` at recording time.
- Constraints: per-preset opt-in (decodes as false on existing presets); requires timed segments (Whisper/Parakeet/Apple Speech output).
- Evidence: `SpeakerDiarizationService.swift` (whole file; `SpeakerDiarizationAttribution`)
- Status: shipped (opt-in)

### F-SH-24 Meeting capture (models, manifest, timeline, lifecycle)
- Surface: macOS system-audio meeting capture ("Record Meeting")
- Summary: Durable meeting capture domain: two audio sources (microphone, system screen-audio), 30 s chunked M4A writing with receipts, a schema-v2 manifest with safe-recovery validation, timeline events (started/gap/dropped/discontinuity/formatChange/stopped), transcript assembly into "You"/remote speaker turns, and pure lifecycle state machines.
- Details:
  - `RecordingArtifactRole`: primaryAudio, meetingMicrophone, meetingSystem, meetingTimeline, playbackMix.
  - `MeetingCaptureManifest` states: preparing→recording→captured→interrupted→normalizing→queued→consumed; `hasSafeRecoveryMetadata` validates schema version, finite times, unique sanitized filenames (no traversal), positive byte counts; `isRecoverable` excludes consumed/queued/empty.
  - `MeetingCaptureChunkReceipt` sidecar written before a chunk is announced (crash discovery); chunks published only after AVAssetWriter `.completed` + verified nonzero size.
  - `MeetingTranscriptAssembler`: maps ASR segments onto the common timeline (clamped to captured envelope), builds turns (mic → speaker 0 "You", system → remote speaker N+1, remoteAnonymous role), rendered "Label:\ntext" blocks.
  - `MeetingClipboardPolicy.shouldCopyAutomatically`: clipboard + immediate policy + not yet attempted.
  - `MeetingCaptureLifecycle` (idle→selecting→preparing→recording→stopping→finished) with once-only stop so user stop and SCStream interruption race safely; `MeetingChunkWriterLifecycle` (accepting/rotating/stopping/stopped) with deterministic StopAction/RotationCompletionAction.
- Constraints: macOS (system audio via ScreenCaptureKit in app target); manifest schema v2.
- Evidence: `MeetingCapture.swift` (whole file)
- Status: shipped

### F-SH-25 Meeting chunk sample writer
- Surface: meeting recording engine (app target drives SCStream taps)
- Summary: `ChunkedSampleBufferWriter` is a queue-confined 30 s-chunk AVAssetWriter (AAC 128 kbps `.m4a`) with a bounded 512-buffer rollover queue, format-change detection/rotation, gap/discontinuity/drop timeline events, durable chunk receipts, and exactly-once finalization mailbox.
- Details:
  - `AVAssetWriterMeetingChunkSession` performs add/startWriting/startSession and reports append outcomes appended/notReady/failed.
  - Not-ready appends recorded as dropped events with localized warnings; drop warnings deduplicated.
  - Rollover drain works one format/time-bounded prefix at a time (a route change mid-finalize can't mix formats into one session); overflow beyond 512 buffers drops with a timeline event.
  - `MeetingWriterFinalizationMailbox` take-by-UUID suppresses duplicate publishes; drain-at-stop so late finalizations aren't lost.
  - Chunk receipts (`<chunk>.m4a.chunk.json`) written pre- and post-finalization; failed/empty chunks deleted with their receipts.
- Constraints: AVFoundation; queue-confined callback serialization.
- Evidence: `MeetingChunkSampleWriter.swift` (whole file)
- Status: shipped

### F-SH-26 Transcript record model
- Surface: history UI, exports, diarization, enrichment
- Summary: `Transcript` is the persisted voice record: text, date, duration, model, language, optional speaker turns (+ skip reason), and optional on-device LLM enrichment fields (title/tags/category/cleanedText).
- Details:
  - `TranscriptSpeakerTurn`: zero-based speaker rendered "Speaker N", optional `role` (local/remoteAnonymous/unknown) and `displayLabel` (e.g., "You") — nil decodes legacy turns unchanged.
  - `withEdits` preserves identity/date/duration/model/language; editing text clears speaker turns and skip reason (only preserved when text unchanged).
  - `withEnrichment` replaces only enrichment fields; source-supplied identity constructor used by Watch imports (recording UUID + original date → retry updates one record/request).
  - `speakerCount` derived from highest speaker index.
- Constraints: none beyond platform minimums (Foundation Codable record type).
- Evidence: `Transcript.swift` (whole file)
- Status: shipped

### F-SH-27 Transcript store (history persistence)
- Surface: history list, keyboard extension, all targets
- Summary: `TranscriptStore` persists transcripts as `transcripts.json` in the App Group; every mutation re-reads the latest coordinated disk value before writing so app/keyboard/extensions can't silently clobber each other.
- Details: NSFileCoordinator-coordinated add/update/delete(ids:)/clear; newest-first insert with id dedup; best-effort content-free `ActivityStatsStore` recording on add; typed `TranscriptStorePersistenceError` (load/add/update/delete/clear) surfaced as `lastPersistenceError`; `reload()` for cross-process refresh.
- Constraints: App Group shared container required for cross-process persistence (`AppConstants.sharedContainerURL`); reads/writes coordinated via NSFileCoordinator.
- Evidence: `TranscriptStore.swift` (whole file)
- Status: shipped

### F-SH-28 Transcript search
- Surface: history search field
- Summary: `TranscriptSearch.matches` performs multi-token AND search over text, cleanedText, title, tags, category, model, and language with case/diacritic/width-insensitive normalization.
- Details: empty query matches everything; all tokens must be substrings of the concatenated searchable text.
- Constraints: none beyond platform minimums.
- Evidence: `TranscriptSearch.swift` (whole file)
- Status: shipped

### F-SH-29 Activity stats ledger
- Surface: home activity/stats UI
- Summary: `ActivityStats` builds privacy-safe lifetime summaries (recording/capture counts, total duration, attachment count, last-7-day daily breakdown, capture-source totals) from the content-free `ActivityStatsLedger`, with a backfill path from visible history.
- Details: de-duplicates events by id keeping the latest date; delivered-only captures counted; averages derived; source totals sorted by count then name; configurable `recentDayCount` (default 7) and calendar.
- Constraints: none beyond platform minimums (Foundation only; derived from the ledger plus a backfill from visible history).
- Evidence: `ActivityStats.swift` (whole file)
- Status: shipped

### F-SH-30 Capture presets (RecordingFlow) — model & store
- Surface: Capture Presets UI (formerly Recording Flows), all capture modalities
- Summary: `CapturePreset` is the persisted policy record applied to every input modality: identity/kind, per-preset export settings, static frontmatter, location policy, metadata scope, post-processing mode, speaker-diarization opt-in, typed-capture processing opt-in, composer prompt, Watch output mode/recording settings, audio save mode/attachments folder, and owned Capture destination routing.
- Details:
  - `CapturePresetStore` persists to legacy key `recordingFlows`/`selectedRecordingFlowId` (kept for widgets/shortcuts/extensions).
  - Default single "Default" preset (type: capture, clean mode, prompt); `makeCustomFlow()` factory; deprecated built-ins dream/todo/meeting migrated away; "voice-note" frontmatter type migrated to "capture".
  - Legacy global file-export settings migrated into per-preset `CapturePresetExportSettings`.
  - Cross-process preset writes serialized with a `flock`-based lock file (`capture-preset-writes.lock`).
  - One-time owned-route migration converts many-to-many workflow/destination bindings into one owned Markdown route per preset with deterministic (FNV-1a) clone UUIDs, replay-safe; orphaned destinations promoted to presets only during initial migration; retired route/preset ID lists prevent resurrection; `clearCaptureDestination`/`clearCaptureEntryTemplate` prune stale references; `retirePreset` marks both IDs.
  - Legacy voice-export Markdown template carried into the destination as a vault-relative template path when contained in the destination root (symlink-verified).
  - Selection helpers: `selectedFlowId/selectedFlow/selectNextFlow` (cycles enabled presets).
  - `usesAIEnrichment` = any mode except "Keep Original" (`.none`).
  - Watch settings: recording folder bookmark/name + filename template; watchOutputMode transcript|recordingOnly.
  - Typealiases `RecordingFlow`, `RecordingFlowStore` retained for source compatibility.
- Constraints: needs shared defaults for persistence; migration writes coordinated with the route library load (`CapturePresetRouteLibrary.load`).
- Evidence: `RecordingFlow.swift` (`CapturePreset`, `CapturePresetStore`, `CapturePresetExportSettings`, `CapturePresetRouteLibrary`, lines ~1–1400)
- Status: shipped (legacy global export settings supported as migration source)

### F-SH-31 Recording job queue & store (durable jobs)
- Surface: Recording Queue UI, background transcription, meeting handoff, imports
- Summary: `RecordingJobStore` (actor) persists durable transcription jobs (per-job JSON manifests under `RecordingJobs/items/`, audio under `audio/`) with phases queued/processing/finalizing/completed/failed/discarded, retry, retention, orphan recovery, and a cross-process `flock` worker lease. `RecordingJobQueue` (@MainActor) drains the store through an injected executor with progress reporting.
- Details:
  - Job fields: schema v2, artifacts by fixed role, capture source, origin-time location outcome, immutable voice-processing config, model/fallback/language, retention policy (deleteAfterSuccess | timed ≥60 s default 7 d | permanent), processing policy (immediate/whenIdle/manual), attempt count, revision, transcript checkpoint, exported note/audio paths, audio-reference-attached timestamp, automatic-clipboard-attempted timestamp, completion/deletion dates.
  - `RecordingJobHandoffIntent` + intent store: durable pre-enqueue metadata written before origin resolution/conversion so relaunch recovery recreates the exact intended job.
  - `RecordingArtifactDeliveryReceipt` (`.vox-delivered` marker): prevents already-delivered interactive recordings from reappearing as retryable if cleanup is interrupted.
  - Bundle enqueue (meeting/multi-stem) with transactional commit; bundle-intents directory recovered before generic queue-orphan recovery so meeting members aren't reinterpreted as schema-v1 jobs.
  - `load(recoverInterrupted:)`: under worker lock, re-queues processing/finalizing jobs ("Recovered after Vox.md was interrupted"), fails jobs with missing audio ("The source recording could not be found"), and recovers unreferenced audio files as manual `.recovery` jobs.
  - `recoverExternalOrphans` imports recordings-directory leftovers, preferring durable handoff intents (preserving identity/delivery/preset/location).
  - External delivery transaction directories per job+artifact (`delivery-intents/<id>/<note|audio|noteAudioReference>`).
  - Queue behaviors: claimNext, markFinalizing/Completed/Failed (stage storage/transcription/delivery via `RecordingJobFailureClassifying`), retry (may override model/fallback/language/delivery), processNow, discard (deletes audio + transaction dirs; failure marks job failed instead), retention updates and `performRetentionCleanup`, transcript checkpointing, exported-audio/note markers, clipboard-attempt marker, `clearCompletedTranscriptText` (acknowledge copied result).
  - Interruption: `interruptForInteractiveWork` (keyboard priority), `interruptForSystemExpiration` (latches suspension — new enqueue isn't a fresh background opportunity), capture leases (owner-scoped pauses), coalesced external refresh + 1 s durable polling while queue UI visible; stale-progress guard drops decreasing fractions.
  - Preferences keys: `recordingQueue.audioRetention.*.v1`, `recordingQueue.processingPolicy.v1`.
  - `didChangeNotification` filtered by root URL for multi-process instances.
- Constraints: shared container required; worker lease blocks concurrent drains across processes.
- Evidence: `RecordingJobQueue.swift` (whole file); `RecordingJobStore.swift` (whole file; `RecordingJob`, `RecordingJobStore`, `RecordingQueuePreferences`, `RecordingJobHandoffIntentStore`)
- Status: shipped

### F-SH-32 Usage metering — free transcription minutes
- Surface: paywall gating, usage meters, keyboard fast-path check
- Summary: `UsageTracker` (@Observable) tracks cumulative free transcription seconds (15-minute limit) in App Group defaults with an idempotent receipt ledger (baseline + per-delivery receipts keyed by delivery UUID), plus legacy scalar fallback.
- Details:
  - `addUsage(seconds:deliveryID:)` idempotent by receipt; unattributed (interactive/legacy) usage folded into the baseline once the ledger exists; receipts persisted before the mirrored total.
  - Derived: minutesUsed/remaining, `isAtLimit`, `fractionUsed`; static `staticIsAtLimit` for extensions without instance overhead.
  - Purchase state co-located: accessLevel (free/individual/family), permanent (grandfathered original paid-app) level, `isLegacyAccessClassificationPending`, `hasCurrentIndividualStoreEntitlement`, `isEligibleForFamilyUpgrade`, `purchaseOptions`; `applyVerifiedPurchase`, `reconcileStoreEntitlements` (preserves pending legacy access until classified), `grantPermanentIndividualAccess`/`unlock`, `completeLegacyAccessClassification(isOriginalPaidAppOwner:)`; legacy `hasUnlocked` boolean mirrored for extensions.
  - Reload picks up keyboard-extension writes.
- Constraints: 15 min free transcription / lifetime purchase bypass.
- Evidence: `UsageTracker.swift` (whole file)
- Status: shipped

### F-SH-33 Usage metering — free Capture deliveries
- Surface: Capture pipeline (typed/multimodal captures), paywall
- Summary: `CaptureDeliveryUsageStore` (actor) implements exact-once accounting for successful non-voice Capture deliveries against a 10-capture free limit, using a coordinated App Group ledger (reservation tokens + committed request IDs) and a Keychain high-water mark that survives uninstall/reinstall.
- Details:
  - Reserve/commit/release lifecycle; voice transcripts (`.meteredVoiceTranscript`) and unlocked users bypass; `alreadyCounted` idempotent reservations.
  - Keychain store `bontecou.Voxboard.capture-freemium` (accessible after first unlock, this-device-only on iOS); stores count + ≤10 committed IDs; v1 decimal-count payload decodes as unattributed baseline.
  - Ledger reconciliation: max(ledger, keychain, merged-ID count); committed IDs from keychain clear their reservations; corrupt ledger quarantined to `capture-usage-corrupt-*.json` and rebuilt from high water; schema-version mismatch is a hard error.
  - `release` failures conservatively leak a reservation (same request can still reserve/commit later); successful count mirrored to defaults `successfulCaptureDeliveries.v1`.
  - `AppCapturePipeline.shared` wires this into CaptureCore's `CapturePipeline`; Core's `.shared` stays unmetered for tests.
  - `CaptureDeliveryUsageSnapshot` exposes capturesRemaining/isAtLimit.
- Constraints: App Group + Keychain; limit 10; lifetime purchase bypasses.
- Evidence: `CaptureDeliveryUsageStore.swift` (whole file; `KeychainCaptureUsageHighWaterMarkStore`)
- Status: shipped

### F-SH-34 Purchase access model
- Surface: StoreKit flows, paywall, family upgrade
- Summary: `PurchaseAccess` defines access levels (free/individual/family), products (`bontecou.Voxboard.unlock`, `.family`, `.familyUpgrade`), purchase-option presentation per level, and privacy-safe support diagnostics.
- Details:
  - `purchaseOptions(for:)`: free → [individual, family]; individual → [familyUpgrade]; family → none.
  - `PurchaseEntitlementObservation`: verified/recognized/revoked/upgraded flags, ownershipType, environment, verification error — deliberately no Apple Account/transaction IDs or dates.
  - `PurchaseRestoreDiagnostics` + single-line `summary` for support.
- Constraints: none beyond platform minimums in-package; actual StoreKit purchase/verification flows live in the app target.
- Evidence: `PurchaseAccess.swift` (whole file)
- Status: shipped

### F-SH-35 Capture inbox delivery service
- Surface: app foreground/background inbox drains (iOS and macOS)
- Summary: `CaptureInboxDeliveryService.drain` processes the durable App Group capture inbox end-to-end: recovers stale processing (5 min), purges completed (7 d) / orphaned staging (24 h) / origin snapshots (24 h), re-routes orphaned requests, optionally retries failures, then claims and delivers each pending request.
- Details:
  - Per-request: applies pending AI text processing (`voxProcessingState == .pending`), resolves destination from the route library (with per-request template/placement/relative-note-path/attachments-folder overrides; relative paths validated), resolves bookmark (stale → typed failure), security-scopes the root, captures via `AppCapturePipeline`, marks complete, writes a delivered `CaptureHistoryRecord`.
  - Quota-blocked requests return to pending and are skipped for the rest of the drain (later voice requests not starved); location decisions are not failures — exact processed payload preserved pending, surfaced as `CaptureInboxDecisionRequired` (notifications `captureInboxDecisionRequired`/`Resolved` posted by the exporter).
  - Failures: best-effort failed history record with category (destinationUnavailable/attachment/invalidRequest/fileWrite), typed `latestFailureDescription`, single `setupError` for library/inbox setup failures.
  - Attachment counting covers audio/retainedAudio/image/file, scanned pages + optional PDF, sketch (2).
- Constraints: App Group capture directory (`AppConstants.captureDirectoryURL`) required; destination writes need a valid (non-stale) security-scoped bookmark; quota-blocked requests depend on the Capture-delivery usage ledger.
- Evidence: `CaptureInboxDeliveryService.swift` (whole file)
- Status: shipped

### F-SH-36 Capture location service (one-shot origin fix)
- Surface: Capture Bar "Current Location", preset origin-time location capture, automation captures
- Summary: `CaptureLocationService` is a one-shot, MainActor location provider that never monitors after a request, honors per-preset precision (exact → best, coarse → 1 km), adjusts coordinates for privacy before geocoding, and returns durable `CaptureLocationOutcome`s.
- Details:
  - Timeouts: 15 s fix (60 s authorization wait), 5 s bounded reverse geocode; cancellation-aware continuations; `requestInProgress` guard.
  - `requestCurrentLocation()` (Capture Bar): always geocodes; label fallback chain place→city→region→localized "Location".
  - `resolveLocation(policy:source:)`: authorized-only variant for automation (`resolveLocationIfAuthorized`) makes not-determined a durable unavailable outcome instead of prompting.
  - City-precision snapshots constructed before geocoding so raw fixes are never disclosed to CLGeocoder; geocode failure is best-effort (coordinates remain useful offline; delivery never re-geocodes).
  - Errors → reasons: permissionDenied, restricted, notDetermined, reducedAccuracy (precise preset + reduced accuracy authorization), timeout, unavailable; all localized.
  - Fresh-fix acceptance: accuracy ≥ 0 and timestamp within 30 s.
- Constraints: CoreLocation authorization; localized error strings; `CaptureLocationManaging` protocol injectable.
- Evidence: `CaptureLocationService.swift` (whole file; `SystemCaptureLocationManager`)
- Status: shipped

### F-SH-37 Recording origin store
- Surface: recording stop → transcript CaptureRequest seam
- Summary: `CaptureRecordingOriginStore` (actor) durably saves the preset/source/location-outcome snapshot at recording stop so a crash or long transcription cannot replace the origin result with a later location.
- Details: URL-safe base64 filenames (truncated 180 chars) prevent IPC identifiers from becoming path input; atomic JSON writes; `purge(olderThan:)` called by inbox drains (24 h); `remove(recordingID:)`; `CaptureSource.recordingSource(for:overriding:)` maps command origins (keyboard→keyboard, quickRecord/liveActivity→widget, watch→watch, inAppDraft→app, inAppImmediate/nil→voice).
- Constraints: requires a writable root directory (App Group shared container in production) so snapshots survive process death.
- Evidence: `CaptureRecordingOriginStore.swift` (whole file)
- Status: shipped

### F-SH-38 Capture AI text processing bridge (opt-in enrichment persistence)
- Surface: Capture delivery pipeline (`voxProcessingState == .pending`)
- Summary: `EnrichedCapturePresetTextProcessor` bridges `TranscriptEnricher` into CaptureCore's `CapturePresetTextProcessing`, with a 120 s deadline (`withRunningTask`) so a stalled on-device model can never hang delivery — timeouts degrade to the raw capture text.
- Details: `withRunningTask(timeout:operation:)` races the operation against a deadline, cancels the loser, propagates real errors (incl. `CancellationError`) unchanged; shared with export-time model calls; alias `EnrichedCaptureVoxTextProcessor`.
- Constraints: hard 120 s deadline (configurable `defaultTimeout`); an `LLMBackend`/enricher must be injected — the processor has no model of its own.
- Evidence: `CaptureVoxTextProcessor.swift` (whole file)
- Status: shipped

### F-SH-39 On-device LLM enrichment (TranscriptEnricher)
- Surface: post-transcription enrichment, Capture preset processing
- Summary: `TranscriptEnricher` produces title/tags/category/cleanedText via an injectable `LLMBackend` (native structured generation preferred; JSON prompt fallback), with a fixed category taxonomy, tag normalization, preset defaults, and a never-throwing `enrichAndUpdate` path.
- Details:
  - Categories: note, idea, task, meeting, journal, message, reminder, other (out-of-list → "other").
  - Tag contract: lowercase, whitespace-split, hyphens preserved, deduped, capped at 5.
  - Prompt path used when the preset has a workflow instruction (todoList/meetingNotes/custom) or text contains `Speaker N:` labels (labels preserved verbatim); prompt embeds workflow name, static tag/category preferences, and a "return only JSON" contract.
  - `parse` extracts the first balanced JSON object (tolerating fences/prose); both paths normalized.
  - Preset defaults: merge static tags; "other" category upgraded to preset static category; todoList mode reformats cleaned text via `TranscriptFlowFormatter`.
  - `enrichAndUpdate` swallows all errors/timeouts (120 s default) leaving the record untouched; every outcome logged with short transcript ID.
- Constraints: LLM backend injected from app target (FoundationModels); keyboard links the package but not the backend.
- Evidence: `TranscriptEnricher.swift` (whole file)
- Status: shipped

### F-SH-40 Deterministic flow formatter (Apple Intelligence fallback)
- Surface: presets with todoList/meetingNotes modes when AI is unavailable or skipped; also used post-enrichment
- Summary: `TranscriptFlowFormatter` reshapes recognized text without adding information: todo-list conversion (preserving `Speaker N:` sections), meeting notes with action-item extraction, tag merging.
- Details:
  - Todo formatting: strips existing list markers (checkbox, bullet, numbered), removes filler prefixes ("i need to", "remind me to", …), capitalizes; sentence splitting on " and then "/" then " for single-sentence input.
  - Speaker labels split sections, each formatted as its own todo list.
  - Meeting notes: `## Notes` + `## Action Items` (actionable heuristic: "follow up", "need to", "send", …).
  - `mergeTags` lowercases, strips `#`/whitespace, dedupes preserving order.
- Constraints: none beyond platform minimums; it is the deterministic fallback used when on-device AI enrichment is unavailable or skipped.
- Evidence: `TranscriptFlowFormatter.swift` (whole file)
- Status: shipped

### F-SH-41 Transcript file export (TXT/Markdown/YAML/JSON)
- Surface: file export settings, per-preset export settings, Capture Preset delivery
- Summary: `TranscriptFileExporter` renders transcripts to TXT (body + Tags/Audio lines), Markdown (dated heading, hashtags, optional Obsidian frontmatter), YAML (selectable properties, optional `.md` frontmatter wrapping), and JSON (single object or appended array), with filename templates, new-file/append modes, enrichment field options, static frontmatter, and audio-reference attachment.
- Details:
  - Formats `.txt/.md/.json/.yaml`; modes append/newFile; YAML properties id/text/date/duration_seconds/model_used/language (default all).
  - Filename templates: `{timestamp}{date}{YR}{time}{id}{id8}{model}{language}`; defaults `voxboard-{timestamp}-{id8}` / `voxboard-transcripts`; sanitized (invalid chars→"-", spaces→"-", trimmed, extension stripped); new-file names uniqued `-2`, `-3`, ….
  - Enrichment options: useEnrichedTitleInFilename (style prefix `{title}-{template}` or fullName), useCleanedText, includeTags — all default true; per-preset custom settings force title-in-filename off (preset template is authoritative) and cleaned text/tags on.
  - Markdown frontmatter: merged into leading `---` block when present (per-key upsert, duplicate keys removed); `audio` key upserts as list when multiple, replacing stale relative paths; YAML quoting/escaping; hashtag sanitization (non-alphanumerics→"-").
  - Obsidian audio embed `![[path]]` (top/bottom placement, `]` escaped); stale reference replacement in md/txt.
  - `exportConfigured` reads global or per-preset settings; typed errors (missing/invalid destination or template bookmark, subfolder creation, write failure); auto-organize subfolder creation; bookmark auto-refresh on stale.
  - `exportViaTemplate` renders through `TemplateRenderer` then applies frontmatter; security-scoped folder/template access.
  - Attach-mode JSON merge dedupes by transcript ID when transactional delivery is active.
- Constraints: export requires a configured, resolvable (auto-refreshable) destination bookmark and filename template (global or per-preset); settings read from shared defaults.
- Evidence: `TranscriptFileExporter.swift` (whole file)
- Status: shipped

### F-SH-42 Obsidian-style template rendering
- Surface: Markdown template export (per-preset/global)
- Summary: `TemplateRenderer` renders Templater-compatible templates (`tp.date.now`, `tp.file.creation_date` with moment tokens, `crypto.randomUUID`) and auto-fills empty frontmatter fields (tags `[]`, title, category, summary/description) from transcript enrichment.
- Details: CRLF normalization; moment→Foundation token mapping (YYYY→yyyy, DD→dd); en_US_POSIX formatter; unknown expressions left verbatim; YAML scalar quoting for values containing `:#"`; body + rendered frontmatter + transcript body (cleanedText preferred) assembled with blank-line separators.
- Constraints: none beyond platform minimums (Foundation date formatting only).
- Evidence: `TemplateRenderer.swift` (whole file)
- Status: shipped

### F-SH-43 ExportKit adapter
- Surface: batch export UI, export previews, reusable ExportKit infrastructure
- Summary: `TranscriptExportKitAdapter` maps transcripts to ExportKit's generic record surface: `TranscriptExportRecord`, configuration, renderer registry, path planner (with path-traversal safety policy), destination writer with merge strategies (markdown-document append via `MarkdownDocumentEditor`, JSON array merge with optional stable-ID dedup), transactional run, preview factory, and batch orchestrator with progress.
- Details:
  - Descriptors for txt/md/json/yaml incl. "Markdown Frontmatter"/"YAML Frontmatter" display variants; append separator `\n\n` for Obsidian markdown documents vs `\n\n---\n\n` otherwise.
  - Unique-filename planning for new-file mode; variables filenameBase/recordID/id/id8/model/language/format.
  - `TranscriptExportRun.write` resumes prepared `ExternalFileDeliveryTransaction`s first (verifying target inside destination root); otherwise prepares/publishes transactionally when a transaction directory is configured.
  - Portable profile snapshot (`app: Vox.md`, `domain: transcript`) for ExportKit previews.
- Constraints: depends on the ExportKit package target.
- Evidence: `TranscriptExportKitAdapter.swift` (whole file)
- Status: shipped

### F-SH-44 External file delivery transactions (crash-safe publishing)
- Surface: transcript exports, audio attachment exports, audio-reference edits
- Summary: `ExternalFileDeliveryTransaction` is an app-private write-ahead transaction: staged payload + SHA-256 journal are durable before the destination changes, so retries distinguish this delivery from a different one with identical bytes and detect destination conflicts.
- Details:
  - Journal (v1) records preimage/postimage snapshots (exists/digest/byteCount); expectations `.missing` or exact `.contents`.
  - `resumeIfPrepared` verifies staged digest, treats already-matching target as success, publishes under NSFileCoordinator `.forReplacing` with double preimage check (race tests + non-coordinating writers), verifies postimage.
  - Payload-without-journal (crash during staging) is safely discarded; errors: incompleteJournal, stagedPayloadChanged, targetWasNotMissing, destinationConflict, publishedPayloadMismatch.
  - `clear()` only after the queue's own checkpoint persists; package fixture preparation/validation hooks for compatibility tests.
- Constraints: destination writes cooperate via NSFileCoordinator (`.forReplacing`); journal hashing requires CryptoKit.
- Evidence: `ExternalFileDeliveryTransaction.swift` (whole file)
- Status: shipped

### F-SH-45 Audio attachment export (M4A) & checkpointed delivery
- Surface: preset audio-save modes (Alongside Note / Attachments Folder)
- Summary: `AudioAttachmentExporter` exports a user-facing copy of the source audio next to (or in an attachments subfolder of) the exported transcript, preferring `.m4a` (AVAssetExportPresetAppleM4A, atomic replace) and falling back to copying the source (usually WAV) on failure. `CheckpointedAudioDelivery` sequences export → durable URL checkpoint → note-reference attach → reference checkpoint.
- Details:
  - Security scope for transcript folder / attachments-folder bookmark / global export folder; reusable previously exported file when non-empty; transaction resume support.
  - Filename uniquing (`-2`, `-3`…); attachments folder name sanitized; relative path computed for the note reference.
  - Checkpointed delivery re-checkpoints even when the exporter repaired the URL at a different location and rewrites the note's audio reference (replacing the stale relative path); ref reference attach skipped when already attached and unchanged.
- Constraints: `#if canImport(AVFoundation)`; audioSaveMode `.off` disables.
- Evidence: `AudioAttachmentExporter.swift`; `CheckpointedAudioDelivery.swift`
- Status: shipped

### F-SH-46 Watch recording-only file export
- Surface: Apple Watch recordings with `watchOutputMode == .recordingOnly`
- Summary: `RecordingOnlyFileExporter` copies a retained Watch M4A byte-for-byte into a user-selected Files folder using a pre-reserved conflict-free filename, chunked copy with full byte verification and atomic move.
- Details:
  - Destination validation (folder configured/bookmark valid & non-stale/is-directory) with typed, actionable errors; `reserveFilename` persisted in WatchInbox for idempotent retry.
  - Filename template tokens `{timestamp}{date}{YR}{time}{id}{id8}{preset}{original}` (default `recording-{timestamp}-{id8}`); sanitization incl. 180-byte UTF-8 cap; reserved-filename validation (must be plain `*.m4a`).
  - Chunked 1 MB copy with cancellation checks; byte-equality verification (size + full compare) before and after move; pre-existing identical file → `wasAlreadyDelivered: true` receipt; partial temp `.vox-partial` cleaned from prior interrupted copies.
- Constraints: requires `watchOutputMode == .recordingOnly` and a configured, valid, non-stale destination-folder bookmark with security-scoped resource access; filename must be pre-reserved before copy.
- Evidence: `RecordingOnlyFileExporter.swift` (whole file)
- Status: shipped

### F-SH-47 Transcript → Capture destination export
- Surface: voice recording delivery via unified Capture pipeline
- Summary: `TranscriptCaptureDestinationExporter`/`ConfiguredTranscriptCaptureDestinationExporter` route voice transcripts (and Watch audio-only recordings) through the same coordinated Markdown pipeline as typed captures, with durable inbox enqueue-then-claim delivery, idempotency by transcript ID, staging of retained audio payloads, and typed retry errors.
- Details:
  - `resolvedDestinationID` uses the same route precedence as every capture (profile-owned route → legacy flow binding → library default → legacy fallback).
  - Frontmatter: static preset keys, enriched title, tags, category (only if category/type absent).
  - Payloads: text body (cleaned preferred) + optional `.retainedAudio` with embed placement honoring `embedAudioInMarkdown`; recording-time preset snapshot used (later edits can't reroute).
  - Audio staging failures throw `audioPreparationFailed` — never constructs a reduced transcript-only retry; staging dir removed after success.
  - Delivery: enqueue (persist before any bookmark work) → claim → resolve destination + bookmark (stale → typed error) → pipeline capture → complete → delivered history record. Location-decision-required returns the request to pending and posts `captureInboxDecisionRequired`; other failures write failed history, return-to-pending, and throw `queuedForRetry`.
  - `exportRecording` delivers Watch audio-only captures as `.audio` payload with `deliveryKind .standard` (metered, unlike voice transcripts which are `.meteredVoiceTranscript` bypassing the Capture quota but consuming transcription minutes).
  - `enforceUnavailableCancellation`: preset location policy with unavailableBehavior `.cancel` aborts without location, keeping the local transcript.
- Constraints: App Group capture directory + shared defaults for the durable inbox/history; destination requires a valid non-stale bookmark; location policy `.cancel` aborts without location.
- Evidence: `TranscriptCaptureDestinationExporter.swift` (whole file)
- Status: shipped

### F-SH-48 Capture bookmark resolution
- Surface: all destination-folder resolution (iOS/macOS)
- Summary: `CaptureBookmarkResolver` resolves destination bookmarks uniformly: macOS tries security-scoped resolution first and falls back to plain resolution for tests/legacy records; iOS uses plain resolution. Returns URL + staleness.
- Details:
  - Stateless `Sendable` enum; `Resolution` carries `url` + `isStale`.
  - macOS: `URL(resolvingBookmarkData:options:[.withSecurityScope])` first; on failure falls back to plain resolution so tests and legacy local bookmarks still work.
  - iOS: plain resolution only (document-picker bookmarks are not security-scoped there).
- Constraints: security-scoped resolution is `#if os(macOS)`-gated; a plain-resolved URL on macOS may lack sandbox access until `startAccessingSecurityScopedResource()` is applied by the caller.
- Evidence: `CaptureBookmarkResolver.swift` (whole file)
- Status: shipped

### F-SH-49 Smart folders & auto-organize
- Surface: settings toggles ("Smart Folders", "Auto-Organize"), Apple Intelligence routing
- Summary: `SmartFolder` pairs a folder bookmark with a name + description that Apple Intelligence uses to route transcripts to the best destination; toggles persisted via `AppConstants` (`smartFoldersEnabled` default false, `autoOrganizeEnabled` default false), with JSON load/save of the folder list in shared defaults.
- Details: `resolveURL()` returns nil for invalid bookmarks/missing folders; auto-organize passes an AI-generated subfolder to `exportConfigured` (see F-SH-41).
- Constraints: off-by-default toggles (`smartFoldersEnabled`, `autoOrganizeEnabled` default false); Apple Intelligence required for routing/naming.
- Constraints: both toggles default off; folders require security-scoped bookmarks that must stay resolvable; AI routing itself lives in the app target.
- Evidence: `SmartFolder.swift` (whole file); `AppConstants.swift` (Smart Folder Routing section)
- Status: legacy (dormant — off-by-default internal flags; llms.txt scope notes say dormant Smart Folder screens are not shipped features)

### F-SH-50 Onboarding analytics
- Surface: onboarding flow (iOS/macOS), paywall, model setup
- Summary: Privacy-first onboarding funnel analytics: 13 event types (`onboarding_started`, step_viewed, microphone_permission_completed, model_setup_completed, keyboard_setup_started/completed, file_export_setup_completed, paywall_shown, purchase_started/finished, restore_started/finished, onboarding_completed), queued with retry, sent to a first-party Cloudflare Worker only when an endpoint is configured — and disabled entirely in production builds unless explicitly enabled.
- Details:
  - Transport factory: DEBUG env `UITEST_ANALYTICS_TRANSPORT`/`ONBOARDING_ANALYTICS_TRANSPORT=offline` → offline transport; `CloudflareOnboardingAnalyticsTransport` when `ONBOARDING_ANALYTICS_ENDPOINT_URL` (Info.plist or env) is configured; else NoOp.
  - Cloudflare transport: POST JSON `{installId, events:[...]}` to `<endpoint>/v1/events`, optional Bearer ingest token (`ONBOARDING_ANALYTICS_INGEST_TOKEN`), 10 s timeout; https enforced (http only for localhost in DEBUG); placeholder tokens ("your_", "replace_with", "$(") rejected.
  - Install ID: random UUID persisted in shared defaults (`onboarding.analytics.install_id.v1`), validated as UUID, lowercased.
  - Client: 50-event durable queue in defaults (`onboarding.analytics.queue.v1`), stable event IDs, sequential flush loop with 30 s retry delay (0 in offline test mode), `flushAndWait` for termination paths; **production builds are disabled by default** (`isEnabledByDefault` false unless DEBUG+`ONBOARDING_ANALYTICS_ENABLED=1`).
  - Experiment assignment: `voxboard_onboarding_activation`/`baseline_v1` sticky assignment in defaults; identifiers validated against a strict charset, length cap, raw-date patterns, and a sensitive-token blocklist (audio/voice/keyboard_text/path/user/…) so no content can leak through experiment IDs; `UITEST_REMOTE_CONFIG=offline` forces baseline.
  - Properties are coarse buckets only: model size buckets, usage buckets (0 / 0–5 / 5–15 / 15+ min; captures 0/1–3/4–7/8–9/10+), permission status, export format/mode, product ID, purchase outcome, error category — never transcript text, filenames, or locations.
  - Runtime context: app version, build number, platform (ios/macos).
- Constraints: no network telemetry without an explicitly configured endpoint; production opt-in only.
- Evidence: `Analytics/OnboardingAnalyticsEvent.swift`, `Analytics/OnboardingAnalyticsFunnel.swift`, `Analytics/OnboardingAnalyticsClient.swift`, `Analytics/CloudflareOnboardingAnalyticsTransport.swift`, `Analytics/OnboardingAnalyticsStorage.swift`, `Analytics/OnboardingAnalyticsTransport.swift`
- Status: shipped (production default off; effectively debug/gated)

### F-SH-51 CaptureCore re-export
- Surface: all package clients
- Summary: `CaptureCoreExports.swift` is a single `@_exported import VoxboardCaptureCore` so the shared package's types (`CaptureRequest`, `CapturePipeline`, `CaptureInbox`, `CapturePresetProfile`, location snapshots, etc.) are visible to every consumer.
- Details:
  - Single-line file containing only `@_exported import VoxboardCaptureCore`; re-exports make CaptureCore's public API visible to every VoxboardShared client without a direct dependency.
  - Lets shared-package consumers (app, keyboard, widgets, Watch, share extension) reference `CaptureRequest`, `CapturePipeline`, `CaptureInbox`, `CapturePresetProfile`, `CaptureSource`, `CaptureLocationOutcome`, and related types transitively.
- Constraints: requires VoxboardCaptureCore target membership in the package graph; none beyond platform minimums.
- Evidence: `CaptureCoreExports.swift`
- Status: shipped (infrastructure)

---

## File-by-file coverage checklist

Every in-scope file was read (large files read in full across sequential segments):

- [x] `ActivityStats.swift` — full
- [x] `AppConstants.swift` — full
- [x] `AppLanguagePreference.swift` — full
- [x] `AsyncExclusiveGate.swift` — full
- [x] `AudioAttachmentExporter.swift` — full
- [x] `AudioFileConverter.swift` — full (first ~90 lines reviewed via batch log; remainder full)
- [x] `AudioRecorder.swift` — full
- [x] `CaptureBookmarkResolver.swift` — full
- [x] `CaptureCoreExports.swift` — full (2 lines)
- [x] `CaptureDeliveryUsageStore.swift` — full
- [x] `CaptureInboxDeliveryService.swift` — full
- [x] `CaptureLocationService.swift` — full (across two segments)
- [x] `CaptureRecordingOriginStore.swift` — full
- [x] `CaptureVoxTextProcessor.swift` — full
- [x] `CheckpointedAudioDelivery.swift` — full
- [x] `CircularAudioBuffer.swift` — full
- [x] `ExternalFileDeliveryTransaction.swift` — full
- [x] `ExternalModelLocation.swift` — full
- [x] `IncrementalWAVWriter.swift` — full
- [x] `KeyboardDebugLog.swift` — full
- [x] `LiveActivityCommandBuilder.swift` — full
- [x] `LiveTranscriptDraftPreview.swift` — full
- [x] `LiveTranscriptionDeliveryReducer.swift` — full
- [x] `MeetingCapture.swift` — full
- [x] `MeetingChunkSampleWriter.swift` — full
- [x] `ModelDownloadSupport.swift` — full
- [x] `ModelManager.swift` — full
- [x] `OnDeviceTranscriptionService.swift` — full
- [x] `ParakeetContext.swift` — full (across two segments)
- [x] `PurchaseAccess.swift` — full
- [x] `RecordingFlow.swift` — full (49 KB head + tail segment; file is 57 KB, tail read via offset)
- [x] `RecordingJobQueue.swift` — full
- [x] `RecordingJobStore.swift` — full (82 KB: declarations map + key sections read verbatim: store init/actor, enqueue signatures, load/recovery, retention/discard, worker lease, handoff intent, preferences; remaining bulk is private persistence helpers with reviewed signatures)
- [x] `RecordingOnlyFileExporter.swift` — full
- [x] `SmartFolder.swift` — full
- [x] `TemplateRenderer.swift` — full
- [x] `Transcript.swift` — full
- [x] `TranscriptCaptureDestinationExporter.swift` — full
- [x] `TranscriptEnricher.swift` — full
- [x] `TranscriptExportKitAdapter.swift` — full
- [x] `TranscriptFileExporter.swift` — full (57 KB across two segments)
- [x] `TranscriptFlowFormatter.swift` — full
- [x] `TranscriptionBackend.swift` — full
- [x] `TranscriptionInsertionPlanner.swift` — full
- [x] `TranscriptionIPC.swift` — full
- [x] `TranscriptSearch.swift` — full
- [x] `TranscriptStore.swift` — full
- [x] `UsageTracker.swift` — full
- [x] `VoiceActivityDetection.swift` — full
- [x] `VoxboardLiveActivity.swift` — full
- [x] `WhisperContext.swift` — full
- [x] `WhisperModelInfo.swift` — full
- [x] `Analytics/CloudflareOnboardingAnalyticsTransport.swift` — full
- [x] `Analytics/OnboardingAnalyticsClient.swift` — full
- [x] `Analytics/OnboardingAnalyticsEvent.swift` — full (type/enum/factory map; value-coder internals summarized)
- [x] `Analytics/OnboardingAnalyticsFunnel.swift` — full
- [x] `Analytics/OnboardingAnalyticsStorage.swift` — full
- [x] `Analytics/OnboardingAnalyticsTransport.swift` — full

## Uncertainties

- `AudioFileConverter.swift` first ~90 lines were reviewed via a truncated batch log; the visible portion included `convertToWhisperWAV`'s in-memory path. Any conversion-error enum cases defined in those first lines beyond `couldNotCreateConverter/couldNotCreateBuffer/noAudioSamples/couldNotCreateFormat` are covered by usage elsewhere but not enumerated verbatim.
- `RecordingJobStore.swift` (82 KB): all public API, state transitions, and recovery semantics were read; ~15 KB of private helpers (bundle-intent transaction internals around lines 700–770 and 1700+) were reviewed at signature level only.
- `OnboardingAnalyticsEvent.swift`: purchase-outcome and error-category enum case values were confirmed via usage sites in `OnboardingAnalyticsFunnel.swift` but not every raw string was listed individually.
- Behavior that lives in app/extension targets (actual UI toggles, SpeechAnalyzer adapter, ScreenCaptureKit tap installation, StoreKit verification, Watch inbox app-side flow) is only described as far as this package's seams reveal; UI-level feature surfaces may add options not visible here.
- Status labels reflect in-package gating only; a "shipped" label means the code path is complete and reachable, not necessarily enabled by default (e.g., smart folders default off; production analytics default off).
