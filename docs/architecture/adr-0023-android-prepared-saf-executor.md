# ADR-0023: Android prepared-artifact persistence and SAF commit executor

- Status: **Accepted** (oracle-approved `dba53149` re-review after initial REJECT; implementation obligations 1–4 noted in the verdict are discharged in this phase)
- Product decision ID: `PD-M3-ANDROID-PREPARED-SAF-EXECUTOR-001`
- Required by: M3 Android text/link vertical slice (Phase 5)
- Extends: ADR-0018 (package/journal authority), ADR-0019 (SAF ambiguity
  reconciliation), ADR-0021 (fenced leases, revision-CAS journal),
  ADR-0022 (lazy UniFFI bridge)

## Context

M3 Phases 2–4 delivered the durable package/journal authority, fenced-lease
revision-CAS journal replacement, the Room v2 quota/tombstone projection, the
lazy fail-closed UniFFI bridge, and source-built native packaging. First
physical-target execution on a Pixel 7 proved native load, UniFFI control
calls, and Room migration on-device. Nothing yet connects the Rust core's
materialization session to the durable package or executes a provider commit:
no prepared bytes are persisted, no journal reaches `MATERIALIZED`,
`COMMITTING`, or `COMPLETED`, and the Phase 3 terminal quota/tombstone
transaction has no reachable caller because no verified receipt can exist.

This ADR conforms to ADR-0018's governed package layout; the implementation
plan's §7.1 "Suggested package" sketch is non-normative where it differs.

## Decision

### 1. Prepared artifacts are package-owned immutable outputs (ADR-0018 layout)

The executor extends the existing durable package exactly per ADR-0018:

```text
noBackupFilesDir/vox-captures/<request-id>/
  request.json
  assets.json
  observations/<attempt-id>.json
  prepared/<plan-hash>/artifact-plan.json
  prepared/<plan-hash>/note.bin
  delivery-journal.json
  commit-attempt.json          (native crash-window marker; §4)
  receipts/<receipt-id>.json
```

Rules:

- `prepared/` directories are append-only and named by the finalized lowercase
  plan SHA-256. A retry never overwrites prepared bytes; a directory with an
  identical plan hash may be reused only after every retained byte and
  descriptor hash verifies. Differing plan hashes accumulate append-only.
- `note.bin` is written once through the package durable-file primitives
  (new-file, fsync) while draining the sealed session in bounded 1 MiB
  chunks; each drained chunk hash is verified against the chunk descriptor
  before the next drain. `artifact-plan.json` is the canonical finalized plan
  JSON; the executor recomputes `planHash` (canonical bytes with `planHash`
  zeroed) and every artifact-plan/v1 deterministic ID and fails closed on
  mismatch. Both files are hash-verified before the journal may enter
  `MATERIALIZED` (ADR-0018).
- `observations/<attempt-id>.json` records the immutable observation snapshot
  per materialization attempt (attempt ID = journal revision at which the
  attempt started, plus request UUID, giving a bounded deterministic identity).
- Deletion is permitted only for provably-incomplete directories: a directory
  whose `note.bin`/`artifact-plan.json` never both hash-verified (a materialization
  attempt crashed mid-write) may be deleted only before any later journal event
  claims `MATERIALIZED`. A verified directory is never deleted pre-commit.
- The authoritative prepared-plan hash is durably recorded (journal event
  payload binding, per implementation plan §7.3) so restart in `COMMITTING`
  selects the plan named by the commit marker, never a re-derived guess.

### 2. One materialization coordinator owns the control document

A data-layer coordinator (`CoreMaterializationCoordinator`) is the only
production composer of the materialization control document. It:

1. runs as the fenced lease holder (ADR-0021) and loads the durable request
   envelope and current journal under the continuous root lock;
2. calls bridge `prepare()` with the canonical preparation input bytes from
   `request.json`, and persists the frozen observation snapshot for the
   attempt;
3. composes the canonical control: contract/session limits, runtime pins
   copied from the request (never synthesized), the preparation
   `snapshotHash`, and observations from the live bridge output plus native
   candidate occupancy for the planned destination;
4. drives `startMaterialization → seal → drain → finalize` with bounded
   input/outputs, persisting and hash-verifying drained bytes per §1;
5. appends `MATERIALIZED` through the coordinator's revision-CAS path only
   after both prepared artifacts verify.

The control document is canonical UTF-8 JSON produced by the same strict
writer used for package/journal documents; any Rust-side
`NonCanonicalControl` or pin mismatch is a coarse retryable failure, never a
Kotlin rendering fallback.

