# ADR-0017: Core API identities, fail-closed readiness, and first-core packaging

Status: **Accepted**

Product decision IDs: `PD-M2-CORE-API-001`, `PD-M2-DETERMINISTIC-IDENTITY-001`, `PD-M2-READINESS-001`, `PD-M2-FIRST-PACKAGING-001`

## Context

M2 needs a small independently versioned service boundary without conflating API
compatibility with input, renderer, artifact-plan, model, or wearable versions. It also
needs deterministic identities that Swift and Rust can reproduce exactly. The first
shared-core binary has no honest nonzero predecessor, so percentage growth from a
fictional zero-byte baseline is undefined.

## Decision

`core-api/v1` is independently versioned. Its records are strict canonical JSON and do
not change the independent versions of capture inputs, artifact plans, renderers,
profiles, persisted schemas, or wearable messages. The M2 supported profile is exactly
`new-note-text-link/apple-parity-v1`; unknown operations, profiles, contract versions,
renderer revisions, or core API versions fail closed. Apple remains authoritative in
`legacy` and `shadow`; readiness never grants side-effect authority.

Canonical JSON is UTF-8, object keys sorted lexicographically by Unicode code point,
two-space indentation, JSON literals without non-finite numbers, no insignificant
trailing spaces, and exactly one final LF. SHA-256 is lowercase hexadecimal over the
specified canonical bytes. UUID derivations use RFC 4122 UUIDv5 with SHA-1, the fixed
namespace `8c7f8d7e-4f61-5d92-a94a-3b9e6cc8e415`, a literal ASCII domain label, one NUL
byte, then the named canonical preimage. UUID text is lowercase hyphenated form. The
artifact-plan contract freezes each domain and preimage; changing it is a contract
version change.

Build info reports source/toolchain identity but grants no readiness. Expected versions
are an exact request. Readiness is `ready` only when every expected value equals a
supported compiled value; otherwise it is `incompatible`, lists bounded safe mismatch
codes, and permits no session. Expected artifact descriptors precede byte draining;
prepared chunk metadata is bounded and sequenced; drained hashes bind finalized bytes.

For the first M2 core artifacts, all six exact leaf scopes must pass their absolute size
gates. There is no percentage comparison and no zero-byte baseline. The approved M2
artifact set—exact revisions, toolchain/configuration, scope identities, bytes, and
SHA-256—becomes the nonzero future percentage-growth baseline. Every later comparable
artifact must pass both its absolute gate and the existing 10% scoped-growth gate.

## Consequences

M2 implementation cannot begin unless the exact toolchain manifest validates. The
foundation does not claim Rust behavior, generated bindings, Apple shadow execution,
Android authority, binaries, sizes, or performance. First-core packaging evidence is
recorded only after actual source builds exist.
