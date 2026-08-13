# Vox.md portable contracts

This directory is the source of truth for platform-neutral core inputs/plans and durable wearable envelopes. Current Apple JSON/property-list stores remain **legacy persisted codecs**; Markdown/attachments remain independently compatible user artifacts. Neither is silently replaced by these internal contracts.

## Ownership and versions

Rust later owns deterministic validation/rendering only. Swift/Kotlin own UI, lifecycle, permissions, capture, persistence, queues, filesystem/provider capabilities, receipts, transports, billing, credentials, and scheduling. Each family versions independently; a revision in one does not advance another. M1 adds no Rust/Kotlin implementation or authority.

Families:

- `capture-preparation-input/v1`
- `required-observations/v1`
- `capture-materialization-input/v1`
- `artifact-plan/v1`
- `wearable-protocol/v1`

Each has normative `contract.md`, strict `schema.json`, and synthetic fixtures. `manifest.json` governs every source document/schema/fixture and three byte-identical resource-only mirrors:

- `Packages/VoxboardShared/Tests/Fixtures/Contracts/v1`
- `packages/vox-core-rust/tests/resources/contracts/v1`
- `apps/android/core-bridge/src/test/resources/contracts/v1`

The latter paths are conformance resources only; they do not introduce build files or execution authority.

## Deterministic workflow

```sh
python3 packages/contracts/scripts/convert_capabilities.py --check
python3 packages/contracts/scripts/validate.py --regenerate-manifest
python3 packages/contracts/scripts/validate.py
python3 -m unittest discover -s packages/contracts/tests -v
```

Regeneration first converts the M0 ledger, copies governed resources byte-for-byte to every mirror, then writes a stable sorted manifest with actual SHA-256 and byte counts. Normal validation never regenerates. Fixture changes require synthetic provenance review and an intentional manifest diff.

The inventory pins M0 closure `29ec869c8bda4d511af787af394658d0274b339b` and Health.md precedent `c70de9201ab7cfbadf2442183dfba23c0d248478`.
