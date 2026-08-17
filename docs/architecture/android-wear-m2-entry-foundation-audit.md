# Android/Wear M2 foundation completion audit

Status: **M2 closed — hosted milestone qualification passed**

Qualified source revision: `450abcaab4f09f5a4803d535ee843d1c058f099b`

This audit closes the M2 scope from
`docs/android-wear-shared-core-implementation-plan.md`: new-note text/link
materialization only. It does not authorize Android product authority, Rust-owned native
side effects, Apple Rust authority, M3 application work, physical-device claims, or an
authenticated release approval.

## Closure record

| Evidence | Result |
| --- | --- |
| Shared Rust core CI | [run 31838926900](https://github.com/CodyBontecou/vox.md/actions/runs/31838926900), success at the qualified revision |
| Canonical hosted job | `m2-evidence`, job `94891366115`, success, run attempt 1 |
| Apple CI | [run 31838927593](https://github.com/CodyBontecou/vox.md/actions/runs/31838927593), all five jobs passed at the qualified revision |
| Qualified scope | `milestoneClosure` through `M2` |
| Required tuples | 7 passed; 0 failed, blocked, or incomplete |
| Retained artifact | `m2-evidence`, artifact ID `9233785753`, 1,216,216,409 bytes |
| Artifact retention | Not expired when audited; GitHub reports expiry `2026-09-13T20:49:46Z` |
| Uploaded ZIP SHA-256 | `a055ac37ff8bc307a5bd3d0d8d6e24867c04fc4e8e5adb5514a36cc593ba21ac` |
| Raw USTAR SHA-256 | `6b13159663c2c4a516d9f5dc223e0b378e65a610e1c5560ec90b402d4f8a8cf3` |
| Raw USTAR size | 607,848,448 bytes |
| Authenticated identity | `CodyBontecou/vox.md`, repository ID `1153091883`, owner ID `20440899`, `refs/heads/main`, push event, GitHub-hosted runner |
| OIDC identity | Issuer `https://token.actions.githubusercontent.com`; audience `https://vox.md/m2-evidence/v1`; immutable repository/owner-ID subject enforced by the verifier |

The hosted aggregate is `passed` and binds source revision, workflow revision,
workflow bytes, unconditional orchestrator bytes, live GitHub OIDC claims, clean
checkout, run identity, executable provenance, evidence, native leaves, materialization
bytes, and the retained archive.

## Plan-to-artifact audit

| M2 plan requirement | Implemented artifacts | Executable verification |
| --- | --- | --- |
| Pure `vox-core` and thin `vox-core-uniffi` | `Packages/vox-core-rust/crates/vox-core/**`, `Packages/vox-core-rust/crates/vox-core-uniffi/**`, workspace `Cargo.toml` and `Cargo.lock` | Workspace tests, Clippy, MSRV tests, release panic test, hosted `CORE-001`–`CORE-005` |
| Build info and exact readiness | `crates/vox-core/src/lib.rs`, `crates/vox-core/build.rs`, `Packages/contracts/core-api/v1/**`, `toolchains/android-wear-shared-core.json` | `build_info_exposes_exact_readiness_pins`, `readiness_is_exact_and_fail_closed`, toolchain validator |
| Validation and typed bounded errors | Core and UniFFI facade sources; core/preparation/materialization schemas and contracts | Boundary/malformed tests, `typed_contract_bounds_survive_exported_boundary`, `CORE-002` |
| Logical paths and deterministic identities | Core path planning/UUIDv5 implementation and contract vectors | Rust path/identity tests; Swift admission tests reject divergent tokens, calendars, timezones, uppercase HTTP(S), frontmatter order, filename bounds, and boundary whitespace |
| Template/frontmatter/Markdown bytes and hashes | Core renderer plus production Swift oracle consumers under `VoxboardCaptureCore` | `swift-m2-oracle-v1.json`, coherent oracle regeneration, `CORE-001`, editor/writer production-consumer tests |
| Bounded materialization sessions | Core input/seal/drain/finalize/cancel state machine | Exact chunk/aggregate/sequence tests, typed receipts, 25-run hosted materialization campaign |
| Terminal resource release | `MaterializationSession.release_captured_resources`; streams dropped after materialization and all captured input/streams/output/descriptors dropped at finalization, failure, or cancellation | `tests::terminal_transitions_release_all_captured_resources`, explicitly required by hosted `CORE-005` execution |
| Panic containment | Release profiles use unwind; UniFFI catches and maps panics without changing the process-global hook | Exact release `panic_is_contained`; source-hook mutation test |
| Rust unit/golden/malformed/property coverage | `crates/vox-core/src/lib.rs` tests and `crates/vox-core/tests/m2_core.rs` | Rust workspace and MSRV suites; named exact hosted tests |
| Committed pinned Swift/Kotlin bindings | `generated/swift/**`, `generated/kotlin/**`, xtask, generation/normalization scripts | `scripts/check-bindings.sh`; `CORE-003`; SwiftPM generated copy is byte-identical |
| Android source-built libraries | `scripts/build-android-cdylibs.sh` and governed NDK/Rust targets | Hosted build and direct retained ELF inspection for four required ABIs |
| Static Apple XCFramework | Apple build/merge/normalize scripts | Hosted source build and retained Mach-O/archive/XCFramework/plist/header/modulemap inspection |
| No committed M2 binaries | Only generated language/header sources are tracked | Scoped `git ls-files` check returns no M2 `.so`, `.a`, or XCFramework binary |
| Handwritten Swift wrapper and adapter | `Packages/VoxboardShared/Sources/VoxCoreRust/VoxCoreRust.swift`, `VoxCoreGenerated`, `VoxCoreFFI`, `CaptureCoreEnginePolicy.swift` | Swift package compilation, focused wrapper/policy tests, binding drift gate |
| Side-effect-free Apple shadow | `CapturePipeline.capture` resolves one immutable route before quota/filesystem/attachment/queue/success boundaries; shadow returns legacy authority | `CaptureCoreEnginePolicyTests`, complete build-bound isolation checks, `CORE-005` |
| Privacy-safe mismatch reporting | `CaptureCoreComparison` reports equality facts only | Diagnostic schemas, exact diagnostics, no-content/path tests, `INV-PRIVACY-DIAGNOSTICS` |
| Governed hosted producer | `.github/workflows/core-rust-ci.yml` and `run-m2-hosted-evidence.sh` | Exact workflow/job/orchestrator validator and successful live hosted run |
| Authenticated hosted provenance | `Packages/contracts/scripts/github_actions_oidc.py` | Stdlib-only RS256/JWKS verification, bounded runtime token host, exact immutable identity claims and mutation tests |
| Retained functional/performance/native evidence | Core-exit, materialization, native-build, and package-inspection scripts plus validation schemas | Exact campaign/archive/external inventories and independent post-download revalidation |

## Exit-gate results

| Case/gate | Result |
| --- | --- |
| `CORE-001` exact Swift/Rust path, bytes, and hash parity | Passed |
| `CORE-002` unsupported versions and policies fail closed | Passed |
| `CORE-003` generated binding regeneration has zero byte drift | Passed |
| `CORE-004` readiness pins every independent version/hash | Passed |
| `CORE-005` Apple shadow is legacy-authoritative and side-effect-free | Passed |
| `PERF-003` 1 MiB nearest-rank p95 | 12.748167 ms, limit 100 ms |
| `PERF-003` 256 MiB additional RSS | 2,048,000 bytes, limit 67,108,864 bytes |
| `PERF-003` maximum FFI chunk | 1,048,576 bytes, exact limit |
| `PERF-003` aggregate coverage | Exact 1, 16, and 256 MiB runs; maximum 268,435,456 bytes |
| `PERF-008` Android arm64-v8a | 2,732,328 bytes, limit 12,582,912 |
| `PERF-008` Android armeabi-v7a | 1,701,160 bytes, limit 10,485,760 |
| `PERF-008` Android x86_64 | 2,855,592 bytes, limit 14,680,064 |
| `PERF-008` Android x86 | 2,142,108 bytes, limit 12,582,912 |
| `PERF-008` Apple XCFramework aggregate | 18,665,072 bytes, limit 62,914,560 |
| `PERF-008` Apple slices | 6,328,272 and 12,336,800 bytes, per-slice limit 15,728,640 |

The materialization receipt contains exactly 25 runs: one warm-up, twenty independent
1 MiB latency runs, three aggregate-coverage runs, and one dedicated 256 MiB RSS run.
The RSS run retained 1,338 unfiltered samples; its largest adjacent gap was 6,216,166 ns,
within the declared 10 ms cadence.

The package record is the honest first `initialCandidate`: six absolute leaves and no
zero-byte predecessor or fabricated growth percentage. Future adoption remains subject
to the monotonic baseline registry and authenticated hosted-evidence approval policy.

## Commands and verification surfaces

The exact qualified source was checked in a clean detached worktree with:

```text
Packages/vox-core-rust/scripts/generate-oracle-fixtures.sh
python3 Packages/contracts/scripts/validate_toolchain.py
cargo fmt --all -- --check
cargo test --workspace --locked
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo +1.87.0 test --locked -p vox-core -p vox-core-uniffi
Packages/vox-core-rust/scripts/check-bindings.sh
cargo test --release --locked -p vox-core-uniffi panic_is_contained -- --exact
swift test --filter CaptureCoreEnginePolicyTests
swift test --filter CapturePipelineTests
swift test --filter MarkdownDocumentEditorTests
./scripts/test-project-contracts.sh
git diff --check
```

Results included 7 core unit tests, 17 M2 integration tests, 4 UniFFI tests, 12 engine
policy tests, 25 pipeline tests, 17 editor tests, and 64 project-contract tests. The
project-contract suite reported 163 governed files, 86 fixtures, 270 capabilities,
3 mirrors, 6 roles, 3 providers, 26 cases, and 23 gates.

The canonical hosted job additionally installed the pinned Rust/NDK/Apple targets,
built the four Android libraries and two Apple archive leaves, executed all governed
CORE/PERF producers, validated the complete campaign, and uploaded only after that
validation passed.

## Independent retained-artifact audit

The final artifact was downloaded through GitHub's authenticated artifact API. Its
locally computed ZIP SHA-256 exactly matched the upload action's logged digest. The ZIP
contained 121 files and no symlinks. GitHub omits empty directories, so the empty
`campaign/approvals` directory was reconstructed locally before re-running the validator;
no retained file bytes were changed.

The post-download audit then re-ran the full campaign validator against the exact clean
qualified repository revision and retained authenticated identity facts. It recomputed
all evidence/aggregate hashes, source inventories, executable hashes, materialization
controls/inputs/outputs/chunks/drains, ELF/Mach-O/archive/XCFramework structure,
header/modulemap bytes, raw canonical USTAR headers/order/checksums/padding/termination,
and exact external inventory. Result: passed, 7/7 required tuples.

This post-download run does not pretend to mint a second OIDC attestation. Live OIDC
authentication occurred inside canonical job `94891366115`; the independent audit binds
the downloaded bytes to its GitHub-published artifact digest and retained exact identity.

## Independent review

- Final evidence/authentication/native review at predecessor `4cc2e0d` passed with no
  blocker/high finding; its canonical hosted run also passed.
- A final core review found two high issues not covered by that run: boundary-whitespace
  path divergence and terminal captured-buffer retention. M2 remained open.
- Both were fixed, covered by named governed tests, and re-reviewed at clean revision
  `3bb9c304fa76a3b873b94b74a38d3fb6744903c7` (byte-equivalent implementation later
  cherry-picked to the qualified main lineage). Focused review `6052ca08` and delta
  review `59a4bc43` both returned **PASS — no blocker/high findings**.
- The exact main-line successor `450abca...` differs only in coherent oracle provenance
  ancestry and then passed the clean local suites plus canonical hosted and Apple CI.

## Boundaries preserved

- Apple production authority remains `legacy`; `shadow` is side-effect-free and `rust`
  remains test-only behind the unpromoted commit barrier.
- Rust owns deterministic bounded validation/planning/rendering/hashing/reduction only.
  Native code retains persistence, quota, filesystem, attachments, queues, lifecycle,
  permissions, credentials, billing, receipts, and wearable transports.
- No network transcription, enrichment, geocoding, inference, user content, real device
  identity, provider approval, signature, or physical campaign was fabricated.
- `releaseGate` and package-baseline adoption remain intentionally disabled until an
  authenticated approval verifier is configured. Hosted technical milestone closure is
  not a release approval.
- Swift and Kotlin resource mirrors remain planned unless their named executable consumer
  is present; only the executed Rust mirror is required.

M2 is complete. M3 may begin only by committing its exact JDK/Gradle/AGP/Kotlin/SDK,
build-tools, and Compose pins and preserving the implementation-plan boundaries above.
