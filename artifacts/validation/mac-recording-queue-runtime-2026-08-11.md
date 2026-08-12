# macOS Recording Queue Runtime Evidence

- Date: 2026-08-12
- Result: **PASS**
- Base revision: `2c079cabb23b219e78b9292107589ccdbffb00a7`
- Host: `Mac16,12`, arm64
- OS: macOS 26.5.1 (`25F80`)
- Xcode: 26.6 (`17F113`)
- Harness: `scripts/test-mac-recording-queue-runtime.sh`
- Harness SHA-256: `e7db463a82962b522664ddb32855322d94466f8581fb446a15716c512835b0bf`
- Semantic screenshot validator SHA-256: `fc5c87cf4fe6b454ae3d48de6724f1b564c44de895cf2a1111e0aaa9938e9ff9`
- Failed UI: `artifacts/validation/mac-recording-queue-runtime-ui-2026-08-11.png` — SHA-256 `eef2b3d34f4b2e43603dca4865ae370babdf28842f997fbd5baa12a88d3f9797`
- Queued UI: `artifacts/validation/mac-recording-queue-runtime-ui-2026-08-11-queued.png` — SHA-256 `380afab9ee8bb3874211de450785e33ccf0ff5aa4d404b86f3a07327ba4abbdd`
- Copy-ready UI: `artifacts/validation/mac-recording-queue-runtime-ui-2026-08-11-copy.png` — SHA-256 `a0c7fa8cad441557c92714f130938e3ff606f1cae7b53777e0bc4580a596afb4`

## Isolation

The harness built the current checkout's macOS Debug target into disposable Derived Data. It launched only that generated executable with a `DEBUG`-only shared-container override pointing at a temporary directory. It accepted no caller-supplied app, did not use the normal App Group/Application Support queue, terminated every launched process, and removed the temporary app data and build products.

A full macOS Release build also succeeded with the validation-only symbols compiled out.

## Cases

### Interrupted external WAV import

A valid, non-empty, app-owned legacy WAV was placed in the isolated recordings directory with an old modification date. A real Vox.md process recovered it and the harness directly inspected the durable manifest and audio file.

Verified:

- phase `failed`;
- source `recovered`;
- processing policy `manual`;
- failure stage `storage`;
- recovery status message persisted;
- queue-owned audio existed and was non-empty;
- the external source was removed only after its durable import.

### Live claimed-job termination and relaunch recovery

The harness launched a real app with a `DEBUG`-only executor that pauses after a durable claim, observed `processing` with `attemptCount == 1`, terminated that process, confirmed the live claim remained persisted, changed only future scheduling to manual, and launched a second real app.

Verified:

- termination occurred while the queue executor was active;
- persisted phase remained `processing` with exactly one attempt;
- the second app returned the job to `queued`;
- status changed to `Recovered after Vox.md was interrupted`;
- the original queue-owned audio remained present and non-empty.

This validates live process termination after a real queue claim. It does **not** claim to validate termination inside a production ASR backend.

### Two-process worker exclusion and failed-job retention

The durable job was reset to immediate queued state with a deliberately unavailable model. Two real Vox.md processes were launched concurrently against the same isolated container.

Verified after lease handoff time:

- the job reached `failed`;
- `attemptCount` remained exactly `1`;
- the second process did not claim or execute the same job;
- queue-owned source audio remained present and non-empty after execution failure.

## Runtime UI rendering

Isolated processes rendered the real `RecordingQueueView` for three durable states. Vision OCR fails the harness if expected state/action labels are missing. Direct inspection of the attached view-cache PNGs confirms:

- failed recovery: `Recovered Recording`, `Needs attention`, the persisted recovery message, Choose Preset, Reveal, Keep Audio, and Delete;
- queued recovery: `Queued`, the relaunch-recovery message, Process Now, Reveal, Keep Audio, and Delete;
- completed deferred clipboard: `Clipboard Transcription`, `Ready to copy`, the explicit-copy message, Copy, Reveal, Keep Audio, and Delete.

The failed, queued, and copy-ready images are 2360×1520. This verifies runtime rendering and state binding for these rows. It does not claim that the controls were activated, that Retry All's navigation toolbar was captured, or that iOS Share Audio rendered on macOS.

## Captured output

```text
Isolated macOS failed Recording Queue UI rendered at 2360x1520.
Recording Queue screenshot semantics passed for mac-failed.
Isolated macOS app-runtime orphan import passed.
Isolated macOS live claimed-job termination and relaunch recovery passed.
Isolated macOS queued Recording Queue UI rendered at 2360x1520.
Recording Queue screenshot semantics passed for mac-queued.
Isolated macOS copy-ready Recording Queue UI rendered at 2360x1520.
Recording Queue screenshot semantics passed for mac-copy-ready.
Isolated macOS two-process worker lease passed.
```

## Optional real-microphone gate

The harness now supports `VOXBOARD_VALIDATE_REAL_MAC_MICROPHONE=1`. It ad-hoc signs only its disposable Debug build with an audio-input entitlement, records two seconds from the real default input, and verifies a non-empty queue-owned audio file after durable handoff. No project signing or provisioning asset is changed. Its real application process performs the authorization check; no helper-process permission is treated as evidence.

Current attempt result: **BLOCKED** — after resetting macOS Microphone privacy state, the exact disposable Vox.md application identity waited for the OS authorization decision and could not proceed noninteractively. Granting microphone access requires user interaction in System Settings/the TCC prompt. The ordinary isolated queue cases above still pass.

## Remaining scope

This evidence does not yet cover successful real microphone capture, live force-termination timing, successful ASR, configured export, clipboard behavior, activation of interactive queue UI actions, iOS lifecycle behavior, or StoreKit account restoration. Those cases remain gated in `docs/recording-queue-storekit-validation.md`.
