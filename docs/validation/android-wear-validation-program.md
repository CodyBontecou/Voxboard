# Android/Wear validation program

Status: **M1 definition; no physical campaign evidence recorded**

These repository-owned definitions specify the device/provider matrix, cases, numerical gates, evidence records, approvals, and aggregate gate. They do not attest that hardware exists in a lab or that a case passed.

## Definition and evidence boundary

Files under `Packages/contracts/validation/` ending in `*-matrix.json`, `case-catalog.json`, and `performance-gates.json` are reviewed definitions. Campaign records use `case-evidence.schema.json`, `approval.schema.json`, and `aggregate.schema.json`.

Never prefill serial numbers, build fingerprints, installed provider versions, build signatures, timestamps, operator identities, or results. Those values must be observed during a named campaign. Synthetic fixtures are allowed, but their committed SHA-256 values must be copied into each evidence record.

## Gate rules

- Required cases must have applicable evidence for every required device/provider role.
- `passed` is the only passing case status and requires `actual=(passed, expectedOutcomeObserved)`, all invariants/checks passed, and all measurements within gates. `failed` maps to `(failed, expectedOutcomeNotObserved)` and requires an observed failed invariant, gate, or diagnostic check. `blocked`, `notRun`, and `notApplicable` map exactly to `executionBlocked`, `executionNotRun`, and `catalogNotApplicable`, respectively, with no invariant or measurement claims; none passes a required applicable case.
- `notApplicable` requires a catalog applicability rule proving the combination is outside scope; operators cannot declare it ad hoc.
- Non-waivable invariants cannot be waived or overridden by approval.
- Waivers apply only to explicitly waivable non-safety requirements, have an owner, rationale, expiry, and approving identity, and never turn failed evidence into passed evidence.
- Aggregate status is computed: `passed` only when definitions validate, all required applicable cases pass, performance samples meet gates, required approvals are approved, not future-dated, and unexpired, every non-waivable invariant is covered and evaluated, and evidence contains no placeholder campaign facts. The domain state `unknownOutcome` is valid; standalone `unknown` remains a rejected placeholder.

## Hardware and provider identities

The matrix names procurement targets and roles, not lab inventory. Exact serials and OS build fingerprints are campaign evidence.

Provider identity is exact by Android document-provider authority and package name. A UI label such as “Drive” is insufficient. Provider package version and signing-certificate SHA-256 are captured from the installed campaign device, not guessed in M1.

## Storage pressure

Wear recording/transfer cases require free space of at least `max(1 GiB, 20% of total capacity)` before starting a normal run. Storage-pressure cases intentionally cross the separately stated frontier and must preserve the last durable copy.

## Evidence layout

Write completed case evidence beneath:

`artifacts/validation/android-wear/<campaign-id>/<case-id>/<evidence-id>.json`

Write the computed aggregate beside it as `aggregate.json`. Human notes, logs, and screenshots are outside machine evidence and cannot satisfy a gate. For privacy-governed cases, every referenced fixture and artifact must be a canonical `.diagnostic.json` summary accepted by the strict allowlist schema; raw logs, screenshots, free text, captured content, and storage handles are structurally rejected.

Use `docs/validation/android-wear-case-evidence-template.md` when conducting a campaign. Validate definitions with:

```sh
python3 Packages/contracts/scripts/validate_validation_definitions.py
python3 -m unittest discover -s Packages/contracts/tests -p 'test_validation_definitions.py'
```

## Large-screen and tuple expansion

`REC-004` executes rotation, resize, split-screen, background/foreground, and state restoration on the required tablet role. `SAF-005` executes the provider picker and durable delivery across every required provider on that role. The validator expands each required case into the Cartesian product of its required device roles and catalog-approved provider applicability (`none`, `allRequired`, or `nonLocalRequired`). A required role without a case is a definition error. Operators cannot retarget evidence or invent N/A combinations.

## Privacy-safe diagnostic summaries

`INV-PRIVACY-DIAGNOSTICS` is a bounded structural guarantee, not semantic text detection. For every governed case, `actual` is an exact result-code object and every `fixtureHashes`/`artifacts` file must end in `.diagnostic.json`, be canonical UTF-8 JSON, and validate against `diagnostic-summary.schema.json`. That schema permits only version/format/kind/result enums, allowlisted check code/result/count triples, and role/SHA-256 references. It has no free-text, filename, path, URI, coordinate, content, payload, or storage-handle field. Arbitrary `.txt`, logs, any URI scheme, unlabeled text, unknown fields, binary bytes, and noncanonical JSON are rejected. This makes such content unrepresentable in accepted machine diagnostic summaries; it does not claim to inspect external human artifacts or infer the semantics of a malicious hash.

## Packaging-growth baseline

The first M2 core has no predecessor binary and therefore no percentage baseline. Its exact nonzero leaf set—Android `arm64-v8a`, `armeabi-v7a`, `x86_64`, and `x86`, plus Apple `xcframework-ios-device-arm64` and the combined `xcframework-ios-simulator-arm64-x86_64` library slice—must pass all absolute gates with bound source revision, toolchain/configuration, actual bytes, and SHA-256. A zero-byte or fabricated planning-parent artifact is forbidden. The approved first-core set becomes the future identically scoped baseline. Later evidence carries exactly one ordered baseline/candidate entry per leaf, binds referenced file bytes/hashes, derives the XCFramework aggregate, and derives scoped growth as `((candidateBytes - baselineBytes) / baselineBytes) * 100`; every later artifact must pass both its absolute gate and the unchanged 10% growth gate.

## Campaign validation

The validator accepts `--campaign-dir <directory>`. The non-symlink campaign directory contains only non-symlink `evidence/*.json`, non-symlink `approvals/*.json`, `aggregate.json`, and an `artifacts/` tree referenced relative to the campaign root; unexpected entries and file types in machine directories are rejected. Audit timestamps are canonical UTC RFC 3339 values ending `Z`. Fixture refs require diagnostic `kind=fixture`; artifact refs require `kind=artifact`, with role-safe referenced hashes. It verifies referenced bytes, enforces each gate's declared sampling method and minimum sample count, computes nearest-rank p95 (`ceil(0.95*n)` in sorted samples), minimum/maximum gates, the normal Wear free-storage floor, required invariant coverage, approval intervals/hashes, packaging growth from attested byte counts, and aggregate tuple counts/status. Packaging candidate revision and artifact hashes must bind to the evidence commit and referenced artifacts. Privacy-governed machine evidence is structurally restricted to canonical diagnostic summaries and structured result codes; arbitrary free text is rejected rather than scanned heuristically. The checked-in aggregate is an assertion only: disagreement with the computed aggregate is rejected. Safety invariants are never waivable.

Files under `Packages/contracts/fixtures/validation/` are explicitly synthetic schema and mutation fixtures. They are not physical-device results, inventory, signatures, or approvals.
