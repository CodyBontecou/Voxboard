# Wearable protocol v1

This durable bounded protocol family covers negotiation, frozen presets, recording metadata, manifests, resumable frontiers, reconciliation, receipts, staged acknowledgements, reassignment, retry, and discard. `protocolVersion` is exactly `1`; unsupported versions produce `unsupportedVersion` without deleting media. Every envelope includes kind, lowercase message/recording/sender-installation/device/correlation UUIDs, epoch, monotonic revision, and replay rule. Unknown envelope fields fail closed; payload extensions are bounded and message-kind semantics below are normative.

A recording freezes a complete portable preset snapshot/hash. Recording Only requires local ASR disabled, location excluded, and a stable phone-native folder/filename policy reference. Its `vaultCommitted` occurs only after verified user-visible audio export.

`phoneIngested` requires checksum verification and durable phone package commit. `vaultCommitted` requires verified destination commit. `sourceDeletionAuthorized` is terminal, correlates the vault commit, and requires threshold `vaultCommitted`; transport receipt or `phoneIngested` never authorizes deletion. Terminal failure/discard are distinct. Duplicate envelopes are idempotent, stale epochs/revisions do not regress state, and reconciliation preserves unacknowledged media.

Asset/chunk lengths and SHA-256 are verified; chunks are at most 1 MiB and durable offsets are monotonic and bounded by asset length. Payloads never contain bookmarks, URIs, provider paths, credentials, captured text, or hidden network instructions.
