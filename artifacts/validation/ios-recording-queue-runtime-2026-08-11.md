# iOS Recording Queue Simulator Runtime Evidence

- Date: 2026-08-12
- Result: **PASS**
- Base revision: `2c079cabb23b219e78b9292107589ccdbffb00a7`
- Device: disposable iPhone 17 Pro simulator
- Runtime: iOS 26.5 (`23F77`)
- Xcode: 26.6 (`17F113`)
- Harness: `scripts/test-ios-recording-queue-runtime.sh`
- Harness SHA-256: `f08f073b526f8e68d2ee949973771ff757c652070190fd76c62a02c87f31c9c7`
- Semantic screenshot validator SHA-256: `fc5c87cf4fe6b454ae3d48de6724f1b564c44de895cf2a1111e0aaa9938e9ff9`
- Failed UI: `artifacts/validation/ios-recording-queue-runtime-ui-failed-2026-08-11.png` — SHA-256 `cb1f03d85c195d62b27fb703a1292df06dce6e60b4474c759110ffd7fc26e62e`
- Accessibility UI: `artifacts/validation/ios-recording-queue-runtime-ui-failed-accessibility-2026-08-11.png` — SHA-256 `736dbff990791b930e20b8498af7080adf2a7a47f06b0965194400a2d6dfa4ca`
- Queued UI: `artifacts/validation/ios-recording-queue-runtime-ui-queued-2026-08-11.png` — SHA-256 `7aa7df4ab19dfd94457995bfc373fc1c45330f921abfcd5160ad0254ae577826`
- Copy-ready UI: `artifacts/validation/ios-recording-queue-runtime-ui-copy-2026-08-11.png` — SHA-256 `c007c33edd6dbe0c74f809a3c34b2cef0d229d03ec1e6251b239514503df0f7f`

## Isolation

The harness created and booted a dedicated simulator, built and installed only the current checkout's Debug app, and pointed the `DEBUG`-only shared-container override inside that disposable simulator's app data container. It did not install over or inspect an existing simulator app. Every exit terminates the app and deletes the simulator and temporary build products.

A full iOS Simulator Release build also succeeded with the runtime-validation root and container override compiled out.

## Runtime persistence cases

### Interrupted external WAV import

A valid, old app-owned WAV was placed in the isolated recordings directory before launching a real simulator app process.

Verified:

- phase `failed`;
- source `recovered`;
- processing policy `manual`;
- failure stage `storage`;
- recovery status persisted;
- durable queue audio existed and was non-empty;
- the external source disappeared only after durable import.

### Live claimed-job termination and relaunch recovery

The harness reset the durable job to immediate state and launched a real app with a `DEBUG`-only executor that pauses after the queue claim. It observed persisted `processing` state with `attemptCount == 1`, terminated that live simulator process, confirmed the claim remained durable, changed only its future scheduling policy to manual, and launched a second app.

Verified:

- the first process was terminated while the queue executor was active;
- persisted phase remained `processing` with exactly one attempt after termination;
- the second process returned the job to `queued`;
- status became `Recovered after Vox.md was interrupted`;
- the original durable audio remained present and non-empty.

This validates live process termination after a real durable queue claim. It does **not** claim to validate termination inside a production ASR backend or OS background-expiration delivery on a physical device.

## Runtime UI matrix

The real `RecordingQueueView` was rendered for three durable states at 1206×2622. Vision OCR fails the harness if the expected state and action labels are missing or if release notes obscure the view; direct inspection of the attached screenshots confirms:

- failed recovery: `Recovered Recording`, `Needs attention`, Choose Preset, Share Audio, Keep Audio, and Delete;
- queued: `Queued`, Process Now, Share Audio, Keep Audio, and Delete;
- completed deferred clipboard: `Clipboard Transcription`, `Ready to copy`, Copy, Share Audio, Keep Audio, and Delete.

The initial runtime capture exposed unusable one-syllable button wrapping on compact width. `RecordingQueueRow` was changed to an adaptive two-column grid on iOS while preserving the macOS row. At accessibility Dynamic Type sizes it switches to one column, separates status from the title, and uses an inline navigation title. The attached accessibility capture shows complete, unwrapped action labels; semantic OCR verifies its key controls.

The harness also ran DEBUG-only semantic action drivers against disposable durable jobs. The first invoked the same queue methods wired to Retry, Process Now, Copy acknowledgement, permanent retention override, and Delete, then verified the queued fixture's immediate scheduling state, the failed fixture's immediate retry state, the cleared deferred transcript, permanent policy, and discarded state. The second invoked the shared Retry All action path for two distinct failed jobs and the remaining timed and delete-after-success retention actions, then verified all four durable outcomes. This validates state-changing queue action wiring without claiming physical touch behavior, share-sheet presentation, pasteboard contents, or toolbar touch activation.

## Captured output

```text
Isolated iOS Simulator app-runtime orphan import passed.
Isolated iOS Simulator failed Recording Queue UI rendered at 1206x2622.
Recording Queue screenshot semantics passed for ios-failed.
Isolated iOS Simulator failed-accessibility Recording Queue UI rendered at 1206x2622.
Recording Queue screenshot semantics passed for ios-failed-accessibility.
Isolated iOS Simulator live claimed-job termination and relaunch recovery passed.
Isolated iOS Simulator queued Recording Queue UI rendered at 1206x2622.
Recording Queue screenshot semantics passed for ios-queued.
Isolated iOS Simulator copy-ready Recording Queue UI rendered at 1206x2622.
Recording Queue screenshot semantics passed for ios-copy-ready.
Isolated iOS Simulator queue action activation passed.
Isolated iOS Simulator Retry All and complete retention activation passed.
Isolated iOS Simulator runtime queue validation passed.
```

## Remaining scope

This simulator evidence does not cover physical microphone capture, live force-termination timing, opportunistic background expiration, successful ASR, configured export, real pasteboard/share-sheet activation, physical touch accessibility behavior, Retry All toolbar touch activation, keyboard-extension IPC, or StoreKit account restoration. Those remain gated in `docs/recording-queue-storekit-validation.md`.
