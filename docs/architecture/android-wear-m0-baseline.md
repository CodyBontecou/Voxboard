# Android/Wear Shared-Core M0 Baseline

Status: **M0 complete — committed, fresh-checkout verified, and hosted Apple CI passed**

Implementation plan: `docs/android-wear-shared-core-implementation-plan.md`

## Provenance

| Item | Pinned value |
|---|---|
| Vox.md planning and implementation-start parent | `b50167aebb959e394908af3a5949f43fa88d6265` (`Prepare Vox.md 2.1 release`) |
| Recording queue introduction | `ed0fbf0f680cc7ace6a51fbf1ea1a419242d9234` (`Add durable cross-platform recording queue`), an ancestor of the baseline |
| Health.md architecture precedent | `c70de9201ab7cfbadf2442183dfba23c0d248478` |
| M0 implementation baseline | `6d453e7c4cc60fda0fb2cb9d9399c8d92873b7d0` (`Attest deterministic M0 fixture provenance`); `f8098dc` is the initial M0 commit |
| Fixture-producing implementation revision | `6d453e7c4cc60fda0fb2cb9d9399c8d92873b7d0`; the manifest separately hashes the final generator source |

Health.md references are read from the pinned commit with `git show`/`git cat-file`, not from uncommitted state in a neighboring checkout. The patterns being adopted are the native/Rust ownership boundary, independently versioned contracts, generated-binding policy, exact fixture comparisons, immutable commit barrier, and `legacy`/`shadow`/`rust` rollout. Health-domain DTOs and renderer profiles are not copied.

### Exact Health.md precedent surface

The following files are the M0-recorded precedent at commit
`c70de9201ab7cfbadf2442183dfba23c0d248478`:

| File at pinned revision | Adopted precedent |
|---|---|
| `docs/architecture/adr-0001-shared-rust-uniffi-core.md` | Native/platform ownership boundary and coarse UniFFI API |
| `docs/architecture/shared-core-m5-rendering-baseline.md` | Bounded sessions, frozen observations, artifact plans, and native commits |
| `docs/architecture/shared-core-m6-rollout-runbook.md` | Per-operation `legacy`/`shadow`/`rust`, durable engine pins, and fail-closed rollback |
| `docs/architecture/shared-core-m7-protocol-baseline.md` | Transport-independent protocol authority while sockets, credentials, lifecycle, persistence, and side effects remain native |
| `Packages/contracts/README.md` and `Packages/contracts/manifest.json` | Independently versioned inventories, fixtures, mirrors, provenance, and drift validation |
| `packages/healthmd-core-rust/Cargo.toml` | Rust workspace/package/lint convention; Rust MSRV 1.85, edition 2024, UniFFI exactly 0.32.0 |
| `packages/healthmd-core-rust/scripts/generate-swift-bindings.sh` | Checked, locked xtask-based Swift binding generation |
| `packages/healthmd-core-rust/scripts/generate-kotlin-bindings.sh` | Rust 1.88.0 binding toolchain and normalized Kotlin output |
| `.github/workflows/core-rust-ci.yml` | Rust 1.85 MSRV gate; Rust 1.88 test/clippy/binding generation gate |
| `.github/workflows/apple-ci.yml` and `.github/workflows/android-ci.yml` | Platform packaging, binding drift, and consumer test topology |
| `apps/android/gradle/wrapper/gradle-wrapper.properties` and `apps/android/gradle/libs.versions.toml` | Gradle 8.11.1, AGP 8.9.1, Kotlin 2.1.0 precedent only; Vox.md will pin its own reviewed versions at M1 |
| `apps/apple/Packages/HealthMdCoreRust/Package.swift` | Local committed XCFramework wrapper package shape (Swift tools 5.9) |

Tool versions above are precedent pins, not silently inherited Vox.md dependencies.
M1 must choose and commit Vox.md-owned versions explicitly.

The baseline commit contains the intended recording queue and store implementation in:

- `Packages/VoxboardShared/Sources/VoxboardShared/RecordingJobStore.swift`
- `Packages/VoxboardShared/Sources/VoxboardShared/RecordingJobQueue.swift`
- `Packages/VoxboardShared/Sources/VoxboardShared/RecordingFlow.swift`
- `Voxboard/PersistentRecorder.swift`
- `Voxboard/VoxboardApp.swift`

The initial M0 commit records `b50167a` as its parent. Fixture provenance records the deterministic-codec revision `6d453e7c4cc60fda0fb2cb9d9399c8d92873b7d0`; `b50167a` and `f8098dc` are not represented as the final fixture-producing codec revision.

## Supported Apple baseline

| Product | Deployment target | Verification surface |
|---|---:|---|
| iPhone/iPad app and extensions | iOS 17.6 | `Voxboard` and `VoxboardTests` shared schemes |
| macOS companion | macOS 14.0 | `Voxboard Mac` shared scheme |
| Apple Watch app and widget | watchOS 10.0 | `Voxboard Watch` shared scheme |
| `VoxboardShared` Swift package | iOS 17, macOS 14, watchOS 10 | `Packages/VoxboardShared/Package.swift` |

