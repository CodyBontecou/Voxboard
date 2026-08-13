# Android/Wear M0 Apple persistence fixture evidence

Status: **local format audit complete — baseline/hosted/device gates remain open**

The committed corpus is under `Packages/VoxboardShared/Tests/Fixtures/Persistence/v1/`.
Its `manifest.json` records `b50167a` only as the planning parent and records deterministic codec revision
`6d453e7c4cc60fda0fb2cb9d9399c8d92873b7d0` as the producer. It also records the generator path/SHA-256, fixed synthetic provenance,
and a SHA-256 plus byte count for every file. CI validates committed bytes; it never
regenerates them first.

## Executable production-codec coverage

| Surface | Production consumer/producer | Fixture evidence | Executed behavior |
|---|---|---|---|
| Capture library | `CaptureLibraryStore` | `capture-library/` and `negative/capture-library/` | Store-driven production/current encode-decode, bookmark `Data`, future-version rejection, malformed base64 rejection |
| Draft and prepared request | `CaptureDraftStore` | `drafts/` and `negative/drafts/` | Store-driven draft and prepared-request production/current encode-decode plus missing required ID rejection |
| Capture inbox tombstone | `CaptureInbox.enqueue`, `claim`, `complete`, and `requestIDs` | `inbox/` and `negative/inbox/` | Tombstone is produced by the private production codec; current decode and future receipt sanitization are executed |
| Capture history | `CaptureHistoryStore.writeCompatibilityFixture` and `load` | `history/` and `negative/history/` | Private production envelope encode/decode and future file-version rejection |
| Recording job/handoff | `RecordingJobStore`, `RecordingJob`, `RecordingJobHandoffIntent` | `recording-jobs/job-v1.json`, `handoff-v1.json`, negative job, `recording-jobs/checkpoints/`, delivery receipt bytes, and `recording-jobs/recovery/` | Production-store transcript/audio/note/reference checkpoints, complete future-version rejection, delivery marker bytes, and recovery of interrupted processing/finalizing, missing audio, completed deleted audio, and orphan audio |
| External delivery transaction | `ExternalFileDeliveryTransaction` private journal codec | `recording-jobs/delivery-journals/{note,audio,noteAudioReference}/` | Production `{version,targetPath,preimage,postimage}` journals and payloads for every artifact role; missing/existing preimages and SHA-256 postimages verified by the private production implementation |
| Capture usage | `CaptureDeliveryUsageStore.reserve`, `commit`, and `snapshot` | `usage/capture-usage-v1.json` | Private production ledger is generated and consumed through the actor store |
| Keyboard IPC | Public `Transcription*`, `Recording*`, `ListeningState`, and live-transcription codecs | `keyboard-ipc/` | Every committed JSON file is decoded and semantically checked; raw `Float`, pending text, and retained audio bytes are exact-checked |
| Transcript, activity, origin, live state | `TranscriptStore`, `ActivityStatsStore`, `CaptureRecordingOriginStore`, and live-state codec | `transcripts/`, `stats/`, `recording-origin/`, `live-state/` | Store-driven producer/consumer validation for the first three and current semantic live-state decode |
| Foundation wire | `JSONEncoder` / `JSONDecoder` defaults | all JSON fixtures | Date reference epoch, base64 `Data`, UUID strings, and raw enum strings are asserted |

`VoxboardPersistenceFixtures --validate` also requires an exact manifest/file-set
match, validates every SHA-256, executes every current negative fixture, and scans
textual fixtures for machine/user path or App Group leakage.

## App-hosted Watch fixture coverage

`VoxboardTests/AndroidWearM0PersistenceFixtureTests.swift` executes the committed
Watch inbox and property-list bytes against app-target production models, stores,
and key catalogs. It covers current/legacy/malformed `WatchRecordingInboxItem`,
production index/sidecar/tombstone and orphan recovery, current and legacy-minimal
XML/binary application contexts, current/legacy/incompatible file
metadata including preset/location payloads, and committed property lists for every
current command and preset response outcome.

