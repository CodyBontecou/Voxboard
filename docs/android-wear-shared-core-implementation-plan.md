# Android, Wear OS, and Shared Core Implementation Plan

Status: **Proposed**

Scope: Android phone/tablet, Wear OS, shared Rust/UniFFI core, and incremental Apple migration

Planning baseline: `b50167a` (`Prepare Vox.md 2.1 release`)

Pinned Health.md precedent: `c70de9201ab7cfbadf2442183dfba23c0d248478`; use files as committed at that revision, not uncommitted changes in a neighboring checkout

Primary precedent: `../health-md/docs/architecture/adr-0001-shared-rust-uniffi-core.md` as committed at the pinned Health.md revision

## 1. Outcome

Deliver a production Android phone/tablet app and a standalone-capable Wear OS app that match Vox.md's existing Apple product capabilities by outcome while preserving its local-first guarantees and user-owned Markdown files.

At the same time, move deterministic post-capture behavior into a language-neutral Rust core consumed through UniFFI by Swift and Kotlin. Apple remains functional throughout the migration and moves from Swift authority to Rust authority one operation at a time.

The program is complete when:

1. Android supports text, links, voice, photos, screenshots, scans, sketches, files, Capture Presets, Markdown editing/routing/placement, templates and metadata, local transcription and model management, history/stats/quotas, audio retention/export, billing, retries, durable recovery, and share/keyboard/widget/shortcut/deep-link/tile entry points.
2. Wear OS records without a phone, preserves audio through process/device interruptions, synchronizes idempotently, and exposes app, Tile, complication, notification, and active-recording surfaces.
3. Equivalent Apple and Android capture inputs produce the agreed deterministic Markdown and logical artifact plans.
4. User content is staged locally before any UI reports success or clears the composer.
5. No capture, transcription, enrichment, geocoding, or retry path silently uses a network service; any permitted model acquisition, billing, or explicitly consented label lookup is isolated, disclosed, and carries no captured content beyond the coordinates the user chose to resolve.
6. Apple can roll individual operations between `legacy`, `shadow`, and `rust` without changing persisted user files or crossing an unsafe side-effect boundary.
7. CI verifies contracts, fixtures, generated bindings, Rust, Swift, Android, Wear, packaging, and release artifacts.

## 2. Preconditions and sequencing constraints

### 2.1 Stabilize the current Apple source of truth

The recording queue has recently landed in the planning baseline after substantial persistence and application changes. Before defining cross-language recording contracts:

- Confirm the landed recording queue and release behavior as the intended source of truth.
- Establish a clean implementation-start baseline commit and record its fixture provenance; do not assume this planning SHA remains the implementation base.
- Confirm the intended behavior of:
  - `Packages/VoxboardShared/Sources/VoxboardShared/RecordingJobStore.swift`
  - `Packages/VoxboardShared/Sources/VoxboardShared/RecordingJobQueue.swift`
  - `Packages/VoxboardShared/Sources/VoxboardShared/RecordingFlow.swift`
  - `Voxboard/PersistentRecorder.swift`
  - `Voxboard/VoxboardApp.swift`
- Do not generate contracts from uncommitted, release-branch-only, or still-transitional persistence models.

### 2.2 Add new top-level directories; do not move Apple yet

Add `apps/android`, `Packages/contracts`, and `Packages/vox-core-rust` without relocating the current Xcode project. Move Apple under `apps/apple` only after Apple build/test CI is green and only as a behavior-free change.

### 2.3 Required product decisions

The following defaults are assumed by this plan. Record each decision in an ADR before its dependent milestone begins.

| Decision | Proposed default | Required by |
|---|---|---|
| Cross-platform Markdown parity | Byte-identical path and UTF-8 note bytes for equivalent contract inputs | M2 |
| Ambiguous retry policy | Embed request-ID markers for shared-note mutations; otherwise enter `unknownOutcome` rather than retry blindly | M3 |
| Template freeze point | Freeze template bytes when a delivery is first prepared | M2 |
| Wear deletion point | Retain Watch/Wear media through `vaultCommitted`; offer explicit storage-pressure recovery | M7 |
| Android content backup | Exclude captures, audio, transcripts, databases, journals, prepared bytes, and model caches; optionally back up non-content preferences | M3 |
| Offline ASR baseline | App-owned local long-form backend is the dependable path; system on-device recognition is an optional capability | M4 |
| IME fallback | A visible capture activity is acceptable when direct IME microphone capture fails OS/OEM/policy validation | M6 |
| Billing | Play purchase infrastructure may use the network, but it remains isolated from captured content | M8 |
| Cross-store entitlement | Purchases are store-specific unless a separately approved account/backend project is introduced | M8 |
| Android free-quota reinstall behavior | Free usage resets after uninstall unless an approved account/backend design is introduced; classify this as product-adjusted rather than claiming Keychain-equivalent resistance | M1/M3 |
| Location label lookup | Coordinate-only is always available locally; city/place labels use a vetted offline database or an explicit per-preset consented system lookup whose possible network use is disclosed and frozen in the request | M1/M5 |
| Advanced local intelligence | Diarization and shipped enrichment outcomes require an app-owned local implementation for program completion; deferral is a release-scope reduction, not parity completion | M9 |

## 3. Architectural principles

1. **Share deterministic policy, not platform SDKs.** Rust starts after native capture and ends before native side effects.
2. **Durability precedes processing.** The source package must survive before the composer clears, transcription starts, or delivery is attempted.
3. **Prepared output is immutable.** Retries reuse persisted bytes and hashes rather than rerendering against changed settings.
4. **Native storage capabilities stay native.** Apple bookmarks, file coordination, Android tree URIs, document IDs, Room, and provider behavior never enter canonical domain models.
5. **No FFI callbacks into platform storage.** UniFFI calls receive bounded owned DTOs and return bounded owned plans.
6. **Version contracts independently.** Core API, capture input, artifact plan, renderer, persisted state, and wearable protocol versions do not advance together automatically.
7. **Preserve legacy bytes before replacing codecs.** Existing Swift JSON and property-list formats are compatibility inputs, not automatically the new canonical model.
8. **Treat uncertain completion explicitly.** A local receipt cannot prove that a provider did not commit immediately before process death.
9. **Parity is semantic, not visual.** Android system surfaces should feel native rather than imitate Apple frameworks.
10. **Fail closed.** Unsupported versions, missing local speech, invalid paths, revoked grants, and incompatible models must produce actionable local failures, not hidden fallbacks.

## 4. Target repository and module topology

```text
Vox.md/
  apps/
    android/
      app/                         # Phone/tablet UI and Android entry points
      wear/                        # Wear OS app
      core-bridge/                 # Generated UniFFI Kotlin + handwritten service
      capture-domain/              # Kotlin orchestration interfaces and native adapters
      data/                        # Room, DataStore, staging, SAF, workers
      platform-services/           # Audio, ASR, camera, OCR, billing, Data Layer
      build-logic/                 # Convention plugins and pinned toolchains

  packages/
    contracts/
      README.md
      manifest.json
      product-capabilities.json
      capture-preparation-input/v1/
      required-observations/v1/
      capture-materialization-input/v1/
      artifact-plan/v1/
      wearable-protocol/v1/
      fixtures/
      scripts/

    vox-core-rust/
      Cargo.toml
      rust-toolchain.toml
      crates/
        vox-core/                  # Pure deterministic implementation
        vox-core-uniffi/           # Thin mobile FFI facade
      xtask/                       # Contract and binding tooling
      scripts/
        generate-kotlin-bindings.sh
        generate-swift-bindings.sh
        build-android-cdylibs.sh
        build-apple-xcframework.sh

  Packages/VoxboardShared/         # Existing Apple package remains in place initially
  Voxboard*/                       # Existing Apple targets remain in place initially
  docs/
```

### Android module responsibilities

| Module | Owns | Must not own |
|---|---|---|
| `app` | Compose navigation, ViewModels, phone/tablet UI, Sharesheet activity, deep links, shortcuts, widget, Quick Settings tile, IME shell | Markdown rules, filesystem assumptions, ASR implementation details |
| `wear` | Wear Compose UI, recorder service, local Wear persistence, Tile, complication, ongoing activity, Data Layer client | Phone vault access or phone-only state |
| `core-bridge` | Generated Kotlin binding, lazy native loading, version handshake, stable Kotlin errors, DTO serialization | UI or platform side effects |
| `capture-domain` | Use cases, repository interfaces, native/core adapters, capture orchestration | Android framework storage implementation |
| `data` | Room, app-private packages, SAF resolver/executor, WorkManager drain, reconciliation | Rendering policy |
| `platform-services` | Audio, local ASR engines, camera/photo/scanner/OCR, location, Play Billing, Wear transport | Durable domain truth or Markdown formatting |

