# Recording Queue and Family Restore Validation

This checklist is the release gate for the cross-platform recording queue and the independent macOS Family restore update. Automated checks are necessary but do not replace the device/account cases below.

## Automated evidence

| Requirement | Implementation evidence | Automated evidence |
| --- | --- | --- |
| Stage audio before processing and preserve failures | `RecordingJobStore`, `RecordingJobQueue` | `RecordingJobStoreTests`, `RecordingJobQueueTests` |
| Recover active/interrupted recordings | `AudioRecorder`, `IncrementalWAVWriter`, `PersistentRecorder` | `IncrementalWAVWriterTests`, relaunch/orphan tests, isolated macOS and iOS Simulator app-runtime recovery |
| Preserve keyboard audio until successful IPC delivery | `KeyboardRecordingArtifactRetention`, thrown IPC delivery error, privacy-safe cleanup result | delivery-failure and partial-cleanup `KeyboardRecordingArtifactRetentionTests` |
| Serialize workers across processes | queue worker `flock` lease | queue/store lease tests plus isolated two-app-process single-attempt validation |
| Delete only after durable transcript and requested delivery | transcript/draft/clipboard checkpoints plus write-ahead note, audio, and audio-reference transactions and retention gates | retention, cleanup-failure, delivery-transaction crash boundaries, distinct-identical-job, external-edit conflict, recorder-level missing/zero-length checkpoint repair and stale-reference replacement, deferred-Copy, stale-receipt repair, and `RecordingDraftDeliveryTests` |
| Immediate, idle, and manual processing | `RecordingQueuePreferences`, queue claim rules | policy tests |
| Capture during processing and background expiration recovery | independent enqueue path, serialized worker, interruption reason | concurrent-enqueue, system-expiration, and no-automatic-restart queue tests |
| Delete-after-success, timed, and permanent retention | `RecordingQueuePreferences`, store cleanup | retention tests |
| Retry, Retry All, Process Now, Copy, share/reveal, retention override, delete | responsive `RecordingQueueViews`, explicit recovered-job preset routing, durable UI polling | action-error/routing/fallback/notification/polling tests, DEBUG semantic iOS state-action drivers covering all queue mutations and all retention modes, builds, and attached Mac/iOS three-state runtime UI matrices |
| No deferred clipboard overwrite | original-policy and attempted-delivery checkpoints | process-now and clipboard checkpoint tests |
| Family and Family Upgrade recognition | `PurchaseAccess`, both Store managers | `PurchaseAccessTests`, project StoreKit contract |
| Privacy-safe restore diagnostics | `PurchaseRestoreDiagnostics` | diagnostics summary test |

Run before either release:

```bash
swift test --package-path Packages/VoxboardShared
xcodebuild -project Voxboard.xcodeproj -scheme Voxboard \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Voxboard.xcodeproj -scheme 'Voxboard Mac' \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Voxboard.xcodeproj -scheme VoxboardTests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  CODE_SIGNING_ALLOWED=NO test
scripts/test-mac-recording-queue-runtime.sh
# Optional real Mac microphone gate after granting Vox.md microphone access:
VOXBOARD_VALIDATE_REAL_MAC_MICROPHONE=1 scripts/test-mac-recording-queue-runtime.sh
scripts/test-ios-recording-queue-runtime.sh
scripts/test-project-contracts.sh
git diff --check
```

## Device failure-injection gate (iOS and macOS)

Concrete host/output evidence is recorded in `artifacts/validation/mac-recording-queue-runtime-2026-08-11.md`; the `mac-recording-queue-runtime-ui-2026-08-11*.png` files show real recovered-failed, queued, and copy-ready rows with their applicable Choose Preset, Process Now, explicit Copy, Reveal, Keep Audio, and Delete controls. The iOS Simulator harness creates and later deletes a dedicated simulator, verifies isolated orphan import and live claimed-job termination/relaunch recovery, and captures failed, queued, and copy-ready runtime UI. Its first capture exposed compact-width action labels wrapping one syllable per line; the final adaptive-grid captures at `artifacts/validation/ios-recording-queue-runtime-ui-*.png` verify readable two-column controls and a one-column accessibility Dynamic Type layout. Vision OCR now fails both runtime harnesses when expected state/action labels are missing or an overlay obscures the iOS queue. Details and limitations are in `artifacts/validation/ios-recording-queue-runtime-2026-08-11.md`. Simulator evidence does not satisfy physical microphone, background-expiration, or keyboard-extension gates.

