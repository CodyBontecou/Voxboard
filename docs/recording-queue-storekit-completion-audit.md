# Recording Queue and StoreKit Completion Audit

Audit date: 2026-08-12

Base revision: `2c079ca`

Overall status: **Not complete — external device, signing, upload, and account gates remain blocked.**

This is the prompt-to-artifact audit for the cross-platform recording queue and independent macOS Family restore milestone. A passing build or test suite is not treated as evidence for device/account behavior by itself.

## Concrete objective

1. Preserve iOS and macOS recordings through transcription, delivery, interruption, and relaunch.
2. Recover durable jobs and execute transcription through one serialized cross-process worker.
3. Offer delete-after-success, timed, and permanent source-audio retention.
4. Offer immediate, idle, and manual processing.
5. Keep capture available while earlier jobs process.
6. Provide Retry, Retry All, Process Now, explicit Copy, share/reveal, retention override, and delete actions.
7. Keep iOS keyboard transcription immediate and preserve its audio through failed IPC delivery.
8. Restore Individual, Family, and Family Upgrade purchases on macOS with privacy-safe diagnostics.
9. Keep the queue release cross-platform while allowing the StoreKit fix to ship independently.
10. Preserve independently applicable artifacts and record all remaining release gates.

## Requirement-to-artifact checklist

| # | Requirement | Concrete artifact | Direct evidence inspected | Status |
| --- | --- | --- | --- | --- |
| 1 | Audio cannot disappear before durable delivery | `RecordingJobStore.swift`, `RecordingJobQueue.swift`, `IncrementalWAVWriter.swift`, `AudioRecorder.swift`, `PersistentRecorder.swift`, `MacRecorder.swift`, `CheckpointedAudioDelivery.swift` | storage-failure, failed-ASR, cleanup-failure, orphan, interrupted/finalizing recovery, path-validation tests, crash-safe note/audio/reference delivery transactions, recorder-level missing/zero-length checkpoint repair with stale-reference replacement, and isolated Mac/iOS Simulator app-runtime recovery; 656-test shared run | Code and isolated runtime cases verified; physical injection pending |
| 2 | Relaunch recovery and one serialized cross-process worker | atomic job manifests, `flock` lease, processing-state recovery, enqueue-race drain flag | lease/handoff, relaunch, active-journal, serialization tests, iOS Simulator relaunch, and two-real-Mac-process single-attempt validation | Runtime recovery verified; physical iOS extension/app interaction pending |
| 3 | Configurable retention | `SourceAudioRetentionPolicy`, `RecordingQueuePreferences`, per-job overrides, retention cleanup | delete-after-success, timed, permanent, failed-delivery, deferred-Copy, and cleanup-receipt tests | Verified |
| 4 | Configurable scheduling | `RecordingJobProcessingPolicy`, queue claim rules, settings UI | immediate/idle/manual and Process Now tests | Verified |
| 5 | Record while earlier work processes | recorder capture paths are separate from queue worker; queue remains serialized | `test_enqueueRemainsAvailableWhileEarlierJobProcesses`; both platform builds | Code verified; simultaneous physical capture pending |
| 6 | Queue actions | Dynamic-Type-responsive `RecordingQueueViews.swift`, explicit recovered-job preset selection, iOS settings integration, macOS root integration | action/error-preservation/routing tests, durable cross-process polling, DEBUG semantic iOS state-action drivers covering Retry, Retry All, Process Now, Copy acknowledgement, every retention mode, and Delete; builds, OCR, Mac/iOS state matrices, and iOS accessibility capture | All state-changing wiring verified; physical touch and share/reveal activation remain pending |
| 7 | Keyboard priority and preservation | `interruptForInteractiveWork`, `KeyboardRecordingArtifactRetention`, thrown `TranscriptionIPC.writeResponse` failures | priority/cancellation tests; delivery-failure and partial-cleanup tests; full 50-test iOS run | Code verified; keyboard-extension device IPC failure pending |
| 8 | macOS purchase restoration | `PurchaseAccess.swift`, `StoreManager.swift`, `MacStoreManager.swift` | product mapping/diagnostic tests, project contract, read-only ASC product check, independent Release build | Code verified; uploaded sandbox/TestFlight account matrix pending |
| 9 | Cross-platform queue and independent StoreKit release | shared package/UI integration; independent StoreKit patch changes only two files | iOS and macOS builds; independent patch scope contract and Release build | Verified as source artifacts; release pending |
| 10 | Independently applicable artifacts and gates | `artifacts/releases/*.patch`, this audit, `recording-queue-storekit-validation.md`, release preflight | clean detached apply, reverse exactness, checksums, contracts, documented blockers | Verified |

## Constraint checklist