Dependency direction is inward: UI and platform modules depend on domain interfaces; domain depends on `core-bridge`; storage implementations depend on domain contracts. The Rust bridge never depends on UI or Android services.

## 5. Ownership boundary

### 5.1 Rust-owned behavior

Initial ownership:

- Contract decoding, validation, field bounds, and typed errors
- Capture/preset/destination policy validation after native capability resolution
- Logical path segment validation and traversal rejection
- Deterministic title, filename, date, timezone, and template expansion
- Markdown/frontmatter rendering
- New-note and rolling-note content generation
- Existing-note append, prepend, and heading placement from frozen input bytes
- Request markers, hashes, and destination-neutral materialized plans
- Privacy-safe mismatch diagnostics and build/version information

Later ownership after native behavior is stable:

- Pure recording-job transition and retention reducers
- Transcript/history filtering and statistics reducers
- Wearable message canonicalization/fingerprints
- Other destination-neutral deterministic transforms

### 5.2 Native-owned behavior

Swift/Kotlin retain:

- UI, navigation, accessibility, localization, and lifecycle
- Microphone, audio focus/session, interruptions, notification controls, and foreground services
- Apple Speech, Android recognition, Whisper/Parakeet/other runtime adapters
- Camera, Photo Picker, scanner, OCR, sketch input, file import, and location
- Security-scoped bookmarks and Apple file coordination
- SAF tree grants, document IDs, provider capabilities, and `ContentResolver`
- Room/JSON persistence, transactions, worker leases, process recovery, and scheduling
- Attachment reads/copies and all destination commits
- StoreKit/Play Billing, Keychain/Keystore, signing, and credentials
- Keyboard, Sharesheet, widgets, shortcuts, Quick Settings, Tiles, complications, and notifications
- WatchConnectivity and Wear Data Layer transport

### 5.3 Queue boundary

Rust may eventually expose a reducer shaped like:

```text
reduceJob(currentSemanticState, event, frozenPolicy, frozenNow)
    -> newSemanticState + abstractRequiredEffects
```

Rust must not own the queue repository, Room/JSON codec, locks, worker loop, WorkManager, filesystem recovery, live progress stream, or OS execution opportunities.

## 6. Contracts and versioning

### 6.1 Contract categories

Do not use one universal canonical model. Maintain:

1. **Legacy persisted codecs** — current Apple JSON/property-list schemas and their compatibility decoders.
2. **Internal core contracts** — explicit platform-neutral input/output records crossing UniFFI.
3. **Durable cross-device protocols** — versioned Watch/Wear synchronization envelopes.
4. **User artifacts** — Markdown and attachments. Their compatibility is independent of all internal versions.

### 6.2 Contract rules

- UUIDs are normalized lowercase strings.
- Time is explicit epoch time plus the required timezone/calendar facts; no ambient current locale or timezone.
- Tagged unions use explicit discriminator values.
- Binary payloads are referenced by source ID, length, media type, and SHA-256; large media never crosses UniFFI.
- Paths are arrays of logical relative segments, never absolute paths, bookmarks, tree URIs, or document IDs.
- Ordered fields and payloads stay ordered.
- Optional/default/unknown-field behavior is normative and fixture-tested.
- Every array, string, note, and batch has an explicit maximum and a typed oversize error.
- Errors contain codes and safe field paths, not user content.
- Contract fixtures are synthetic and include producer provenance and SHA-256 in `manifest.json`.

### 6.3 Initial core contracts

#### `capture-preparation-input/v1`

Contains the normalized request facts, frozen preset/destination policy, logical route policy, and operation/profile pins needed to determine which native observations are required. It contains no template bytes, existing-note bytes, provider IDs, bookmarks, or URIs.

#### `required-observations/v1`

Contains an ordered, bounded list of typed observation requests such as candidate occupancy, frozen template bytes/hash, current note bytes/hash, and staged-asset metadata. Native code resolves each request once and includes the results in materialization input; Rust never calls back into storage.

#### `capture-materialization-input/v1`

Contains:

- Contract and renderer revision
- Request ID, capture source, and created-at facts
- Ordered normalized text/link payloads
- Frozen preset and destination policy without storage handles
- Logical route and collision policy
- Frozen template bytes/hash or explicit absence
- Frozen metadata/frontmatter settings
- Every resolved observation keyed by the preparation request ID, including candidate occupancy, existing-note bytes/length/hash, template bytes/length/hash, and staged-asset descriptors
- Explicit snapshot revision/hash so a response from another prepare attempt cannot be mixed into this call

Control JSON is limited to 1 MiB. Byte-bearing inputs use a bounded session with chunks no larger than 1 MiB and an initial aggregate note/template limit of 256 MiB. M1 may lower or raise the aggregate limit only with legacy-corpus, memory, and product evidence; M5 cannot claim existing-note parity while any Apple-supported note size lacks an Android path.

#### `artifact-plan/v1`

Contains:

- Request ID and all core/model/profile pins
- Logical note path segments
- Exact bounded UTF-8 note bytes; native code persists them as immutable prepared bytes before commit
- Deterministic operation and artifact IDs plus an explicit ordered commit sequence
- Write/mutation mode, collision policy, and expected-existing/absent policy
- Expected original hash when mutating an existing note
- Result SHA-256, media type, and byte count
- Complete attachment descriptors: source ID, source media type/length/SHA-256, logical destination segments, expected-existing policy/hash, result length/hash, and equivalence rule
- Idempotency marker details
- Required journal frontier/receipt kind for every operation
- Typed warnings and diagnostics

Plan output uses the same 1 MiB chunking rule for prepared note bytes. Native receipts correlate the plan hash, operation ID, observed destination identity, verified length/hash, and commit timestamp without exposing paths in diagnostics.

#### `wearable-protocol/v1`

This is a protocol family rather than one catch-all payload. M1 defines separate bounded envelopes and conformance fixtures for:

- capability/version negotiation and unsupported-version responses;
- preset inventory plus complete frozen preset snapshots and hashes;
- recording metadata, including transcript versus Recording Only mode, local-ASR policy, location exclusion/policy, and native recording-only folder/filename policy references;
- asset manifests and resumable chunk/channel frontiers with length and SHA-256;
- reconciliation summaries and transfer receipts;
- correlated `phoneIngested`, `vaultCommitted`, `terminalFailure`, and `discarded` acknowledgements;
- phone/user actions for reassignment, retry, discard, and explicit retention/deletion authorization.

Every envelope contains protocol/message kind, message/recording/sender-installation/device IDs, epoch and monotonic revision, correlation ID, replay rules, and bounded unknown-field behavior. Preset snapshots carry their schema/revision and complete portable policy rather than relying on a matching phone revision. Storage handles remain native and are represented only by stable capability references resolved on the owning phone.

### 6.4 Core API shape

Start with a minimal coarse surface:

```text
getBuildInfo() -> CoreBuildInfo
checkReadiness(ExpectedVersions) -> ReadinessResult
prepareCapture(CapturePreparationInputJson) -> RequiredObservationsJson
beginMaterializeCapture(CaptureMaterializationControlJson) -> CaptureMaterializationSession

CaptureMaterializationSession
  pushObservationBytes(observationID, sequence, chunk, eof)
  finishInput() -> ExpectedArtifactDescriptorsJson
  nextPreparedArtifactChunk(maxBytes) -> {artifactID, sequence, bytes, eof}
  finalizeOutput(DrainedArtifactHashesJson) -> ArtifactPlanJson
  cancel()
```

The session moves only through `input → outputReady → draining → finalized|cancelled`. `finishInput()` seals input and returns expected artifact descriptors—ordered operation/artifact IDs, media types, lengths, hashes, and required receipt/frontier kinds—but no side-effect receipt and no committable plan. Native code drains every sequenced artifact stream into immutable prepared files, verifies them, and supplies the drained hashes to `finalizeOutput()`. Only that method can return the committable plan, which native persists before commit. Small text/link requests use the same session so there is one bounded API, not a separate unbounded JSON shortcut.

