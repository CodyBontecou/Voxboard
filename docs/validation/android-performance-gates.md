# Android/Wear performance gates

Status: **M1 thresholds frozen; execution evidence belongs to dependent milestones**

The machine-readable authority is
[`Packages/contracts/validation/performance-gates.json`](../../Packages/contracts/validation/performance-gates.json),
validated against `performance-gates.schema.json` by
`validate_validation_definitions.py`. This document explains the frozen values; it does
not claim that an Android, Wear, Rust, provider, or physical-device run has occurred.
Changing a threshold, method, scope, or required sample count requires a reviewed ADR
before the dependent implementation begins.

## Measurement rules

- Duration uses monotonic elapsed time around the named production path. Setup outside
  that path is excluded only where the gate says so.
- A p95 gate uses at least 20 independent runs after one untimed warm-up and the
  nearest-rank value `sortedSamples[ceil(0.95 * n) - 1]`. The complete bounded sample
  set is retained; outliers are not removed.
- Maximum/minimum gates retain every value from the complete bounded run.
- RSS is additional or peak resident bytes as named, sampled by the platform-appropriate
  process metric. Thermal warnings and unbounded growth remain correctness failures,
  not values hidden by the numerical aggregate.
- A blocked/not-run campaign records no fabricated measurement and cannot pass an
  applicable required gate.

## Frozen latency and resource thresholds

| Gate ID | Milestone | Frozen threshold |
|---|---:|---|
| `enqueue-text-link-p95` | M3 | p95 ≤ 500 ms from Send to durable **Saved locally** for text/link on the low phone tier |
| `quick-capture-warm-p95` | M3 | warm p95 ≤ 500 ms to editable UI |
| `quick-capture-cold-p95` | M3 | cold p95 ≤ 1,500 ms to editable UI |
| `rust-materialize-1mib-p95` | M2 | p95 ≤ 100 ms for 1 MiB new-note materialization |
| `rust-materialize-additional-rss` | M2 | additional RSS ≤ 64 MiB |
| `ffi-max-chunk` | M2 | every FFI chunk ≤ 1 MiB |
| `materialization-max-aggregate` | M2 | accepted streamed aggregate ≥ 256 MiB; tests cover 1, 16, and 256 MiB inputs |
| `saf-actionable-watchdog` | M3 | provider work completes or reaches durable actionable retry/`unknownOutcome` within 30 s, with no UI-thread provider I/O |
| `recorder-session-duration` | M4 | continuous test duration ≥ 3,600 s |
| `recorder-max-prefix-loss` | M4 | abrupt-process-loss durable prefix ≤ 2 s |
| `asr-realtime-factor` | M4 | launch local model real-time factor ≤ 1.0 |
| `asr-peak-rss` | M4 | peak RSS ≤ 1.25 GiB |
| `asr-cancel-latency` | M4 | cancellation completes ≤ 2 s |
| `wear-session-duration` | M7 | recording test duration ≥ 3,600 s |
| `wear-battery-consumption` | M7 | normalized consumption ≤ 20% on every launch watch |
| `wear-transfer-ingest` | M7 | transfer and phone ingest ≤ 600 s once stable connectivity is available |

Recorder evidence also fails on a platform thermal warning, storage corruption, or
unbounded memory growth. Wear evidence also fails on thermal warning or corruption.
SAF campaigns record p50 and p95 for every required provider even though the hard
watchdog is a maximum gate.

## Packaging budgets

M1 freezes pre-implementation uncompressed release-artifact ceilings:

| Scope/gate | Maximum bytes |
|---|---:|
| Android `arm64-v8a` (`android-core-arm64-uncompressed`) | 12 MiB |
| Android `armeabi-v7a` (`android-core-armv7-uncompressed`) | 10 MiB |
| Android `x86_64` (`android-core-x86_64-uncompressed`) | 14 MiB |
| Android `x86` (`android-core-x86-uncompressed`) | 12 MiB |
| Apple XCFramework aggregate (`apple-xcframework-aggregate`) | 60 MiB |
| Apple individual/combined library slice (`apple-xcframework-per-slice`) | 15 MiB |
| Each identically scoped artifact (`packaging-growth`) | unexplained growth ≤ 10% |

The exact Apple leaf set is iOS device arm64 and one combined iOS Simulator
arm64+x86_64 library slice. Packaging evidence binds clean baseline and candidate files,
source revisions, pinned toolchain, configuration, features, artifact identity, actual
byte counts, and SHA-256. The planning-parent baseline is
`b50167aebb959e394908af3a5949f43fa88d6265`; it is not a fabricated binary result.
M2 must produce the comparable baseline/candidate artifacts after its exact toolchain is
pinned.

## Deferred launch-model package budget

`local-asr-model-package` is intentionally the sole deferred required budget. Before M4
starts, an accepted model/tier decision must freeze package size using measured license,
quality, runtime, memory, and supported-device evidence. Deferral of this numerical
budget does not permit remote inference or a silent unsupported tier.

## Executable gate

```sh
python3 Packages/contracts/scripts/validate_validation_definitions.py
python3 -m unittest discover -s Packages/contracts/tests -p 'test_validation_definitions.py' -v
```

Campaign evidence later runs the same validator with `--campaign-dir`. The validator
checks declared sampling methods/counts, computes the statistic, binds packaging files
and hashes, and recomputes aggregate status.
