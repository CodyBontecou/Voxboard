# Vox.md portable contracts

This directory is the source of truth for five independently versioned platform-neutral product families and the M2 validation-evidence contracts. Rust owns only bounded deterministic behavior; native Swift/Kotlin retain UI, lifecycle, persistence, platform capabilities, side effects, receipts, and transport.

Every family has normative prose, strict JSON Schema, positive and isolated negative synthetic fixtures, and typed validator errors. Schemas use only validator-audited keywords; unsupported keywords are rejected. Final artifact JSON never duplicates streamed prepared bytes. The shipped marker remains `<!-- vox-capture:<lowercase-uuid> -->`.

`manifest.json` governs exact bytes/categories for this README, scripts/tests, accepted ADRs, validation docs/schemas/definitions, contract sources/fixtures, M0-derived capability inventory/source hash, scope overlay, and all resource mirrors. Fixture provenance names the structured deterministic producer script/revision.

ADR-0013 lifecycle applies. Mirrors must remain byte-identical and cannot claim behavior merely from presence. The Rust mirror is `required` because `vox-core` executes it in `m2_core::rust_contract_mirror_is_consumed`; Swift and Kotlin mirrors remain `resourceOnlyPlanned`.

`scope-variances.json` overlays no current rows and is validated against an exact strict schema. Only `unavailable` and `deferred` are valid overlay classifications; each requires an accepted decision ID, reason, user-visible behavior, `objectiveAmended: false`, and `parityStatus: blocking`. The base 270-row inventory always preserves M0 ownership.

```sh
python3 Packages/contracts/scripts/convert_capabilities.py --check
python3 Packages/contracts/scripts/generate_fixtures.py
python3 Packages/contracts/scripts/validate.py --regenerate-manifest
python3 Packages/contracts/scripts/validate.py
python3 Packages/contracts/scripts/validate_validation_definitions.py
python3 -m unittest discover -s Packages/contracts/tests -v
# Real hosted campaign validation additionally supplies --campaign-dir,
# --qualification hostedRun, --repository-root, and --external-artifact-root.
```