| Constraint | Evidence | Status |
| --- | --- | --- |
| Existing users default to delete after successful processing | preference default and tests | Verified |
| Failed/interrupted/unprocessed/undelivered audio is never automatically deleted | queue retention gates and failure/recovery tests | Verified in code |
| Success includes durable transcript plus requested delivery | transcript/draft/clipboard checkpoints plus write-ahead note, audio, and audio-reference delivery transactions | Verified in code |
| Deferred Mac clipboard jobs never overwrite newer clipboard state | original-policy and attempted-delivery checkpoints; explicit Copy | Verified in code; device pasteboard exercise pending |
| Keyboard IPC failure preserves audio | thrown delivery error plus cleanup-after-delivery helper | Verified in code; extension-host exercise pending |
| Capture is independent; transcription remains serialized | concurrent-enqueue and max-concurrency tests | Verified |
| Cross-process workers cannot duplicate a job | nonblocking `flock` lease and handoff tests | Verified in tests |
| iOS correctness does not depend on background processing | durable state plus cancellation/relaunch recovery; expiration latch | Verified in code; OS expiration exercise pending |
| Diagnostics omit account IDs, transaction IDs, dates, and receipts | diagnostic model/summary tests and source inspection | Verified |
| Dirty unrelated work is excluded | full patch path set excludes `.github`; no staged files | Verified |
| Queue milestone covers iOS and macOS together | shared implementation plus both builds | Verified |
| StoreKit patch remains independently shippable | two-file patch and preflight | Verified as artifact |

## Verification surface

Latest successful local checks:

- `swift test --package-path Packages/VoxboardShared`: **656 XCTest cases plus 4 Swift Testing cases, 0 failures**.
- `xcodebuild ... -scheme VoxboardTests ... test`: **68 tests, 0 failures**.
- iOS simulator build/test host: **succeeded**.
- macOS Debug build: **succeeded**.
- Independent macOS StoreKit Release build from detached `HEAD`: **succeeded**.
- Full macOS and iOS Simulator Release builds with runtime hooks compiled out: **succeeded**.
- `scripts/test-ios-recording-queue-runtime.sh`: **isolated orphan import, live claimed-job termination/relaunch recovery, and corrected three-state responsive and accessibility UI rendering with semantic OCR passed**; evidence is attached at `artifacts/validation/ios-recording-queue-runtime-2026-08-11.md` and `artifacts/validation/ios-recording-queue-runtime-ui-*.png`.
- `scripts/test-mac-recording-queue-runtime.sh`: **isolated orphan import, live claimed-job termination/relaunch recovery, two-real-app-process worker exclusion, and real failed-row UI rendering passed**; its new optional real-microphone mode stops fail-closed until this disposable validation identity is granted macOS Microphone access; host/output evidence is attached at `artifacts/validation/mac-recording-queue-runtime-2026-08-11.md` and the `artifacts/validation/mac-recording-queue-runtime-ui-2026-08-11*.png` matrix.
- `scripts/test-project-contracts.sh`: **passed**.
- `git diff --check`: **passed**.
- Independent reviewer `decf1470`: all six incremental safety findings resolved; no new concrete blocker.
- Independent reviewer `8b209d31`: semantic screenshot and accessibility responsiveness findings resolved; no residual blocker.
- Independent reviewer `dc4c34ba`: write-ahead note/audio/reference delivery, distinct identical jobs, external-edit conflicts, coordinated publication, unusable-checkpoint republication, and legacy manifest findings resolved; no blocker/high/medium finding.
- Independent reviewer `45eb7380`: queue action errors, explicit recovered-job routing, current retry settings, Retry All eligibility, durable cross-process UI polling, and fallback clearing findings resolved; no blocker/high/medium finding.
- Recorder-level checkpoint orchestration now directly tests missing/zero-length audio repair, exact URL re-checkpointing, stale TXT/Markdown/YAML reference replacement, reference-checkpoint invalidation, and source preservation across checkpoint failures.
- Full patch cleanly applies to detached base `2c079ca`, passes post-apply `git diff --check` and project contracts, and reverse-checks exactly against this checkout.
- Working tree and index are clean after the integrated commit.

Release artifacts:

- `artifacts/releases/cross-platform-recording-queue.patch`
  - Regenerated and detached-apply validated after the latest delivery-safety fixes.
  - Its SHA-256 is reported externally rather than embedded here, because this audit is itself contained in that patch.
- `artifacts/releases/mac-family-restore-diagnostics.patch`
  - SHA-256: `6d69e21e21c329f6d8efd79b6d347427c600cb1c252b33c7e13523750b3bbedc`

## Unmet gates — completion is prohibited

### Physical-device recording matrix

Isolated iOS Simulator and real macOS Debug app processes now cover legacy-WAV durable import, live claimed-job termination/relaunch recovery, responsive three-state queue rendering, and exactly-one-attempt exclusion between two concurrent Mac workers without touching existing user/simulator storage. An optional real-microphone Mac harness was added and attempted; it currently reports a concrete TCC blocker because the exact disposable validation identity requires an interactive macOS Microphone authorization decision. Simulator evidence is not physical-device evidence. No attached evidence yet covers force termination during capture, stop, ASR, persistence, export, and finalization; live overlapping capture; real background expiration; keyboard-extension IPC failure; pasteboard preservation; physical touch activation; or platform share/reveal presentation. Follow `docs/recording-queue-storekit-validation.md` and record device model, OS, app build, case, expected result, actual result, and evidence location.

### macOS signing and account matrix

`scripts/preflight-mac-family-restore-release.sh` currently reports:

- no local Apple Distribution private key;
- a local Vox.md provisioning profile is installed;
- latest uploaded macOS build is still pre-Family build `37`.

Therefore no Family-capable build is available for Individual, Family, Family Upgrade, separate family member, revoked/refunded, unverified, or `Transaction.latest` sandbox/TestFlight validation.

Required next input is access to or installation of the Apple Distribution certificate/private key, followed by explicit authorization to archive, export, and upload a validation build. The preflight remains non-mutating and does not perform those release actions.

The active goal must remain incomplete until both external matrices have concrete evidence.
