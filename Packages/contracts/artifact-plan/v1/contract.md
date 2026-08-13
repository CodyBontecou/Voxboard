# Artifact plan v1

Normative encoding is canonical UTF-8 JSON. Every field is required; nullable hashes express absence explicitly, arrays are ordered/bounded, and unknown fields/kinds/enums fail closed without defaults. Final JSON contains descriptors only and never duplicates drained artifact bytes.

The plan freezes request and all core/renderer/profile pins, plan hash, operation, shipped marker policy/syntax/placement, typed warnings/diagnostics with privacy-safe paths, and an exact ordered discriminated artifact list. Attachments describe source and result media/length/SHA, logical destination, expected-existing hash policy, equivalence rule, deterministic IDs, receipt, and frontier. The single last note additionally specifies write mode, expected original hash, and immutable prepared-stream ID. Native persists and verifies all drained bytes and finalized plan before side effects, then persists each correlated receipt/frontier.