The implementation baseline is validated with Xcode 26.6 (build 17F113) and Swift 6.3.3. CI uses the hosted `macos-26` image and explicitly selects Xcode 26.6; changing that pin requires a reviewed baseline update. Simulator builds disable signing; they do not validate App Groups, distribution profiles, microphone/background behavior, StoreKit accounts, or physical-device execution.

## M0 verification surfaces

`.github/workflows/apple-ci.yml` provides independent gates for:

1. `scripts/test-project-contracts.sh` on Linux.
2. Both Swift package test targets on macOS.
3. The app-hosted iOS `VoxboardTests` suite. Building its host transitively compiles the iOS app, keyboard, Share extension, widget/control/Live Activity target, Watch app, and Watch widget.
4. An unsigned native macOS app build.
5. Watch-target codec tests plus an unsigned Watch app and Watch widget build.

`Voxboard.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` and `Packages/VoxboardShared/Package.resolved` pin current dependency revisions. CI refuses a SwiftPM resolution that modifies the package lock. Compiled binaries and DerivedData are not committed.

## Required M0 artifacts

| Artifact | Purpose | Current status |
|---|---|---|
| `docs/android-wear-shared-core-implementation-plan.md` | Program contract and milestone gates | Authored; must be committed with implementation work |
| `docs/architecture/android-wear-m0-capabilities.json` | Atomic iPhone/iPad/Watch capability, setting, surface, recovery action, and persisted-store ledger | Implemented structural ledger; all 28 persisted-store capabilities have complete machine-validated format/dimension evidence |
| `scripts/validate-android-wear-m0.py` | Validate capability evidence, 49 source-enum inventories, 15 persisted-key source inventories, dependencies, and acceptance mappings | Implemented |
| `Packages/VoxboardShared/Tests/Fixtures/Persistence/v1/` | Synthetic raw legacy bytes and expected decode behavior | Implemented 150-entry corpus; all 29 persisted formats classify all 10 required dimensions, with every cell executed or explicitly not applicable |
| `docs/architecture/android-wear-m0-fixture-evidence.md` | Distinguish executable production-codec evidence from remaining compatibility-matrix gaps | Implemented; local format matrix complete and baseline/hosted/device gates explicit |
| `VoxboardPersistenceFixtures` executable | Generate and validate production-codec fixtures without reading user state | Implemented for package-owned surfaces; app-target and Watch-only codecs are executed by their native test targets |
| `.github/workflows/apple-ci.yml` | Repeatable Apple compile/test gate | Passed all five hosted jobs at `c173f3b90a03a1d11f563a7a2ddb9682f9ceb0c7` |

## Hosted Apple CI attestation

- Final tested revision: `c173f3b90a03a1d11f563a7a2ddb9682f9ceb0c7`.
- Successful workflow: [Apple CI run 31673674485](https://github.com/CodyBontecou/vox.md/actions/runs/31673674485).
- Hosted toolchain: Xcode 26.6 (`17F113`), Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`, `clang-2100.1.1.101`).
- Successful jobs: repository contracts, shared Swift package tests and fixture validation, iOS app-hosted tests, macOS build, and Watch tests/build.
- Physical-device, pairing, signing, upload, StoreKit/account, storage-pressure, and system-service behavior remains external; simulator CI does not claim those outcomes.

## Baseline rules

- Fixtures use only fixed UUIDs, fixed timestamps, synthetic relative paths/content, arbitrary bookmark bytes, and generated silent audio. They must never read production App Group containers, standard defaults, Documents, contacts, photos, location, microphone, or WCSession.
- Every committed fixture entry carries a SHA-256 and byte count. Package validation exercises all current negative files and production package settings consumers; app-hosted tests execute the committed toolbar and Watch fixtures.
- Existing Foundation JSON/property-list formats remain legacy compatibility inputs. Adding an internal Rust DTO version never changes them implicitly.
- Security-scoped bookmark bytes, absolute sandbox paths, localized error strings, UTI identifiers, and Apple transport dictionaries are platform-bound legacy fields, not portable canonical data.
- Default Foundation persistence currently encodes `Date` as numeric seconds relative to 2001-01-01, `Data` as base64, UUIDs as strings, and raw enums as strings. Tests using ISO-8601 are not wire-byte evidence.
- Unknown keyed JSON fields are currently accepted and usually dropped on typed rewrite. This behavior must be frozen as legacy evidence and must not become the forward-compatible shared contract policy.
- M0 introduces no Rust or Android authority.

## Exit-gate accounting

M0 is not complete merely because local tests pass. It closes only after:

- the plan and M0 artifacts are committed on a clean implementation baseline;
- Apple CI passes from a fresh checkout;
- every persisted format named by M0 has synthetic provenance, positive/negative compatibility fixtures, and executable validation through its actual production consumer;
- the machine ledger has no unmapped shipped capability when checked against README, source enums/settings, target graph, and the recording-queue audit;
- unresolved physical-device, signing, upload, and account matrices remain explicitly reported rather than being inferred from simulator CI.
