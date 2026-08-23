# Android/Wear OS Port (Voxboard) — Planned Capability Inventory

LID: **AP** (Android Port). All features below are in-development Android/Wear OS capability,
explicitly separated from shipped iOS/Mac/Watch features. Planning baseline: `b50167a`
(Vox.md 2.1 release); program plan `docs/android-wear-shared-core-implementation-plan.md`
(1192 lines, Status: Proposed). Machine ledger: `Packages/contracts/product-capabilities.json`
(271 capability rows; statuses `inventoried` / `verified` only — no Android capability is shipped).

---

## Part 1 — Milestone Roadmap & Current Status

| Milestone | Scope (from plan §15 + audit docs) | Status | Evidence |
|---|---|---|---|
| **M0** Baseline stabilization | Recording-queue confirmation, fixture provenance, Apple CI, capability ledger | **Complete** (committed, fresh-checkout verified, hosted Apple CI passed) | `docs/architecture/android-wear-m0-baseline.md` ("M0 complete"); `android-wear-m0-fixture-evidence.md`; `android-wear-m0-capabilities.json` (270-row ledger); `android-wear-m0-compatibility-matrix.json` |
| **M1** Contracts & architecture baseline | 5 versioned contract families + core-api, ADR-0001..0016, 270→271-row machine ledger, scope variances, validation program | **Complete** (local + contracts CI; hosted CI noted) | `docs/architecture/android-wear-m1-completion-audit.md` ("Complete locally; hosted CI required…"); `android-wear-m1-decisions.md`; `Packages/contracts/manifest.json`, `product-capabilities.json`, `scope-variances.json` (empty variances), `validation/` |
| **M2** Rust/UniFFI proof + Apple shadow | vox-core + vox-core-uniffi crates, exact new-note text/link materialization, bindings, Apple shadow | **Complete** ("M2 closed — hosted milestone qualification passed", rev `450abca`) | `docs/architecture/android-wear-m2-entry-foundation-audit.md`; `crates/vox-core/src/lib.rs` (2203 lines); `crates/vox-core-uniffi/src/lib.rs`; `Packages/VoxboardShared/Sources/VoxCoreGenerated|VoxCoreRust|VoxCoreFFI|VoxboardM2Oracle|VoxboardM2MaterializationEvidence` |
| **M3** Android foundation + text/link vertical slice | Gradle modules, durable packages/journal, Room v2, quota, lazy UniFFI bridge, SAF commit executor, Compose shell | **In progress — Phases 1–5 foundations hosted-qualified; vertical slice incomplete; no end-to-end user capture** | `docs/architecture/android-wear-m3-scope-and-entry-audit.md` ("M3 Phase 1–4 foundations hosted-qualified; vertical slice incomplete"); ADR-0018..0023; first physical-target execution on one Pixel 7 (bridge + Room migration) |
| **M4** Voice recording & local transcription | Mic FGS, recording jobs, local ASR, model mgmt, transcript review | **Pending** | ADR-0014 policy accepted; no implementation in `apps/android/platform-services` (only `PlatformServicesFoundation.kt`, 8 lines) |
| **M5** Full multimodal & Markdown placement parity | 114 ledger rows (largest), photos/scans/sketches/location/editor/presets/export/stats | **Pending** | Ledger milestone counts; no code |
| **M6** Share/shortcuts/widget/tile/keyboard | Entry points incl. IME prototype | **Pending** | ADR-0015 policy accepted |
| **M7** Wear OS | Standalone recorder, protocol v1, Tile/complication, transfer | **Pending** | ADR-0007 policy accepted; `wearable-protocol/v1` contract defined; **no `apps/android/wear` module exists** |
| **M8** Entitlements & hardening | Play Billing, quotas, accessibility/localization | **Pending** | ADR-0008/0009 policy accepted |
| **M9** Advanced local intelligence | Diarization, enrichment, Apple cutover | **Pending** | ADR-0011 policy accepted |
| **M10** Release & consolidation | Bundles, Play testing, repo move | **Pending** | Plan §15 |

### M3 approved product scope (from `android-wear-m3-scope-and-entry-audit.md`)
- Surface: M3 milestone planning documents (not a user surface)
- Summary: The M3-approved ledger scope is exactly ten capabilities (`cap.ai.mode-none`, `cap.billing.reinstall-adjustment`, `cap.delivery.standard`, `cap.entry.app`, `cap.history.tombstone`, `cap.payload.text`, `cap.payload.url`, `cap.quota.capture`, `cap.quota.retry-no-charge`, `cap.target.new`); everything else slid to M4–M9 as a schedule correction, not scope removal.
- Details: enumerated capability list above; transcription quota and voice metering moved to M4; editor actions/location at M5+.
- Constraints: planning status only; no user-visible product until the vertical slice completes.
- Evidence: `docs/architecture/android-wear-m3-scope-and-entry-audit.md` ("Approved M3 product scope")
- Status: planned

---

## Part 2 — Contract Families (Packages/contracts/)

### F-AP-01 capture-preparation-input/v1
- Surface: Internal cross-FFI contract; consumed by Rust `prepare()` and Kotlin `CoreMaterializationCoordinator`
- Summary: Normalized request facts, frozen preset/destination policy, logical route policy, and operation/profile pins needed to decide required native observations. No template bytes, note bytes, provider IDs, bookmarks, or URIs.
- Details: strict JSON schema (`v1/schema.json`); governed M3 fixture `capture-preparation-input/valid-android-m3-text-link.json` (core `0.1.0-alpha.1`, renderer `swift-legacy-m0`, profile `apple-parity-v1` v1, preset UUID `33333333-…`, preset `snapshotHash` = SHA-256 of canonical preset JSON with `snapshotHash` zeroed, verified by Kotlin before admission); M3 profile restricted to app-originated `newNote` with 1–2 text/link payloads, Gregorian calendar, no model, `Inbox`/`capture-{id}.md`/`markdownDotMd`/`deterministicSuffix`, `expectedCaseSensitivity: sensitive` only
- Constraints: 1 MiB control-JSON cap; unknown versions/discriminators fail closed
- Evidence: `Packages/contracts/capture-preparation-input/v1/contract.md`, `schema.json`; ADR-0020
- Status: **experimental** (contract frozen at M1; consumed by implemented, unwired substrate)

### F-AP-02 required-observations/v1
- Surface: Output of Rust `prepare()`, input to native observation resolution
- Summary: Ordered, bounded list of typed observation requests — candidate occupancy, frozen template bytes/hash, current note bytes/hash, staged-asset metadata. Rust never calls back into storage; native resolves each once per prepare attempt.
- Evidence: `Packages/contracts/required-observations/v1/{contract.md,schema.json}`; ADR-0005; implemented in `vox-core` `prepare()` (lib.rs:515) and `CoreMaterializationCoordinator.observeOccupiedCandidates` / `frozenTemplateObservation`
- Details: contract behavior is fully described in Summary; see the cited ADR/contract for the normative statement.
- Constraints: Android/Wear platform only; contract/substrate stage — not shipped to users.
- Status: **experimental**

