# Wearable protocol v1

Each message is canonical UTF-8 JSON and matches exactly one schema variant. Every envelope carries protocol/message kind, message/recording/sender-installation/device IDs, epoch, monotonic revision, correlation ID, explicit replay rule, and its kind-specific bounded payload. All fields are required, absence is explicit `null` where allowed, and unknown fields/kinds/versions fail closed while retaining source media. No ambient defaults exist.

The 17 exact kinds cover capability/version negotiation; inventory and complete hashed frozen preset snapshot; transcript/Recording Only metadata; asset manifest and resumable frontier; reconciliation and transport receipt; correlated phone-ingested/vault-committed/failure/discard/deletion outcomes; and reassignment/retry/discard actions. Recording Only requires disabled ASR, excluded location, and both native folder/filename policy references; transcript mode requires both Recording Only policy references to be `null`.

`trace.schema.json` defines bounded conformance traces. Validation correlates sender/device/epoch/recording/correlation, strictly increasing revision, transport before ingestion, ingestion before vault ACK, terminal exclusivity, and vault ACK before source deletion authorization. Deletion is permitted only after durable authorization or explicit durably receipted discard.
