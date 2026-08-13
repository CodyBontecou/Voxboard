# ADR-0012: Bounded UniFFI sessions and resource policy

- Status: **Accepted**
- Product decision ID: `PD-M1-UNIFFI-BOUNDS-001`
- Required by: M1 contracts and M2 bridge

## Context

An unbounded JSON request/response or callback-driven FFI can duplicate large notes,
exhaust memory, make cancellation ambiguous, and cross native ownership boundaries.
Small requests taking a separate path would create two materialization semantics.

## Decision

Use coarse, owned UniFFI calls and an explicit bounded session for every
materialization, including small text/link requests. Control JSON is at most 1 MiB.
Every input and output byte chunk is at most 1 MiB. The initial aggregate note/template
input limit is 256 MiB. Raising or lowering it requires a superseding reviewed resource
decision supported by legacy-corpus, memory, and product evidence; existing-note parity
cannot be claimed while an Apple-supported note size lacks a bounded Android path.

Every contract string, array, map, batch, diagnostic list, envelope, and artifact count
has an explicit per-field maximum and a typed safe field-path error. Binary payloads
other than bounded note/template streams cross by descriptor (source ID, media type,
length, SHA-256), not bytes or native handle.

The session state machine is exactly
`input → outputReady → draining → finalized|cancelled`. Input accepts one sequence per
observation and one EOF, then seals once. Output is drained in declared artifact and
sequence order with caller `maxBytes` capped at 1 MiB. Finalization occurs once after
all artifacts are drained and their hashes supplied. Cancellation is explicit and
terminal. Repeated, missing, out-of-order, wrong-observation/artifact, post-EOF,
hash-mismatched, abandoned, post-finalize, or post-cancel calls fail closed and return
no plan. Wrappers release/cancel abandoned sessions. Panics are caught at the facade
and mapped to stable privacy-safe errors.

FFI errors and diagnostics may contain versions, codes, safe field paths, coarse kinds,
size/duration buckets, and hash equality. They never contain captured bytes, text,
paths, URIs, filenames, coordinates, or model input.

## Compatibility and consequences

Streaming limits peak duplication and keeps native storage/materialization separate.
The initial 256 MiB limit is policy, not evidence that every device can process it; M2
records performance/RSS baselines. Legacy Apple files remain readable even if a later
core profile cannot accept them—the job fails actionably before authority/commit.

## Rejected alternatives

- **Unbounded JSON/base64 notes:** rejected for memory, copy, and denial-of-service risk.
- **Native callbacks from Rust:** rejected because storage/lifecycle remains native.
- **Special unbounded shortcut for small text:** rejected because it creates divergent
  semantics and can grow unnoticed.
- **Best-effort sequence repair:** rejected because it can materialize corrupt output.

## Executable gates

- Boundary tests hit every exact maximum and reject maximum-plus-one with typed errors.
- Session model tests cover every legal transition and malformed sequence listed above,
  including abandonment and panic containment; incomplete sessions return no plan.
- Large synthetic 1/16/256 MiB streams remain in 1 MiB chunks and record M2 RSS/time
  evidence without committing user content.
- Binding/wrapper tests prove cancellation and terminal resource release on Swift and
  Kotlin consumers.