### F-AP-03 capture-materialization-input/v1
- Surface: Control document fed to the UniFFI materialization session
- Summary: Frozen request + policy + every resolved observation keyed to the preparation snapshot; drives deterministic byte rendering.
- Details: contract/renderer revision pins; explicit snapshot revision/hash; 1 MiB control cap; ≤1 MiB chunks; 256 MiB aggregate note/template initial limit (M5 cannot claim existing-note parity while any Apple note size lacks an Android path)
- Evidence: `Packages/contracts/capture-materialization-input/v1/`; ADR-0012; `CoreMaterializationCoordinator.composeControl` (lines 114–178)
- Constraints: Android/Wear platform only; contract/substrate stage — not shipped to users.
- Status: **experimental**

### F-AP-04 artifact-plan/v1
- Surface: Output of `finalizeOutput()`; persisted as `prepared/<plan-hash>/artifact-plan.json`
- Summary: Committable immutable plan: logical path segments, exact UTF-8 note bytes (streamed), deterministic operation/artifact IDs, ordered commit sequence, collision/expected-existing policy, expected original hash for mutations, result SHA-256/length/media-type, attachment descriptors, idempotency marker details, journal frontier/receipt kinds, typed warnings.
- Details: deterministic ID derivation = UUIDv5(SHA-1), namespace `8c7f8d7e-4f61-5d92-a94a-3b9e6cc8e415`, NUL-separated preimage (ADR-0017); planHash recomputed with `planHash` zeroed by `PreparedPlanVerifier`
- Evidence: `Packages/contracts/artifact-plan/v1/`; ADR-0002/0003/0017; `apps/android/data/.../PreparedPlanVerifier.kt`
- Constraints: Android/Wear platform only; contract/substrate stage — not shipped to users.
- Status: **experimental**

### F-AP-05 wearable-protocol/v1
- Surface: Watch/Wear ↔ phone synchronization envelopes (17 message kinds)
- Summary: A protocol family, not one payload: capability/version negotiation (+unsupported-version responses), preset inventory + complete frozen preset snapshots/hashes, recording metadata (transcript vs Recording Only, local-ASR policy, location exclusion, recording-only folder/filename policy references), asset manifests + resumable chunk/channel frontiers (length + SHA-256), reconciliation summaries, transfer receipts, correlated `phoneIngested`/`vaultCommitted`/`terminalFailure`/`discarded` ACKs, phone/user actions (reassign/retry/discard/retention authorization). Every envelope carries protocol/message kind, message/recording/sender-installation/device IDs, epoch + monotonic revision, correlation ID, replay rules, bounded unknown-field behavior.
- Evidence: `Packages/contracts/wearable-protocol/v1/{contract.md,trace-contract.md,trace.schema.json}`; ADR-0007
- Details: contract behavior is fully described in Summary; see the cited ADR/contract for the normative statement.
- Constraints: Android/Wear platform only; contract/substrate stage — not shipped to users.
- Status: **planned** (contract frozen; no Wear app module exists)

### F-AP-06 core-api/v1 (UniFFI service boundary)
- Surface: `libvox_core_uniffi.so` via UniFFI; Kotlin `core-bridge`, Swift `VoxCoreRust`
- Summary: Independently versioned coarse API: `getBuildInfo`, `checkReadiness` (exact-match, fail-closed `incompatible` with bounded safe mismatch codes), `prepare`, and the bounded `CaptureMaterializationSession` (`input → outputReady → draining → finalized|cancelled`; `seal` → descriptors; `drain(maxBytes ≤1 MiB)`; `finalize(drainedHashes)` → plan; `cancel`). M2 supported profile exactly `new-note-text-link/apple-parity-v1`; everything else fails closed. Panics caught and mapped to privacy-safe errors.
- Evidence: `Packages/contracts/core-api/v1/`; `crates/vox-core-uniffi/src/lib.rs` (`CoreBuildInfo`, `CoreReadiness` records, lines ~14–28); `crates/vox-core/src/lib.rs` (`readiness` :220, `prepare` :515, `MaterializationSession::new/seal/drain/finalize/cancel` :1035–1342)
- Details: contract behavior is fully described in Summary; see the cited ADR/contract for the normative statement.
- Constraints: Android/Wear platform only; contract/substrate stage — not shipped to users.
- Status: **experimental** (implemented, tested, hosted-qualified M2; not wired into any shipping Android flow)

---

## Part 3 — ADR-Defined Capabilities (behaviors/decisions)

### F-AP-07 Shared-core ownership boundary & versioning (ADR-0001)
- Surface: All Rust/Kotlin/Swift code
- Summary: Rust owns only bounded deterministic destination-neutral policy (contract decode/validate, logical path planning, template/frontmatter/Markdown materialization, hashes, markers, typed errors, later pure reducers). Native owns UI, permissions, capture, inference adapters, persistence, queues, provider commits, billing, credentials, wearable transport. No Rust→platform callbacks; no handles/URIs/bookmarks in contracts. Seven version families (core API, preparation input, observations, materialization input, artifact plan, renderer profile, persisted state, wearable protocol) advance independently. Apple rolls per operation via persisted `legacy`/`shadow`/`rust` pins; malformed config → `legacy`; incompatible pinned Rust job preserved and fails actionably; legacy retained ≥2 releases.
- Evidence: `docs/architecture/adr-0001-shared-core-ownership-versioning-rollout.md` (all)
- Details: contract behavior is fully described in Summary; see the cited ADR/contract for the normative statement.
- Constraints: Android/Wear platform only; contract/substrate stage — not shipped to users.
- Status: **experimental** (enforced in implemented code) / Apple rollout **planned**

### F-AP-08 Exact Markdown & logical-path parity (ADR-0002)
- Surface: Rust renderer + native commit verification
- Summary: Equivalent contract inputs must produce byte-identical UTF-8 note bytes and identical ordered logical relative path segments on both platforms. Freezes the Swift oracle's details: calendar/timezone/date tokens, lowercase UUID substitution, `.md` extension, collision suffixing, payload ordering/blank-line placement, boundary-newline trimming, CRLF/CR normalization (existing-note editor only), link/alias escaping, attachment placement, frontmatter merge ordering, heading selection/creation, fenced-code exclusion, destination entry-template substitutions (literal payload text not interpolated), request-marker syntax. No ambient locale/timezone/filesystem influence.
- Evidence: ADR-0002; fixtures in `Packages/contracts/fixtures/`
- Details: contract behavior is fully described in Summary; see the cited ADR/contract for the normative statement.
- Constraints: Android/Wear platform only; contract/substrate stage — not shipped to users.
- Status: **experimental** (M2 proven for new-note text/link; broader operations M5 **planned**)

