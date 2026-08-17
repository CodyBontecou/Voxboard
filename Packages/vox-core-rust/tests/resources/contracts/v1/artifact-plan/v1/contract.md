# Artifact plan v1

Normative encoding is canonical UTF-8 JSON. Every field is required; nullable hashes express absence explicitly, arrays are ordered/bounded, and unknown fields/kinds/enums fail closed without defaults. Final JSON contains descriptors only and never duplicates drained artifact bytes.

The plan freezes request and all core/renderer/profile pins, plan hash, operation, shipped marker policy/syntax/placement, typed warnings/diagnostics with privacy-safe paths, and an exact ordered discriminated artifact list. Attachments describe source and result media/length/SHA, logical destination, expected-existing hash policy, equivalence rule, deterministic IDs, receipt, and frontier. The single last note additionally specifies write mode, expected original hash, and immutable prepared-stream ID. Native persists and verifies all drained bytes and finalized plan before side effects, then persists each correlated receipt/frontier.

## Deterministic identities and plan hash

All UUIDs below are RFC 4122 UUIDv5/SHA-1 using namespace
`8c7f8d7e-4f61-5d92-a94a-3b9e6cc8e415`. The UUID name bytes are the literal ASCII
domain label, one NUL byte, then the canonical UTF-8 JSON bytes of the stated preimage.
Canonical JSON sorts object keys lexicographically, uses two-space indentation, has no
trailing spaces or non-finite numbers, and ends in exactly one LF. UUID text is lowercase
hyphenated. Arrays retain contract order and nullable values remain explicit.

- `operationID`: domain `vox.operation.v1`; preimage
  `{"commitSequence":n,"operation":operation,"requestID":requestID}`.
- `artifactID`: domain `vox.artifact.v1`; preimage
  `{"kind":kind,"logicalPath":logicalPath,"operationID":operationID}`.
- `preparedStreamID`: domain `vox.stream.v1`; preimage
  `{"artifactID":artifactID,"resultLength":resultLength,"resultSHA256":resultSHA256}`.
- `receiptID`: domain `vox.receipt.v1`; preimage
  `{"artifactID":artifactID,"operationID":operationID,"requestID":requestID}`.
  Receipt IDs are derived by the native platform executor only (receipts are native-owned
  per ADR-0018/ADR-0023 and never appear in plan JSON); the same derivation is authoritative
  for the journal `verifiedCommitted` `receiptID` payload and the append-only
  `receipts/<receipt-id>.json` package entry.

`planHash` is lowercase SHA-256 of canonical plan JSON after replacing `planHash` with
64 lowercase zeroes. It includes all final deterministic IDs, descriptors, warnings, and
diagnostics, but never streamed bytes. Implementations must recompute these values and
fail closed on mismatch; alternative UUID namespaces, random IDs, omitted nulls, or a
hash over noncanonical bytes are incompatible with artifact-plan/v1.
