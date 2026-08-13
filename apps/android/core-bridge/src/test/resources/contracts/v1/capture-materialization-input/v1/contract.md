# Capture materialization input v1

This internal input supplies frozen preparation facts and resolved observations. `contractVersion` is exactly `1`; unsupported versions, unknown fields, mismatched request/preparation revision/snapshot hash, duplicate observation IDs, missing required observations, or descriptor/hash inconsistencies fail closed with content-free typed errors.

Control JSON is UTF-8 and at most 1 MiB. Byte-bearing observations use the bounded session: chunks are at most 1 MiB, sequence starts at zero and is contiguous per observation, EOF occurs once, aggregate template/note bytes are at most 256 MiB, input seals once, and post-EOF/post-seal calls fail. The state machine is `input -> outputReady -> draining -> finalized|cancelled`. Repeated, missing, out-of-order, wrong-artifact, hash-mismatched, abandoned, cancelled, or post-terminal calls yield no committable plan.

Payload and observation collections are ordered. Binary bytes are described by ID, media type, length, and lowercase SHA-256, never embedded in control JSON. Paths are logical segments only. Errors expose stable codes and safe field paths, never capture content.