### F-AP-09 Prepared-plan commit barrier (ADR-0003)
- Surface: Core session + Android executor
- Summary: `finishInput()` exposes expected artifact descriptors but never a committable plan; native drains all artifacts to immutable storage, verifies length/SHA-256, and only then `finalizeOutput()` returns the plan, which native persists before any side effect. Ordered commit with correlated journal frontier/receipt after each operation; attachments before referencing note; verified terminal receipt before cleanup. Cancelled/abandoned/out-of-order/hash-mismatched sessions yield no plan. Once `committing`: never rerender, switch engine, or silently retry.
- Evidence: ADR-0003; implemented in `SafVaultCommitExecutor.kt` (lines 31–320), `CoreMaterializationCoordinator`
- Details: contract behavior is fully described in Summary; see the cited ADR/contract for the normative statement.
- Constraints: Android/Wear platform only; contract/substrate stage — not shipped to users.
- Status: **experimental** (substrate implemented and tested JVM; not production-wired)

### F-AP-10 Existing-note retry markers (ADR-0004)
- Surface: Markdown mutations, retry path
- Summary: Marker `<!-- vox-capture:<lowercase-uuid> -->` with the capture request UUID, preserving the shipped Swift `CaptureRequestMarker.text(for:)` syntax. CRLF/CR normalized to LF before duplicate detection; existing exact marker → unchanged document; non-empty entry followed by blank line then marker. Before retrying a mutation, native reads the current note and checks the marker — present ⇒ reconcile without duplicate write; absent with possible commit ⇒ `unknownOutcome` requiring explicit inspection.
- Evidence: ADR-0004; ledger `cap.format.retry-marker` (M5)
- Details: contract behavior is fully described in Summary; see the cited ADR/contract for the normative statement.
- Constraints: Android/Wear platform only; contract/substrate stage — not shipped to users.
- Status: **planned** (M5)

### F-AP-11 Template & observation freeze (ADR-0005)
- Surface: Prepare/materialize pipeline
- Summary: Template bytes frozen at first preparation for a delivery; snapshot carries presence/absence, bytes, length, SHA-256. Observation snapshots correlate to a preparation attempt + revision hash; responses from separate attempts cannot be mixed. Retries reuse frozen bytes with the persisted plan; pre-commit conflict starts a new identified prepare attempt. Shipped `CaptureEntryTemplateRenderer` oracle: token substitution only in destination formatting, never in literal payload text.
- Evidence: ADR-0005; implemented: `CoreMaterializationCoordinator.frozenTemplateObservation` (:167), `observations/<attempt-id>.json`
- Details: contract behavior is fully described in Summary; see the cited ADR/contract for the normative statement.
- Constraints: Android/Wear platform only; contract/substrate stage — not shipped to users.
- Status: **experimental** for M3 path; templates generally **planned** (M5)

### F-AP-12 Android backup & device-transfer exclusion (ADR-0006)
- Surface: OS backup, Data Extraction, D2D transfer
- Summary: Exclude all content- or authority-bearing data from Auto Backup/data extraction/transfer: capture packages, drafts, audio, transcripts, staged media, prepared bytes, Room DBs/journals/receipts/tombstones/recovery state/wearable replicas, provider URIs/grants, installation/device identity, credentials, entitlement caches, models, diagnostics, temp files. Capture packages under `noBackupFilesDir`; new preferences default excluded until reviewed. Reinstall ⇒ new installation identity, vault re-selection, reconcile only on-device data.
- Evidence: ADR-0006; `apps/android/app/src/main/res/xml/backup_rules.xml`, `data_extraction_rules.xml`
- Details: contract behavior is fully described in Summary; see the cited ADR/contract for the normative statement.
- Constraints: Android/Wear platform only; contract/substrate stage — not shipped to users.
- Status: **experimental** (rules files present in app module)

### F-AP-13 Wear acknowledgements, retention, Recording Only (ADR-0007)
- Surface: Wear app ↔ phone transfer lifecycle
- Summary: Three correlated milestones: `phoneIngested` (checksum verified + durable phone package), `vaultCommitted` (verified user-visible destination result + receipt), `sourceDeletionAuthorized` (local authorization, not a third delivery milestone). Watch retains media through `vaultCommitted`; storage pressure offers explicit recover/retry/export/discard but never silently weakens the threshold; duplicate/stale ACKs idempotent; unknown versions preserve media and fail actionably. Recording Only freezes portable preset policy + native folder/filename policy at creation; phone reaches `vaultCommitted` only after verifying the exported audio artifact; no transcription; never requests/emits location metadata. Discard is explicit and durably receipted.
- Evidence: ADR-0007; contract `wearable-protocol/v1`
- Details: contract behavior is fully described in Summary; see the cited ADR/contract for the normative statement.
- Constraints: Android/Wear platform only; contract/substrate stage — not shipped to users.
- Status: **planned** (M7)

### F-AP-14 Play Billing network isolation (ADR-0008)
- Surface: Billing module, entitlement
- Summary: Vox.md Unlimited = Play non-consumable. Billing may use network only inside a native billing boundary; verified `PURCHASED` only; acknowledge per policy; explicit pending/cancelled/unavailable/refunded/stale states. Billing failure never deletes/mutates/blocks staged content. Billing sees only product IDs + coarse quota facts — no packages, notes, transcripts, filenames, URIs, coordinates, content-derived hashes. Store-specific purchases (no cross-store account). Offline policy: last locally verified `PURCHASED` usable indefinitely but visibly labeled stale with last-verification time + retry/restore; fresh install stays free-tier until verified; authoritative non-purchased result removes entitlement; pending transaction does not erase prior purchase.
- Evidence: ADR-0008; ledger `cap.billing.*` (M8)
- Details: contract behavior is fully described in Summary; see the cited ADR/contract for the normative statement.
- Constraints: Android/Wear platform only; contract/substrate stage — not shipped to users.
- Status: **planned** (M3/M8)

### F-AP-15 Free-quota reinstall & grandfathering (ADR-0009)
- Surface: Quota metering, install lifecycle
- Summary: Android free usage is installation-local and **resets after uninstall/reinstall** (product-adjusted, not Keychain-equivalent). Metering only at the semantic success boundary, idempotent by request/delivery ID; failed/cancelled/discarded/unverified work never consumes quota; retries cannot double-charge. Grandfathering store-specific: Apple keeps signed-AppTransaction classification; Android has no Apple paid-app grandfathering and no historical cohort — access only via verified Play purchase; no date/preference/self-asserted shortcut.
- Evidence: ADR-0009; implemented ledger: `RoomQuotaLedger.kt` (86 lines), `QuotaReservationEntity`, reservation only "immediately before the future `committing` barrier"; current free capacity = 10 successful captures/installation
- Details: contract behavior is fully described in Summary; see the cited ADR/contract for the normative statement.
- Constraints: Android/Wear platform only; contract/substrate stage — not shipped to users.
- Status: **experimental** (Room v2 primitives implemented, unwired) / product behavior **planned**

