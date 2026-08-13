# ADR-0003: Prepared-plan commit barrier

- Status: **Accepted**
- Product decision ID: `PD-M1-COMMIT-BARRIER-001`
- Required by: M2 and every native destination executor

## Context

A plan is unsafe if native code can begin side effects before all output is durable and
verified. Crashes between provider commit and local receipt also create genuinely
ambiguous outcomes.

## Decision

Core materialization uses prepare, bounded materialize/drain, finalize, native persist,
and native commit as distinct phases. `finishInput()` may expose expected artifact
descriptors, but it returns neither a side-effect receipt nor a committable plan.
Native code must drain every sequenced artifact into immutable prepared storage and
verify expected length and SHA-256. Only `finalizeOutput()` may return the complete
artifact plan after receiving the verified drained hashes.

Native code persists that finalized plan and its pins before the first external side
effect. It then executes the ordered commit sequence, persists a correlated journal
frontier/receipt after each operation, reads back destination length/hash, and records
the verified terminal receipt before cleanup. Attachments commit before their
referencing note. The source package remains durable until ownership and retention
rules permit deletion.

A cancelled, abandoned, incomplete, out-of-order, hash-mismatched, or post-terminal
session produces no committable plan. State changes may trigger a fresh prepare while
still pre-commit. Once a job enters `committing`, it never rerenders, switches engine,
or silently retries an unproven mutation. A crash after a possible destination commit
but before proof transitions to reconciliation or `unknownOutcome`.

## Compatibility and consequences

Current native coordination, containment, permissions, and provider behavior remain
native. Existing Apple direct-write behavior serves as an oracle only where it meets
this barrier; migration adapters must not weaken it. Immutable prepared bytes make
retries independent of later settings/template changes.

## Rejected alternatives

- **Commit while output streams:** rejected because incomplete output can escape.
- **Treat expected descriptors as a plan:** rejected because bytes have not been
  durably drained and verified.
- **Persist receipt after all side effects only:** rejected because intermediate crash
  frontiers would be unknowable.
- **Rerender on every retry:** rejected because settings and observations can change.

## Executable gates

Failure-injection tests cover cancellation and process death before/after input seal,
each drain frontier, finalization, plan persistence, every destination operation,
readback, receipt persistence, and cleanup. Tests assert that no side effect is
possible before finalized-plan persistence; mismatched or missing hashes fail closed;
and ambiguous post-commit crashes never auto-retry blindly.