The isolated macOS app-runtime harness now verifies that an interrupted legacy WAV is imported into durable queue audio, receives a persisted failed/manual recovery manifest, and leaves the isolated external inbox. Its optional `VOXBOARD_VALIDATE_REAL_MAC_MICROPHONE=1` mode can additionally record from the host input and verify durable queue handoff; it currently stops fail-closed because the exact disposable app identity requires an interactive macOS Microphone authorization decision that cannot be completed by this noninteractive harness. It then starts and observes a real durable claim with a DEBUG-only paused executor, terminates that live process, launches a second real app process, and verifies the same audio returns to queued state. It runs without touching user storage. Finally, it starts two real app processes against one immediate durable job and verifies the cross-process worker lease records exactly one attempt while retaining audio after the forced model failure. This covers macOS orphan recovery, live claimed-job termination/relaunch recovery, and real two-process lease exclusion—not microphone capture, successful ASR, export, clipboard, UI actions, or iOS lifecycle behavior.

For every remaining case, confirm the source recording remains in Recording Queue unless the job reached durable delivery and its selected retention deadline elapsed.

- Force quit while actively recording, immediately after Stop, during ASR, during transcript persistence, during configured export, and during finalization.
- Fail storage while staging and while deleting retained audio.
- Fail configured note export, audio export, and attachment insertion, then Retry without duplicate draft payloads, note bodies, audio references, or usage.
- Start recording B while A processes; confirm B's live preview and journal are not changed when A succeeds or fails.
- Start a keyboard recording while an app queue job processes; confirm keyboard capture starts and the queued job resumes later.
- Revoke iOS background time; confirm the active job returns to a retryable queued state.
- For manual/idle macOS clipboard jobs, change the clipboard before processing and confirm it is never overwritten. Copy explicitly from the queue.
- Exercise Process Now, Retry, Retry All, Copy, share/reveal, all retention overrides, and Delete on both platforms. All state-changing paths now have isolated iOS semantic-driver evidence; physical touch and platform share/reveal activation remain required.

## Current App Store Connect evidence

Read-only ASC verification on 2026-08-11 confirmed:

- App `6758967337` / bundle ID `bontecou.Voxboard`.
- `bontecou.Voxboard.family` is an approved, family-shareable non-consumable.
- `bontecou.Voxboard.familyUpgrade` is an approved, family-shareable non-consumable.
- `bontecou.Voxboard.unlock` is approved.
- The newest uploaded macOS build is still `37` (`2.0.3`, uploaded 2026-07-29). No build containing the modern Family mapping and diagnostics is available for account validation yet.

The complete queue milestone is preserved independently of the unrelated dirty `.github` files in `artifacts/releases/cross-platform-recording-queue.patch`. Regenerate and revalidate that artifact after source changes before release. Project contracts and `git diff --check` pass; the latest shared package run executed 656 XCTest cases plus 4 Swift Testing cases with zero failures, the latest iOS target run executed 68 tests with zero failures, and both iOS and macOS Debug and Release targets built successfully.

The independent release patch is `artifacts/releases/mac-family-restore-diagnostics.patch` (SHA-256 `6d69e21e21c329f6d8efd79b6d347427c600cb1c252b33c7e13523750b3bbedc`). It changes only `PurchaseAccess.swift` and `MacStoreManager.swift`, applies cleanly to base `2c079ca`, and passed a clean macOS Release build in a detached worktree. This proves the StoreKit diagnostics can ship without the recording queue. Run the non-mutating release preflight with `scripts/preflight-mac-family-restore-release.sh`. It validates the patch checksum/applicability, performs a clean independent Release build, reads ASC product/build state, and inspects local signing assets without creating profiles or uploading a build.

A prior clean archive attempt without provisioning mutations failed with: `No profiles for 'bontecou.Voxboard' were found ... pass -allowProvisioningUpdates`. The current preflight now finds a local Vox.md provisioning profile, but this machine still exposes no Apple Distribution private key. Continuing requires access to or installation of that distribution signing key plus explicit authorization to archive, export, and upload; the preflight itself remains non-mutating.

The hosted `VoxboardTests` target was also probed with `SKTestSession`; StoreKitTest rejected off-device purchases with `notEntitled`/`noContext`, so that harness cannot be presented as restoration evidence. A dedicated StoreKit-capable test host or sandbox/TestFlight build is required.

## Independent macOS StoreKit gate

Validate the StoreKit fix in a macOS sandbox/TestFlight build independently of the recording-queue release:

1. Original Individual purchaser: restore Individual access and Family Upgrade eligibility.
2. Family purchaser: restore Family access.
3. Individual purchaser who bought Family Upgrade: restore Family access.
4. Separate Apple Family member: restore a family-shared Family or Family Upgrade entitlement.
5. Refunded/revoked transaction: do not grant access; diagnostics show `revoked`.
6. Unverified transaction: do not grant access; diagnostics show `unverified` and only the error type.
7. Missing current entitlement with transaction history: diagnostics include the privacy-safe `Transaction.latest` observation.
8. Confirm diagnostics contain product ID, recognized/verified/revoked/upgraded state, ownership type, environment, storefront, requested/loaded products, and sync outcome—but no Apple Account ID, transaction ID, purchase date, or receipt.

Record the tested macOS version/build and account role for each case. The currently published pre-Family macOS build is not evidence for this gate; an uploaded build containing the modern product mapping is required.
