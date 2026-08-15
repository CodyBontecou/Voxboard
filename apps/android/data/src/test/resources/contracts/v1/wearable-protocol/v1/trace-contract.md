# Wearable protocol trace v1

A trace is a bounded ordered sequence of production envelopes paired with a required
expected disposition. All fields are required and no defaults apply. Final assertions
name the exact sender installation, device, recording, epoch, and correlation scope.
No transfer, acknowledgement, terminal, action, or deletion state crosses that scope.

Accepted messages advance the synthetic reducer. Replay events explicitly attest
`duplicateNoOp`, `staleRevisionNoOp`, `staleEpochNoOp`, or
`foreignInstallationRejected`. A sender-scoped duplicate message ID is a no-op only
when the complete canonical envelope bytes are identical; any changed envelope is a
typed collision error. First observation records the ID and canonical bytes even when
its disposition is rejected or stale. A `reconciliationSummary` is the only trace event
that can replace the active sender installation, and a retired installation can never
become active again. Epoch monotonicity is installation-scoped: a new installation may
begin at epoch 1 regardless of the old installation's last epoch, while returning to an
old installation or lowering an epoch within one installation remains stale/foreign.
The summary contains unique recording IDs, includes its envelope recording exactly
once, preserves any locally known `(lastRevision, state)` frontier exactly, may import
an otherwise unknown recording frontier from a newly reconciled installation, and
names only earlier accepted action correlations from the same installation and device.

The validator requires a complete accepted preset inventory and snapshot before
recording metadata, then binds metadata ID/revision/hash and every frozen portable
policy field to a deep canonical copy of that snapshot. Later inventory/snapshot
messages cannot mutate the recording facts or reassignment baseline. Recording Only
therefore attests disabled ASR, excluded location, native folder/filename references,
routing/metadata policy, and destination capability before transfer.

Resumable transfer starts at chunk zero, advances contiguous chunk sequence, strictly
increasing frontier revision, and coherent offset by chunk length against the exact
manifest ID/length/SHA-256, and neither a chunk nor durable offset may exceed the
asset. Replacing a manifest clears downstream authority and is rejected after phone
ingest in the same scope. A complete frontier and matching receipt are required before
phone ingest. Ingest, vault commit, and deletion receipts remain correlated in
the exact recording scope. Unsupported version and other terminal outcomes forbid an
accepted follow-up. Action IDs are scope-unique; retry names an earlier accepted
revision, reassignment must change destination through confirmed action, and discard
requires the correlated durable action receipt.

Synthetic traces cover transcript and Recording Only, negotiation, complete preset
exchange, multiple partial resumable frontiers, reinstall reconciliation,
reassignment, retry, discard, ACK/deletion, failure, duplicate/collision, and all
adversarial scope boundaries. Trace fixtures do not constitute physical-device,
persistence-order, or transport evidence.
