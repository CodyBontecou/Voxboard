# ADR-0004: Existing-note retry markers and ambiguous outcomes

- Status: **Accepted**
- Product decision ID: `PD-M1-RETRY-MARKER-001`
- Required by: M2 fixture parity and M3 provider retry behavior

## Context

Existing/shared-note mutations can commit immediately before process death. A local
receipt alone cannot prove whether the mutation happened. Vox.md already ships a
request marker; a new syntax would break duplicate detection and user-file parity.

## Decision

When retry protection is enabled for a Markdown note mutation, use exactly:

```text
<!-- vox-capture:<lowercase-uuid> -->
```

`<lowercase-uuid>` is the capture request UUID in canonical hyphenated lowercase form.
The shipped syntax from `CaptureRequestMarker.text(for:)` remains authoritative. Do
not replace it with an operation-ID marker or add a second marker syntax. Deterministic
operation IDs remain internal plan/receipt metadata.

The current editor behavior is preserved as the oracle: it normalizes CRLF/CR to LF
before editing and duplicate detection; an existing exact marker returns the normalized
document unchanged; when protection is enabled, a non-empty entry is followed by one
blank line and then the marker, while an empty wrapped entry consists of the marker;
the resulting capture block participates in the editor's existing append, prepend, or
beneath-heading blank-line rules. M2 exact fixtures freeze these details rather than
re-specifying them opportunistically in Rust.

Before retrying a mutation, native code reads the current note and checks the exact
request marker. A present marker completes/reconciles the request without a duplicate
write. If the marker is absent but the provider may have committed, or content cannot
be read and verified, the job enters `unknownOutcome` and asks for explicit
inspection/reconciliation. Stable paths plus hash equivalence protect new notes and
attachments; they do not justify blind shared-note mutation retries.

## Compatibility and consequences

Existing marked notes remain detectable across Apple and Android. The marker is
intentionally visible in source Markdown but inert in rendered output. Unmarked legacy
mutations retain their existing behavior; enabling cross-platform retry protection is
an explicit operation/profile decision.

## Rejected alternatives

- **`vox-operation` or operation-ID marker:** rejected because it conflicts with the
  shipped request-ID syntax.
- **Hidden native receipt only:** rejected because it cannot close the provider commit
  crash window.
- **Search by captured text:** rejected as ambiguous and privacy-invasive.
- **Blind retry when marker read fails:** rejected because it can duplicate user data.

## Executable gates

- Swift/Rust exact fixtures cover lowercase syntax, placement, LF/CRLF/CR input,
  append/prepend/heading placement, empty entry, and duplicate replay.
- Negative fixtures reject malformed/uppercase/wrong-request markers as proof for the
  target request.
- Failure injection after provider mutation and before receipt proves marker-based
  reconciliation or `unknownOutcome`, never duplicate auto-append.
