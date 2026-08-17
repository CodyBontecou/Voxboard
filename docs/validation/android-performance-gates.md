# Android/Wear performance gates

Status: **M2 evidence contract executable; no real M2 performance campaign recorded**

The machine authority is [`Packages/contracts/validation/performance-gates.json`](../../Packages/contracts/validation/performance-gates.json). Definition validation does not attest execution.

## Measurement derivation

Executed measurements are summaries of strict typed receipts, never independent numeric assertions. The validator reloads the receipt named by each measurement derivation, derives the complete ordered samples, recomputes nearest-rank p95/minimum/maximum, and requires exact equality.

M2 materialization uses the named generated-UniFFI host consumer `vox-core-uniffi-swift-host-v1`. Receipts bind clean source revision, executable, toolchain, exact recipe, deterministic synthetic generator, canonical per-run control document, generator-derived repeated-byte input stream, full ordered ingress/drain chunks, descriptor/output hashes, and completed drain. The validator derives control/input hashes from the governed seed instead of trusting arbitrary retained bytes. Chunks are 1..1,048,576 bytes, sequences start at zero and are contiguous through at most 262143, and every governed chunk contributes to `ffi-max-chunk`.

- `rust-materialize-1mib-p95`: at least twenty completed 1 MiB timed runs after exactly one first, uncounted warmup; nearest-rank p95 <= 100 ms.
- `materialization-max-aggregate`: maximum over the **exact** successful set 1,048,576, 16,777,216, and 268,435,456 bytes; maximum >= 256 MiB. Missing, duplicate, or extra aggregate-coverage sizes fail.
- `rust-materialize-additional-rss`: a dedicated completed 256 MiB production run. On macOS, `macosMachTaskResidentSizeSampled` starts at elapsed zero and retains every <=10 ms sample through a final verified-drain sample. Baseline is resident bytes immediately before opening the session; additional bytes are `max(0, max(baseline, all samples) - baseline)` and must be <=64 MiB.

Hosted validation additionally verifies the active GitHub Actions run/workflow/workspace, rehashes the retained executable and receipt-declared raw synthetic control/input/output, and rejects undeclared files under the non-symlink external artifact root.

## Packaging baseline modes

Exactly six ordered nonzero leaves are required: four Android ABIs, iOS device arm64, and combined iOS Simulator arm64+x86_64. Candidate bytes and SHA-256 are derived from the native inspection receipt; Apple aggregate is the sum of its two leaves. Hosted reinspection parses ELF section/dynamic-symbol/dependency tables, Mach-O build-version/symbol/load commands inside bounded archives and fat slices, and the retained XCFramework `Info.plist`; receipt check labels cannot substitute for those observations.

- `initialCandidate`: candidate-only and allowed only while no governed registry exists. It passes the absolute gates and forbids baseline or growth data. It does not become an approved future baseline merely by passing.
- `approvedBaselineComparison`: requires a separate governed, really approved baseline registry. Baseline identity must match every scope, toolchain, configuration, feature set, byte count, hash, and source revision. The unchanged growth gate is maximum `((candidate-baseline)/baseline)*100 <= 10` across all six leaves.

No registry is committed by this contract-only slice because no real baseline has been adopted.

## Scope and qualification

A `milestoneClosure` aggregate derives all required cases through its milestone. M2 selects `CORE-001` through `CORE-005`, `PERF-003`, and `PERF-008`; a `caseExecution` aggregate is a shard/rerun and cannot claim closure. Therefore package/performance evidence alone is explicitly incomplete.

Qualification is independent of technical status:

1. `repositoryObservation`: canonical committed receipts validate; unretained binaries are not independently rehashed. Empty approvals are required.
2. `hostedRun`: exact workflow/run identity is bound and external retained artifacts are rehashed. Empty approvals are allowed.
3. `releaseGate`: hosted facts plus real, unexpired definition/campaign/release approvals bound to exact hashes.

A technically passed repository observation is not hosted or release qualification. M2 exit requires a real hosted M2-closure campaign.

## Remaining gates

All M3+ duration, recorder, SAF, ASR, Wear battery/transfer, physical-device, provider, and thermal requirements remain unchanged and require their real target identities. Blocked/not-run evidence records no fabricated samples.

## Commands

```sh
python3 Packages/contracts/scripts/validate_validation_definitions.py
python3 -m unittest discover -s Packages/contracts/tests -p 'test_validation_definitions.py' -v
```
