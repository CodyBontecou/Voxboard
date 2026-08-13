# Vox.md portable contracts

This is the M1 source of truth for five independently versioned platform-neutral families. Rust later owns deterministic behavior; native Swift/Kotlin retain UI, lifecycle, persistence, platform capabilities, side effects, receipts, and transport. M1 introduces no Rust or Android authority.

Every family has normative prose, strict JSON Schema, positive and isolated negative synthetic fixtures, and typed validator errors. Schemas use only validator-audited keywords; unsupported keywords are rejected. Final artifact JSON never duplicates streamed prepared bytes. The shipped marker remains `<!-- vox-capture:<lowercase-uuid> -->`.

`manifest.json` governs exact bytes/categories for this README, scripts/tests, accepted ADRs, validation docs/schemas/definitions, contract sources/fixtures, M0-derived capability inventory/source hash, scope overlay, and all resource mirrors. Fixture provenance names the structured deterministic producer script/revision.

ADR-0013 lifecycle applies: all current mirrors are `resourceOnlyPlanned`; if present they must be exact byte/file-set mirrors but claim no execution. Promotion to `required` needs a named executable consumer and evidence. Rust and Kotlin remain planned. Swift also remains planned because no executable production-language consumer currently reads this corpus.

`scope-variances.json` overlays no current rows and is validated against an exact strict schema. Only `unavailable` and `deferred` are valid overlay classifications; each requires an accepted decision ID, reason, user-visible behavior, `objectiveAmended: false`, and `parityStatus: blocking`. The base 270-row inventory always preserves M0 ownership.

```sh
python3 Packages/contracts/scripts/convert_capabilities.py --check
python3 Packages/contracts/scripts/generate_fixtures.py
python3 Packages/contracts/scripts/validate.py --regenerate-manifest
python3 Packages/contracts/scripts/validate.py
python3 Packages/contracts/scripts/validate_validation_definitions.py
python3 -m unittest discover -s Packages/contracts/tests -v
```