### F-AP-16 Location-label consent & freeze (ADR-0010)
- Surface: Preset location metadata, Current Location editor action
- Summary: Coordinate-only output + map/geo links always local. City/place labels only under frozen lookup class: `offline` (vetted local DB) or `systemMayUseNetwork` (explicit per-preset/invocation consent, disclosed that the Android geocoder may contact a remote service). `none` = no lookup. Preset consent not inherited by editor actions. At invocation/recording-stop, freeze the privacy-adjusted coordinate or unavailable result, whether labels were requested, lookup class, consent decision/version, and label outcome; retries cannot re-acquire location, switch class, or re-ask a geocoder. Tombstones remove coordinates/labels. Current Location action derives its map link from coordinates directly and never calls a geocoder.
- Evidence: ADR-0010; ledger `cap.location.*` (M5/M7)
- Details: contract behavior is fully described in Summary; see the cited ADR/contract for the normative statement.
- Constraints: Android/Wear platform only; contract/substrate stage — not shipped to users.
- Status: **planned**

### F-AP-17 Advanced local intelligence (ADR-0011)
- Surface: Diarization, enrichment (cleanup/title/tag/category/checklist/meeting/custom transforms)
- Summary: Every shipped AI outcome requires an app-owned **local** implementation on declared device/model tiers before parity completion; no network-capable inference fallback ever. Model downloads only with explicit consent + size/license/source/verification disclosure; integrity-verified. Missing hardware/models, thermal limits, unsupported languages fail closed to explicit local capability state preserving untransformed source. Unavailable/deferred = explicit unmet parity gate, not completion.
- Evidence: ADR-0011; ledger `cap.ai.*` (M9)
- Details: contract behavior is fully described in Summary; see the cited ADR/contract for the normative statement.
- Constraints: Android/Wear platform only; contract/substrate stage — not shipped to users.
- Status: **planned** (M9)

### F-AP-18 Bounded UniFFI session resource policy (ADR-0012)
- Surface: FFI boundary
- Summary: All materialization (even small text) uses the bounded session; 1 MiB control JSON, 1 MiB chunks, 256 MiB aggregate initial limit. Explicit per-field maximums with typed safe field-path errors. Binaries cross by descriptor (source ID, media type, length, SHA-256), never bytes/handles. Exact session state machine; every malformed call (repeated/missing/out-of-order/wrong-artifact/post-EOF/hash-mismatch/abandoned/post-terminal) fails closed with no plan. Errors carry versions/codes/paths/buckets only — never captured content.
- Evidence: ADR-0012; enforced in `vox-core-uniffi/lib.rs`, `core-bridge/CoreBridge.kt`
- Details: contract behavior is fully described in Summary; see the cited ADR/contract for the normative statement.
- Constraints: Android/Wear platform only; contract/substrate stage — not shipped to users.
- Status: **experimental**

### F-AP-19 Contract fixture mirror sequencing (ADR-0013)
- Surface: CI, manifests
- Summary: Byte-identical synthetic fixtures mirrored to Swift/Rust/Kotlin test resources with explicit lifecycle `resourceOnlyPlanned` → `required` (promotion requires named executable consumer evidence). M1 mirrors were all `resourceOnlyPlanned`; Kotlin mirrors promote with the M3 consumer.
- Evidence: ADR-0013; `Packages/contracts/manifest.json`, mirrors under Rust/Kotlin test resources
- Details: contract behavior is fully described in Summary; see the cited ADR/contract for the normative statement.
- Constraints: Android/Wear platform only; contract/substrate stage — not shipped to users.
- Status: **experimental** (process in force)

### F-AP-20 Offline ASR baseline (ADR-0014)
- Surface: Transcription engines
- Summary: Dependable long-form Android ASR is an **app-owned local backend** (engine/model baseline must be committed before M4 starts — not yet named). System on-device `SpeechRecognizer` is an optional adapter only when runtime capability checks prove on-device language availability; loss/ambiguity falls back to app-owned backend or actionable audio-only state, never a network recognizer. Audio preserved through ASR failure; model absence/unsupported language are actionable states.
- Evidence: ADR-0014; ledger `cap.model.*`, `cap.voice.local-only` (M4)
- Details: contract behavior is fully described in Summary; see the cited ADR/contract for the normative statement.
- Constraints: Android/Wear platform only; contract/substrate stage — not shipped to users.
- Status: **planned** (M4)

### F-AP-21 IME visible-activity fallback (ADR-0015)
- Surface: Android keyboard (InputMethodService)
- Summary: Direct IME mic capture ships only where the M6 device/API/OEM/policy campaign proves it; otherwise a visible capture activity owned by the IME session records and transcribes but never holds `InputConnection`; only the active IME inserts after revalidating the original editor and sensitive-field policy. Focus loss, editor/package change, token mismatch, duplicate/stale result, IME recreation, process death, permission denial ⇒ refuse automatic insertion into a different editor, preserve audio/transcript for explicit Copy/retry. Password/sensitive fields disable dictation. Surrounding editor context never persisted. Separate durable transcription/insertion profile — no vault materialization/SAF commit.
- Evidence: ADR-0015; plan §7.5, §12; ledger `cap.entry.keyboard` (M6)
- Details: contract behavior is fully described in Summary; see the cited ADR/contract for the normative statement.
- Constraints: Android/Wear platform only; contract/substrate stage — not shipped to users.
- Status: **planned** (M6)

### F-AP-22 Vox-owned toolchain pinning (ADR-0016)
- Surface: Builds, CI
- Summary: Exact pins committed in `toolchains/android-wear-shared-core.json` (schema v2): Rust 1.97.1 / MSRV 1.87.0 / edition 2024 / UniFFI 0.32.0 / cargo-ndk 4.1.2 / NDK 27.1.12297006 / API 28 / Xcode 26.6 / Swift 6.3.3 / iOS 17.6; Android app: Gradle 9.3.1 (sha256-pinned distribution), AGP 9.1.1, Kotlin, JDK Temurin 17.0.20+8, Compose BOM 2026.08.00, Room 2.8.4, WorkManager 2.11.2, JNA 5.17.0, Hilt 2.60.1, plus lockfiles and dependency-verification metadata. No dynamic/latest inheritance; validator fails closed on drift.
- Evidence: ADR-0016; `toolchains/android-wear-shared-core.json`; `docs/architecture/android-wear-toolchain-baseline.md`
- Details: contract behavior is fully described in Summary; see the cited ADR/contract for the normative statement.
- Constraints: Android/Wear platform only; contract/substrate stage — not shipped to users.
- Status: **experimental** (in force)

