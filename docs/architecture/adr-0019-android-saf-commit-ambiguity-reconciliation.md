# ADR-0019: Android SAF commit ambiguity and reconciliation

- Status: **Accepted**
- Product decision ID: `PD-M3-ANDROID-SAF-RECONCILIATION-001`
- Required by: M3 Android text/link vertical slice

## Context

A DocumentsProvider is a capability service, not a POSIX filesystem. Providers may expose
non-local storage, delayed visibility, duplicate display names, short or transformed
writes, unsupported rename, revoked grants, and a process-death window after commit but
before a local receipt. A normal retry from that window can create duplicate notes.

M3 promotes Rust authority for deterministic new-note text/link bytes only. Kotlin must
execute the resulting immutable plan while preserving provider ambiguity honestly.

## Decision

SAF ownership remains entirely native. Tree URIs, document IDs, `ContentResolver`, persisted
grants, cursors, descriptors, and provider capabilities never enter core contracts or
UniFFI. Rust receives and returns logical relative segment arrays, candidate occupancy,
immutable bytes, and hashes only.

The M3 executor supports one new Markdown note and no attachments, existing-note mutation,
rolling target, rename dependency, or Kotlin rendering fallback. It resolves every logical
segment through `DocumentsContract`/`ContentResolver`, treats all names and metadata as
untrusted, bounds all reads, and performs provider I/O off the main thread.

### Commit preconditions and ordering

Before provider mutation, native code must:

1. load a valid durable package and journal;
2. verify exact engine/core/contract/profile/toolchain pins;
3. verify finalized plan hash, note descriptor, and immutable `note.bin` bytes;
4. revalidate the persisted URI grant and destination identity;
5. observe candidate occupancy and rematerialize only while still pre-commit if that
   observation changed;
6. reserve quota idempotently;
7. persist journal state `committing` and fsync it.

After `committing`, the executor never rerenders, changes engines, selects another
candidate, or falls back to Kotlin. It creates/writes the planned note, closes the provider
handle, and reads the created document back to verify exact length and SHA-256. Only exact
readback is `verifiedCommitted`.

### Result taxonomy

Every attempt ends in exactly one native result:

- `verifiedCommitted`: the intended candidate is readable and exact length/SHA-256 match;
- `provedNotCommitted`: provider evidence proves the intended candidate was not created and
  another normal attempt is safe;
- `permissionLost`: the capability is revoked/unavailable and the package enters
  `needsPermission` without deletion;
- `ambiguous`: commit or absence cannot be proved, so the package enters `unknownOutcome`
  for explicit inspection/reconciliation.

Timeout, provider crash, null/contradictory metadata, delayed listing, duplicate candidate,
short read, transformed bytes, and process death are not automatically
`provedNotCommitted`. A local Room receipt alone cannot prove provider state.

### Restart and reconciliation

Restart from `committing` without a verified receipt invokes reconciliation only. It never
calls the normal write path first. Reconciliation revalidates the original destination and
planned candidate, then performs bounded lookup/readback:

- one exact candidate with matching length/SHA-256 establishes `verifiedCommitted`;
- authoritative absence under a provider behavior already proven synchronous may establish
  `provedNotCommitted`;
- missing grant establishes `permissionLost`;
- every duplicate, delayed, inaccessible, transformed, or otherwise uncertain state is
  `ambiguous`.

`verifiedCommitted` persists its correlated receipt before the terminal quota/tombstone
transaction defined by ADR-0018. `provedNotCommitted` may release reservation and schedule a
new pre-commit attempt. `permissionLost` opens destination repair. `ambiguous` retains the
package, prepared bytes, reservation context, and inspection action; it does not charge or
blindly retry.

A repaired destination is correlated by the stable native destination UUID. Re-selection
never rewrites the old provider merely because a new URI was granted. User-directed discard
is explicit and distinct from proof of non-commit.

### Provider capability policy

M3 requires no rename or atomic replace. Temporary-document/rename optimizations may be
used only after a named provider capability test proves their semantics, and correctness
must not depend on them. Case sensitivity, stable IDs, immediate listing, seekability,
reported size, MIME preservation, and atomic close are not assumed.

Each provider operation has a 30-second watchdog. The watchdog ends in a persisted typed
retry, permission, user-action, or unknown state; it never blocks the UI thread or erases
the package.

## Consequences

Users may occasionally need to inspect a provider after an ambiguous failure. This is
preferable to silent duplication or data loss. Non-local provider evidence is a physical
campaign requirement; emulator/fake-provider success cannot close M3.

The policy is deliberately narrower than later existing-note and attachment operations.
Those operations require their own markers, original hashes, orphan handling, and reviewed
promotion.

## Rejected alternatives

- **Blind WorkManager retry after timeout/process death:** rejected because the provider may
  already have committed.
- **Trust create/write return without readback:** rejected because close or transformation
  may fail after the API returns.
- **Use filesystem paths or rename assumptions:** rejected because DocumentsProviders do
  not promise POSIX semantics.
- **Render again in Kotlin when core/readiness fails:** rejected because Android has no
  legacy renderer authority.
- **Treat missing Room receipt as absence:** rejected because provider commit and Room
  receipt cannot be atomic.

## Executable gates

- Fake/instrumented providers cover grant revocation, duplicate names, rename unsupported,
  delayed visibility, offline/timeout, short write/read, transformed bytes, null metadata,
  provider death, and exact readback.
- Process death is injected before `committing`, after provider create, during/after write,
  after readback, before/after receipt, and before/after terminal transaction.
- Reconciliation tests prove restart from `committing` cannot invoke the normal writer and
  every uncertain case becomes `unknownOutcome`.
- Static dependency tests prove SAF handles remain native and no Kotlin renderer exists.
- Physical campaigns cover local DocumentsUI plus at least two named non-local providers on
  the required Pixel, Samsung, API-28, and large-screen roles. No identity or result is
  recorded until actually observed.