**Restart semantics (prepared-present, pre-`MATERIALIZED`):** after a crash
with the journal at `PREPARING`, the coordinator rematerializes
deterministically under a new lease; an identical recomputed plan hash reuses
the retained `prepared/<plan-hash>/` directory only after full byte and
descriptor hash verification (ADR-0018); a differing hash accumulates a new
append-only directory. The journal never claims `MATERIALIZED` from a prior
crash's bytes without that re-verification.

### 3. SAF executor is native-only and provider-untrusting

The `data` module (which the implementation plan assigns "SAF
resolver/executor") gains two components:

- `SafDocumentsGateway`: the only code that touches `ContentResolver`,
  `DocumentsContract`, cursors, or provider streams. It exposes bounded,
  content-free operations — grant revalidation, segment resolution, document
  creation, bounded write, bounded read-back, and name-bounded child lookup —
  each executed off the main thread under a 30-second watchdog that ends in a
  typed executor result, never an unbounded hang or erased package. The
  gateway's create operation is unreachable without a durably persisted
  commit-attempt marker (statically governed, like the existing bridge-bypass
  governance; §4).
- `SafVaultCommitExecutor`: the only caller of the gateway. It executes the
  ADR-0019 precondition order against a persisted vault destination record
  (stable destination UUID plus tree URI, native-owned): load package/journal,
  verify pins against bridge build info, verify plan hash and note bytes,
  revalidate the grant, observe candidate occupancy against the plan's
  `absent` policy, reserve quota idempotently, persist `COMMITTING` with
  fsync, durably persist the commit marker, create the note document, write
  prepared bytes, close, then read back exact length and SHA-256.

**Executor journal binding (ADR-0021):** the commit executor runs as the
lease-holding worker; every journal append it causes (`COMMIT_STARTED`,
`PROVED_NOT_COMMITTED`, `PERMISSION_LOST`, `COMMIT_AMBIGUOUS`,
`VERIFIED_COMMITTED` — all worker-lease codes) routes through the
coordinator's revision-CAS mutation path under the continuous root lock. A
changed-occupancy observation pre-commit never rerenders in place: the
executor returns a typed `staleOccupancy` result and the coordinator appends
`PREPARING` (`PREPARATION_STARTED`) as a journaled rematerialization
transition.

After `committing`, the executor never rerenders, changes engines, selects
another candidate, or falls back to Kotlin rendering.

### 4. Commit-attempt marker and crash-window truth

Immediately before issuing the provider `createDocument` call, the executor
persists `commit-attempt.json` through the package durable primitives —
new-file write, file fsync, **and parent-directory fsync**, completing
strictly before `createDocument` is issued — containing the destination UUID,
authoritative plan hash, and candidate display name. The marker is never
deleted between its durable write and the outcome of the create/write
attempt it guards. This is a native crash-window marker, not a core contract
and not a receipt.

- Restart from `committing` with **no marker** proves by causality (marker
  durability precedes create issuance) that create was never issued; this is
  a refinement of ADR-0019's "reconciliation only" restart rule — local
  causal proof of no-issue is the strongest form of `provedNotCommitted`
  evidence — so the executor appends `PROVED_NOT_COMMITTED` and the package
  retries the normal pre-commit path. This refinement is recorded here so
  the two ADR texts do not conflict.
- Restart with a **marker present** invokes reconciliation only: exact
  candidate lookup and bounded read-back establish `VERIFIED_COMMITTED`; any
  duplicate, missing-but-listed-late, transformed, inaccessible, or otherwise
  uncertain state is `COMMIT_AMBIGUOUS` (`unknownOutcome`); missing grant is
  `PERMISSION_LOST`. The normal write path is never invoked first.
- **Marker lifecycle across attempts:** appending `PROVED_NOT_COMMITTED`
  clears the marker atomically (temp → fsync → replace → directory fsync
  within the same journaled mutation window). A stale marker found at
  restart is always treated as reconciliation-only, never as proof of
  create issuance or non-issuance.
- A local Room receipt alone never proves provider state (ADR-0019).

**Watchdog-timeout mapping:** a watchdog expiry before the durable marker
completes is a journaled retryable pre-commit failure (no provider mutation
was possible); expiry after the marker (create may have been issued or the
provider may be slow) is `COMMIT_AMBIGUOUS`/`UNKNOWN_OUTCOME`; detected
permission loss maps to `PERMISSION_LOST`. Every expiry persists a typed
journal state.

### 5. Receipts gate the terminal transaction

`verifiedCommitted` persists `receipts/<receipt-id>.json` — canonical JSON
correlating request, operation, and artifact IDs, plan hash, destination
UUID, verified length/SHA-256, and commit timestamp — before appending
`VERIFIED_COMMITTED` (which requires the receipt ID) and before the Phase 3
internal terminal quota-commit + tombstone transaction. The receipt ID is
deterministic (derived from operation/artifact identity per the program's
UUID derivation discipline), so a crash between receipt persistence and the
journal append replays idempotently; `receipts/` is append-only, and an
existing identical receipt is verified, not rewritten. Receipts contain no
tree URIs, document IDs, provider names, or user content, and the Room
tombstone gains no `planHash` or other content-derived hash (ADR-0018
tombstone rule). Marker and receipts stay inside the backup-excluded package
and are covered by the existing backup-inspection gates, extended to name
them.

The terminal transaction remains internal-only and unreachable without a
verified receipt.

### 6. Bounded result taxonomy

Every executor attempt returns exactly one coarse native result mapped to the
journal reducer's existing states: `verifiedCommitted` → `COMPLETED`,
`provedNotCommitted` → `RETRYABLE_FAILURE` (normal pre-commit retry),
`permissionLost` → `NEEDS_PERMISSION` (package and prepared bytes retained),
`ambiguous` → `UNKNOWN_OUTCOME` (package, prepared bytes, marker, and
reservation context retained; no charge, no blind retry), and
`staleOccupancy` → journaled `PREPARING` rematerialization (§3). Coarse codes
are content-free; provider exception text never crosses the boundary.

### 7. Package entry-inventory defense (extending the Phase 2 gate)

`DurableCaptureStore` validation gains a state-gated inventory policy that
remains fail-closed:

- The Phase 2 base entries (`request.json`, `assets.json`,
  `delivery-journal.json`) stay mandatory in every state.
- `observations/` accepts only `<attempt-id>.json` files matching the bounded
  deterministic attempt identity; count ≤ 1,024.
- `prepared/` accepts only `<lowercase 64-hex>/` directories each containing
  exactly `artifact-plan.json` and `note.bin`; plan-directory count ≤ 64;
  optional from `PREPARING`, mandatory once `MATERIALIZED` or later is
  claimed; a `MATERIALIZED` claim without verified prepared artifacts fails
  closed.
- `commit-attempt.json` is optional from `COMMITTING` onward.
- `receipts/` accepts only `<deterministic receipt id>.json`; mandatory at
  `COMPLETED`; count ≤ 1,024.
- Unknown entries, symlinks, nested unexpected directories, per-file byte
  bounds (control files ≤ 1 MiB; `note.bin` ≤ 256 MiB aggregate cap), and
  aggregate bounds violations remain typed corruption. The mutation-tested
  governance is extended in the same change, not relaxed.

### 8. Test and evidence boundary

- JVM tests cover the control composer (canonical bytes, pin propagation,
  observation correlation), plan verifier (hash/ID recomputation, negative
  mutations), marker/receipt codecs and lifecycle, taxonomy and watchdog
  mapping, inventory policy, and coordinator failure containment.
- Instrumentation on a physical target drives enqueue → prepare →
  materialization → prepared-artifact verification → commit → read-back →
  receipt → terminal transaction against the real local DocumentsProvider
  through the production executor, plus permission-lost and crash-window
  reconciliation cases. The provider campaign requirement of ADR-0019
  (local plus two non-local providers) remains open until executed on real
  targets; emulator or fake-provider success does not close it.
- App composition remains `unwiredCoreBridge()`; the executor is an explicit
  library consumer, and WorkManager scheduling remains a later phase.
- Post-terminal package cleanup remains governed by ADR-0018 and is out of
  this ADR's scope.

## Rejected alternatives

- **Persist prepared bytes outside the package (cache/staging):** rejected —
  recoverability must not depend on a second authority.
- **Kotlin-side plan reconstruction or rendering fallback:** rejected — no
  Android rendering authority exists.
- **Retry from `committing` without reconciliation:** rejected — provider may
  already have committed; duplicates or loss follow.
- **Store tree URI/document IDs in receipts, journals, or the marker:**
  rejected — storage handles stay in native destination records only.
- **Treat create-call success as commit:** rejected — only exact read-back
  verification is `verifiedCommitted`.
- **Non-hash-named or mutable prepared directories:** rejected — contradicts
  ADR-0018 append-only, plan-hash-named prepared directories.

## Consequences

The M3 delivery path becomes end-to-end real on-device for the local
provider: composer-cleared durability (Phase 2) now flows into verified
provider commits gated by receipts and quota. Ambiguous outcomes are honest
and user-inspectable. M3 still cannot close without the non-local provider
campaign, process-death injection across every durable transition, and
composer/WorkManager wiring.
