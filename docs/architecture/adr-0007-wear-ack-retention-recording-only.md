# ADR-0007: Wear acknowledgements, retention, and Recording Only

- Status: **Accepted**
- Product decision IDs: `PD-M1-WEAR-ACK-001`, `PD-M1-WEAR-RETENTION-001`, `PD-M1-WEAR-RECORDING-ONLY-001`
- Required by: M1 protocol and M7

## Context

Transport delivery does not prove that phone storage or the user's vault owns a Wear
recording. Deleting source audio too early creates unrecoverable loss. Recording Only
has a different terminal artifact from transcript delivery.

## Decision

The durable protocol distinguishes and correlates these application milestones:

1. `phoneIngested`: phone verified complete asset length/SHA-256 and durably committed
   a phone-owned package.
2. `vaultCommitted`: phone verified the user-visible destination result and persisted
   its receipt.
3. `sourceDeletionAuthorized`: Wear durably observed the configured acknowledgement
   threshold and may clean up its source; this is local authorization, not a third
   phone delivery milestone.

`terminalFailure` and `discarded` are separate correlated outcomes. Transport receipts,
chunk/channel frontiers, application acknowledgements, and user-action receipts are
never conflated. Every message is replay-safe and tied to recording/sender installation,
epoch, monotonic revision, correlation ID, and protocol version.

Wear retains source media through `vaultCommitted`, the accepted deletion threshold.
A terminal queue state is persisted before audio deletion. Storage pressure may expose
explicit recover/retry/export/discard choices, but cannot silently weaken the threshold
or convert transport success into deletion authority. Duplicate/stale ACKs are
idempotent; unknown versions preserve media and fail actionably.

Recording Only freezes complete portable preset policy plus native folder/filename
policy references at recording creation. The phone reaches `vaultCommitted` only after
exporting and verifying the user-visible audio artifact. It does not transcribe and
never requests or emits location metadata. Reassignment/retry may change a native
capability reference only through a durable user action; it does not mutate the frozen
recording facts. Discard is explicit and durably receipted before deletion.

## Compatibility and consequences

Current Watch property-list formats remain legacy adapters. Protocol v1 does not assume
a matching live phone preset revision. A phone reinstall is a new installation and
requires reconciliation/reassignment; it cannot inherit stale ACK authority.

## Rejected alternatives

- **Delete after Data Layer delivery or `phoneIngested`:** rejected because the user's
  vault does not yet own the output.
- **Treat `sourceDeletionAuthorized` as a phone milestone:** rejected because it records
  the Wear cleanup decision after observing an ACK.
- **Silently delete under pressure:** rejected because durability outranks convenience.
- **Run location/transcription for Recording Only:** rejected because it changes the
  selected outcome and privacy contract.

## Executable gates

Protocol conformance fixtures cover transcript and Recording Only, frozen presets,
resumable transfer, reconciliation, all ACK/failure/action outcomes, duplicates, stale
revisions, reinstall identity, reassignment, retry, and discard. Failure-injection tests
prove save-before-delete and that no deletion occurs before correlated durable
`vaultCommitted` observation. Physical interruption/storage tests remain M7 evidence.
