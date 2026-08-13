# ADR-0001: Shared-core ownership, versioning, and rollout

- Status: **Accepted**
- Product decision IDs: `PD-M1-CORE-OWNERSHIP-001`, `PD-M1-CONTRACT-VERSIONING-001`, `PD-M1-APPLE-ROLLOUT-001`
- Required by: M1, M2, and every later shared-core promotion

## Context

Vox.md needs deterministic outcomes on Apple and Android without moving platform
capabilities or side effects behind FFI. Current Apple persisted formats and behavior
remain compatibility inputs while authority moves incrementally.

## Decision

Rust owns only bounded, deterministic, destination-neutral policy: contract decoding
and validation, logical path planning, template/frontmatter/Markdown materialization,
hashes, markers, typed errors, and later pure reducers after native fixtures stabilize.
Native Swift and Kotlin continue to own UI, permissions, lifecycle, capture, local
inference adapters, persistence, queues, scheduling, filesystem/provider capabilities,
commit/readback, billing, credentials, and wearable transport.

There is no callback from Rust into platform storage and no platform handle, bookmark,
URI, document ID, absolute path, credential, or live service object in a core contract.
The queue repository and OS execution opportunities remain native even if a pure state
reducer later moves to Rust.

Core API, preparation input, required observations, materialization input, artifact
plan, renderer profile, persisted native state, and wearable protocol versions are
independent. Compatibility is negotiated by explicit version/hash pins; changing one
does not implicitly advance another. Legacy Apple disk codecs, internal core contracts,
cross-device protocol envelopes, and user-owned artifacts remain distinct families.

Apple rolls out per operation/profile using persisted `legacy`, `shadow`, or `rust`
pins:

- `legacy`: Swift plans and native Swift commits.
- `shadow`: Swift remains authoritative; Rust compares the same frozen input without
  writes, quota reservations, queue mutations, success changes, or content diagnostics.
- `rust`: Rust materializes; native Swift persists the plan and performs the commit.

Missing or malformed mutable Apple configuration resolves to `legacy` for new work.
A pinned incompatible Rust job is preserved and fails actionably; it is never silently
rerendered. Rollback changes defaults only for new work. The compatible executor for
already-pinned work is retained or the work fails closed before commit. Swift legacy
authority remains available for at least two stable releases after each Rust default.
Android has no hidden legacy/ad-hoc renderer: readiness failure preserves its durable
package and fails closed.

## Compatibility and consequences

Current Apple user-file and persistence bytes do not change merely because a core
contract is introduced. Adapters translate at the boundary. Rust cannot become a
shortcut around native durability or permission repair. Promotion is deliberately
slower but independently reversible and privacy-safe.

## Rejected alternatives

- **Whole-product Rust rewrite:** rejected because UI, storage capabilities, lifecycle,
  billing, and transports are platform concerns.
- **One universal canonical model/version:** rejected because disk compatibility,
  internal FFI, wearable protocol, and user artifacts evolve independently.
- **Global Apple switch or fallback after partial Rust execution:** rejected because it
  makes rollback and immutable-job recovery unsafe.
- **Kotlin renderer fallback on Android:** rejected because it creates an unreviewed
  second authority.

## Executable gates

- Contract/readiness tests reject unsupported independent version/hash combinations.
- Boundary tests reject platform handles and unbounded payloads.
- Apple shadow tests prove exact comparison and absence of side effects.
- Promotion tests persist operation/profile pins; downgrade tests preserve or refuse
  incompatible jobs before the commit barrier.
- Fixture tests continue executing legacy codecs independently of core DTO tests.

These are requirements for dependent milestones, not claims of current execution.
