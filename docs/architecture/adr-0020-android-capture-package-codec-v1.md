# ADR-0020: Android capture-package codec v1 and durable enqueue

- Status: **Accepted**
- Product decision ID: `PD-M3-ANDROID-CAPTURE-PACKAGE-V1-001`
- Required by: M3 Android text/link vertical slice

## Context

ADR-0018 makes the app-private package and journal recovery authority. This slice needs an executable, crash-safe enqueue boundary without claiming composer, quota, SAF/provider, scheduling, or native bridge completion.

## Decision

Capture-package version 1 stores exact canonical `capture-preparation-input/v1` bytes as `request.json`, an exact empty `assets.json` version 1, and `delivery-journal.json` version 1. Journal v1 durably binds the actual request and asset byte counts and SHA-256 values and records package, request, asset, and journal versions. Decode, duplicate handling, and reconciliation verify those bindings against reopened retained bytes before Room indexing. There is no separate package-metadata envelope.

JSON is UTF-8, sorted-key, two-space canonical form with exactly one final LF. Unknown or duplicate keys, non-finite numbers, noncanonical bytes, unsupported versions, uppercase UUID/SHA values, malformed/truncated inputs, or a replay frontier that differs from the supplied journal snapshot fail closed. Each control file is at most 1 MiB, the journal has 1–1024 events, and retained package bytes are at most 256 MiB.

The governed M3 fixture is `capture-preparation-input/valid-android-m3-text-link.json`. It uses core `0.1.0-alpha.1`, renderer `swift-legacy-m0`, profile `apple-parity-v1` version 1, no model, and fixed preset UUID `33333333-3333-4333-8333-333333333333`. Its preset `snapshotHash` is SHA-256 of canonical preset JSON after replacing `snapshotHash` with 64 zeroes. Kotlin verifies this derivation before admission, and the existing Rust production `prepare` function consumes the exact governed bytes.

Kotlin first performs complete preparation-input v1 shape/type/bounds validation, including ZoneId validation, before applying the narrower M3 profile. Current enqueue additionally gates the current core pin. Historical package validation retains the structural v1 and M3-policy checks but does not compare an older retained core pin to the current app build, so an upgrade does not relabel otherwise valid retained bytes as corrupt.

M3 accepts only app-originated `newNote` requests with one or two unique text/link payloads, Gregorian calendar, no model, no retry marker, no frontmatter/template/ordered metadata, LF plus final newline, empty attachment folder, `Inbox`, `capture-{id}.md`, `markdownDotMd`, and `deterministicSuffix`. `expectedCaseSensitivity` must be `sensitive`. That value must come from native observation before enqueue; `unknown` and `insensitive` fail admission. Real-provider observation support remains a product blocker and is never inferred from this fixture.

Filesystem staging is not semantic state. The reducer enforces the ADR-0018 graph; in particular, `materialized` cannot transition to itself. Journal encoding replays every event and requires exact request/frontier/event equality.

Enqueue rejects a negative event time before root creation. It verifies app-private roots without following symlinks, creates or verifies `noBackupFilesDir/vox-captures`, and fsyncs `noBackupFilesDir` before any acknowledgement path. Request-correlated temporary names have the form `.tmp-<request UUID>-<nonce UUID>`. Every file write, flush, file sync, close, reopen, temporary-directory sync, promotion, parent sync, index call/result, and post-index/pre-result boundary has separate before/after fault checkpoints; tests claim only those boundaries, not injection inside an OS call.

Promotion uses a cooperative app-private interprocess protocol, not an unqualified kernel no-replace primitive. Each participant opens the persistent `vox-captures/.promotion.lock`, obtains a `FileChannel` exclusive lock, rechecks the final target with `NOFOLLOW_LINKS`, then performs `ATOMIC_MOVE` without a replace option. A process crash releases the lock. Same-process callers additionally serialize lock acquisition. Unsupported locking or atomic move fails closed; there is no copy/delete, `renameTo`, replace-existing, or silent downgrade. After promotion, `vox-captures` is fsynced. Before an existing duplicate may acknowledge, the `vox-captures` package parent is fsynced again; root setup also fsyncs `noBackupFilesDir`.

Request and asset files in an existing package are immutable. Exact inventory, schemas, correlations, journal bindings, and actual bytes are validated. ADR-0021 narrowly permits one exact same-package `.delivery-journal.<nonce UUID>.tmp` only while atomically replacing the canonical journal; it is non-authoritative and never promoted by recovery. Identical request/assets bytes repair or verify the content-free Room projection and may return `SavedLocally`; differing admitted bytes return `CorrelationConflict`; invalid retained bytes return `ExistingPackageCorrupt`. A forced promotion-barrier test with separate stores and differing canonical requests proves one winner, one conflict, and winner-byte retention under this cooperative protocol.

Reconciliation verifies complete UUID packages and handles request-correlated temporary directories explicitly. It deletes only bounded, known-entry, non-symlink partial temporary trees and reports suspicious temporary trees without deleting them. Package and index exceptions become typed reconciliation results. Room remains a content-free projection and not queue truth.

## Consequences and limits

JVM tests establish codec, ordering, cooperative-race, reconciliation, and injected-boundary behavior; they do not establish physical flash durability. Generated Room code and the instrumentation APK compile, but no emulator/device run or passed M3 evidence is recorded here. Runtime Room qualification, native case-sensitivity discovery, and real-provider support remain blockers.

ADR-0021 adds production-unwired journal replacement, fenced leases, quota primitives, and reservation classification. Completed-package cleanup remains unimplemented. Composer acknowledgement, SAF/provider commit, WorkManager execution, DataStore runtime, prepared artifacts, and the Rust Kotlin/native bridge remain out of scope. WorkManager and DataStore remain compile-only dependencies.
