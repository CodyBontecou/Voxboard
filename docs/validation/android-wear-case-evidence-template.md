# Android/Wear case evidence template

Do not commit this file as proof. Create one JSON record conforming to `packages/contracts/schemas/case-evidence.schema.json` for each executed case/device/provider combination.

## Campaign facts (required when applicable)

- Campaign/evidence/case IDs
- Vox.md commit and contract-manifest SHA-256
- Signed build ID and build signature SHA-256
- Device role, manufacturer, model, serial hash, OS/API, exact build fingerprint
- Provider ID, authority, package name, installed version, signing-certificate SHA-256
- UTC start/end, operator identity
- Synthetic fixture IDs and SHA-256
- Expected and actual outcome
- Measurements with units
- Sanitized artifact references and SHA-256
- Status: `passed`, `failed`, `blocked`, `notRun`, or catalog-authorized `notApplicable`

Never place user content or placeholder values such as `TBD`, `unknown`, dummy serials, or fabricated versions in completed evidence. A missing physical fact means the run is incomplete (`blocked` or `notRun`), not passed.

## Review checklist

- [ ] Case applicability matches the catalog.
- [ ] Required hardware/provider identity was observed, not copied from a planning placeholder.
- [ ] Every non-waivable invariant was evaluated.
- [ ] Exact numerical gate comparison is recorded.
- [ ] Logs/screenshots contain no captured content or platform storage handles.
- [ ] Evidence and attachments hash correctly.
- [ ] Required independent approval exists and is unexpired.