Later add separate operations instead of expanding one call:

```text
beginExistingNoteMaterialization(...) -> bounded input/output session
reduceRecordingJob(...)
canonicalizeWearEnvelope(...)
```

Sessions enforce 1 MiB maximum chunks, explicit cancellation, one input seal, one output finalization, and terminal close semantics. Repeated, missing, out-of-order, wrong-artifact, post-EOF, hash-mismatched, abandoned, or post-terminal calls fail closed. A cancelled or incomplete session produces no committable plan.

The UniFFI layer catches Rust panics and maps them to a stable privacy-safe error enum. Handwritten Swift/Kotlin wrappers perform lazy loading, readiness checks, cancellation, DTO adaptation, and user-facing error mapping.

## 7. End-to-end capture lifecycle

Every vault-directed phone capture entry point uses the same transaction:

```text
native input
  -> app-private staging
  -> durable request envelope
  -> Room/index insertion
  -> prepare observations
  -> Rust materialization
  -> immutable prepared output
  -> native destination commit
  -> destination readback/verification
  -> durable receipt
  -> payload-free history tombstone + retention cleanup
```

### 7.1 Durable local enqueue

1. Allocate a stable request UUID.
2. Create a temporary package under `noBackupFilesDir`.
3. Copy inbound URI/media bytes immediately while temporary grants remain valid.
4. Write and fsync the request envelope and asset manifest.
5. Close media containers and verify readable length.
6. Atomically promote the package where the local filesystem permits.
7. Insert/update the Room index.
8. Only now report **Saved locally** and clear the composer.
9. Reconcile filesystem packages without Room rows and Room rows without packages at launch and before drains.

Suggested package:

```text
noBackupFilesDir/vox-captures/<request-id>/
  request.json
  assets.json
  assets/<asset-id>.<extension>
  transcription/
  prepared/
    artifact-plan.json
    note.bin
  delivery-journal.json
```

Room is the searchable index and coordination store. The package and journal preserve recoverability when database and filesystem updates cannot commit atomically.

Keyboard editor insertion is a separate durable operation profile. It shares capture IDs, local audio/transcription jobs, entitlement checks, and retention rules, but it does not invoke vault artifact materialization or SAF commit. Its terminal side effect is a validated IME-owned editor insertion or a recoverable transcript awaiting user action.

### 7.2 Prepare, materialize, commit

**Prepare** resolves portable policy and returns required live observations. Native obtains current template bytes, candidate occupancy, current note bytes/hash, and staged-asset metadata.

**Materialize** receives those frozen observations and returns exact output bytes, paths, expected hashes, and operations. Native persists this output before side effects.

**Commit** executes a pinned immutable plan:

1. Revalidate destination permission and current original hash.
2. Resolve logical paths using the platform storage capability.
3. Copy attachments first to deterministic unique paths and verify length/hash.
4. Commit the note last and read back its length/hash.
5. After each artifact, persist a correlated receipt and advance the durable journal frontier before the next operation.
6. Persist the verified note receipt before cleanup.
7. Track orphan attachments if the note fails and reconcile them later.

If state changes before commit, rematerialize while still pre-commit. Once state becomes `committing`, never rerender, switch engines, or fall back.

### 7.3 Delivery state

Use explicit states rather than treating WorkManager as the queue:

```text
staging
queued
preparing
materialized
committing
completed
retryableFailure(nextAttemptAt)
needsPermission
needsUserAction
unknownOutcome
permanentFailure
discarded
```

Persist attempt count, lease, engine/core/contract pins, prepared-plan hash, and typed error code. Do not persist user content in analytics/history tables.

### 7.4 Idempotency and unknown outcomes

- Derive deterministic operation IDs from request ID plus destination/operation identity.
- New notes and attachments use stable logical paths and verify existing content before recreating.
- Shared-note mutations use an invisible request marker when the product decision allows it.
- If a provider may have committed but no marker/verified receipt is available, transition to `unknownOutcome` and ask the user to inspect/reconcile.
- Never assume a Room receipt can close the crash window between destination commit and receipt persistence.

### 7.5 IME transcription and insertion lifecycle

```text
explicit IME action
  -> durable recording/transcription package
  -> local transcription
  -> bounded result tied to IME session + editor token
  -> IME revalidates active editor and sensitive-field policy
  -> insert once, or preserve for explicit Copy/retry
```

Only the active `InputMethodService` owns `InputConnection` and may call `commitText`. A visible fallback activity returns a result to the IME; it never holds or invokes the editor connection itself. Focus loss, editor/package change, IME recreation, process death, stale/duplicate result, or token mismatch must preserve audio/transcript and refuse automatic insertion into a different editor.

## 8. Android product architecture

### 8.1 SDK and toolchain baseline

- Phone/tablet `minSdk`: API 28.
- Wear `minSdk`: API 30 / Wear OS 3.
- Compile against the newest stable SDK. If shipping on or after 31 August 2026, plan for phone `targetSdk 36` and Wear `targetSdk 35`, then re-check the live Play requirement immediately before release.
- Pin AGP, Kotlin, Compose, JDK, NDK, Rust, Cargo dependencies, and UniFFI in reviewed version files. Do not make preview-only APIs required for parity.
- Initially build Rust for `arm64-v8a`, `armeabi-v7a`, `x86_64`, and `x86` to match the Health.md packaging pattern and support release/emulator coverage. Review 32-bit packaging against real device support and bundle-size evidence before production.

### 8.2 UI and navigation

Use Jetpack Compose, a single-activity architecture, unidirectional data flow, `StateFlow`, and adaptive phone/tablet/foldable layouts.

Primary screens:

- Onboarding and local-first/privacy explanation
- Vault/destination setup and permission repair
- Quick Capture composer
- Recording screen and persistent recording controls
- Capture Presets and route editor
- Capture inbox/status/retry/reconcile
- Transcript history, search, review, and correction
- Statistics and quota/entitlement
- Local models/languages/storage management
- Wear connection and transfer status
- Settings, permissions, backup behavior, and diagnostics export

All surfaces call shared use cases. The widget, share target, keyboard, tile, shortcut, and deep link must not implement separate delivery logic.

### 8.3 Storage

- Use SAF `ACTION_OPEN_DOCUMENT_TREE` and persisted URI permission for user-owned vaults.
- Never request `MANAGE_EXTERNAL_STORAGE`.
- Prefer Photo Picker and sender-granted content URIs over broad media permissions.
- Keep tree URIs/document IDs in native destination records only.
- Use Room for durable indexes/jobs and DataStore for non-content preferences.
- Exclude all content-bearing files and databases from Auto Backup/data extraction rules.
- Add grant repair and destination re-selection UX; queued packages remain intact while permission is unavailable.

### 8.4 SAF executor

Provider behavior is capability-tested, not assumed:

- No POSIX path, symlink, case, atomic rename, or immediate consistency assumptions.
- Resolve each logical segment through `DocumentsContract`/`ContentResolver`.
- Use temporary documents and rename only when the provider proves support.
- Read back length/hash after writes.
- Re-read current note hash immediately before existing-note mutation.
- Persist `unknownOutcome` when commit status cannot be proved.
- Test local storage and at least two non-local DocumentsProviders on physical devices.

### 8.5 Background execution

- A user-started foreground service owns active microphone capture.
- Start it while an eligible visible/user-interaction context exists and immediately show an ongoing notification.
- Declare microphone foreground-service permissions/type and Play Console usage.
- WorkManager performs transcription, delivery, cleanup, and reconciliation; it never initiates surprise recording.
- Use unique drain work and exponential backoff, but keep retry timing/state in the durable job model.
- Drain opportunistically on app foreground in addition to WorkManager.

### 8.6 Permissions

Request only at the point of use:

- `RECORD_AUDIO` immediately before voice capture is enabled.
- Notification permission before relying on notification recording controls.
- Fine/coarse location only for explicit one-shot location metadata.
- SAF/Photo Picker URI grants instead of broad storage/media permission.
- Camera permission only for CameraX fallback; ML Kit's scanner-owned flow does not require app camera permission.

Handle denial, device-wide microphone disablement, lock state, interruptions, and revoked grants without dropping staged content.

