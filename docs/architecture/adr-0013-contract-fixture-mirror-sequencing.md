# ADR-0013: Contract fixture mirror sequencing

- Status: **Accepted**
- Product decision ID: `PD-M1-MIRROR-SEQUENCING-001`
- Required by: M1 manifest and fixture validation

## Context

M1 requires identical contract fixtures mirrored for Rust, Swift, and Kotlin consumers,
but Rust implementation authority begins in M2 and Android implementation authority in
M3. Requiring nonexistent consumers makes M1 impossible; treating every mirror as
optional allows permanent drift.

## Decision

The repository may create resource-only fixture destinations for future Rust and Kotlin
consumers during M1. A resource-only mirror contains only byte-identical synthetic
fixtures plus minimal resource metadata/readme needed to identify them. It must not
contain executable Rust/Kotlin product code, generated bindings, build integration,
production dependency edges, or any authority/fallback claim.

Each mirror is declared with an explicit lifecycle:

- `resourceOnlyPlanned`: destination may exist and must match canonical bytes if it
  exists; no consumer is claimed.
- `required`: destination must exist, match canonical bytes/hash/file set, and be
  consumed by the named production-language test target.

M1 may make existing Swift test-resource mirrors `required` when an actual Swift test
consumer executes them. Rust mirrors transition to `required` with the M2 consumer;
Kotlin mirrors transition with the M3 consumer. Promotion is a reviewed manifest change
that names consumer evidence. A mirror cannot remain resource-only once dependent
implementation code lands.

Canonical contract fixtures are repository-owned, synthetic, deterministic,
provenance-backed, and SHA-256 manifested. Mirrors copy exact bytes; they do not
regenerate or translate JSON/property lists. Legacy persistence fixtures remain a
separate corpus and are not relabeled as internal core contracts.

## Compatibility and consequences

This permits M1 to freeze cross-language inputs without starting Rust/Android authority.
It also prevents path existence from being reported as behavioral evidence. Empty
scaffolding does not satisfy any M2/M3 gate.

## Rejected alternatives

- **Require all consumers in M1:** rejected because it violates milestone sequencing.
- **Never create destinations until implementation:** rejected because mirror paths and
  drift policy would remain undecided.
- **Treat copied bytes as executed evidence:** rejected because manifests prove bytes,
  not behavior.
- **Regenerate per language:** rejected because serializers can alter bytes/order.

## Executable gates

- Manifest validation rejects unknown lifecycle, duplicate destination, missing
  canonical fixture, hash/byte/file-set drift, and a `required` mirror without named
  executable consumer evidence.
- Negative tests prove a resource-only path cannot satisfy behavioral acceptance.
- M2/M3 CI fails unless its language mirror has been promoted to `required` and is
  executed through the named consumer.
- Repository review confirms M1 resource-only destinations contain no implementation,
  bindings, build authority, or platform side effects.
