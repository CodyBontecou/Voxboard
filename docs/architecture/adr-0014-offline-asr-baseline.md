# ADR-0014: Android offline ASR baseline

- Status: **Accepted**
- Product decision ID: `PD-M1-OFFLINE-ASR-001`
- Required by: M4

## Context

Vox.md promises local capture and must not silently send recordings or transcripts to a
network recognizer. Android system recognizers vary by device, language, installed
packs, OEM behavior, and whether their advertised on-device mode is actually available.
They cannot be the dependable long-form transcription baseline.

## Decision

The dependable Android long-form transcription path is an app-owned local ASR backend.
Before M4 implementation begins, its concrete engine/model baseline, supported
languages, license/provenance, package/download integrity, device-tier budgets, and
update policy must be reviewed and committed. Models may be bundled or explicitly
downloaded with consent, but inference runs locally and no capture content is sent to a
network service.

A system on-device recognizer is an optional capability adapter only. It may be offered
when runtime capability checks establish that the requested language and on-device mode
are available without network inference. Failure, ambiguity, model absence, or loss of
that capability falls back to the app-owned local backend or an actionable audio-only
state; it never silently selects a network-capable recognizer.

The app preserves original audio through ASR failure and exposes model absence,
unsupported language, download state, storage requirements, and engine selection. No
M1 document claims that an engine, model, language, performance result, or physical
device outcome has already been selected or verified.

## Compatibility and consequences

Android may use a different local engine from Apple while preserving the product outcome:
private on-device transcription, recoverable source audio, explicit capability state,
and no silent network inference. Advanced diarization/enrichment remains governed by
ADR-0011 and is not implied by this baseline.

## Rejected alternatives

- **System recognizer as the required baseline:** rejected because availability and
  network isolation are not dependable across the support matrix.
- **Silent cloud fallback:** rejected because it violates local-first privacy.
- **Discard audio after transcription attempt:** rejected because it strands recovery.
- **Name an unverified M1 engine/model:** rejected because the repository has no honest
  selection evidence yet.

## Executable gate

M4 cannot start until the concrete app-owned engine/model baseline and budgets are
committed. M4 tests then prove local-only routing, model integrity, actionable
unsupported/missing states, source-audio retention, and the defined device-tier
performance/thermal campaign. System-adapter tests must prove fail-closed capability
selection and no implicit network recognizer.

This ADR approves policy only; it claims no implementation or test evidence.