### 8.7 Security and privacy baseline

- Keep all capture packages under `noBackupFilesDir`; separately exclude content-bearing Room databases and any content outside that directory through backup/data-extraction rules.
- Export only the Sharesheet activity, IME service, widget/tile receivers, and deep-link surfaces that Android requires. Protect every other component and validate caller-controlled intents.
- Use explicit, immutable `PendingIntent`s where mutability is not required and stable request IDs for replay protection.
- Treat every incoming URI, MIME type, filename, deep link, shortcut extra, and wearable message as untrusted. Bound reads, sniff media where needed, sanitize logical names, and reject path traversal or unsupported schemes.
- Never log note text, transcript text, URLs, coordinates, filenames, tree URIs, document IDs, model input, surrounding keyboard context, or raw wearable payloads.
- Keep billing credentials, signing material, and any future destination credentials in native Keystore-backed references. They never cross UniFFI or enter capture packages.
- Audit dependency and SDK network behavior. Capture content may not leave the device; model and billing traffic must be explicit and isolated from content-bearing stores.
- Define deletion semantics for active jobs, completed tombstones, recordings, transcripts, models, diagnostics, and Wear replicas, including what can and cannot be securely erased on flash-backed storage.

## 9. Capability implementation matrix

| Product capability | Android/Wear implementation | Parity classification | Delivery milestone |
|---|---|---|---|
| Text and link capture | Compose composer + Rust materialization + SAF | Exact outcome | M3 |
| Capture Presets | Kotlin UI/repository; portable frozen policy DTO | Exact outcome | M3/M5 |
| New, rolling, existing-note placement | Rust logical rendering/mutation; native SAF commit | Exact outcome | M3/M5 |
| Templates/frontmatter | Frozen native template observation + Rust renderer | Exact outcome | M3/M5 |
| Durable drafts/inbox/history | App-private packages + Room | Exact outcome | M3 |
| Long voice recording | Microphone foreground service + ongoing notification | Exact outcome, native Android surface | M4 |
| Local transcription | App-owned local backend; optional system on-device recognizer | Product-adjusted | M4 |
| Transcript editing/search | Compose + Room/indexed metadata; content stays local | Exact outcome | M4 |
| Markdown editor and customizable Capture Bar | Selection-aware Compose editor, ordered action configuration, undo and formatting commands | Exact outcome | M3/M5 |
| One-shot/persistent recording modes | Recorder service with explicit session/segment state and durable segment jobs | Product-adjusted for Android lifecycle | M4 |
| Live finalized/volatile transcription and pause detection | Backend capability contract; stream only when the selected local engine supports it; local VAD companion | Product-adjusted | M4/M9 |
| Model picker and storage management | Explicit local model catalog, consented downloads, verification, selection, deletion, and capability state | Exact outcome | M4 |
| Photos/screenshots/camera | Photo Picker filters + CameraX | Exact outcome | M5 |
| Scans/PDF/journal OCR | ML Kit scanner, bundled OCR, CameraX/manual fallback; preserve original and derived Markdown | Product-adjusted | M5 |
| Sketches | Compose Canvas and retained raw strokes + rendered image | Product-adjusted | M5 |
| Files and audio attachments | Sharesheet/SAF URI import copied to staging; preset-controlled attachment references | Exact outcome | M5 |
| Opt-in preset location metadata | Explicit one-shot fix, privacy mode, frozen unavailable outcome, structured fields, and no background tracking | Exact outcome with Android geocoder differences | M5 |
| Transcript/history export | Local TXT/Markdown/JSON/YAML rendering plus share/SAF export | Exact outcome | M5 |
| Private activity stats | Content-free local ledger and reducers | Exact outcome | M5 |
| Free quotas and successful-delivery accounting | Idempotent local metering by request ID; Play entitlement where purchased; free counter resets on uninstall absent a future approved account service | Product-adjusted reinstall behavior | M3/M8 |
| Share extension | Exported `ACTION_SEND`/`ACTION_SEND_MULTIPLE` activity | Exact outcome | M6 |
| Keyboard | `InputMethodService`, prototype-gated microphone, visible-activity fallback | Product-adjusted/high risk | M6 |
| Shortcuts/deep links | Static/dynamic/pinned shortcuts and stable intent routes | Exact outcome | M6 |
| Home widgets | Jetpack Glance | Exact outcome within widget constraints | M6 |
| Control Center control | Quick Settings `TileService` | Product-adjusted | M6 |
| Live Activity/Dynamic Island | Ongoing notification plus widget/tile/in-app state | No literal equivalent | M4/M6 |
| StoreKit lifetime purchase | Play Billing non-consumable | Commercial equivalent | M8 |
| Queue scheduling and recovery actions | Immediate/idle/manual policy; Retry/Retry All/Process Now/Copy/share/reveal/retention override/delete | Exact outcome | M4 |
| Automatic preset transcript export | New/append TXT/Markdown/JSON/YAML, filename/template/frontmatter rules, and optional audio reference | Exact outcome | M5 |
| Watch recording | Standalone Wear recorder + local queue | Exact outcome | M7 |
| Watch Recording Only | Frozen folder/filename policy, phone-native verified audio export, no location metadata | Exact outcome | M7 |
| Watch quick action/status | Wear Tile, complication, Ongoing Activity | Product-adjusted native equivalent | M7 |
| Watch transfer | Data Layer Asset/Channel + Vox acknowledgements | Exact outcome with app protocol | M7 |
| Apple Intelligence enrichment outcomes | App-owned local model implementing approved cleanup/title/tag/checklist/meeting/custom-transform profiles | Product-adjusted implementation; required for full parity | M9 |
| Speaker diarization | App-owned local runtime/model on declared device tiers | Product-adjusted implementation; required for full parity | M9 |

## 10. Recording and transcription design

### 10.1 Recorder

The recorder service must:

- Start only from explicit user action.
- Create the durable recording package before opening the microphone.
- Record to a recoverable local format/container and finalize incrementally where possible.
- Support pause, resume, stop, and cancel from the app and notification.
- Handle calls, audio focus changes, input loss, route changes, device mic disablement, ordinary process death, task dismissal, force-stop, reboot, storage exhaustion, and zero/silent input as distinct cases.
- Flush a recoverable audio frontier at least every two seconds. Force-stop and reboot are not continuous-recording promises: after the next explicit launch, detect the interruption and offer finalize/recover/discard for the last durable prefix.
- Publish status through a repository observed by app, notification, widget, and tile.
- Never delete audio because transcription or destination delivery failed.

### 10.2 Transcription abstraction

Define a native interface shared semantically with Apple:

```text
TranscriptionBackend
  capabilities(language, device) -> availability/model state
  transcribe(localAsset, options) -> local result stream/final result
  cancel(jobID)
```

Implementations:

1. Android on-device `SpeechRecognizer` only when `isOnDeviceRecognitionAvailable()` and language/model checks pass. Do not use generic network-capable recognition as fallback.
2. App-owned local long-form backend, initially Whisper unless benchmarking selects another runtime.
3. Manual/audio-only mode when no local model can run.

Model selection must consider language coverage, APK/download size, licensing, CPU/GPU/NPU support, RAM, battery, thermal behavior, cancellation, timestamps, and expected recording length. Model downloads require explicit consent and show size/state. Network use is limited to model acquisition, never inference content.

### 10.3 Recording job pipeline

```text
recorded
  -> queuedForTranscription
  -> transcribing
  -> transcriptPrepared
  -> captureMaterialized
  -> committing
  -> completed
```

Side states include `paused`, `waitingForModel`, `needsPermission`, `retryableFailure`, `unknownOutcome`, `permanentFailure`, and `discarded`.

Persist semantic events and native checkpoints. The eventual Rust reducer is added only after Swift and Kotlin behavior have stable fixtures.

## 11. Multimodal implementation

### Photos and camera

- Use Android Photo Picker for existing media.
- Use CameraX for app camera capture.
- Copy selected/captured bytes into staging before enqueue completes.
- Preserve media type, orientation, dimensions, original filename when safe, byte length, and SHA-256.

### Scans and OCR

- Prefer ML Kit Document Scanner for GMS devices.
- Provide CameraX/manual crop fallback for non-GMS or unavailable-module cases.
- Prefer bundled OCR models where offline first-use is required.
- Persist original scan/PDF separately from derived OCR text.
- OCR failure degrades to attachment-only; it never deletes the source.

