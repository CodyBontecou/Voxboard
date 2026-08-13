# ADR-0010: Location-label consent and freeze

- Status: **Accepted**
- Product decision ID: `PD-M1-LOCATION-LABEL-CONSENT-001`
- Required by: M1 contract and M5

## Context

Coordinates can be formatted locally, but Android's system geocoder may use a remote
backend. A retry must not disclose coordinates under a newly selected lookup policy or
resolve labels at a later place/time.

## Decision

Coordinate-only output and map/geo links are always the local baseline. Current
Location editor insertion derives its shipped map-link outcome directly from a one-shot
coordinate fix and does not call a geocoder.

City/place labels are permitted only when the invocation's frozen policy selects one
of:

- `offline`: an approved vetted local database; or
- `systemMayUseNetwork`: explicit per-preset/invocation consent after disclosure that
  the system geocoder may contact a remote service and transmit the chosen coordinates.

`none` means no label lookup. Preset consent is not inherited by an independent editor
action. No background/continuous location is introduced.

At invocation (or recording-stop, where the product flow defines it), native code
freezes the privacy-adjusted coordinate or unavailable result; whether labels were
requested; lookup class; consent decision/version; and resulting label or unavailable
outcome. Materialization and retry consume that frozen observation. A retry cannot
reacquire location, switch lookup class, newly ask a geocoder, or replace an unavailable
result with a later location. Completed content-free tombstones remove coordinates and
labels; pending work keeps only recovery-required frozen facts.

Captured content other than explicitly consented coordinates never enters a geocoder
request. Diagnostics omit coordinates, labels, paths, and content.

## Compatibility and consequences

Existing Apple/local Current Location output remains available without network. Android
place labels may differ by approved provider, but the consent class and frozen result
are explicit contract facts. Declining lookup degrades to coordinate/local-map output,
not capture failure.

## Rejected alternatives

- **Call the system geocoder and describe it as local:** rejected because network use is
  not guaranteed absent.
- **Consent once globally or inherit preset consent for editor actions:** rejected
  because disclosure must match the invocation.
- **Resolve/re-resolve on retry:** rejected because it can disclose a new location and
  change immutable output.
- **Require labels for location capture:** rejected because local coordinates suffice.

## Executable gates

- Contract tests reject missing/unknown consent class and inconsistent label outcomes.
- Network-call detection with networking disabled proves coordinate-only and no-consent
  paths make no outbound request and retain local map-link capability.
- Retry/relaunch tests prove no location reacquisition or lookup-class change.
- Consented system-geocoder tests use synthetic coordinates and verify the frozen
  disclosure/observation boundary; physical/provider quality evidence belongs to M5.
