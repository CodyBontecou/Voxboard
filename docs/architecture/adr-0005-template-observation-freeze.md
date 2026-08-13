# ADR-0005: Template and observation freeze

- Status: **Accepted**
- Product decision IDs: `PD-M1-OBSERVATION-FREEZE-001`, `PD-M1-TEMPLATE-FREEZE-001`
- Required by: M2

## Context

Deterministic materialization requires native facts that Rust cannot safely discover
through callbacks: current template and note bytes, candidate occupancy, and staged
asset metadata. Re-reading them during retries can silently change output.

## Decision

Preparation returns an ordered, bounded set of typed observation requests. Native code
resolves each request once for that prepare attempt. Materialization accepts only a
complete observation snapshot correlated to the preparation request/attempt and an
explicit snapshot revision/hash. Responses from separate attempts cannot be mixed.

Template bytes are frozen when a delivery is first prepared for materialization. The
snapshot carries explicit presence/absence, bytes, length, and SHA-256. Existing-note
observations similarly carry exact bytes, length, hash, and the relevant logical
identity; candidate occupancy and staged-asset descriptors remain ordered and hashed.
Native provider handles are never observations.

Current Apple behavior remains the template and editor oracle. In particular, the
shipped `CaptureEntryTemplateRenderer` substitutes metadata/date/source/ID tokens only
in destination entry formatting; literal capture payload text such as `{date}` is not
interpolated. The current path template and Markdown/frontmatter behavior is preserved.
M2 exact fixtures freeze token replacement, ordering, newline, and missing-template
details against production Swift before Rust authority can be admitted.

Retries reuse frozen template and observation bytes with the persisted immutable plan.
A pre-commit conflict may start a new explicitly identified prepare attempt. No retry
may quietly re-read a newer template or combine a newer note with older occupancy.

## Compatibility and consequences

User template edits affect future preparations, not already-prepared jobs. Legacy Apple
persisted template records remain native compatibility inputs. Hashes permit safe
comparison without content diagnostics.

## Rejected alternatives

- **Rust callbacks into storage:** rejected because they are unbounded, lifecycle-
  coupled, and expose native capabilities.
- **Read templates at commit/retry time:** rejected because output would not be
  immutable.
- **Snapshot fields without attempt correlation/hash:** rejected because stale response
  mixing would remain possible.
- **Interpolate tokens in captured text:** rejected because it changes shipped behavior.

## Executable gates

- Session tests reject missing, duplicate, stale-attempt, wrong-ID, wrong-order, wrong-
  length, and wrong-hash observations.
- M2 golden fixtures compare production Swift and Rust template/path/note bytes exactly,
  including literal payload tokens and missing template.
- Retry tests edit templates/native notes after prepare and prove pinned jobs neither
  reread nor change; explicit pre-commit rematerialization receives a new snapshot ID.