### Sketches

- Store a versioned raw stroke model plus a rendered attachment preview.
- Keep digital-ink recognition optional and separate from capture durability.
- Treat language-model downloads like ASR model downloads.

### Files and shared URIs

- Copy sender-granted URI bytes immediately; grants may expire after the share activity.
- Sanitize logical filenames while preserving safe extensions and media types.
- Enforce configurable local size bounds and provide a clear oversize error before composer cleanup.

### Preset location metadata

- Keep location disabled by default and request one origin-time fix only for an explicitly opted-in preset or the independent Current Location editor action.
- Freeze the privacy-adjusted location or the unavailable outcome at the invocation/recording-stop boundary; retries never acquire a later location.
- Support Exact and City/coarsened policies, structured field selection/renaming, map/geo links, and validated advanced frontmatter without continuous or background tracking.
- Coordinate-only output is the strict local default. The independent Current Location editor action reproduces its shipped map-link outcome directly from coordinates and never calls a geocoder.
- Place/city labels in preset metadata require either a vetted offline database or explicit per-preset consent for Android's system geocoder, with disclosure that it may use a remote backend. Never classify the platform geocoder as guaranteed local.
- Freeze whether labels were requested, which lookup class was consented (`offline`, `systemMayUseNetwork`, or `none`), and the resulting label/unavailable state. A retry cannot newly disclose coordinates or switch lookup class. If a future independent editor action requests labels, it requires the same disclosure as an invocation-specific decision rather than inheriting preset consent.
- Test Current Location and no-consent preset flows with networking disabled and with network-call detection; both must remain coordinate/map-link capable without an outbound request.
- Remove coordinates and labels when completed jobs become content-free tombstones; pending jobs retain only what is needed for recovery.

## 12. System entry points

### Sharesheet

- Export an activity for `ACTION_SEND` and `ACTION_SEND_MULTIPLE` with narrow MIME handling.
- Normalize text, URLs, and URI grants into the same durable capture package.
- Show a minimal preset/edit confirmation screen.
- Finish only after durable local enqueue, not destination delivery.

### Shortcuts and deep links

- Define stable versioned routes for quick capture, preset capture, recording, inbox, and permission repair.
- Make intent handling idempotent across recreation and duplicate delivery.
- Keep captured/sensitive text out of shortcut labels and metadata.

### Glance widget

- Provide text, voice, and selected-preset actions.
- Display coarse queued/recording/failure state only.
- Launch eligible user-interaction paths rather than performing long work in the widget.

### Quick Settings tile

- Support open/start and stop depending on current recording state.
- Handle secure lock state with explicit unlock flow.
- Treat the tile as a compact action, not a full capture UI.

### Keyboard

Prototype before committing to launch parity:

- Separate the IME transcription/insertion profile from vault capture and keep the IME service isolated from vault browsing and destination state.
- Request microphone permission in a visible settings/activity flow.
- Disable dictation in password and sensitive input fields.
- Do not retain surrounding editor context; persist only an opaque IME session ID, editor identity token, audio/transcript job ID, and delivery status.
- Display unmistakable listening/stop state.
- Validate microphone foreground eligibility on Pixel and Samsung across supported API levels, including lock/background transitions.
- If direct recording is unreliable, launch a visible capture activity tied to the IME session. The activity returns a bounded result to the IME, and only the IME inserts after revalidating the original active editor.
- On focus loss, editor change, token mismatch, duplicate result, or IME recreation, retain the result for explicit Copy/retry rather than inserting into whichever editor is now active.

## 13. Wear OS architecture

### 13.1 Product model

Wear is hybrid but offline-first:

- Recording works without the phone.
- The watch stores the audio, metadata, preset snapshot, and transfer state durably.
- The phone owns vault access, full transcription, and final Markdown delivery.
- Preset synchronization is revisioned; each recording freezes the selected preset snapshot.

Rust does not need to run in the Wear process initially. Kotlin and Swift codecs can implement the versioned protocol against shared fixtures.

### 13.2 Wear recording lifecycle

```text
localRecording
localRecorded
assetPublished
phoneIngested
vaultCommitted
sourceDeletionAuthorized
```

Additional states: `transferRetry`, `unsupportedVersion`, `phoneUnavailable`, `terminalFailure`, and `discarded`.

`phoneIngested` and `vaultCommitted` are correlated application acknowledgements, not transport delivery. `sourceDeletionAuthorized` records that the configured acknowledgement threshold was durably observed and cleanup may occur; it is not another phone-side delivery milestone. Recording Only reaches `vaultCommitted` only after the phone verifies the user-visible audio export, and it never requests location metadata.

The watch app must preserve the last flushed audio prefix through phone absence, ordinary process death, reboot, storage pressure, interruptions, and Data Layer duplicates. As on phone, force-stop/reboot ends live capture; the next explicit launch detects and offers recovery of the durable prefix. Retry/discard and phone-side reassignment become visible only after their state/action receipt is durable.

### 13.3 Transfer protocol

- Use `DataClient` Data Items/Assets for buffered synchronization.
- Use `ChannelClient` only where a connected large transfer benefits from streaming.
- Never use `MessageClient` as the sole recording transport.
- Deduplicate by recording UUID, sender installation ID, revision, length, and SHA-256.
- Phone sends `phoneIngested` only after checksum verification and durable phone-owned package commit.
- Phone sends `vaultCommitted` only after verified destination delivery.
- Watch deletion follows the product acknowledgement decision, currently `vaultCommitted`, and requires a correlated durable `sourceDeletionAuthorized` transition; storage pressure may prompt explicit user discard but cannot silently weaken the threshold.
- Resume transfers from durable chunk/channel frontiers and correlate transport receipts separately from application acknowledgements.
- Both devices reconcile outstanding IDs and pending user actions on reconnect and reject stale/unsupported protocol versions safely.

### 13.4 Wear surfaces

- Compose for Wear app for recording, presets, status, retries, and settings.
- Tile for quick record/open action and coarse state.
- Complication for ready/recording/pending-failure state.
- Microphone foreground service and Ongoing Activity during recording.
- Local notification where required by OS behavior.

## 14. Apple migration

Apple migration follows a strangler pattern and does not wait for Android completion.

### 14.1 Adapter seams

| Existing Apple file | Migration role |
|---|---|
| `CaptureModels.swift` | Preserve legacy codecs; adapt to portable input DTOs |
| `CapturePathPlanner.swift` | Legacy logical planner and Rust shadow oracle; native containment remains |
| `CaptureMarkdownRenderer.swift` | Legacy renderer and Rust exact-byte oracle |
| `MarkdownDocumentEditor.swift` | Legacy existing-note mutation and Rust oracle |
| `CapturePipeline.swift` | Native prepare/materialize/commit coordinator |
| `CaptureDraftStore.swift` / `CaptureInbox.swift` | Native durable repositories |
| `CaptureInboxDeliveryService.swift` | Native drain/executor around pinned materialized plans |
| `RecordingJobStore.swift` | Native persistence |
| `RecordingJobQueue.swift` | Native scheduling/execution; later invokes reducer |
| `WatchPhoneBridge.swift` | Legacy plist compatibility adapter and new protocol endpoint |

### 14.2 Engine modes

Persist mode and version pins per operation/job:

- `legacy` — Swift plans and commits.
- `shadow` — Swift is authoritative; Rust receives the same frozen input and compares plans without side effects.
- `rust` — Rust materializes; native Swift commits.

Shadow mode must not write files, copy attachments, reserve quota, enqueue jobs, alter success, or expose user content in diagnostics.

Engine resolution is normative:

- Missing, malformed, or unknown mutable Apple mode/profile configuration resolves closed to `legacy` for new work.
- Rust authority is admitted for the whole operation only when the core loads and every contract/profile/version/hash is compatible; partial Rust execution is not admitted.
- Durable job pins decode strictly. An unknown or incompatible pinned Rust job remains preserved and reports an actionable compatibility failure; it never silently rerenders with Swift.
- A rollback build must retain every Rust executor needed by already-pinned jobs or explicitly refuse those jobs without crossing the commit barrier.
- Android has no legacy renderer for new operations: readiness failure preserves the package and fails closed rather than selecting a network or ad hoc Kotlin renderer.