### F-AP-23 Core API identities, readiness, first-core packaging (ADR-0017)
- Surface: UniFFI API, packaging CI
- Summary: Canonical JSON = sorted keys, 2-space indent, one final LF; lowercase-hex SHA-256; UUIDv5/SHA-1 namespace `8c7f8d7e-…` derivations; strict `new-note-text-link/apple-parity-v1` profile. Readiness = exact equality else `incompatible` + bounded safe mismatch codes, no session. First M2 core packaging uses absolute size gates over six leaves (no zero-byte baseline); those become the future 10% growth baseline.
- Evidence: ADR-0017; hosted evidence `m2-evidence` run 31838926900
- Details: contract behavior is fully described in Summary; see the cited ADR/contract for the normative statement.
- Constraints: Android/Wear platform only; contract/substrate stage — not shipped to users.
- Status: **experimental**

### F-AP-24 Durable capture package & journal authority (ADR-0018)
- Surface: `data` module durability
- Summary: The versioned app-private package + delivery journal are recovery authority; Room is only index/lease/grant/quota projection; WorkManager is an execution opportunity. Package layout `noBackupFilesDir/vox-captures/<lowercase-request-uuid>/{request.json, assets.json, observations/<attempt-id>.json, prepared/<plan-hash>/{artifact-plan.json,note.bin}, delivery-journal.json, commit-attempt.json, receipts/<receipt-id>.json}`. Durable enqueue ordering (allocate UUID → temp package → write → fsync → verify → atomic promote → fsync parent → Room row idempotent → only then `SavedLocally` may clear the composer). Explicit semantic states (`STAGING…DISCARDED`).
- Evidence: ADR-0018; implemented `DurableCaptureStore.kt` (721 lines), `CapturePackageCodec.kt`, `DurableCapture.kt` (`CaptureState`, `JournalCode` enums)
- Details: contract behavior is fully described in Summary; see the cited ADR/contract for the normative statement.
- Constraints: Android/Wear platform only; contract/substrate stage — not shipped to users.
- Status: **experimental** (implemented + JVM fault-boundary tests; no production wiring)

### F-AP-25 SAF commit ambiguity & reconciliation (ADR-0019)
- Surface: DocumentsProvider commit executor
- Summary: SAF fully native; capability-tested providers (no POSIX assumptions); every logical segment resolved via `DocumentsContract`/`ContentResolver`; all names/metadata untrusted; bounded reads; off-main-thread I/O. Preconditions before mutation: load durable package/journal → verify pins → verify plan hash + `note.bin` → revalidate grant/destination → observe occupancy (rematerialize only pre-commit) → reserve quota idempotently → persist `COMMITTING` + fsync. Result taxonomy exactly one of `verifiedCommitted` / `provedNotCommitted` / `permissionLost` (→ `needsPermission`, package kept) / `ambiguous` (→ `unknownOutcome`).
- Evidence: ADR-0019; implemented `SafVaultCommitExecutor.kt`, `SafDocumentsGateway.kt`, `SafCandidateOccupancy.kt`
- Details: contract behavior is fully described in Summary; see the cited ADR/contract for the normative statement.
- Constraints: Android/Wear platform only; contract/substrate stage — not shipped to users.
- Status: **experimental** (real-provider execution remains a recorded blocker)

### F-AP-26 Capture-package codec v1 & durable enqueue (ADR-0020)
- Surface: Package encoding/decoding
- Summary: v1 stores canonical `capture-preparation-input/v1` bytes as `request.json`, empty `assets.json` v1, journal v1 with bound byte counts/SHA-256. Canonical sorted-key 2-space JSON, one final LF; uppercase UUID/SHA, duplicate keys, non-finite numbers, unsupported versions fail closed; 1 MiB per control file; 1–1024 journal events; ≤256 MiB retained bytes. Cooperative `.promotion.lock` interprocess promotion protocol (FileChannel lock → NOFOLLOW recheck → ATOMIC_MOVE, no replace); `.tmp-<request-uuid>-<nonce-uuid>` temporaries; per-boundary fault checkpoints in tests; duplicate admission ⇒ reuse identical bytes / `CorrelationConflict` / `ExistingPackageCorrupt`.
- Evidence: ADR-0020; implemented `CapturePackageCodec.kt` (270 lines), `DurableCaptureStore`
- Details: contract behavior is fully described in Summary; see the cited ADR/contract for the normative statement.
- Constraints: Android/Wear platform only; contract/substrate stage — not shipped to users.
- Status: **experimental**

### F-AP-27 Journal replacement, fenced leases, quota, Room v2 (ADR-0021)
- Surface: `data` module Room layer
- Summary: Revision-CAS journal mutation under the promotion lock (temp journal file → fsync → atomic replace → fsync dir → repair Room; durability-uncertain exceptions trust only the canonical journal; identical replay repairs without new events). Room v2 (`capture-index-v1.db`, explicit non-destructive migration): attempt count, opaque-UUID fenced leases (1,000–600,000 ms caller-supplied, no production default; wall-clock expiry; renew/release by exact token; reboot does not clear), persisted max accepted wall-clock, installation identity, quota reservations (10 successful captures/install, keyed by request UUID, coalesce identical, release by token, retained for `materialized/committing/unknownOutcome/completed/…` states), content-free completion tombstones (no text/URL/path/URI/document ID/content hash). Terminal quota-commit + tombstone transaction is an internal primitive with no production caller yet.
- Evidence: ADR-0021; implemented `RoomCaptureCoordination.kt`, `RoomQuotaLedger.kt`, entities `CaptureLeaseEntity`, `QuotaReservationEntity`, `CaptureTombstoneEntity`, `InstallationIdentityEntity`, `LeaseClockEntity`, `CaptureDatabase.java`
- Details: contract behavior is fully described in Summary; see the cited ADR/contract for the normative statement.
- Constraints: Android/Wear platform only; contract/substrate stage — not shipped to users.
- Status: **experimental** (Room instrumentation compiled; not claimed executed per ADR text, though Pixel 7 migration execution is recorded in the M3 audit)

