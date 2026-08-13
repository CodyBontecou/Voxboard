# Capture preparation input v1

This internal core contract requests deterministic observation planning; it is not a legacy disk schema. JSON is UTF-8. `contractVersion` is exactly `1`; other versions fail closed. UUIDs are lowercase, epoch time is milliseconds, calendar is Gregorian, timezone is explicit IANA text, collections preserve order, and unknown fields are rejected.

The input contains normalized text/link/asset facts, frozen portable preset policy, logical path segments, collision policy, and operation. It never contains template/note bytes, bookmarks, URIs, provider IDs, document IDs, or absolute paths. Strings, arrays, binary descriptors, and logical segments obey `schema.json` bounds. Segments `.`/`..`, separators, and NUL are unsafe. Text/link preparation does not perform side effects.

Template bytes freeze at first preparation. Existing-note mutation selects marker policy `voxCaptureCommentV1`; the shipped marker is exactly `<!-- vox-capture:{lowercase-uuid} -->`. User Markdown line endings are normalized from CRLF or CR to LF before mutation; output joining uses LF and blank-line block separation, matching the Swift legacy oracle.