### 14.3 Promotion order

1. New-note text/link rendering
2. Rolling-note text/link rendering
3. Existing-note text/link mutation
4. Multimodal new-note rendering and attachment plans
5. Multimodal existing-note mutation
6. History/stat reducers
7. Recording transition reducer
8. Wearable protocol canonicalization where useful

Promote by operation/profile, not globally. Retain Swift legacy authority for at least two stable releases after each corresponding Rust default. Rollback only changes new jobs; jobs already pinned to Rust resume with compatible Rust or fail safely.

## 15. Milestone plan

### M0 — Baseline stabilization

**Work**

- Confirm the landed recording queue is the intended contract baseline and resolve any subsequent worktree changes before implementation starts.
- Record the implementation baseline commit SHA, its relationship to planning baseline `b50167a`, and supported Apple deployment targets.
- Add Apple package tests, Xcode build/tests, and `scripts/test-project-contracts.sh` to CI.
- Inventory every shipped iPhone/iPad/Watch capability, Capture Preset/settings field, editor action, entry surface, queue/recovery action, export mode, billing/quota rule, and persisted store in a requirement-to-capability ledger.
- Give every ledger row an owning layer, parity class, milestone, acceptance test/evidence path, and explicit dependency. No unlisted feature may be inferred covered by a broad row such as “voice” or “presets.”
- Capture raw synthetic fixtures for destination/preset/library JSON, drafts, inbox, history tombstones, recording manifests/crash states, and every current `WatchPhoneBridge.swift` property-list envelope and file-metadata variation.
- Include old versions, missing fields, unknown fields, malformed inputs, dates, data blobs, UUIDs, and enums.

**Exit gate**

- Clean committed baseline.
- Apple CI is repeatable from a fresh checkout.
- All existing persisted formats have fixture provenance and compatibility tests.
- The capability ledger is reviewed against `README.md`, source settings models, target manifests, and the recording-queue completion audit, with no unmapped shipped outcome.
- The committed Health.md revision and exact precedent files/tool versions used by this program are recorded; local modifications in `../health-md` are excluded.
- No Rust or Android authority is introduced.

### M1 — Contracts and architecture baseline

**Work**

- Add `Packages/contracts` manifest, capability inventory, specs, fixtures, and hash validator.
- Record ADRs for ownership, versioning, prepared-plan commit barrier, retry markers, template freeze, Android backup, Wear acknowledgements, and billing isolation.
- Convert the M0 ledger into machine-validated `product-capabilities.json`; classify each feature as shared, native, adjusted, unavailable, or deferred and retain the concrete acceptance-evidence mapping.
- Treat unavailable/deferred as an explicit scope variance. Such a row cannot satisfy feature-complete parity unless the objective is separately amended by the product owner.
- Define initial `capture-preparation-input/v1`, `required-observations/v1`, `capture-materialization-input/v1`, `artifact-plan/v1`, and the complete `wearable-protocol/v1` envelope family.
- Resolve quota reinstall/grandfathering, geocoder consent, advanced local-intelligence, Watch Recording Only/acknowledgement, template freeze, and marker decisions before their consumers begin.
- Define repository-owned physical-device/provider/performance matrices with named devices, provider identities, numerical thresholds, and evidence templates.
- Add contract fixtures mirrored into Rust/Swift/Kotlin test resources.

**Exit gate**

- Every field has normative encoding/default/bound semantics.
- Legacy disk schemas and internal core contracts are explicitly distinct.
- Product decisions needed by M2/M3 are approved, including the product-adjusted free-quota reinstall behavior.
- The wearable envelope family represents transcript and Recording Only flows, frozen presets, resumable transfer, reconciliation, staged acknowledgements, reassignment, retry, and discard.
- Manifest validation fails on fixture, ledger, consumer-mirror, or acceptance-mapping drift.

### M2 — Rust/UniFFI proof and Apple shadow

**Scope:** only new-note text/link materialization.

**Work**

- Create pure `vox-core` and thin `vox-core-uniffi` crates.
- Implement build info, readiness, validation, logical path planning, template/frontmatter rendering, exact Markdown bytes, hashes, and typed errors.
- Add Rust unit/property/golden/malformed tests.
- Generate and commit Swift/Kotlin bindings using pinned tooling.
- Build source-generated Android libraries for required ABIs and a static Apple XCFramework; do not commit binaries.
- Add handwritten Swift wrapper and adapter.
- Run Swift authority plus side-effect-free Rust shadow from the same frozen input.
- Record path/byte/hash mismatches without captured content.

**Exit gate**

- Exact Swift/Rust fixture parity.
- Unsupported versions fail closed.
- Binding regeneration has zero diff.
- Readiness pins every independent version/hash.
- Shadow mode has no side effects.
- Performance, peak memory, and Apple binary-size baselines are recorded.

### M3 — Android foundation and text/link vertical slice

**Work**

- Create Gradle convention plugins and modules.
- Establish Compose navigation, dependency injection, Room, DataStore, WorkManager, and `core-bridge` loading.
- Implement onboarding, SAF destination picker, persisted grant repair, one preset, Quick Capture, inbox/status, history shell, and idempotent free-quota accounting for the vertical slice.
- Implement app-private durable packages, Room index, orphan reconciler, engine/version pins, and immutable prepared bytes.
- Implement Rust-authoritative text/link new-note delivery to SAF.
- Implement readback verification, retry, needs-permission, and unknown-outcome handling.
- Add Android backup exclusions before content is stored.

**Exit gate**

- A text/link capture survives process death after every durable transition.
- Composer clears only after local durability.
- Delivery works against local and non-local document providers.
- Revoked grants preserve capture and lead to repair UI.
- The exact expected Markdown exists after successful delivery.
- No broad storage permission or content backup is present.

### M4 — Voice recording and local transcription

**Work**

- Add microphone foreground service, ongoing notification, pause/resume/stop/cancel, interruption handling, and recording recovery.
- Add recording/transcription job persistence; immediate/idle/manual scheduling; delete-after-success/timed/permanent retention and per-job override; and Retry, Retry All, Process Now, Copy, share/reveal, and delete recovery actions.
- Add system on-device recognizer capability adapter.
- Benchmark and integrate the selected app-owned local long-form backend.
- Add model/language management, download consent, progress, cancellation, and audio-only fallback.
- Build transcript review/edit/history/search and final capture delivery.
- Add notification/widget/tile state repository hooks.

**Exit gate**

- Physical-device long recordings continue through supported screen-off/task-dismissal/interruption cases and preserve a recoverable prefix through ordinary process kill, force-stop, reboot, and transient storage/delivery failures. Force-stop/reboot recovery is verified after explicit relaunch and does not claim uninterrupted recording.
- The maximum lost audio after abrupt process death is no more than the specified two-second flush interval.
- No network-capable recognizer is used implicitly.
- Audio remains available after ASR or delivery failure.
- Model absence and unsupported language are actionable states.
- Performance and thermal tests pass defined device tiers.

### M5 — Full multimodal and Markdown placement parity

**Work**

- Add Photo Picker, screenshot filtering, CameraX, file/audio import, scanner/PDF, journal OCR, sketch, and one-shot location.
- Implement the selection-aware Markdown editor, configurable Capture Bar, all shipped Capture Preset settings, route/template overrides, and automatic per-preset transcript export in new/append TXT/Markdown/JSON/YAML modes with filename/template/frontmatter/audio-reference rules.
- Extend contracts/core for rolling notes, existing-note placement, attachment plans, templates, frontmatter, and request markers.
- Implement SAF mutation race detection and orphan attachment reconciliation.
- Add content fidelity/degradation previews where a platform backend cannot represent a payload.

**Exit gate**

- Every existing iPhone/iPad payload type and editor/preset behavior has Android capture, durable staging, rendering, delivery, retry, and history coverage.
- Existing-note concurrent-edit tests never overwrite undetected changed content.
- Original media survives derived-processing failures.
- Rust/Swift/Kotlin golden fixtures agree for all shared operations.

### M6 — Share, shortcuts, widget, Quick Settings, and keyboard

**Work**

- Add Sharesheet receive activity and immediate URI copying.
- Add stable deep links and static/dynamic/pinned shortcuts.
- Add Glance widgets and Quick Settings tile.
- Complete ongoing recording/failure notification actions.
- Build the IME prototype, privacy controls, OEM/API test matrix, and fallback flow.
- Route every vault-directed surface through the same durable capture enqueue use case; route the IME through the separate durable transcription/insertion profile in §7.5.

