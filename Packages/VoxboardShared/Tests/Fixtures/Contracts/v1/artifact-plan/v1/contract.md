# Artifact plan v1

This destination-neutral plan becomes committable only after all prepared output streams have been drained into immutable native files, their descriptor lengths/SHA-256 values verified, and finalization succeeds. Drained immutable bytes plus their descriptors are normative plan content. The final JSON references those verified bytes and **does not duplicate them**. A cancelled or incomplete session produces no plan.

`contractVersion` is exactly `1`; unknown versions/fields fail closed. Artifacts have deterministic IDs, ordered unique commit sequence, logical relative segments, media type, length/hash, expected-existing policy, journal frontier, and receipt kind. Attachments commit and verify before the note. Existing-note mutation requires the expected original hash. Every commit is followed by durable correlated receipt/frontier persistence.

Prepared chunks are at most 1 MiB. UUIDs and SHA-256 are lowercase. Diagnostics contain no user content or native storage identity. Retry markers preserve shipped syntax exactly: `<!-- vox-capture:{lowercase-uuid} -->`. Legacy mutation first normalizes CRLF/CR to LF, trims only boundary newlines, and joins nonempty blocks with two LF characters. Internal plans do not alter legacy disk schemas.
