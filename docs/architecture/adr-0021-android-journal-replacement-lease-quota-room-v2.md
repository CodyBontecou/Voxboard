# ADR-0021: Android journal replacement, fenced leases, quota, and Room v2

- Status: **Accepted**
- Product decision ID: `PD-M3-ANDROID-DURABILITY-V2-001`
- Required by: M3 Android text/link vertical slice

## Context

ADR-0020 establishes durable package creation but cannot durably advance its canonical journal. Room v1 is only a content-free projection and cannot fence work or reserve the installation-local free quota.

## Decision

The canonical `delivery-journal.json` remains semantic recovery authority. A revision-CAS mutation holds the existing app-private `.promotion.lock`, revalidates the package, reducer-validates the complete proposed event, writes one same-package `.delivery-journal.<lowercase nonce UUID>.tmp` with create-new/no-follow semantics, fsyncs and reopens it, atomically replaces the canonical regular file, reopens the destination, fsyncs the package directory, and only then repairs Room. Unsupported atomic replacement fails closed. An exception after replacement, after a successful mutation while releasing the lock, or at any boundary where replacement cannot be disproved is durability-uncertain; restart trusts only the canonical journal. Lock, temporary-write, or Room fence-check failures before replacement are typed coordination failures, never package corruption or lease loss. Identical command replay repairs Room without adding an event. A temporary file is never inferred to be authoritative or promoted during recovery. Recovery may delete only one exact, bounded, regular, non-symlink journal temporary and fsync that deletion.

Room v2 adds journal-derived `attemptCount`, opaque UUID lease fencing, a persisted greatest accepted wall-clock observation, installation identity, quota reservations, and content-free completion tombstones. The database remains `capture-index-v1.db` and migrates explicitly from v1; destructive migration is prohibited. Migration does not invent installation identity.

Lease duration is caller supplied and must be 1,000–600,000 milliseconds. There is no production default or scheduler consumer. Acquire replaces only an absent or wall-clock-expired lease; renew/release require the exact opaque token. Every valid non-rollback time-bearing observation—including busy and lost results—advances the persisted maximum transactionally without changing lease ownership. Operations reject `now` below that maximum without mutation. Reboot does not clear leases: persisted wall-clock expiry remains authoritative. Lease expiry only revokes coordination ownership and never changes journal state. Raw Room lease access is module-internal; all production lease operations route through the coordinator under the same root lock and one root-lock-before-Room order. That lock remains continuous across fence check, journal CAS, atomic replacement, package-directory fsync, and projection.

The current free capacity is 10 successful captures per installation. Reservation is keyed by request UUID, coalesces identical requests, and counts committed tombstone units plus active reservations. Release requires the exact token. Reconciliation may classify reservations for release only under the ADR-0009 policy. It retains reservations for `materialized`, `committing`, `unknownOutcome`, `completed`, permission repair resuming commit, missing, or corrupt packages. Valid pre-commit, proved-not-committed, permanent-failure, user-action, and explicit-discard states prove no chargeable verified success and may release; an explicit user discard after ambiguity is likewise unverified discarded work under ADR-0009. Reservation remains immediately before the future `committing` barrier, not enqueue or lease acquisition.

A Room transaction for quota commit plus tombstone insertion exists only as an `internal` data-layer primitive. It requires an exact reservation token and a complete content-free tombstone draft, is idempotent only for an exact existing tombstone, and rolls back on conflict. No production caller or domain completion API exists until a later governed verified receipt is persisted. Tombstones contain no text, URL, filename, logical path, URI, document ID, artifact/note hash, or content-derived identifier.

## Consequences and limits

This slice is production-unwired substrate. It adds no SAF, provider receipt, UniFFI/native loading, WorkManager runtime, composer, prepared artifact, package cleanup, or success orchestration. JVM tests exercise pure planners and filesystem fault boundaries. Room instrumentation and migration tests are compiled but are not claimed executed. Physical atomic replacement, directory fsync, locking, migration, clock, provider, backup, and process-death behavior remain unqualified until honest target execution.