**Exit gate**

- Duplicate/recreated intents enqueue at most one request.
- Temporary share grants are no longer needed after local enqueue.
- Widget/tile actions obey foreground-service restrictions.
- IME has passed policy/security review and physical-device tests or ships with the approved visible-activity fallback.
- Password/sensitive fields cannot start dictation.
- Editor switch, focus loss, IME recreation, fallback-activity process death, stale/duplicate result, and token mismatch never insert into a different editor and preserve recoverable audio/transcript.

### M7 — Wear OS

**Work**

- Add Wear Compose app, Room/local files, recorder service, Ongoing Activity, notification, Tile, and complication.
- Implement preset synchronization and complete frozen snapshots, including transcript/Recording Only output mode, recording-only naming policy, and location exclusion/policy.
- Implement the M1-approved `wearable-protocol/v1` family against legacy and cross-platform conformance fixtures before replacing the existing Apple Watch payload.
- Add Data Layer Asset/Channel transport, durable outbox, checksums, duplicate reconciliation, and staged acknowledgements.
- Add phone ingestion, reassignment/retry/discard actions, and final recording-export/vault status UI on both devices.
- Add retention/storage-pressure UX and explicit discard.

**Exit gate**

- Watch records and retains at least ten queued recordings, including one 60-minute recording, through 72 hours with the phone unavailable, subject only to an explicit predeclared device-storage test threshold.
- Kill/reboot/disconnect/reconnect/duplicate/corrupt-transfer scenarios preserve exactly one usable phone package.
- No Watch deletion occurs before the configured acknowledgement.
- Unsupported protocol versions retain media and show a repair path.
- Physical Wear devices pass battery, thermal, route, and storage-pressure tests.

### M8 — Entitlements and production hardening

**Work**

- Map the existing premium model to a Play Billing non-consumable product.
- Query purchases on startup/resume, verify `PURCHASED`, and acknowledge within policy deadlines.
- Keep entitlement network traffic isolated from capture packages.
- Implement the M1-approved restore/offline grace/pending/cancelled/refunded, existing-user/grandfathering, and product-adjusted free-quota reinstall policies.
- Complete accessibility, localization, large-screen, backup, privacy, retention, diagnostics, and support flows.
- Add sanitized crash diagnostics with no notes, transcript text, filenames, URIs, or audio metadata beyond coarse buckets.

**Exit gate**

- Billing license tests pass and purchase state cannot cause content loss.
- Data Safety and privacy disclosures match actual code and SDK telemetry.
- Accessibility tests cover phone/tablet/Wear/system surfaces.
- All content-bearing data is excluded from OS backup as decided.

### M9 — Advanced local intelligence and broad Apple cutover

**Work**

- Evaluate and implement local diarization and enrichment backends, licensing, device tiers, and model delivery for the shipped cleanup, title, tag, category, checklist, meeting-note, and custom-instruction outcomes.
- Keep every inference path local. If an outcome cannot meet the approved performance/quality gate, the program remains incomplete for feature parity unless the owner explicitly amends the objective; marking it unavailable/deferred is not completion.
- Expand Apple shadow and Rust authority in the promotion order.
- Add the pure recording reducer only after native state fixtures stabilize.
- Migrate Apple Watch to the versioned protocol through a legacy compatibility adapter.

**Exit gate**

- Every shipped diarization and enrichment outcome has an approved local implementation and capability/device-tier behavior; any remaining unavailable/deferred ledger row is reported as an unmet parity gate rather than completion.
- Every promoted Apple operation has beta evidence, rollback instructions, and two-release legacy retention.
- No operation changes engine after its commit barrier.

### M10 — Release and optional repository consolidation

**Work**

- Build signed Android App Bundles and Wear artifacts from pinned source.
- Upload native debug symbols and retain provenance/SBOM/dependency/license records.
- Complete Play internal, closed, and staged production testing.
- Re-audit target SDK, foreground-service, permissions, Data Safety, billing, and Wear quality policy immediately before submission.
- Only after Apple CI and release tooling are stable, move Apple under `apps/apple` as a behavior-free reviewed change.

**Exit gate**

- Release candidate passes the complete verification matrix below and `product-capabilities.json` has no unmet, unavailable, or deferred iPhone/iPad/Watch parity row.
- Rollback, migration, support, and content-recovery runbooks are exercised.
- Staged rollout has no unresolved data-loss, duplicate-delivery, transcription-network, or Wear-transfer defects.

## 16. Verification strategy

### Contract and Rust

- Schema/manifest/hash validation
- Exact golden path and byte tests
- Property tests for paths, templates, Unicode, dates, and Markdown placement
- Malformed, unknown-version, oversize, cancellation, and panic-containment tests
- Rust format, clippy, unit, MSRV, fuzz, and dependency/license checks
- Generated Swift/Kotlin binding drift checks

### Apple

- Legacy codec fixtures from supported persisted versions
- Swift/Rust exact shadow corpus
- Xcode build/tests for app, extensions, widgets, and Watch targets
- Commit-barrier failure injection
- Profile-scoped promotion and rollback tests

### Android JVM/instrumentation

- Room migrations and repository tests
- Filesystem/Room orphan reconciliation
- WorkManager unique-work/retry tests
- Compose navigation/state tests
- SAF provider contract tests
- Permission revocation and backup-rule inspection
- Process-death injection before/after every durable transition
- Native library load/readiness tests for each packaged ABI

### Physical-device matrix

At minimum, M1 records the following named procurement targets and campaign fact requirements. Exact lab device model/serial, OS/API, build fingerprint, signed build ID, and build signature are observed—not fabricated—in each later physical campaign before that evidence can pass:

- One physical phone on API 28–30 for the low/minimum tier, plus an API 28 emulator when maintained physical hardware is unobtainable
- One current supported Pixel phone
- One current supported Samsung phone
- One tablet or foldable
- One Pixel/reference Wear watch and one Samsung Wear watch
- Local DocumentsUI storage, Google Drive, and Microsoft OneDrive DocumentsProviders; an unavailable provider may be replaced only by an approved non-local provider with the same test cases recorded in the matrix

Scenarios:

- Screen off and app background/dismissal while recording
- Ordinary process kill with at most the two-second durable-prefix loss budget
- Force-stop and reboot followed by explicit relaunch and interrupted-recording recovery; uninterrupted recording is not expected
- Phone call/audio interruption, mic toggle, permission revoke
- Full disk/storage pressure, zero-byte/corrupt media, model missing
- Vault removed/moved, provider offline/slow/eventually consistent
- Crash before commit, during commit, and after commit before receipt
- Watch disconnected for the defined 72-hour/ten-recording matrix, duplicate/corrupt transfer, and phone reinstall

Every physical run writes `artifacts/validation/android-wear/<build-id>/<case-id>.md` with commit/core/contract versions, signed build ID, device model, OS/API, provider/app version, prerequisites, expected/actual result, timestamps, logs/screenshots, and hashes of synthetic fixtures. A green aggregate report must link every required case; an aggregate status without case evidence is not a gate.

### Performance gates

M1 freezes final thresholds in `docs/validation/android-performance-gates.md`. The initial budgets below are defaults and may change only by reviewed ADR before the dependent implementation begins:

- Text/link durable enqueue: p95 ≤ 500 ms from Send to **Saved locally** on the low phone tier; media measures copy throughput separately and never clears before copying completes.
- Quick Capture: warm p95 ≤ 500 ms and cold p95 ≤ 1.5 s to editable UI on the current Pixel/Samsung matrix.
- Rust new-note materialization: p95 ≤ 100 ms for 1 MiB input and ≤ 64 MiB additional RSS; large-note tests cover 1, 16, and 256 MiB streamed inputs without crossing the 1 MiB FFI chunk limit.
- SAF: each named provider records p50/p95 and must finish or enter a durable actionable retry/unknown state within a 30-second watchdog; no UI thread blocks on provider I/O.
- Recorder: a 60-minute session has no lost prefix beyond two seconds after abrupt process kill, no platform thermal warning, and no unbounded memory growth.
- Local ASR: the selected launch model has real-time factor ≤ 1.0 for a 30-minute synthetic fixture, peak RSS ≤ 1.25 GiB, and successful cancellation within two seconds on every declared supported tier.
- Wear: a 60-minute recording causes no platform thermal warning or storage corruption, consumes ≤ 20% battery on each launch watch after battery-health normalization, and transfers/ingests within ten minutes once a stable phone connection is available.
- Packaging: M1 records per-ABI/core/model size budgets before M2/M4; release fails on unexplained growth above 10% from the approved baseline.