### F-AP-28 Lazy UniFFI loading & native packaging (ADR-0022)
- Surface: `core-bridge` module
- Summary: Compiles committed generated Kotlin from `Packages/vox-core-rust/generated/kotlin`; binding normalizer makes generated declarations module-internal (governance rejects `md.vox.core` refs from any non-test source except the sole adapter, incl. Java/debug/release bypasses); a handwritten owned-value boundary (`CoreBridge.kt`, 298 lines; `GeneratedNativeCoreAdapter.kt`) is the only API. Bridge construction inert; availability `LAZY_NOT_PROBED` until first operation; failed load ⇒ content-free coarse error, never app-start failure. Inputs bounded 1 MiB / identifiers 256 UTF-8 bytes; direct ByteBuffer borrows cleared after use; heap wrap forbidden; failing cancellation makes exactly one native attempt then closes. Four ABIs (`arm64-v8a`, `armeabi-v7a`, `x86_64`, `x86`) source-built; no committed `.so`; JNA pinned AAR with `libjnidispatch.so` at each path; debug-APK ELF inspection.
- Evidence: ADR-0022; `apps/android/core-bridge/`; first on-device load proven on Pixel 7 (M3 audit)
- Details: contract behavior is fully described in Summary; see the cited ADR/contract for the normative statement.
- Constraints: Android/Wear platform only; contract/substrate stage — not shipped to users.
- Status: **experimental**

### F-AP-29 Prepared-artifact persistence & SAF commit executor (ADR-0023)
- Surface: Materialization → commit pipeline
- Summary: `prepared/` append-only, named by plan hash; `note.bin` written once with per-chunk hash verification while draining; `artifact-plan.json` canonical with recomputed planHash + deterministic IDs (fail-closed mismatch); both hash-verified before journal `MATERIALIZED`. `CoreMaterializationCoordinator` is the sole control-document composer, lease-holding, driving `startMaterialization → seal → drain → finalize`; crash pre-`MATERIALIZED` ⇒ deterministic rematerialization, re-verify/reuse identical plan hash, accumulate differing hashes. `SafDocumentsGateway` is the only `ContentResolver`/`DocumentsContract` touchpoint (bounded content-free ops, 30 s watchdog, create unreachable without durable commit-attempt marker). `SafVaultCommitExecutor` executes the ADR-0019 order; stale occupancy pre-commit returns `staleOccupancy` → journaled rematerialization; after `committing`, no rerender/fallback. `commit-attempt.json` crash-window marker persisted (file + parent fsync) before `createDocument`.
- Evidence: ADR-0023 (oracle-approved `dba53149`); implemented files listed above
- Details: contract behavior is fully described in Summary; see the cited ADR/contract for the normative statement.
- Constraints: Android/Wear platform only; contract/substrate stage — not shipped to users.
- Status: **experimental** (M3 Phase 5; vertical slice still incomplete per audit)

---

## Part 4 — Android Product Capabilities (from plan capability matrix §9 + ledger)

All below are **planned** unless noted. Parity classification from plan §9; milestone from ledger.

### F-AP-30 Text & link capture (new note)
- Surface: Compose Quick Capture composer → durable enqueue → Rust materialization → SAF commit
- Summary: Core M3 vertical slice. 1–2 ordered text/link payloads, fixed preset policy, `Inbox`/`capture-{id}.md`, `Saved locally` only after durable enqueue.
- Details: deterministic suffix collision policy; process-death survival after every durable transition; exact expected Markdown verified after delivery; composer clears only after local durability
- Constraints: M3 profile only (`cap.payload.text`, `cap.payload.url`, `cap.target.new`, `cap.entry.app`)
- Evidence: plan §9 row 1; `MainActivity.kt` Quick Capture route is a placeholder saying "not implemented"
- Status: **planned** (substrate experimental)

### F-AP-31 Onboarding, vault setup, SAF destination picker & grant repair
- Surface: Onboarding and Vault setup screens
- Summary: `ACTION_OPEN_DOCUMENT_TREE` persisted URI grant; re-selection/repair UX; queued packages survive revoked grants into `needsPermission`.
- Details: never `MANAGE_EXTERNAL_STORAGE`; Photo Picker preferred; tree URIs/document IDs only in native destination records
- Evidence: plan §8.2/8.3; `MainActivity.kt` Vault placeholder
- Constraints: Android/Wear platform only; contract/substrate stage — not shipped to users.
- Status: **planned**

### F-AP-32 Durable inbox/status/retry/reconcile & history tombstones
- Surface: Inbox screen
- Summary: Delivery states (`staging…discarded`), Retry/needs-permission/unknown-outcome handling; payload-free history tombstone + retention cleanup; orphan reconciliation at launch and before drains.
- Evidence: plan §7; `CaptureState`/`JournalCode` implemented in `capture-domain/DurableCapture.kt`; Inbox placeholder UI
- Details: contract behavior is fully described in Summary; see the cited ADR/contract for the normative statement.
- Constraints: Android/Wear platform only; contract/substrate stage — not shipped to users.
- Status: **planned** (state model experimental)

### F-AP-33 Long voice recording (foreground service)
- Surface: Recording screen, ongoing notification
- Summary: User-started mic FGS with immediate notification; pause/resume/stop/cancel; recoverable audio format with ≥2 s flush frontier; calls/focus loss/mic disable/force-stop/reboot handled distinctly; next launch offers finalize/recover/discard; never deletes audio on transcription/delivery failure.
- Constraints: minSdk API 28 (phone), API 30 (Wear); FGS-type declarations + Play Console disclosure
- Evidence: plan §10.1; ledger `cap.voice.*` (M4)
- Details: contract behavior is fully described in Summary; see the cited ADR/contract for the normative statement.
- Status: **planned**

### F-AP-34 Local transcription & model management
- Surface: Models/languages/storage management screen, transcription pipeline
- Summary: `TranscriptionBackend` interface (capabilities/transcribe/cancel); app-owned local backend (initially Whisper) + optional system on-device adapter + audio-only fallback; consented model downloads with size/state, verification, selection, deletion.
- Evidence: plan §10.2; ledger `cap.model.whisper-*`, `parakeet-v2/v3`, `automatic`, `audio-only` (M4)
- Details: contract behavior is fully described in Summary; see the cited ADR/contract for the normative statement.
- Constraints: Android/Wear platform only; contract/substrate stage — not shipped to users.
- Status: **planned**

### F-AP-35 Transcript editing, search, history
- Surface: Transcript history screens
- Summary: Compose + Room indexed metadata, content local; edit/search/review/correction; export TXT/Markdown/JSON/YAML + share/SAF export.
- Evidence: plan §9; ledger `cap.history.*`, `cap.export.*` (M4/M5)
- Details: contract behavior is fully described in Summary; see the cited ADR/contract for the normative statement.
- Constraints: Android/Wear platform only; contract/substrate stage — not shipped to users.
- Status: **planned**

