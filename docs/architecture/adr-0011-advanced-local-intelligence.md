# ADR-0011: Advanced local intelligence

- Status: **Accepted**
- Product decision ID: `PD-M1-LOCAL-INTELLIGENCE-001`
- Required by: M9 and program completion

## Context

Vox.md ships diarization and enrichment outcomes. Replacing them with network inference
would violate local-first guarantees; calling them deferred while claiming parity would
weaken the program objective.

## Decision

Speaker diarization and every shipped cleanup, title, tag, category, checklist,
meeting-note, and custom-transform outcome require an app-owned local implementation
on declared supported device/model tiers before feature-parity completion. Inference
accepts only local staged input and cannot use a network-capable fallback.

Model acquisition may use the network only after explicit consent with size, license,
source, verification, storage, deletion, and capability state disclosed. Acquired
models are integrity-verified before use. Inference, prompts, transcript/audio, derived
content, filenames, coordinates, and diagnostics remain local. Unavailable hardware,
missing models, thermal/resource limits, cancellation, and unsupported languages fail
closed to an explicit local capability state or preserve the untransformed source; they
do not silently select remote inference.

A capability may be classified unavailable/deferred for a scoped release, but that is
an explicit unmet parity gate and objective reduction, not program completion. The
product owner must amend scope through a superseding accepted decision to remove an
outcome. Each supported lower model/tier and user-visible limitation is named and
measured before release.

## Compatibility and consequences

Apple's current outcome remains the semantic oracle while implementations may differ.
Deterministic downstream rendering receives a frozen local result; the shared core does
not own model runtime, downloads, device acceleration, or lifecycle. Failed enrichment
never deletes audio/transcript or blocks access to raw local content.

## Rejected alternatives

- **Cloud or silent system-network inference fallback:** rejected by the local-first
  product guarantee.
- **Mark every advanced outcome deferred and still claim parity:** rejected because it
  changes the stated objective without approval.
- **Bundle one model for every device regardless of evidence:** rejected because device
  tiers, licensing, memory, battery, and thermal behavior differ.
- **Send content in quality telemetry:** rejected for privacy.

## Executable gates

- Dependency/network tests demonstrate no inference-time outbound path and no capture
  content in model acquisition or diagnostics.
- Per-outcome quality fixtures and declared device-tier performance/memory/thermal/
  cancellation gates pass using local models.
- Missing/corrupt/incompatible model and unsupported-device tests preserve source data
  and report explicit local capability state.
- The capability ledger cannot treat unavailable/deferred parity rows as complete.

This ADR records policy only and claims no model/device benchmark result.