If a device cannot meet an advanced-model threshold, the capability ledger must name the supported lower model/tier and user-visible unavailability. It may not fall back to network inference.

## 17. CI and release pipelines

Add path-filtered workflows:

- `contracts-ci.yml` — validate manifest, fixture hashes, schemas, and mirrors.
- `core-rust-ci.yml` — format, clippy, test, MSRV, fuzz smoke, binding generation, package checks.
- `apple-ci.yml` — prepare XCFramework, binding drift, package/project build and tests, contract fixtures.
- `android-ci.yml` — build Rust ABIs, binding drift, JVM/lint/unit/instrumentation, App Bundle inspection.
- `wear-ci.yml` — Wear build, lint, unit/instrumentation, packaging and manifest checks.
- `android-release.yml` — signed source-built app/Wear bundles, symbols, provenance, dependency/license reports.

CI rules:

- Generated Swift/Kotlin source is committed and never hand-edited.
- XCFrameworks, AARs, and `.so` files are source-built artifacts and are not committed.
- Native releases consume the exact reviewed core revision.
- Contract fixture updates require producer, compatibility analysis, consumer tests, and intentional manifest hash changes.
- Release jobs inspect ABIs, target SDK, manifest permissions/services, backup rules, FGS declarations, and embedded native symbols.

## 18. Rollout and rollback

### Android

- Use internal builds before closed Play testing.
- Gate incomplete surfaces locally by capability/version, not by silently selecting another engine.
- Persist engine/core/contract/renderer pins with every prepared job.
- An app downgrade must either retain a compatible executor or refuse unsupported pinned jobs while preserving their packages.
- A rollback release changes defaults only for new jobs; immutable prepared jobs continue with their compatible implementation.

### Apple

- Default remains `legacy` until exact shadow evidence is approved.
- Promote one operation/profile at a time.
- Keep a user-independent production rollback setting in release configuration; do not require captured-content telemetry.
- Retain legacy implementation for at least two stable releases after Rust default.
- Delete legacy code only after fixture, beta, support, and rollback evidence is documented.

### Privacy-safe diagnostics

Allowed examples:

- Contract/core/profile version
- Error code and state transition
- Coarse payload kinds/count buckets
- Duration/size buckets
- Hash equality/mismatch, never the original values

Never record note text, transcripts, audio, filenames, destination paths/URIs, bookmark data, surrounding keyboard context, or model input.

## 19. Parallel workstreams and critical path

After M0, work can proceed in parallel:

- **Core track:** contracts, Rust, UniFFI, Swift shadow.
- **Android foundation track:** Gradle modules, Compose shell, Room/staging, SAF experiments.
- **Risk prototype track:** IME microphone, physical SAF providers, local ASR benchmarks, Wear transfer.
- **Release track:** CI, signing, Play setup, privacy/billing policy.

Critical path:

```text
M0 clean baseline
  -> M1 contracts
  -> M2 Rust text/link proof
  -> M3 Android durable vertical slice
  -> M4/M5 product capture parity
  -> M6 entry-point parity
  -> M7 Wear parity
  -> M8 release hardening
  -> M9 advanced local-intelligence parity + broad Apple cutover
  -> M10 staged production
```

Apple shadow expansion can continue alongside M3-M8. The IME, ASR, SAF-provider, and Wear experiments should start early because they can change product promises, but experimental code must not define canonical contracts until the baseline is stable.

## 20. Program definition of done

The implementation is complete only when all of the following are true:

- Every row in the machine-validated iPhone/iPad/Watch capability ledger has an Android/Wear implementation and direct acceptance evidence. A platform-adjusted implementation may change the native surface, but an unavailable/deferred row remains incomplete unless the objective is explicitly amended.
- Android and Wear never clear/delete the last durable copy before the next ownership boundary acknowledges it.
- Equivalent canonical inputs meet the approved exact Markdown/path contract.
- Existing-note races and ambiguous provider commits do not cause blind duplicate retries.
- All transcription/enrichment paths are demonstrably local; network-capable inference fallback is impossible without an explicit future product change. Optional system geocoding occurs only under the frozen disclosed consent policy.
- Android backup and Play Data Safety behavior match the documented local-first promise.
- Phone and Wear survive the failure matrix without losing recoverable content.
- Rust has no UI, storage capability, platform SDK, billing, credential, or lifecycle ownership.
- Apple operations can be promoted and rolled back independently without changing user-file formats.
- CI can reproduce bindings and binaries from the reviewed source revision.
- Release, rollback, permission repair, model repair, vault repair, transfer reconciliation, and user-data cleanup runbooks have been exercised.

## 21. Explicit non-goals

- Rewriting the Apple UI or platform services in Rust
- Matching macOS-only menu-bar, global-shortcut, or desktop workspace behavior; this program targets iPhone/iPad and Apple Watch outcome parity
- A cross-platform UI framework
- Exposing filesystem paths, bookmarks, or SAF URIs through UniFFI
- Putting Room, WorkManager, WatchConnectivity, Data Layer, or a live queue repository in Rust
- Automatically uploading notes/audio for transcription, diagnostics, billing, or AI
- Emulating Dynamic Island or Control Center literally
- Using MediaSession playback controls as a recording-status hack
- Requesting all-files or broad photo permissions
- Moving the Apple project before CI protects the relocation
- Shipping every planned third-party destination from `docs/unified-quick-capture-destinations.md` as part of Android parity; the architecture must leave room for them, but this program matches currently shipped capabilities first

## 22. References

Local architecture and behavior:

The Health.md paths below are normative only as committed at `c70de9201ab7cfbadf2442183dfba23c0d248478`; neighboring working-tree changes are not part of this plan.

- `../health-md/docs/architecture/adr-0001-shared-rust-uniffi-core.md`
- `../health-md/docs/architecture/shared-core-m5-rendering-baseline.md`
- `../health-md/docs/architecture/shared-core-m6-rollout-runbook.md`
- `../health-md/docs/architecture/shared-core-m7-protocol-baseline.md`
- `../health-md/Packages/contracts/README.md`
- `docs/recording-queue-storekit-completion-audit.md`
- `docs/recording-queue-storekit-validation.md`
- `docs/unified-quick-capture-destinations.md`

Android platform references:

- Android architecture: <https://developer.android.com/topic/architecture/recommendations>
- Storage Access Framework: <https://developer.android.com/training/data-storage/shared/documents-files>
- WorkManager: <https://developer.android.com/develop/background-work/background-tasks/persistent>
- Microphone foreground services: <https://developer.android.com/develop/background-work/services/fgs/service-types>
- Share receive targets: <https://developer.android.com/develop/ui/compose/sharing/receive>
- Glance widgets: <https://developer.android.com/develop/ui/compose/glance>
- Quick Settings tiles: <https://developer.android.com/develop/ui/views/quicksettings-tiles>
- CameraX: <https://developer.android.com/media/camera/camerax>
- On-device speech API: <https://developer.android.com/reference/android/speech/SpeechRecognizer>
- Wear Data Layer clients: <https://developer.android.com/training/wearables/data/client-types>
- Wear Data Layer synchronization: <https://developer.android.com/training/wearables/data/sync>
- Photo Picker: <https://developer.android.com/training/data-storage/shared/photo-picker>
- ML Kit document scanner: <https://developers.google.com/ml-kit/vision/doc-scanner/android>
- ML Kit text recognition: <https://developers.google.com/ml-kit/vision/text-recognition/v2/android>
- Input method services: <https://developer.android.com/reference/android/inputmethodservice/InputMethodService>
- Play Billing one-time products: <https://developer.android.com/google/play/billing/one-time-products>
- Android backup rules: <https://developer.android.com/identity/data/autobackup>
- Play Data Safety: <https://support.google.com/googleplay/android-developer/answer/10787469>
- Play target API requirements: <https://developer.android.com/google/play/requirements/target-sdk>