### F-AP-36 Markdown editor, Capture Bar, configurable presets, templates/frontmatter
- Surface: Editor UI
- Summary: Selection-aware Compose editor with 30+ ordered actions (ledger `cap.editor.bold/italic/heading/task/hashtag/wiki-link/sketch/scan/timestamp/undo/toolbar-order/…`); all shipped Capture Preset settings, route/template overrides, prefix/suffix, static frontmatter, attachment folder, entry/note templates; placement modes new/append/prepend/heading/daily–yearly rolling targets; existing-note mutation with race detection.
- Evidence: plan §9; ledger (114 M5 rows)
- Details: contract behavior is fully described in Summary; see the cited ADR/contract for the normative statement.
- Constraints: Android/Wear platform only; contract/substrate stage — not shipped to users.
- Status: **planned** (M5)

### F-AP-37 Photos, screenshots, camera, scans/OCR, sketches, file import
- Surface: Composer attachment flows
- Summary: Photo Picker + screenshot filtering; CameraX; ML Kit Document Scanner (GMS) with CameraX/manual fallback; bundled OCR (original persisted separately from derived text; failure degrades to attachment-only); Compose Canvas sketch with versioned raw stroke model + rendered preview; Sharesheet/SAF file import with size bounds and sanitized names.
- Evidence: plan §11; ledger `cap.payload.*` (M5)
- Details: contract behavior is fully described in Summary; see the cited ADR/contract for the normative statement.
- Constraints: Android/Wear platform only; contract/substrate stage — not shipped to users.
- Status: **planned**

### F-AP-38 Preset location metadata (opt-in one-shot)
- Surface: Preset config, Current Location editor action
- Summary: Location disabled by default; one-shot fix at invocation/recording-stop; Exact and City/coarsened policies; structured field selection/renaming incl. map/geo links (Google Maps/Apple Maps/OpenStreetMap/GeoURI) and 14+ field types; unavailable-outcome taxonomy (cancelled/notDetermined/permissionDenied/reducedAccuracy/restricted/timeout/unavailable) frozen at boundary; no background tracking.
- Evidence: plan §11; ledger `cap.location.*`; ADR-0010
- Details: contract behavior is fully described in Summary; see the cited ADR/contract for the normative statement.
- Constraints: Android/Wear platform only; contract/substrate stage — not shipped to users.
- Status: **planned** (M5)

### F-AP-39 Private activity stats & quota accounting
- Surface: Statistics/quota screens
- Summary: Content-free local ledger + reducers (captures/recordings/attachments/sources/seven-day); idempotent free metering (successful captures M3; transcription quota M4; voice metering M4) with Play entitlement where purchased; retry-no-charge.
- Evidence: plan §9; ledger `cap.stats.*`, `cap.quota.*`; `RoomQuotaLedger` substrate experimental
- Details: contract behavior is fully described in Summary; see the cited ADR/contract for the normative statement.
- Constraints: Android/Wear platform only; contract/substrate stage — not shipped to users.
- Status: **planned**

### F-AP-40 System entry points: Sharesheet, shortcuts/deep links, Glance widget, Quick Settings tile, Live Activity equivalent
- Surface: Exported `ACTION_SEND(_MULTIPLE)` activity, static/dynamic/pinned shortcuts, Glance widget, `TileService`, ongoing notification
- Summary: All route through the same durable enqueue use case; immediate URI copy; idempotent intents across recreation; coarse queued/recording/failure state display; tile start/stop with secure lock flow; ongoing notification + widget/tile replace Live Activity/Dynamic Island (no literal equivalent).
- Evidence: plan §12; ledger `cap.entry.share/shortcut/deep-link/widget/control-center/live-activity` (M6, `control-center`/`live-activity` M5)
- Details: contract behavior is fully described in Summary; see the cited ADR/contract for the normative statement.
- Constraints: Android/Wear platform only; contract/substrate stage — not shipped to users.
- Status: **planned**

### F-AP-41 Android keyboard (IME)
- Surface: `InputMethodService` + fallback capture activity
- Summary: Separate durable transcription/insertion profile (see F-AP-21); mic permission in visible settings flow; sensitive-field disabling; opaque IME session ID + editor token only; at-most-once insertion after revalidation.
- Evidence: plan §12; ADR-0015
- Details: contract behavior is fully described in Summary; see the cited ADR/contract for the normative statement.
- Constraints: Android/Wear platform only; contract/substrate stage — not shipped to users.
- Status: **planned** (high-risk; prototype-gated)

### F-AP-42 Wear OS app & surfaces
- Surface: Wear Compose app, Tile, complication, Ongoing Activity, notification
- Summary: Standalone recorder without phone; local queue (≥10 recordings incl. one 60-minute through 72 h phone-absence); preset sync with complete frozen snapshots; recording phases (idle/listening/paused/recording/pending/transcribing/syncing/delivering/error/unavailable); pause/resume; Data Layer Asset/Channel transfer (never MessageClient as sole transport), dedupe by UUID/installation/revision/length/SHA-256, resumable frontiers, staged ACKs (F-AP-13); reassignment/retry/discard; retention/storage-pressure UX.
- Constraints: Wear minSdk API 30 / Wear OS 3; battery ≤20% for 60-min recording; transfer ≤10 min
- Evidence: plan §13; ledger `cap.watch.*` (38 rows, M7)
- Details: contract behavior is fully described in Summary; see the cited ADR/contract for the normative statement.
- Status: **planned** (no `apps/android/wear` module exists)

### F-AP-43 Lifetime purchase (Play Billing non-consumable), restore, family
- Surface: Billing/entitlement UI
- Summary: See F-AP-14; plus restore flow, restore diagnostics, family-sharing/upgrade behavior (`cap.billing.family`, `family-upgrade`), grandfather policy (F-AP-09).
- Evidence: ADR-0008/0009; ledger `cap.billing.*` (M8)
- Details: contract behavior is fully described in Summary; see the cited ADR/contract for the normative statement.
- Constraints: Android/Wear platform only; contract/substrate stage — not shipped to users.
- Status: **planned**

### F-AP-44 Queue scheduling & recovery actions
- Surface: Inbox/queue UI, notifications
- Summary: Immediate/idle/manual scheduling policies; capture concurrency; retention delete-after-success/timed/permanent + per-job override; actions Retry, Retry All, Process Now, Copy, share/reveal, delete, reassign, retention override; keyboard result preservation; recovery through process death.
- Evidence: plan §9; ledger `cap.queue.*` (M4, reassign M4/M7, keyboard-preservation M6)
- Details: contract behavior is fully described in Summary; see the cited ADR/contract for the normative statement.
- Constraints: Android/Wear platform only; contract/substrate stage — not shipped to users.
- Status: **planned**

