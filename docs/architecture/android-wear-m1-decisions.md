# Android/Wear accepted architecture decisions

Status: **Accepted**

These decisions make the product and architecture defaults in
[`docs/android-wear-shared-core-implementation-plan.md`](../android-wear-shared-core-implementation-plan.md)
repository policy. Their stable product-decision IDs are intended for contract-manifest
references. Acceptance records a decision; it does not claim that a later milestone's
implementation or physical-device evidence already exists.

| ADR | Product decision IDs | Subject |
|---|---|---|
| [ADR-0001](adr-0001-shared-core-ownership-versioning-rollout.md) | `PD-M1-CORE-OWNERSHIP-001`, `PD-M1-CONTRACT-VERSIONING-001`, `PD-M1-APPLE-ROLLOUT-001` | Shared-core boundary, independent versions, and Apple rollout |
| [ADR-0002](adr-0002-exact-markdown-logical-path-parity.md) | `PD-M1-MARKDOWN-PARITY-001` | Exact Markdown and logical-path parity |
| [ADR-0003](adr-0003-prepared-plan-commit-barrier.md) | `PD-M1-COMMIT-BARRIER-001` | Prepared-plan commit barrier |
| [ADR-0004](adr-0004-existing-note-retry-markers.md) | `PD-M1-RETRY-MARKER-001` | Existing-note retry marker and ambiguous outcomes |
| [ADR-0005](adr-0005-template-observation-freeze.md) | `PD-M1-OBSERVATION-FREEZE-001`, `PD-M1-TEMPLATE-FREEZE-001` | Template and observation freeze |
| [ADR-0006](adr-0006-android-backup-device-transfer.md) | `PD-M1-ANDROID-BACKUP-001` | Android backup and device transfer |
| [ADR-0007](adr-0007-wear-ack-retention-recording-only.md) | `PD-M1-WEAR-ACK-001`, `PD-M1-WEAR-RETENTION-001`, `PD-M1-WEAR-RECORDING-ONLY-001` | Wear acknowledgements, retention, and Recording Only |
| [ADR-0008](adr-0008-play-billing-network-isolation.md) | `PD-M1-PLAY-BILLING-001`, `PD-M1-CROSS-STORE-ENTITLEMENT-001` | Play billing, entitlement, and network isolation |
| [ADR-0009](adr-0009-quota-reinstall-grandfathering.md) | `PD-M1-QUOTA-REINSTALL-001`, `PD-M1-GRANDFATHERING-001` | Free quota reinstall and grandfathering |
| [ADR-0010](adr-0010-location-label-consent-freeze.md) | `PD-M1-LOCATION-LABEL-CONSENT-001` | Location-label consent and freeze |
| [ADR-0011](adr-0011-advanced-local-intelligence.md) | `PD-M1-LOCAL-INTELLIGENCE-001` | Advanced local intelligence completion policy |
| [ADR-0012](adr-0012-bounded-uniffi-session-resource-policy.md) | `PD-M1-UNIFFI-BOUNDS-001` | Bounded UniFFI session and resource policy |
| [ADR-0013](adr-0013-contract-fixture-mirror-sequencing.md) | `PD-M1-MIRROR-SEQUENCING-001` | Resource-only fixture mirror sequencing |
| [ADR-0014](adr-0014-offline-asr-baseline.md) | `PD-M1-OFFLINE-ASR-001` | App-owned offline ASR baseline and optional system adapter |
| [ADR-0015](adr-0015-ime-visible-activity-fallback.md) | `PD-M1-IME-FALLBACK-001` | Visible-activity fallback for unreliable direct IME capture |
| [ADR-0016](adr-0016-vox-owned-toolchain-pinning.md) | `PD-M1-TOOLCHAIN-PINNING-001` | Vox-owned exact toolchain pins and milestone entry gates |
| [ADR-0017](adr-0017-core-api-identities-readiness-packaging.md) | `PD-M2-CORE-API-001`, `PD-M2-DETERMINISTIC-IDENTITY-001`, `PD-M2-READINESS-001`, `PD-M2-FIRST-PACKAGING-001` | Independent core API, deterministic identities, fail-closed M2 profile, and first-core packaging |

The exact M2 entry pins and mandatory update process are defined in
[`android-wear-toolchain-baseline.md`](android-wear-toolchain-baseline.md) and
`toolchains/android-wear-shared-core.json`. M2 implementation may begin from those
validated pins; M3 remains blocked until its additional app-toolchain pins exist.

## Change control

A later decision may supersede an ADR only through a new accepted ADR that names the
superseded product-decision ID, compatibility impact, migration, and executable gate.
Changing prose in a contract or implementation without that record does not change
these decisions.
