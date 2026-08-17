# ADR-0018: Android durable package and journal authority

- Status: **Accepted**
- Product decision ID: `PD-M3-ANDROID-DURABILITY-AUTHORITY-001`
- Required by: M3 Android text/link vertical slice

## Context

Android cannot atomically commit an app-private filesystem package, a Room row, a quota
reservation, a provider mutation, and a UI acknowledgement. Treating Room or WorkManager
as the sole queue would make a crash between those boundaries lose staged content or
manufacture completion. M3 must define one recovery authority before product modules
write content.

## Decision

The versioned app-private capture package and its delivery journal are recovery authority.
Room is the searchable index, lease coordinator, destination/grant store, quota ledger,
and query projection. WorkManager is an execution opportunity, never queue truth.

Every package lives under
`noBackupFilesDir/vox-captures/<lowercase-request-uuid>/`. Disk schemas are independently
versioned from core API, artifact plan, user Markdown, Room, and wearable protocols. The
initial text/link package contains:

```text
request.json
assets.json
observations/<attempt-id>.json
prepared/<plan-hash>/artifact-plan.json
prepared/<plan-hash>/note.bin
delivery-journal.json
```

M3 has no attachment payload, but `assets.json` is an exact empty versioned manifest so a
future schema cannot be inferred from absence. User text/link bytes remain in the excluded
package, never in analytics or content-free history.

### Durable enqueue ordering

1. Allocate one stable request UUID before writing.
2. Create a same-parent temporary package under `noBackupFilesDir`.
3. Write canonical bounded request and empty-asset envelopes.
4. Flush each file and fsync it.
5. Close and reopen the required files to verify readable length and SHA-256.
6. Atomically promote the temporary package where the local filesystem supports it.
7. Fsync the parent directory so the promoted name is durable.
8. Insert or repair the Room index row idempotently by request UUID.
9. Only after steps 1–8 succeed may the use case return `SavedLocally`; only that result may
   clear the composer.

A crash before promotion leaves an unacknowledged temporary package that reconciliation
may delete after validation. A promoted valid package without a Room row is inserted. A
Room row without a package becomes a typed corruption/missing-package state; it is never
silently treated as completed. Duplicate enqueue with the same request UUID validates and
reuses identical durable bytes or fails correlation.

### Journal and prepared artifacts

The journal uses explicit semantic states from the implementation plan. Every transition
is written temp → fsync → atomic replace → parent fsync before its corresponding Room
projection is updated. A valid newer journal wins over an older Room projection. Room may
hold leases and attempt scheduling, but a lease never advances semantic state.

Observation snapshots are immutable per attempt. Prepared directories are append-only and
named by the finalized lowercase plan SHA-256. `note.bin` and `artifact-plan.json` are
written and hash-verified before the journal may enter `materialized`. A retry never
overwrites prepared bytes. Identical plan hashes may be reused only after every retained
byte and descriptor hash verifies.

Unsupported versions, noncanonical JSON, truncated files, duplicate keys, hash mismatch,
path mismatch, or impossible state transitions quarantine the package in a typed
`needsUserAction`/corrupt state. Recovery does not guess fields, rewrite user bytes, or log
content or logical paths.

### Quota, terminal transaction, and cleanup

Quota is installation-local and keyed idempotently by request UUID. A reservation is
created before the journal enters `committing` and before any provider mutation. Failure,
cancellation, permission loss, retryable failure, and `unknownOutcome` do not commit quota.
Reservations survive process death until reconciliation can release or commit them.

After exact destination readback is verified, the correlated receipt is persisted. The
quota commit and content-free completion tombstone are then committed in one Room
transaction. The tombstone contains request ID, coarse timestamps/status, destination ID,
and engine/version pins but no user content, URL, filename, logical path, provider URI,
document ID, or content-derived hash. A replay of that transaction cannot charge twice.

Package cleanup occurs only after the terminal Room transaction. A crash before cleanup
leaves a removable completed package; a crash after cleanup still retains the tombstone and
quota receipt. Cleanup never defines success.

## Consequences

This ordering accepts temporary Room/package divergence and requires deterministic launch
and pre-drain reconciliation. It prevents a database rollback, worker cancellation, or UI
process death from deleting the last durable copy. It also keeps native filesystem and
persistence authority outside Rust.

The package is not an Android backup mechanism. Backup and device-transfer rules exclude
it, Room, journals, quota, provider grants, identities, and preferences by default under
ADR-0006.

## Rejected alternatives

- **Room as sole queue truth:** rejected because filesystem and database writes cannot be
  atomic and Room may reference missing bytes.
- **Filesystem package without index:** rejected because leases, queries, repair UI, and
  quota transactions need native transactional coordination.
- **Overwrite one prepared directory on retry:** rejected because it can change bytes after
  a commit decision.
- **Clear the composer after an in-memory enqueue:** rejected because process death can lose
  the only copy.
- **Delete the package immediately after provider write:** rejected because receipt/quota
  persistence may still fail.

## Executable gates

- Failure injection covers request fsync, promotion, parent fsync, Room insertion,
  observations, every prepared byte/chunk, plan finalization/persistence, quota reservation,
  `committing`, readback, receipt, terminal transaction, and cleanup.
- Every restart ends with one valid queued package, one verified note, or an explicit typed
  actionable/unknown state; it never creates two notes or two charges.
- Reconciliation covers package-without-row, row-without-package, duplicate request,
  temporary package, corrupt/truncated codec, stale lease, completed package, and orphaned
  reservation.
- Composer tests prove `SavedLocally` and clearing occur only after durable promotion plus
  Room indexing.
- Backup inspection proves no package, database, journal, identity, grant, quota, prepared
  byte, or preference is transferred.
