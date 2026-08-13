# ADR-0015: Android IME visible-activity fallback

- Status: **Accepted**
- Product decision ID: `PD-M1-IME-FALLBACK-001`
- Required by: M6

## Context

Direct microphone capture from an Android `InputMethodService` is sensitive to OS,
foreground-service, permission, lock-state, OEM, and enterprise-policy behavior. Product
parity requires a reliable privacy-preserving capture outcome, not a claim that every
device permits identical in-keyboard recording.

## Decision

Direct IME microphone capture may ship only where the M6 device/API/OEM/policy campaign
proves it reliable. Otherwise the approved product fallback is a visible Vox.md capture
activity, explicitly launched for the active IME session. The activity owns recording
and local transcription but never owns or retains `InputConnection`. It returns a
bounded result tied to an opaque IME session ID, editor identity token, and durable job.
Only the active IME may insert after revalidating the original editor and sensitive-field
policy.

Focus loss, editor/package change, token mismatch, duplicate/stale result, IME
recreation, process death, cancellation, permission denial, or fallback-activity failure
must refuse automatic insertion into a different editor and preserve available audio or
transcript for explicit Copy/retry. Password and sensitive fields disable dictation.
Surrounding editor context is neither persisted nor sent to transcription.

The fallback must be visibly distinct, disclose recording state, and return to the IME
when safe. It is an accepted product-adjusted parity outcome, not a degraded silent
failure. M1 does not claim that direct IME recording or the fallback has been implemented
or physically validated.

## Compatibility and consequences

Editor insertion remains at most once and owned by the IME. Vault capture and destination
state remain isolated from this transcription/insertion profile. Devices that support
reliable direct capture may provide the shorter flow; unsupported environments retain
the same durable, local, user-controlled outcome through the visible activity.

## Rejected alternatives

- **Require direct IME recording on all devices:** rejected because platform policy may
  make that unreliable or impossible.
- **Let the activity call `commitText`:** rejected because only the active IME owns the
  current editor connection.
- **Insert into whichever editor is active on return:** rejected as a privacy and
  correctness failure.
- **Drop results after focus/process changes:** rejected because durable local recovery
  is required.

## Executable gate

M6 must run the defined API/OEM/policy matrix before enabling direct IME recording and
must exercise the visible fallback wherever direct capture fails the gate. Tests cover
session/editor revalidation, sensitive fields, permission denial, focus/package change,
IME/activity recreation, process death, stale/duplicate delivery, at-most-once insertion,
and explicit Copy/retry recovery. No implementation or device result is claimed here.
