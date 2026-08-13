# Core API v1

This service contract is independently versioned from capture inputs, renderer/profile
revisions, artifact plans, persisted schemas, and wearable protocols. All records are
canonical UTF-8 JSON: lexicographically sorted object keys, two-space indentation, no
non-finite numbers or trailing spaces, and exactly one final LF. Every field is required;
explicit `null` represents supported absence; arrays are ordered and bounded; unknown
fields, enum values, profiles, operations, and versions fail closed.

M2 supports exactly operation `newNoteTextLink`, profile `apple-parity-v1`, core API 1,
contract versions 1, renderer `swift-legacy-m0`, and artifact plan 1. `buildInfo` is
informational. `expectedVersions` is an exact request. A `readinessResult` is `ready`
only with an empty mismatch list and `sessionPermitted=true`; any mismatch returns
`incompatible`, safe bounded codes, and `sessionPermitted=false`.

`expectedArtifactDescriptors` is emitted only after sealed input and declares the exact
ordered output set before draining. `preparedChunkMetadata` binds one chunk to an
artifact/stream, zero-based contiguous sequence, bounded byte count (maximum 1 MiB),
SHA-256, and EOF. `drainedArtifactHashes` contains exactly one ordered verified
length/hash per descriptor and is required before finalization can return an artifact
plan. These records carry no platform handles, bytes, side-effect receipts, or authority.

SHA-256 is lowercase hexadecimal over the named bytes. UUID identities use RFC 4122
UUIDv5/SHA-1 with namespace `8c7f8d7e-4f61-5d92-a94a-3b9e6cc8e415`, domain label,
NUL, and the exact canonical preimage defined by artifact-plan/v1. UUID strings are
lowercase hyphenated.
