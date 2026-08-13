# Android/Wear validation program

Status: **M1 definition; no physical campaign evidence recorded**

These repository-owned definitions specify the device/provider matrix, cases, numerical gates, evidence records, approvals, and aggregate gate. They do not attest that hardware exists in a lab or that a case passed.

## Definition and evidence boundary

Files under `Packages/contracts/validation/` ending in `*-matrix.json`, `case-catalog.json`, and `performance-gates.json` are reviewed definitions. Campaign records use `case-evidence.schema.json`, `approval.schema.json`, and `aggregate.schema.json`.

Never prefill serial numbers, build fingerprints, installed provider versions, build signatures, timestamps, operator identities, or results. Those values must be observed during a named campaign. Synthetic fixtures are allowed, but their committed SHA-256 values must be copied into each evidence record.

## Gate rules

- Required cases must have applicable evidence for every required device/provider role.
- `passed` is the only passing case status. `blocked`, `failed`, `notRun`, and `notApplicable` do not pass a required applicable case.
- `notApplicable` requires a catalog applicability rule proving the combination is outside scope; operators cannot declare it ad hoc.
- Non-waivable invariants cannot be waived or overridden by approval.
- Waivers apply only to explicitly waivable non-safety requirements, have an owner, rationale, expiry, and approving identity, and never turn failed evidence into passed evidence.
- Aggregate status is computed: `passed` only when definitions validate, all required applicable cases pass, performance samples meet gates, required approvals are approved and unexpired, no non-waivable invariant fails, and evidence contains no placeholder campaign facts.

## Hardware and provider identities

The matrix names procurement targets and roles, not lab inventory. Exact serials and OS build fingerprints are campaign evidence.

Provider identity is exact by Android document-provider authority and package name. A UI label such as “Drive” is insufficient. Provider package version and signing-certificate SHA-256 are captured from the installed campaign device, not guessed in M1.

## Storage pressure

Wear recording/transfer cases require free space of at least `max(1 GiB, 20% of total capacity)` before starting a normal run. Storage-pressure cases intentionally cross the separately stated frontier and must preserve the last durable copy.

## Evidence layout

Write completed case evidence beneath:

`artifacts/validation/android-wear/<campaign-id>/<case-id>/<evidence-id>.json`

Write the computed aggregate beside it as `aggregate.json`. Human notes, logs, and screenshots may accompany evidence, but machine evidence must reference their SHA-256 and must not contain captured content, filenames, URIs, coordinates, transcripts, or audio.

Use `docs/validation/android-wear-case-evidence-template.md` when conducting a campaign. Validate definitions with:

```sh
python3 Packages/contracts/scripts/validate_validation_definitions.py
python3 -m unittest discover -s Packages/contracts/tests -p 'test_validation_definitions.py'
```

## Large-screen and tuple expansion

`REC-004` executes rotation, resize, split-screen, background/foreground, and state restoration on the required tablet role. `SAF-005` executes the provider picker and durable delivery across every required provider on that role. The validator expands each required case into the Cartesian product of its required device roles and catalog-approved provider applicability (`none`, `allRequired`, or `nonLocalRequired`). A required role without a case is a definition error. Operators cannot retarget evidence or invent N/A combinations.

## Packaging-growth baseline

The baseline is the clean source build at planning parent `b50167aebb959e394908af3a5949f43fa88d6265`. Baseline and candidate must use the same pinned release toolchain, target scope, build configuration, feature set, stripping/symbol handling, archive container, and uncompressed-size procedure. Evidence records the baseline and candidate revisions, toolchain ID, target scope, configuration, feature set, artifact ID, byte counts, and both artifact SHA-256 values. Growth is `((candidateBytes - baselineBytes) / baselineBytes) * 100`; only identically scoped artifacts are compared. A measurement or approval without those identities and hashes cannot satisfy `packaging-growth`.

## Campaign validation

The validator accepts `--campaign-dir <directory>`. The directory contains `evidence/*.json`, `approvals/*.json`, `aggregate.json`, and files referenced by evidence relative to the campaign root. It verifies referenced bytes, computes nearest-rank p95 (`ceil(0.95*n)` in sorted samples), minimum/maximum gates, the normal Wear free-storage floor, required invariant coverage, approval hashes/expiry, and aggregate tuple counts/status. The checked-in aggregate is an assertion only: disagreement with the computed aggregate is rejected. Safety invariants are never waivable.

Files under `packages/contracts/fixtures/validation/` are explicitly synthetic schema and mutation fixtures. They are not physical-device results, inventory, signatures, or approvals.