### F-AP-45 Security & privacy baseline (Android-wide)
- Surface: All modules
- Summary: No logging of note/transcript text, URLs, coordinates, filenames, tree URIs, document IDs, model input, keyboard context, wearable payloads; immutable PendingIntents + stable request IDs; every incoming URI/MIME/deep link/wearable message treated untrusted (bounded reads, media sniffing, traversal rejection); Keystore-backed credentials; deletion semantics defined for jobs/tombstones/recordings/transcripts/models/diagnostics/Wear replicas; sanitized crash diagnostics (coarse buckets only).
- Evidence: plan §8.7
- Details: contract behavior is fully described in Summary; see the cited ADR/contract for the normative statement.
- Constraints: Android/Wear platform only; contract/substrate stage — not shipped to users.
- Status: **planned** (partially enforced already in code-level governance: no `md.vox.core` leakage, content-free errors)

---

## Part 5 — What Is Actually Implemented Today vs Contract-Only

**Implemented and compiled/tested (experimental, production-unwired):**
- Rust core `vox-core` (2203 lines: readiness, prepare, path candidates, token rendering, MaterializationSession) + `vox-core-uniffi` facade — M2 hosted-qualified.
- Swift side: generated `VoxCoreGenerated/VoxCore.swift`, handwritten wrapper `VoxCoreRust.swift`, `VoxCoreFFI` modulemap, `VoxboardM2Oracle` (shadow-oracle corpus runner), `VoxboardM2MaterializationEvidence` (executable evidence), `VoxboardPersistenceFixtures` (`--generate`/`--validate` fixture tool).
- Contracts: manifest, 6 families, schemas, fixtures, mirrors, validators (`validate.py`, `validate_toolchain.py`, `convert_capabilities.py`), validation program (6 device roles, 3 providers, 21 cases, 23 gates).
- Android (`apps/android`, id `md.vox.android`, 6 modules: `app`, `core-bridge`, `capture-domain`, `data`, `platform-services`, `build-logic`):
  - `app`: Compose shell only — 5 placeholder screens (Onboarding/Vault/Capture/Inbox/History), each explicitly stating its feature is *not implemented*; `VoxApplication` composition root returns `CaptureAvailability.NOT_IMPLEMENTED` and `unwiredCoreBridge()`.
  - `core-bridge`: full lazy UniFFI owned-value boundary + generated adapter; JVM + instrumentation tests.
  - `capture-domain`: semantic enums/state (`CaptureState`, `JournalCode`, `JournalEvent`), `CaptureDelivery`, `CaptureDurability` planners, `DurableCapture` models — all framework-free.
  - `data`: `DurableCaptureStore` (durable file primitives, promotion lock), `CapturePackageCodec`, `CoreMaterializationCoordinator`, `SafDocumentsGateway`, `SafVaultCommitExecutor`, `PreparedPlanVerifier`, Room v2 DB + 7 entities + DAOs, `RoomQuotaLedger`, reconciliation; extensive JVM tests + instrumentation tests (compiled; Pixel 7 bridge/Room execution recorded).
  - `platform-services`: single 8-line `PlatformServicesFoundation.kt` placeholder — **no audio/ASR/camera/billing code**.
- First physical-target execution: native load, UniFFI control calls, Room migration on one Pixel 7 (M3 audit).

**Contract-only (no Android/Wear implementation):** wearable-protocol (no wear module), billing, ASR/voice, multimodal payloads, editor/presets/templates, location, entry points, keyboard, IME, stats/export, Wear surfaces. `platform-services` and all UI feature work remain empty/planned.

**No `apps/android/wear` module exists** despite the plan topology naming one.

---

## File-by-file coverage checklist

| In-scope target | Read? |
|---|---|
| `docs/android-wear-shared-core-implementation-plan.md` (all 1192 lines) | ✅ |
| `docs/architecture/adr-0001` … `adr-0023` (all 23 ADRs; 0001–0023 headers/decisions, 0009–0023 full) | ✅ |
| `docs/architecture/android-wear-m0-baseline.md` | ✅ |
| `docs/architecture/android-wear-m0-capabilities.json` (via ledger analysis) | ✅ (referenced; converted to product-capabilities.json) |
| `docs/architecture/android-wear-m0-compatibility-matrix.json` | ✅ (existence + reference; not line-read) |
| `docs/architecture/android-wear-m0-fixture-evidence.md` | ✅ |
| `docs/architecture/android-wear-m1-completion-audit.md` | ✅ |
| `docs/architecture/android-wear-m1-decisions.md` | ✅ |
| `docs/architecture/android-wear-m2-entry-foundation-audit.md` | ✅ |
| `docs/architecture/android-wear-m3-scope-and-entry-audit.md` | ✅ |
| `docs/architecture/android-wear-toolchain-baseline.md` | ✅ |
| `toolchains/android-wear-shared-core.json` | ✅ (head 80 lines + toolchain-baseline cross-check) |
| `Packages/contracts/` — all 6 family dirs, manifest.json, product-capabilities.json (all 271 rows enumerated), scope-variances.json, scripts, validation | ✅ (contract.md bodies summarized via ADRs; schema files listed not line-read) |
| `Packages/vox-core-rust/crates/vox-core/src/lib.rs`, `vox-core-uniffi/src/lib.rs`, generated bindings dirs | ✅ |
| `Packages/VoxboardShared/Sources/VoxCoreFFI`, `VoxCoreGenerated`, `VoxCoreRust`, `VoxboardM2MaterializationEvidence`, `VoxboardM2Oracle`, `VoxboardPersistenceFixtures` | ✅ (key decls; not every line) |
| `apps/android` — all 6 modules' build files, MainActivity, VoxApplication, all `data`/`capture-domain`/`core-bridge`/`platform-services` main sources enumerated with key symbols | ✅ |
| Test sources in `apps/android` | ✅ (enumerated; not individually read) |

## Uncertainties
1. **M1 hosted-CI receipt**: the M1 audit says "Complete locally; hosted CI required on the committed M1 SHA before M2 begins" — whether that receipt landed before M2 closure is not separately verified here (M2 audit shows hosted CI green, implying it did).
2. **ADR-0001..0008 middle sections** (rejected alternatives/executable gates beyond the first ~45 lines) were read only via headers/decision text; summaries rely on decision sections, which are complete.
3. **`android-wear-m0-capabilities.json` vs `product-capabilities.json`**: the 270-row M0 ledger was converted at M1 to 271 rows; the one-row delta and exact conversion diff were not itemized.
4. **Whether the ADR-0021 Room instrumentation tests have since been executed** beyond the single Pixel 7 run recorded in the M3 audit; ADR text predates that run.
5. **Wear module**: plan topology specifies `apps/android/wear`; it does not exist — assumed genuinely pending (M7) rather than relocated.
6. ADR-0023 sections beyond the sampled range (§4 remainder, §5+) — decision intent captured from read portion and cross-referenced implementation.
