# Android capture package v1

Portable envelopes for the empty asset manifest and append-only semantic delivery journal. Journal v1 durably binds the exact `request.json` and `assets.json` byte counts and SHA-256 values together with package, request, asset, and journal versions. ADR-0020 is normative for transition legality, exact M3 text/link request admission, byte bounds, correlation, durable promotion, duplicate handling, and Room projection ordering. `request.json` is not wrapped or normalized: it is exact canonical `capture-preparation-input/v1` bytes.