## Watch-target fixture coverage

`Voxboard Watch Tests/AndroidWearM0WatchPersistenceFixtureTests.swift` consumes the
committed current/legacy application contexts through `WatchRecordingSnapshot`,
freezes the Watch-local snapshot dictionary round trip, executes confirmed and pending preset stores including malformed data and `Int64.max`
sequence rollover, and drives the production Watch queue store through legacy, active,
orphan, and corrupt-index recovery on a watchOS simulator.

## UserDefaults fixture coverage

`settings/allowlisted-settings-v1.json` is produced by isolated `UserDefaults`
through `CapturePresetStore`, `RecordingQueuePreferences`, `UsageTracker`,
`ModelManager`, and the package-owned onboarding analytics stores, then reloaded
through the same production consumers. App-hosted tests additionally load the
committed toolbar bytes through `CaptureToolbarPreferences`, execute review and quote
state, and Watch-target tests consume the committed preset/defaults corpus. The
84-key inventory is broader than this main snapshot: completion/migration markers,
Watch controller state, transport failures, and executable absent/default/invalid
cases also live in focused package, app-hosted, and Watch tests. Source-inventory
completeness remains distinct from committed fixture completeness.

The Watch tests exercise committed confirmed/pending preset bytes,
current/legacy/active/orphan queue layouts, the production local snapshot store,
partial and wrong-type dictionaries, unknown fields/enums, corrupt-index backup,
unsafe queue filename rejection, transfer failure/retry/upload, stale remote updates,
and terminal/duplicate acknowledgement replay. Real storage pressure remains an
explicitly external physical-device gate and is not claimed by codec tests.

## Outstanding compatibility matrix

`docs/architecture/android-wear-m0-compatibility-matrix.json` is the executable
format-by-dimension audit. It covers every `cap.store.*` capability and requires
each format to classify old/missing/unknown/malformed/future, Foundation wire
facts, and crash/recovery as `executed`, `notApplicable`, `pending`, or `external`,
with production symbols, evidence paths, and rationale. The repository validator
rejects omitted dimensions, unresolved production symbols, missing evidence, and
unmapped persisted-store capabilities.

The M0 requirement is a dimension audit, not a demand for nonsensical variants of
every byte stream. All 290 cells (29 formats × 10 dimensions) are explicitly
classified. No cell remains `pending` or `external`. The keyboard uses the tested shared
persist-before-insert/restart reducer, and Watch terminal replay executes the
production save-before-delete queue/audio transition and durable reload. Applicable
cells are `executed`; inapplicable behavior has a production-format rationale.

The M0 implementation and deterministic-codec commits exist. A clean local clone of
the final attested revision passed project contracts, fixture validation, and all
Swift package tests without modifying tracked files. Successful hosted Apple CI is
not yet recorded, and physical-device/account gates remain external. Passing the matrix validator must
not be reported as product or physical-device parity.

## Provenance and regeneration

- Planning parent (not the fixture-producing revision): `b50167aebb959e394908af3a5949f43fa88d6265`.
- Fixture-producing deterministic codec revision: `6d453e7c4cc60fda0fb2cb9d9399c8d92873b7d0`; the manifest generator SHA-256 attests the final source including this record.
- Generator source: `Packages/VoxboardShared/Sources/VoxboardPersistenceFixtures/main.swift`.
- Validation command:
  `swift run --package-path Packages/VoxboardShared VoxboardPersistenceFixtures --validate`.
- Intentional regeneration command:
  `swift run --package-path Packages/VoxboardShared VoxboardPersistenceFixtures --generate`.

The final implementation-baseline commit cannot be recorded until these changes are
committed. A fixture change requires reviewing the byte diff and manifest SHA-256
diff; regeneration is not a compatibility test by itself.
