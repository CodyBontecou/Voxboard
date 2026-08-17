# Android capture package v1

Portable envelopes for the empty asset manifest and append-only semantic delivery journal. The journal binds the exact `request.json` and `assets.json` byte counts and SHA-256 values together with package, request, asset, and journal versions. ADR-0020 is normative for transition legality, exact M3 text/link request admission, byte bounds, correlation, durable promotion, duplicate handling, and Room projection ordering; ADR-0023 is normative for the journal v2 plan-hash binding. `request.json` is not wrapped or normalized: it is exact canonical `capture-preparation-input/v1` bytes.

## Journal v2 plan-hash binding

Journal v2 adds one optional-per-event field, `planHash`, which durably records the
authoritative finalized artifact-plan hash (ADR-0023 §1):

- `materialized` events MUST carry a non-null lowercase 64-hex `planHash` — the
  verified plan hash whose prepared artifacts were hash-verified before the event.
- `commitStarted` events MUST carry a non-null `planHash` equal to the `planHash` of
  the most recent preceding `materialized` event, so a restart in `committing` selects
  the marker-named plan rather than a re-derived guess.
- Every other event code MUST carry `planHash: null`.

Journal v2 is the only accepted journal version; journal v1 bytes are rejected
fail-closed (schema `journalVersion` const `2`). `planHash` values are opaque to the
package schema beyond the 64-hex pattern; recomputation and prepared-artifact
verification are governed by artifact-plan/v1 and ADR-0023, not re-derived here.
